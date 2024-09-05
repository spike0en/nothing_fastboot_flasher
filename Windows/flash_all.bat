@echo off
setlocal enabledelayedexpansion

title Nothing Phone Fastboot ROM Flasher

echo #######################################
echo # Nothing Phone Fastboot Flasher #
echo #######################################

cd %~dp0

:: Download platform tools if they don't exist
if not exist platform-tools-latest (
    curl --ssl-no-revoke -L https://dl.google.com/android/repository/platform-tools-latest-windows.zip -o platform-tools-latest.zip
    Call :UnZipFile "%~dp0platform-tools-latest" "%~dp0platform-tools-latest.zip"
    del /f /q platform-tools-latest.zip
)

set fastboot=.\platform-tools-latest\platform-tools\fastboot.exe
if not exist %fastboot% (
    echo Error: Fastboot executable not found. Aborting.
    pause
    exit /b
)
%fastboot% reboot bootloader
timeout /t 6
:: Detect device type (Phone 1 or Phone 2)
%fastboot% getvar product 2>&1 | findstr /i "taro" > nul
if %errorlevel% equ 0 (
    set device=phone2
    echo Device detected: Nothing Phone 2
) else (
    %fastboot% getvar product 2>&1 | findstr /i "lahaina" > nul
    if %errorlevel% equ 0 (
        set device=phone1
        echo Device detected: Nothing Phone 1
    ) else (
        echo Error: Unknown device. Aborting.
        pause
        exit /b
    )
)

:: Define partitions based on device
if "%device%" equ "phone1" (
    set boot_partitions=boot vendor_boot dtbo
    set firmware_partitions=abl aop bluetooth cpucp devcfg dsp dtbo featenabler hyp imagefv keymaster modem multiimgoem qupfw shrm tz uefisecapp xbl xbl_config
    set logical_partitions=system system_ext product vendor odm
    set vbmeta_partitions=vbmeta_system
) else if "%device%" equ "phone2" (
    set boot_partitions=boot vendor_boot dtbo recovery
    set firmware_partitions=abl aop aop_config bluetooth cpucp devcfg dsp featenabler hyp imagefv keymaster modem multiimgoem multiimgqti qupfw qweslicstore shrm tz uefi uefisecapp xbl xbl_config xbl_ramdump
    set logical_partitions=system system_ext product vendor vendor_dlkm odm
    set vbmeta_partitions=vbmeta_system vbmeta_vendor
)


:: Check for missing files before flashing
echo Checking for missing image files...
set missing_files=
for %%i in (%boot_partitions% %firmware_partitions% %logical_partitions% %vbmeta_partitions%) do (
    if not exist %%i.img (
        set missing_files=!missing_files! %%i.img
    )
)

if defined missing_files (
    echo Warning: The following files are missing: !missing_files!
    choice /m "Do you want to continue flashing without these files? (Y/N)"
    if errorlevel 2 (
        echo Aborting flashing process.
        pause
        exit /b
    ) else (
        echo Proceeding. We are not responsible for any damage to your device.
        
        :: If the user chose to proceed (Y), offer second confirmation
        choice /m "Are you sure you want to proceed without the missing files? (Y/N)"
        if errorlevel 2 (
            echo Aborting flashing process after second prompt.
            pause
            exit /b
        ) else (
            echo Proceeding. We are not responsible for any damage to your device.
        )
    )
) else (
    echo All necessary image files are present.
)


:: Check for fastboot devices
echo #############################
echo # CHECKING FASTBOOT DEVICES #
echo #############################
%fastboot% devices
if %errorlevel% neq 0 (
    echo Error: No fastboot devices detected. Aborting.
    pause
    exit /b
)

:: Check current active slot
%fastboot% getvar current-slot 2>&1 | find /c "current-slot: a" > tmpFile.txt
set /p active_slot= < tmpFile.txt
del /f /q tmpFile.txt
if %active_slot% equ 0 (
    echo #############################
    echo # CHANGING ACTIVE SLOT TO A #
    echo #############################
    call :SetActiveSlot
)

:: Data formatting
echo ###################
echo # FORMATTING DATA #
echo ###################
choice /m "Wipe Data? (Y/N)"
if %errorlevel% equ 1 (
    echo Please ignore "Did you mean to format this partition?" warnings.
    call :ErasePartition userdata
    call :ErasePartition metadata
) else (
    echo Skipping data wipe.
)

:: Flash boot partitions
echo ############################
echo # FLASHING BOOT PARTITIONS #
echo ############################
set slot=a
choice /m "Flash images on both slots? (Y/N)"
if %errorlevel% equ 1 (
    set slot=all
) else (
    set slot=a
)

call :FlashPartitions %boot_partitions% %slot%

:: Reboot to fastbootd
echo ##########################             
echo # REBOOTING TO FASTBOOTD #       
echo ##########################
%fastboot% reboot fastboot
if %errorlevel% neq 0 (
    echo Error: Failed to reboot to fastbootd. Aborting.
    pause
    exit /b
)

:: Flash firmware partitions
echo #####################
echo # FLASHING FIRMWARE #
echo #####################
call :FlashPartitions %firmware_partitions% %slot%

:: Flash vbmeta partitions
echo ###################
echo # FLASHING VBMETA #
echo ###################
set disable_avb=0
choice /m "Disable android verified boot? (Y/N)"
if %errorlevel% equ 1 (
    set disable_avb=1
)

call :FlashVbmeta %vbmeta_partitions% %slot% %disable_avb%

:: Flash logical partitions
echo ###############################
echo # FLASHING LOGICAL PARTITIONS #
echo ###############################
if not exist super.img (
    if exist super_empty.img (
        call :WipeSuperPartition
    ) else (
        call :ResizeLogicalPartition
    )
    call :FlashPartitions %logical_partitions% %slot%
) else (
    call :FlashImage super super.img
)

:: Final reboot
echo #############
echo # REBOOTING #
echo #############
choice /m "Reboot to system? (Y/N)"
if %errorlevel% equ 1 (
    %fastboot% reboot
) else (
    echo Skipping reboot.
)

echo ########
echo # DONE #
echo ########
echo Stock firmware restored.
echo You may now optionally re-lock the bootloader if you haven't disabled android verified boot.

pause
exit /b

:: Function definitions

:UnZipFile
set vbs="%temp%\_.vbs"
if exist %vbs% del /f /q %vbs%
>%vbs%  echo Set fso = CreateObject("Scripting.FileSystemObject")
>>%vbs% echo If NOT fso.FolderExists("%~1") Then
>>%vbs% echo fso.CreateFolder("%~1")
>>%vbs% echo End If
>>%vbs% echo set objShell = CreateObject("Shell.Application")
>>%vbs% echo set FilesInZip=objShell.NameSpace(fso.GetAbsolutePathName("%~2")).items
>>%vbs% echo objShell.NameSpace(fso.GetAbsolutePathName("%~1")).CopyHere(FilesInZip)
cscript //nologo %vbs%
if exist %vbs% del /f /q %vbs%
exit /b

:SetActiveSlot
%fastboot% --set-active=a
if %errorlevel% neq 0 (
    echo Error: Failed to switch to slot A. Aborting.
    pause
    exit /b
)
exit /b

:ErasePartition
%fastboot% erase %~1
if %errorlevel% neq 0 (
    echo Error: Erasing %~1 partition failed.
    call :Choice "Continue flashing? (Y/N)"
)
exit /b

:FlashImage
if exist %~2 (
    %fastboot% flash %~1 %~2
    if %errorlevel% neq 0 (
        echo Error: Flashing %~2 failed.
        call :Choice "Continue flashing? (Y/N)"
    )
) else (
    echo Warning: %~2 not found, skipping.
)
exit /b

:FlashPartitions
for %%i in (%~1) do (
    if %~2 equ all (
        for %%s in (a b) do (
            call :FlashImage %%i_%%s %%i.img
        )
    ) else (
        call :FlashImage %%i %%i.img
    )
)
exit /b

:FlashVbmeta
for %%i in (%~1) do (
    if %~3 equ 1 (
        call :FlashImage %%i "--disable-verity --disable-verification"
    ) else (
        call :FlashImage %%i %%i.img
    )
)
exit /b

:WipeSuperPartition
%fastboot% wipe-super super_empty.img
if %errorlevel% neq 0 (
    echo Error: Wiping super partition failed. Attempting fallback.
    call :ResizeLogicalPartition
)
exit /b

:ResizeLogicalPartition
for %%i in (%junk_logical_partitions%) do (
    for %%s in (a b) do (
        call :DeleteLogicalPartition %%i_%%s-cow
        call :DeleteLogicalPartition %%i_%%s
    )
)
for %%i in (%logical_partitions%) do (
    for %%s in (a b) do (
        call :DeleteLogicalPartition %%i_%%s-cow
        call :DeleteLogicalPartition %%i_%%s
        call :CreateLogicalPartition %%i_%%s 1
    )
)
exit /b

:DeleteLogicalPartition
%fastboot% delete-logical-partition %~1
if %errorlevel% neq 0 (
    echo Error: Deleting logical partition %~1 failed.
    call :Choice "Continue flashing? (Y/N)"
)
exit /b

:CreateLogicalPartition
%fastboot% create-logical-partition %~1 %~2
if %errorlevel% neq 0 (
    echo Error: Creating logical partition %~1 failed.
    call :Choice "Continue flashing? (Y/N)"
)
exit /b

:Choice
choice /m "%~1"
if %errorlevel% equ 2 (
    exit /b
)
exit /b
