@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul && (set "PY=py -3") || (set "PY=python")
%PY% --version >nul 2>nul || (
  echo Python 3 is not installed. Get it from https://www.python.org/downloads/ and tick "Add to PATH".
  pause
  exit /b 1
)
set /p PS4IP=Enter your jailbroken PS4's IP address:
echo.
echo Applying protocol 2121 (0x849) to BO1 on %PS4IP% ...
%PY% protocol_patch.py %PS4IP% apply 0x849
echo.
echo Checking result:
%PY% protocol_patch.py %PS4IP% status
echo.
echo If every line shows 0x849, start a LAN match on the PS4, then join from the PS5.
pause
