[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'src/MacOSPlatformProvider.psm1') -Force
Register-MmtlMacOSPlatform -RepositoryRoot $repositoryRoot
& (Join-Path $repositoryRoot 'common/src/Launcher.ps1') @Arguments
exit $LASTEXITCODE
