@echo off
setlocal
cd /d "%~dp0"
echo ===== Revit MCP setup: pyRevit 7.0.0 + RevitMCP + Claude Desktop =====
echo.
echo Close Revit before you continue.
echo.
echo   1 - Test run (shows the plan, changes nothing)
echo   2 - Install
echo   3 - Install and also set up Python and pyRevit CLI (if missing)
echo   4 - Remove the revitmcp entry from the Claude Desktop config
echo.
set "CHOICE="
set /p CHOICE=Choose 1-4: 
set "ARGS="
set "OK="
if "%CHOICE%"=="1" (set "ARGS=-WhatIf" & set "OK=1")
if "%CHOICE%"=="2" (set "ARGS=" & set "OK=1")
if "%CHOICE%"=="3" (set "ARGS=-InstallPython -InstallCli" & set "OK=1")
if "%CHOICE%"=="4" (set "ARGS=-RemoveClaudeEntry" & set "OK=1")
if not defined OK (
  echo Invalid choice.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-RevitMCP.ps1" %ARGS%
echo.
pause
