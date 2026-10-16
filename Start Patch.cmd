@echo off
rem Opens the patch menu. PowerShell is built into Windows, nothing to install.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Patch-BO1.ps1"
pause
