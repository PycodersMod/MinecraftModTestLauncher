@echo off
setlocal
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MMTL.ps1" %*
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MMTL.ps1" %*
)
if errorlevel 1 echo MMTL exited with an error. See the message above.
if "%MMTL_NO_PAUSE%"=="1" exit /b %errorlevel%
pause
