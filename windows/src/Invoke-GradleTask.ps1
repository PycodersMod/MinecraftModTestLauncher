[CmdletBinding()]
param([string]$LaunchPlanB64)
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $PSScriptRoot 'WindowsPlatformProvider.psm1') -Force
Register-MmtlWindowsPlatform -RepositoryRoot $repositoryRoot
& (Join-Path $repositoryRoot 'common/src/Invoke-GradleTask.ps1') -LaunchPlanB64 $LaunchPlanB64
exit $LASTEXITCODE
