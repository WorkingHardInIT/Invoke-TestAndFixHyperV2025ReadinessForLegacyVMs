@echo off
echo.
echo ============================================================
echo   Hyper-V 2025 ACPI Fix for Windows Server 2012 R2 / 2016 RTM
echo   - Adds MSFT1000 (VMBus) and MSFT1002 (GenCounter)
echo   - Auto-detects ControlSet
echo   - Creates SYSTEM hive backup
echo ============================================================
echo.

:: --- Step 1: Detect Windows drive ---
echo Detecting Windows installation drive...
set WINDRV=

for %%d in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%d:\Windows\System32\Config\SYSTEM (
        set WINDRV=%%d:
    )
)

if "%WINDRV%"=="" (
    echo ERROR: Could not find Windows installation drive.
    echo Aborting.
    exit /b 1
)

echo Windows installation found on %WINDRV%
echo.

:: --- Step 2: Backup SYSTEM hive ---
echo Creating SYSTEM hive backup...
copy "%WINDRV%\Windows\System32\Config\SYSTEM" "%WINDRV%\Windows\System32\Config\SYSTEM.bak"
if errorlevel 1 (
    echo ERROR: Backup failed. Aborting.
    exit /b 1
)
echo Backup created: SYSTEM.bak
echo.

:: --- Step 3: Load SYSTEM hive ---
echo Loading SYSTEM hive into HKLM\TempHive...
reg load HKLM\TempHive "%WINDRV%\Windows\System32\Config\SYSTEM"
if errorlevel 1 (
    echo ERROR: Failed to load SYSTEM hive. Aborting.
    exit /b 1
)
echo Hive loaded.
echo.

:: --- Step 4: Detect active ControlSet ---
echo Detecting active ControlSet...
for /f "tokens=3" %%a in ('reg query HKLM\TempHive\Select /v Current') do set CS=ControlSet00%%a

if "%CS%"=="" (
    echo ERROR: Could not determine active ControlSet.
    reg unload HKLM\TempHive
    exit /b 1
)

echo Active ControlSet: %CS%
echo.

:: --- Step 5: Apply ACPI fixes ---
echo Applying ACPI fixes...

echo - Cloning VMBus -> MSFT1000
reg copy HKLM\TempHive\%CS%\Enum\ACPI\VMBus HKLM\TempHive\%CS%\Enum\ACPI\MSFT1000 /s /f

echo - Cloning Hyper_V_Gen_Counter_V1 -> MSFT1002
reg copy HKLM\TempHive\%CS%\Enum\ACPI\Hyper_V_Gen_Counter_V1 HKLM\TempHive\%CS%\Enum\ACPI\MSFT1002 /s /f

echo ACPI fixes applied.
echo.

:: --- Step 6: Unload hive ---
echo Unloading SYSTEM hive...
reg unload HKLM\TempHive
echo Hive unloaded.
echo.

echo ============================================================
echo   FIX COMPLETE
echo   You may now reboot the VM.
echo ============================================================
echo.
pause