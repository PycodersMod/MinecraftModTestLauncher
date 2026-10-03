[CmdletBinding()]
param([string[]]$Path)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$platformRoot=$null
if($env:RUNNER_OS){$platformRoot=switch($env:RUNNER_OS){'Windows'{'windows'}'Linux'{'linux'}'macOS'{'macos'}default{throw "未知 CI 平台：$env:RUNNER_OS"}}}
else{$platformRoot=switch([Runtime.InteropServices.RuntimeInformation]::OSPlatform){default{$null}};if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){$platformRoot='windows'}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$platformRoot='linux'}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$platformRoot='macos'}}
if(-not $platformRoot){throw '无法识别当前测试平台。'}
$commonPlatform=Join-Path $repositoryRoot 'common/src/Platform/Platform.psm1'
$providerName=switch($platformRoot){'windows'{'WindowsPlatformProvider.psm1'}'linux'{'LinuxPlatformProvider.psm1'}'macos'{'MacOSPlatformProvider.psm1'}}
$providerModule=Join-Path $repositoryRoot "$platformRoot/src/$providerName"
Import-Module $providerModule -Force
$registerCommand=switch($platformRoot){'windows'{'Register-MmtlWindowsPlatform'}'linux'{'Register-MmtlLinuxPlatform'}'macos'{'Register-MmtlMacOSPlatform'}}
& $registerCommand -RepositoryRoot $repositoryRoot
Import-Module $commonPlatform -Force
$env:MMTL_PLATFORM_ENTRYPOINT=Join-Path $repositoryRoot "$platformRoot/launcher.ps1"
$env:MMTL_REPO_ROOT=$repositoryRoot
$env:MMTL_COMMON_ROOT=Join-Path $repositoryRoot 'common'
if(-not $Path){$Path=@((Join-Path $repositoryRoot 'common/tests'),(Join-Path $repositoryRoot "$platformRoot/tests"))}
Invoke-Pester -Path $Path -CI


