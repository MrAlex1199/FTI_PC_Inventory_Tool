@echo off
title Install FTI Enterprise Security Certificate
echo ========================================================
echo   Function International (FTI) - Certificate Installer
echo ========================================================
echo.
echo Installing security certificate to Trusted Root Certification Authorities...
certutil -addstore -f "Root" "%~dp0FTI_Enterprise_Certificate.cer"
echo.
if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] Certificate installed! Windows Defender and SmartScreen will trust FTI_PC_Inventory.exe.
) else (
    echo [NOTICE] Please run this batch file as Administrator to install certificate.
)
echo.
pause