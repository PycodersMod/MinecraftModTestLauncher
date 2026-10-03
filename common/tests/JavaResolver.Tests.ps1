BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/JavaResolver.psm1') -Force
}

Describe 'Cross-platform Java resolver' {
    It 'resolves the current platform map before legacy Java homes' {
        $javaHomeFixture = Join-Path $TestDrive 'jdk'
        New-Item -ItemType Directory -Path (Join-Path $javaHomeFixture 'bin') -Force | Out-Null
        $javaName = (Get-MmtlPlatformProvider).JavaExecutable
        Set-Content -LiteralPath (Join-Path (Join-Path $javaHomeFixture 'bin') $javaName) -Value 'fixture'
        $config = [pscustomobject]@{javaHomesByPlatform=[pscustomobject]@{}}
        $config.javaHomesByPlatform | Add-Member -NotePropertyName (Get-MmtlPlatformProvider).OS -NotePropertyValue ([pscustomobject]@{'17'=$javaHomeFixture}) -Force
        $config | Add-Member -NotePropertyName javaHomes -NotePropertyValue ([pscustomobject]@{'17'='missing'}) -Force
        Resolve-MmtlJava -Config $config -Major 17 -SkipVersionCheck | Should -Be (Join-Path (Join-Path $javaHomeFixture 'bin') $javaName)
    }

    It 'does not silently choose an unconfigured Java home' {
        { Resolve-MmtlJava -Config ([pscustomobject]@{javaHomes=[pscustomobject]@{}}) -Major 17 } | Should -Throw
    }
}
