BeforeAll {
    $script:repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repositoryRoot 'common/src/Config.psm1') -Force
}

Describe 'Linux launcher scenario CLI contract' {
    It 'preserves the Linux launcher argument vector when forwarding to the shared launcher' {
        $path = Join-Path $script:repositoryRoot 'linux/launcher.ps1'
        $source = Get-Content -LiteralPath $path -Raw
        $source | Should -Match '\[Parameter\(ValueFromRemainingArguments=\$true\)\]\[string\[\]\]\$Arguments'
        $source | Should -Match "common/src/Launcher\.ps1.*@Arguments"
        (Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'linux/launcher.sh') -Raw) | Should -Match '\$@'
        (Get-Content -LiteralPath (Join-Path $script:repositoryRoot 'common/launcher-posix.sh') -Raw) | Should -Match '\$@'
    }

    It 'defaults to one offline client and applies explicit CLI overrides on top of a version 3 profile' {
        $profile = [pscustomobject]@{ project = 'fixture'; configVersion = 3 }
        $empty = ConvertFrom-MmtlScenarioCliOverrides -Arguments @()
        $single = Merge-MmtlScenarioConfiguration -Profile $profile -Overrides $empty -ProfileName 'single' -SourceConfigVersion 3
        $single.clientCount | Should -Be 1
        $single.mode | Should -BeExactly 'Single'
        $single.transport | Should -BeExactly 'None'
        $single.identity.kind | Should -BeExactly 'Offline'

        $overrides = ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--client-count', '3', '--host-name', 'LinuxHost')
        $effective = Merge-MmtlScenarioConfiguration -Profile $profile -Overrides $overrides -ProfileName 'matrix' -SourceConfigVersion 3
        $effective.clientCount | Should -Be 3
        $effective.mode | Should -BeExactly 'IntegratedLAN'
        $effective.identity.hostName | Should -BeExactly 'LinuxHost'
        $effective.provenance.valueSources.clientCount | Should -BeExactly 'CommandLine'
    }
}
