[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$baselineRoot=[IO.Path]::GetFullPath($PSScriptRoot)
Import-Module (Join-Path $baselineRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
Register-MmtlWindowsPlatform -RepositoryRoot $baselineRoot
if(-not (Get-Command Invoke-Pester -ErrorAction SilentlyContinue)){throw 'PESTER_REQUIRED: install Pester 5 or newer in the current PowerShell environment'}
$result=Invoke-Pester -Path @((Join-Path $baselineRoot 'common/tests'),(Join-Path $baselineRoot 'windows/tests')) -Output Detailed -PassThru
if($result.FailedCount -gt 0){exit 1}
exit 0
