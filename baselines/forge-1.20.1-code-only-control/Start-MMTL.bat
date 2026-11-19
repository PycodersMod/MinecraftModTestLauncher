@echo off
setlocal EnableExtensions
where.exe pwsh.exe >nul 2>nul
if errorlevel 1 (
  echo MMTL requires PowerShell 7 ^(pwsh.exe^). Install PowerShell 7 and retry.
  exit /b 9009
)
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-MMTL.ps1" %*
set "MMTL_EXIT_CODE=%ERRORLEVEL%"
if not "%MMTL_EXIT_CODE%"=="0" echo MMTL exited with code %MMTL_EXIT_CODE%. See the message above.
if "%MMTL_NO_PAUSE%"=="1" exit /b %MMTL_EXIT_CODE%
pause
exit /b %MMTL_EXIT_CODE%
