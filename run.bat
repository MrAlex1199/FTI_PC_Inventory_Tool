@echo off
setlocal
title FTI PC Inventory Tool

:: Kill any stuck previous instances
taskkill /F /IM FTI_PC_InventoryV2.exe >nul 2>&1
taskkill /F /IM FTI_PC_Inventory.exe >nul 2>&1

if exist "%LOCALAPPDATA%\FTI_PC_Inventory_Tool\dist\FTI_PC_Inventory.exe" (
    echo Starting latest compiled executable...
    start "" "%LOCALAPPDATA%\FTI_PC_Inventory_Tool\dist\FTI_PC_Inventory.exe"
    exit /b
)

if exist "E:\FTI_PC_Inventory.exe" (
    echo Starting latest compiled executable from root...
    start "" "E:\FTI_PC_Inventory.exe"
    exit /b
)

if exist "%TEMP%\FTI_PC_Inventory.exe" (
    echo Starting compiled executable from TEMP...
    start "" "%TEMP%\FTI_PC_Inventory.exe"
    exit /b
)

echo Launching via PowerShell Web Engine...
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\AppServer.ps1"
