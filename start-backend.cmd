@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Starting GLM Coding Helper backend...
powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\one_click_start.ps1" -Target cpu -Port 8888
pause
