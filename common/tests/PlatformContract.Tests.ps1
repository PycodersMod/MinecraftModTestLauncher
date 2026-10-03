Describe 'Platform provider' {
    It 'uses macOS spelling in public display while retaining the canonical enum' {
        $platformRoot = Split-Path -Leaf (Split-Path -Parent $env:MMTL_PLATFORM_ENTRYPOINT)
        $providerFile = switch ($platformRoot) { 'windows' {'WindowsPlatformProvider.psm1'} 'linux' {'LinuxPlatformProvider.psm1'} 'macos' {'MacOSPlatformProvider.psm1'} default { throw "Unknown platform root: $platformRoot" } }
        $registerCommand = switch ($platformRoot) { 'windows' {'Register-MmtlWindowsPlatform'} 'linux' {'Register-MmtlLinuxPlatform'} 'macos' {'Register-MmtlMacOSPlatform'} }
        Import-Module (Join-Path $env:MMTL_REPO_ROOT "$platformRoot/src/$providerFile") -Force
        & $registerCommand -RepositoryRoot $env:MMTL_REPO_ROOT
        Import-Module (Join-Path $env:MMTL_COMMON_ROOT 'src/Platform/Platform.psm1') -Force
        $names = @(Get-MmtlPlatformDisplayName -OS 'MacOS'; Get-MmtlPlatformDisplayName -OS 'Linux')
        $names[0] | Should -BeExactly 'macOS'
        $names[1] | Should -BeExactly 'Linux'
    }

    It 'provides identity and OS-specific defaults' {
        $platformRoot = Split-Path -Leaf (Split-Path -Parent $env:MMTL_PLATFORM_ENTRYPOINT)
        $providerFile = switch ($platformRoot) { 'windows' {'WindowsPlatformProvider.psm1'} 'linux' {'LinuxPlatformProvider.psm1'} 'macos' {'MacOSPlatformProvider.psm1'} default { throw "Unknown platform root: $platformRoot" } }
        $registerCommand = switch ($platformRoot) { 'windows' {'Register-MmtlWindowsPlatform'} 'linux' {'Register-MmtlLinuxPlatform'} 'macos' {'Register-MmtlMacOSPlatform'} }
        Import-Module (Join-Path $env:MMTL_REPO_ROOT "$platformRoot/src/$providerFile") -Force
        & $registerCommand -RepositoryRoot $env:MMTL_REPO_ROOT
        Import-Module (Join-Path $env:MMTL_COMMON_ROOT 'src/Platform/Platform.psm1') -Force
        $provider = $global:MmtlPlatformProvider
        $provider.OS | Should -BeIn @('Windows','Linux','MacOS')
        $provider.PathSeparator | Should -Be ([IO.Path]::DirectorySeparatorChar)
        $provider.PathListSeparator | Should -Be ([IO.Path]::PathSeparator)
        $provider.ExecutableSuffix | Should -BeIn @('.exe','')
        $provider.JavaExecutable | Should -BeIn @('java.exe','java')
        $provider.GradleWrapper | Should -BeIn @('gradlew.bat','gradlew')
        $provider.FabricRuntimeLink | Should -BeIn @('Native','Unsupported')
        $provider.DefaultRuntimeRoot | Should -Not -BeNullOrEmpty
    }

    It 'resolves runtime root with platform defaults and portable override' {
        $platformRoot = Split-Path -Leaf (Split-Path -Parent $env:MMTL_PLATFORM_ENTRYPOINT)
        $providerFile = switch ($platformRoot) { 'windows' {'WindowsPlatformProvider.psm1'} 'linux' {'LinuxPlatformProvider.psm1'} 'macos' {'MacOSPlatformProvider.psm1'} default { throw "Unknown platform root: $platformRoot" } }
        $registerCommand = switch ($platformRoot) { 'windows' {'Register-MmtlWindowsPlatform'} 'linux' {'Register-MmtlLinuxPlatform'} 'macos' {'Register-MmtlMacOSPlatform'} }
        Import-Module (Join-Path $env:MMTL_REPO_ROOT "$platformRoot/src/$providerFile") -Force
        & $registerCommand -RepositoryRoot $env:MMTL_REPO_ROOT
        Import-Module (Join-Path $env:MMTL_COMMON_ROOT 'src/Platform/Platform.psm1') -Force
        Import-Module (Join-Path $env:MMTL_COMMON_ROOT 'src/RuntimeManager.psm1') -Force
        $default = Resolve-MmtlRuntimeRoot -Path ''
        $provider = $global:MmtlPlatformProvider
        $default | Should -Be $provider.DefaultRuntimeRoot
        $portable = Resolve-MmtlRuntimeRoot -Path '' -Portable -LauncherRoot $TestDrive
        $portable | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive '.runtime')))
    }

    It 'exposes canonical path and link detection helpers' {
        $platformRoot = Split-Path -Leaf (Split-Path -Parent $env:MMTL_PLATFORM_ENTRYPOINT)
        $providerFile = switch ($platformRoot) { 'windows' {'WindowsPlatformProvider.psm1'} 'linux' {'LinuxPlatformProvider.psm1'} 'macos' {'MacOSPlatformProvider.psm1'} default { throw "Unknown platform root: $platformRoot" } }
        $registerCommand = switch ($platformRoot) { 'windows' {'Register-MmtlWindowsPlatform'} 'linux' {'Register-MmtlLinuxPlatform'} 'macos' {'Register-MmtlMacOSPlatform'} }
        Import-Module (Join-Path $env:MMTL_REPO_ROOT "$platformRoot/src/$providerFile") -Force
        & $registerCommand -RepositoryRoot $env:MMTL_REPO_ROOT
        Import-Module (Join-Path $env:MMTL_COMMON_ROOT 'src/Platform/Platform.psm1') -Force
        $result = [pscustomobject]@{Canonical=(Get-MmtlCanonicalPath -Path $TestDrive);IsLink=(Test-MmtlPathLink -Path $TestDrive);Inside=(Test-MmtlPlatformPathInsideRoot -Root $TestDrive -Target (Join-Path $TestDrive 'child'))}
        $result.Canonical | Should -Be ([IO.Path]::GetFullPath($TestDrive))
        $result.IsLink | Should -BeFalse
        $result.Inside | Should -BeTrue
    }
}
