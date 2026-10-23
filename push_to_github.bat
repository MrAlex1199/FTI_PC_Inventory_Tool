@echo off
setlocal
title Push FTI PC Inventory Tool to GitHub

echo ===================================================
echo   Pushing FTI PC Inventory Tool to GitHub...
echo ===================================================

powershell -NoProfile -ExecutionPolicy Bypass -Command "& {
    `$staging = Join-Path `$env:TEMP 'fti_inventory_git_staging'
    `$srcRoot = '%~dp0'
    if (-not (Test-Path `$staging)) {
        Write-Host 'Staging directory not found. Initializing...' -ForegroundColor Yellow
        New-Item -ItemType Directory -Path `$staging -Force | Out-Null
        Set-Location `$staging
        git clone https://github.com/MrAlex1199/FTI_PC_Inventory_Tool.git .
    }
    
    # Sync files
    Copy-Item (Join-Path `$srcRoot '.gitignore') `$staging -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path `$srcRoot 'README.md') `$staging -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path `$srcRoot 'build.ps1') `$staging -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path `$srcRoot 'run.bat') `$staging -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path `$srcRoot 'Get-PCInventory_*.md') `$staging -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path `$srcRoot 'src') `$staging -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path `$srcRoot 'tools') `$staging -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path `$srcRoot 'assets') `$staging -Recurse -Force -ErrorAction SilentlyContinue

    Set-Location `$staging
    git add .
    `$status = git status --porcelain
    if (-not `$status) {
        Write-Host 'No new changes to commit.' -ForegroundColor Green
    } else {
        git commit -m 'update: latest changes and improvements'
        git push origin main
        Write-Host 'Push completed successfully!' -ForegroundColor Green
    }
}"

echo.
echo View repository at: https://github.com/MrAlex1199/FTI_PC_Inventory_Tool
pause
