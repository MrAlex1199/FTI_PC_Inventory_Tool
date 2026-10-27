@echo off
setlocal
title FTI PC Inventory Tool

echo ========================================================
echo   FTI PC Inventory Tool - Enterprise Launcher
echo ========================================================
echo.

:: Kill any stuck previous instances
taskkill /F /IM FTI_PC_InventoryV2.exe >nul 2>&1
taskkill /F /IM FTI_PC_Inventory.exe >nul 2>&1

:: Allow passing --engine to force direct script launch
if "%1"=="--engine" goto RUN_POWERSHELL

if exist "%LOCALAPPDATA%\FTI_PC_Inventory_Tool\dist\FTI_PC_Inventory.exe" (
    echo Starting standalone application...
    start "" "%LOCALAPPDATA%\FTI_PC_Inventory_Tool\dist\FTI_PC_Inventory.exe"
    exit /b
)

if exist "E:\FTI_PC_Inventory.exe" (
    echo Starting standalone application from root...
    start "" "E:\FTI_PC_Inventory.exe"
    exit /b
)

:RUN_POWERSHELL
echo Launching via PowerShell Web Engine directly...
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\AppServer.ps1"
