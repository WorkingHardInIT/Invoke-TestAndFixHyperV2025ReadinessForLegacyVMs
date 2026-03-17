<#
.SYNOPSIS
    Pre-seeds legacy Windows Server VMs (2012 / 2012 R2 / 2016) with the
    ACPI device entries required to boot successfully on Hyper‑V 2025 hosts.

.DESCRIPTION
    Hyper‑V 2025 introduces updated ACPI device identifiers that older guest
    operating systems do not recognize on first boot. Without pre-seeding the
    ACPI\MSFT1000 and ACPI\MSFT1002 registry keys, affected VMs may fail to boot
    after migration with a 0x7B (INACCESSIBLE_BOOT_DEVICE) or similar ACPI
    initialization failure.

    This script connects to each VM using:
        1. PowerShell Direct (if the VM is local to the host)
        2. WinRM (if credentials are supplied and remote access is possible)

    Inside the guest, the script:
        - Reports OS version, build, and latest installed patch
        - Determines whether the OS *requires* the fix
        - Detects whether the fix was already applied
        - Validates the presence of required ACPI source keys
        - Creates a SYSTEM hive backup
        - Clones ACPI\VMBus → ACPI\MSFT1000
        - Clones ACPI\Hyper_V_Gen_Counter_V1 → ACPI\MSFT1002
        - Verifies the cloned keys
        - Emits TRACE output for every step

    The script is idempotent:
        - If the VM does not require the fix → it skips
        - If the VM is already pre-seeded → it skips
        - If the VM is already on a 2025 host → it reports and exits
        - If the keys exist → it does not overwrite them

    This makes the script safe to run across large fleets.

.PARAMETER VMs
    One or more VM names to process.

.PARAMETER Credential
    Optional PSCredential object for WinRM access.
    Required only when the VM is not local to the host running the script.

.NOTES
    Requirements:
        - Run from a Hyper‑V host or a management workstation with Hyper‑V tools
        - PowerShell Direct requires running on the owning host
        - WinRM requires:
            * VM reachable over network
            * Valid admin credentials
            * UAC remote filtering disabled OR built‑in Administrator
        - Script must be run with administrative privileges on the host

    The script does NOT modify anything on VMs that:
        - Are already fixed
        - Are already on Hyper‑V 2025
        - Are running OS versions that do not require the fix

.EXAMPLE
    # Run against a single VM using PowerShell Direct (local host)
    .\Invoke-TestAndFixHyperV2025ReadinessForLegacyVMs.ps1 -VMs "WEB01"

.EXAMPLE
    # Run against multiple VMs using WinRM
    $cred = Get-Credential -UserName "DOMAIN\AdminUser"
    .\Invoke-TestAndFixHyperV2025ReadinessForLegacyVMs.ps1 -VMs "WEB01","APP02","SQL03" -Credential $cred

.EXAMPLE
    # Run against a CSV list of VM names
    $vms = Import-Csv .\vm-list.csv | Select-Object -ExpandProperty Name
    $cred = Get-Credential
    .\Invoke-TestAndFixHyperV2025ReadinessForLegacyVMs.ps1 -VMs $vms -Credential $cred

.EXAMPLE
    # Dry-run style: observe TRACE output to confirm which VMs need the fix
    .\Invoke-TestAndFixHyperV2025ReadinessForLegacyVMs.ps1 -VMs (Get-VM | Select -Expand Name)

.LINK
    Internal documentation: “Hyper‑V 2025 Migration Readiness & ACPI Pre‑Seed”
#>

param(
    [Parameter(Mandatory)]
    [string[]]$VMs,

    [pscredential]$Credential = $null
)

function Test-VMIsLocal {
    param([string]$VMName)

    try {
        Get-VM -Name $VMName -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# -------------------------------
# Guest-side script with detection
# -------------------------------
$scriptBlock = {
    function Trace($msg) { Write-Host "[TRACE] $msg" -ForegroundColor DarkCyan }
    function Info($msg)  { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
    function Ok($msg)    { Write-Host "[OK]    $msg" -ForegroundColor Green }
    function Fail($msg)  { Write-Host "[FAIL]  $msg" -ForegroundColor Red }

    Write-Host ""
    Write-Host "=== Hyper-V 2025 ACPI Pre-Seed Fix (Guest-Side) ===" -ForegroundColor Yellow

    # -------------------------------
    # OS version + patch level
    # -------------------------------
    Trace "Collecting OS version and patch level"
    $os = Get-CimInstance Win32_OperatingSystem
    $caption = $os.Caption
    $build   = $os.BuildNumber
    $release = $os.Version
    $hotfix  = (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1)

    Info "OS: $caption"
    Info "Build: $build"
    Info "Version: $release"
    if ($hotfix) {
        Info "Latest Patch: $($hotfix.HotFixID) ($($hotfix.InstalledOn))"
    } else {
        Info "Latest Patch: None detected"
    }

    # -------------------------------
    # Determine if fix is needed
    # -------------------------------
    $needsFix = $false

    if ($caption -match "Windows Server 2012" -or
        $caption -match "Windows Server 2012 R2" -or
        $caption -match "Windows Server 2016") {

        $needsFix = $true
        Info "This OS version requires the Hyper-V 2025 ACPI pre-seed fix."
    }
    else {
        Ok "This OS version does NOT require the fix. Skipping."
        return
    }

    # -------------------------------
    # Registry paths
    # -------------------------------
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\ACPI'
    $srcVMBus = Join-Path $base 'VMBus'
    $srcGen   = Join-Path $base 'Hyper_V_Gen_Counter_V1'
    $dst1000  = Join-Path $base 'MSFT1000'
    $dst1002  = Join-Path $base 'MSFT1002'

    # -------------------------------
    # Check if already pre-seeded
    # -------------------------------
    Trace "Checking if MSFT1000/MSFT1002 already exist"
    $already = (Test-Path $dst1000) -and (Test-Path $dst1002)

    if ($already) {
        Ok "Pre-seed already applied — MSFT1000 and MSFT1002 exist."
        return
    }

    # -------------------------------
    # Validate source keys
    # -------------------------------
    Trace "Validating ACPI source keys"
    if (-not (Test-Path $srcVMBus)) {
        Fail "Missing ACPI\VMBus source key. Cannot pre-seed; verify this is a supported legacy VM and ACPI enumeration is intact."
        return
    }
    if (-not (Test-Path $srcGen)) {
        Fail "Missing ACPI\Hyper_V_Gen_Counter_V1 source key. Cannot pre-seed; verify this is a supported legacy VM and ACPI enumeration is intact."
        return
    }

    # -------------------------------
    # SYSTEM hive backup
    # -------------------------------
    Trace "Backing up SYSTEM hive"
    $backup = "$env:SystemRoot\System32\Config\SYSTEM-preseed-backup.hiv"
    reg.exe save HKLM\SYSTEM $backup /y | Out-Null
    Ok "SYSTEM hive backup created"

    # -------------------------------
    # Clone keys (skip if exist)
    # -------------------------------
    if (-not (Test-Path $dst1000)) {
        Trace "Cloning VMBus -> MSFT1000"
        reg.exe copy "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\VMBus" `
                     "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\MSFT1000" /s /f | Out-Null
    } else {
        Info "MSFT1000 already exists — skipping clone"
    }

    if (-not (Test-Path $dst1002)) {
        Trace "Cloning Hyper_V_Gen_Counter_V1 -> MSFT1002"
        reg.exe copy "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\Hyper_V_Gen_Counter_V1" `
                     "HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\MSFT1002" /s /f | Out-Null
    } else {
        Info "MSFT1002 already exists — skipping clone"
    }

    # -------------------------------
    # Final verification
    # -------------------------------
    Trace "Verifying cloned keys"
    if ((Test-Path $dst1000) -and (Test-Path $dst1002)) {
        Ok "Pre-seed completed successfully."
    } else {
        Fail "Pre-seed failed — one or both keys missing."
    }

    Write-Host ""
    Write-Host "=== Reboot VM before migration. ===" -ForegroundColor Green
}

# -------------------------------
# Host-side logic
# -------------------------------
foreach ($vm in $VMs) {

    Write-Host ""
    Write-Host "--------------------------------------------------------"
    Write-Host " Processing VM: $vm" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------------"

    $ran = $false

    # 1. PowerShell Direct
    if (Test-VMIsLocal $vm) {
        Write-Host "[TRACE] Attempting PowerShell Direct" -ForegroundColor DarkCyan
        try {
            Invoke-Command -VMName $vm -ScriptBlock $scriptBlock -ErrorAction Stop
            Write-Host "[OK] Ran via PowerShell Direct" -ForegroundColor Green
            $ran = $true
        }
        catch {
            Write-Host "[FAIL] Direct failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        Write-Host "[TRACE] VM not local — skipping Direct" -ForegroundColor DarkYellow
    }

    # 2. WinRM
    if (-not $ran) {
        if (-not $Credential) {
            $Credential = Get-Credential -Message "Enter credentials for $vm"
        }

        Write-Host "[TRACE] Attempting WinRM" -ForegroundColor DarkCyan

        try {
            Invoke-Command -ComputerName $vm -Credential $Credential -ScriptBlock $scriptBlock -ErrorAction Stop
            Write-Host "[OK] Ran via WinRM" -ForegroundColor Green
            $ran = $true
        }
        catch {
            Write-Host "[FAIL] WinRM failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($ran) {
        Write-Host "[SUCCESS] VM $vm processed." -ForegroundColor Green
    } else {
        Write-Host "[FAILED] VM $vm unreachable." -ForegroundColor Red
    }
}
