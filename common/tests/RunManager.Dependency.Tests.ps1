BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:workspaceRoot = Split-Path -Parent $script:repoRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    $platformRoot=switch([Runtime.InteropServices.RuntimeInformation]::OSPlatform){default{$null}}
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){$platformRoot='windows'}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$platformRoot='linux'}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$platformRoot='macos'}
    $providerModule=switch($platformRoot){'windows'{Join-Path $script:workspaceRoot 'windows/src/WindowsPlatformProvider.psm1'}'linux'{Join-Path $script:workspaceRoot 'linux/src/LinuxPlatformProvider.psm1'}'macos'{Join-Path $script:workspaceRoot 'macos/src/MacOSPlatformProvider.psm1'}default{throw '无法识别测试平台。'}}
    $providerModuleObject=Import-Module $providerModule -Force -PassThru
    $registerName=switch($platformRoot){'windows'{'Register-MmtlWindowsPlatform'}'linux'{'Register-MmtlLinuxPlatform'}'macos'{'Register-MmtlMacOSPlatform'}}
    & $providerModuleObject.ExportedFunctions[$registerName] -RepositoryRoot $script:workspaceRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/RunManager.psm1') -Force
    $script:supportsNativeFabricLink = $platformRoot -eq 'windows'
}

Describe 'RunManager 模块依赖' {
    It '将 Gradle User Home 放在当前 RuntimeRoot 而不是用户默认目录' {
        $session=Join-Path $TestDrive 'portable-runtime/sessions/session-one'
        New-Item -ItemType Directory -Path $session -Force|Out-Null
        Get-MmtlGradleUserHomeForSession -SessionPath $session | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive 'portable-runtime/gradle-home')))
        { Get-MmtlGradleUserHomeForSession -SessionPath (Join-Path $TestDrive 'not-a-session/project') } | Should -Throw '*SESSION_PATH_INVALID_FOR_GRADLE_HOME*'
        $old=$env:MMTL_GRADLE_USER_HOME
        try {
            $env:MMTL_GRADLE_USER_HOME=Join-Path $TestDrive 'explicit-gradle-home'
            Get-MmtlGradleUserHomeForSession -SessionPath $session | Should -Be ([IO.Path]::GetFullPath($env:MMTL_GRADLE_USER_HOME))
            $env:MMTL_GRADLE_USER_HOME='relative-cache'
            { Get-MmtlGradleUserHomeForSession -SessionPath $session } | Should -Throw '*MMTL_GRADLE_USER_HOME_MUST_BE_ABSOLUTE*'
        } finally { $env:MMTL_GRADLE_USER_HOME=$old }
    }

    It '独立导入后可安全创建 Fabric Runtime junction' -Skip:(-not $script:supportsNativeFabricLink) {
        $root = Join-Path $TestDrive 'fabric-project'
        $session = Join-Path $TestDrive 'runtime\sessions\one'
        $runtime = Join-Path $session 'Dev'
        New-Item -ItemType Directory -Path $root, $runtime -Force | Out-Null

        $link = New-MmtlFabricRuntimeLink -ProjectRoot $root -SessionPath $session -TargetPath $runtime -Name 'client'
        try {
            (Get-Item -LiteralPath $link).LinkType | Should -Be 'Junction'
            [IO.Path]::GetFullPath((Get-Item -LiteralPath $link).Target) | Should -Be ([IO.Path]::GetFullPath($runtime))
        }
        finally {
            if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        }
    }
}
