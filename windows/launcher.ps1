[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'src/WindowsPlatformProvider.psm1') -Force
Register-MmtlWindowsPlatform -RepositoryRoot $repositoryRoot
& (Join-Path $repositoryRoot 'common/src/Launcher.ps1') @Arguments
exit $LASTEXITCODE
