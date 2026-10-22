@echo off
setlocal
title FTI PC Inventory Tool

if exist "dist\FTI_PC_Inventory.exe" (
    echo Starting compiled executable from dist...
    start "" "dist\FTI_PC_Inventory.exe"
    exit /b
)

if exist "%TEMP%\FTI_PC_Inventory.exe" (
    echo Starting compiled executable...
    start "" "%TEMP%\FTI_PC_Inventory.exe"
    exit /b
)

echo Launching via PowerShell Web Engine...
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\AppServer.ps1"
