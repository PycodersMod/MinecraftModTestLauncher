BeforeAll {
    $script:commonRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:commonRoot 'src/Config.psm1') -Force
}

Describe '场景 CLI 覆盖解析与合并' {
    It '解析客户端数量、传输、离线名称和受管世界覆盖并记录来源' {
        (Get-Command ConvertFrom-MmtlScenarioCliOverrides -ErrorAction SilentlyContinue) | Should -Not -BeNull
        $result=ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--client-count','4','--multiplayer','integrated-lan','--host-name','MatrixHost','--guest-name-pattern','Matrix_{index}','--world','goal-world')
        $result.values.clientCount | Should -Be 4
        $result.values.transport | Should -BeExactly 'IntegratedLAN'
        $result.values.hostName | Should -BeExactly 'MatrixHost'
        $result.values.guestNamePattern | Should -BeExactly 'Matrix_{index}'
        $result.values.world | Should -BeExactly 'goal-world'
        $result.sources.clientCount | Should -BeExactly 'CommandLine'
    }

    It '拒绝重复参数、缺值、未知选项、非法数量和未知传输' {
        (Get-Command ConvertFrom-MmtlScenarioCliOverrides -ErrorAction SilentlyContinue) | Should -Not -BeNull
        { ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--client-count','2','--client-count','3') } | Should -Throw '*CLI_ARGUMENT_DUPLICATE*'
        { ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--host-name') } | Should -Throw '*CLI_ARGUMENT_VALUE_REQUIRED*'
        { ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--unknown','x') } | Should -Throw '*CLI_ARGUMENT_UNKNOWN*'
        { ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--client-count','two') } | Should -Throw '*CONFIG_CLIENT_COUNT_INVALID*'
        { ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--multiplayer','remote') } | Should -Throw '*CONFIG_TRANSPORT_INVALID*'
    }

    It '合并时 CLI 覆盖 Profile，未覆盖值仍来自 Profile，并把 Auto 解析为 LAN' {
        (Get-Command Merge-MmtlScenarioConfiguration -ErrorAction SilentlyContinue) | Should -Not -BeNull
        $profile=[pscustomobject]@{project='demo';clientCount=2;identity=[pscustomobject]@{kind='Offline';hostName='ProfileHost';guestNamePattern='Guest_{index}'};multiplayer=[pscustomobject]@{transport='Auto'};worldName='profile-world'}
        $overrides=ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--client-count','3','--world','cli-world')
        $effective=Merge-MmtlScenarioConfiguration -Profile $profile -Overrides $overrides -ProfileName 'matrix' -SourceConfigVersion 3
        $effective.clientCount | Should -Be 3
        $effective.transport | Should -BeExactly 'IntegratedLAN'
        $effective.mode | Should -BeExactly 'IntegratedLAN'
        $effective.identity.hostName | Should -BeExactly 'ProfileHost'
        $effective.world.name | Should -BeExactly 'cli-world'
        $effective.provenance.valueSources.clientCount | Should -BeExactly 'CommandLine'
        $effective.provenance.valueSources.hostName | Should -BeExactly 'Profile'
        $effective.provenance.valueSources.world | Should -BeExactly 'CommandLine'
    }

    It '无覆盖时默认单客户端；None 冲突失败，Dedicated 仅在显式配置时可选' {
        (Get-Command Merge-MmtlScenarioConfiguration -ErrorAction SilentlyContinue) | Should -Not -BeNull
        $profile=[pscustomobject]@{project='demo'}
        $empty=ConvertFrom-MmtlScenarioCliOverrides -Arguments @()
        $single=Merge-MmtlScenarioConfiguration -Profile $profile -Overrides $empty -ProfileName 'default' -SourceConfigVersion 3
        $single.clientCount | Should -Be 1
        $single.transport | Should -BeExactly 'None'
        $conflict=ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--client-count','2','--multiplayer','none')
        { Merge-MmtlScenarioConfiguration -Profile $profile -Overrides $conflict -ProfileName 'default' -SourceConfigVersion 3 } | Should -Throw '*CONFIG_SCENARIO_CLIENT_COUNT_CONFLICT*'
        $dedicated=ConvertFrom-MmtlScenarioCliOverrides -Arguments @('--client-count','3','--multiplayer','dedicated')
        $dedicatedEffective=Merge-MmtlScenarioConfiguration -Profile $profile -Overrides $dedicated -ProfileName 'server-check' -SourceConfigVersion 3
        $dedicatedEffective.mode | Should -BeExactly 'Dedicated'
        $dedicatedEffective.clientCount | Should -Be 3
    }
}
