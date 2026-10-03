[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'src/LinuxPlatformProvider.psm1') -Force
Register-MmtlLinuxPlatform -RepositoryRoot $repositoryRoot
& (Join-Path $repositoryRoot 'common/src/Launcher.ps1') @Arguments
exit $LASTEXITCODE
