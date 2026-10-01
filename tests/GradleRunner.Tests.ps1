BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/GradleRunner.psm1') -Force
}

Describe 'Platform Gradle Wrapper' {
    It 'selects only the project wrapper and returns a POSIX shell invocation when needed' {
        $root = $TestDrive
        $provider = Get-MmtlPlatformProvider
        $wrapper = Join-Path $root $provider.GradleWrapper
        Set-Content -LiteralPath $wrapper -Value 'wrapper fixture'
        $project = [pscustomobject]@{Root=$root}
        $command = Get-MmtlGradleCommand -Project $project -Task build
        if ($provider.OS -eq 'Windows') { $command.File | Should -Be $wrapper }
        else { $command.File | Should -Be 'sh'; $command.Arguments[0] | Should -Be $wrapper }
        $command.Arguments | Should -Contain 'build'
    }
}
