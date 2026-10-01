BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/RuntimeManager.psm1') -Force
}

Describe 'Platform provider' {
    It 'provides identity and OS-specific defaults' {
        $provider = Get-MmtlPlatformProvider
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
        $default = Resolve-MmtlRuntimeRoot -Path ''
        $default | Should -Be (Get-MmtlPlatformProvider).DefaultRuntimeRoot
        $portable = Resolve-MmtlRuntimeRoot -Path '' -Portable -LauncherRoot $TestDrive
        $portable | Should -Be ([IO.Path]::GetFullPath((Join-Path $TestDrive '.runtime')))
    }

    It 'exposes canonical path and link detection helpers' {
        Get-MmtlCanonicalPath -Path $TestDrive | Should -Be ([IO.Path]::GetFullPath($TestDrive))
        Test-MmtlPathLink -Path $TestDrive | Should -BeFalse
        Test-MmtlPlatformPathInsideRoot -Root $TestDrive -Target (Join-Path $TestDrive 'child') | Should -BeTrue
    }
}
