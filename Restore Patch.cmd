@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
set /p PS4IP=Enter your jailbroken PS4's IP address:
echo.
echo Restoring the original protocol 2120 (0x848) ...
%PY% protocol_patch.py %PS4IP% restore
echo.
%PY% protocol_patch.py %PS4IP% status
echo.
echo Restarting BO1 on the PS4 also removes the patch completely.
pause
