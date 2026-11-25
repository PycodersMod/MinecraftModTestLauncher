BeforeAll {
    $script:commonRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:commonRoot 'src/Config.psm1') -Force
}

Describe '规范化启动场景配置' {
    It '把旧 v2 IntegratedLAN 和 Dedicated Profile 映射为对应客户端总数' {
        (Get-Command Resolve-MmtlScenarioProfile -ErrorAction SilentlyContinue) | Should -Not -BeNull
        $config = [pscustomobject]@{
            configVersion = 2; defaultProfile = 'lan'; javaHomes = [pscustomobject]@{}
            profiles = [pscustomobject]@{
                single = [pscustomobject]@{ project = 'demo'; mode = 'Single'; players = 1; hostUsername = 'Dev' }
                lan = [pscustomobject]@{ project = 'demo'; mode = 'IntegratedLAN'; players = 2; hostUsername = 'Host'; clientPrefix = 'Guest_' }
                dedicated = [pscustomobject]@{ project = 'demo'; mode = 'Dedicated'; players = 3; hostUsername = 'Host'; clientPrefix = 'Guest_' }
            }
        }
        $single = Resolve-MmtlScenarioProfile -Config $config -ProfileName 'single'
        $single.mode | Should -BeExactly 'Single'
        $single.clientCount | Should -Be 1
        $single.transport | Should -BeExactly 'None'
        $ambiguousLan=[pscustomobject]@{configVersion=2;defaultProfile='lan';javaHomes=[pscustomobject]@{};profiles=[pscustomobject]@{lan=[pscustomobject]@{project='demo';mode='IntegratedLAN';players=1}}}
        { Resolve-MmtlScenarioProfile -Config $ambiguousLan } | Should -Throw '*CONFIG_SCENARIO_CLIENT_COUNT_CONFLICT*'
        $lan = Resolve-MmtlScenarioProfile -Config $config -ProfileName 'lan'
        $lan.mode | Should -BeExactly 'IntegratedLAN'
        $lan.clientCount | Should -Be 2
        $lan.transport | Should -BeExactly 'IntegratedLAN'
        $lan.identity.kind | Should -BeExactly 'Offline'
        $dedicated = Resolve-MmtlScenarioProfile -Config $config -ProfileName 'dedicated'
        $dedicated.mode | Should -BeExactly 'Dedicated'
        $dedicated.clientCount | Should -Be 3
        $dedicated.transport | Should -BeExactly 'Dedicated'
    }

    It '解析 v3 Auto 配置的显式客户端数并保留配置来源' {
        (Get-Command Resolve-MmtlScenarioProfile -ErrorAction SilentlyContinue) | Should -Not -BeNull
        $config = [pscustomobject]@{
            configVersion = 3; defaultProfile = 'matrix'; javaHomes = [pscustomobject]@{}
            profiles = [pscustomobject]@{ matrix = [pscustomobject]@{
                project = 'demo'; clientCount = 4
                identity = [pscustomobject]@{ kind = 'Offline'; hostName = 'MMTL_Host'; guestNamePattern = 'MMTL_G{index}' }
                multiplayer = [pscustomobject]@{ transport = 'Auto' }
            } }
        }
        $effective = Resolve-MmtlScenarioProfile -Config $config -ProfileName 'matrix'
        $effective.clientCount | Should -Be 4
        $effective.mode | Should -BeExactly 'IntegratedLAN'
        $effective.transport | Should -BeExactly 'IntegratedLAN'
        $effective.identity.kind | Should -BeExactly 'Offline'
        $effective.provenance.profileName | Should -BeExactly 'matrix'
        $effective.provenance.sourceConfigVersion | Should -Be 3
    }

    It '未提供 clientCount 时使用一个离线单人客户端' {
        $config=[pscustomobject]@{configVersion=3;defaultProfile='default';javaHomes=[pscustomobject]@{};profiles=[pscustomobject]@{default=[pscustomobject]@{project='demo'}}}
        $effective=Resolve-MmtlScenarioProfile -Config $config
        $effective.clientCount | Should -Be 1
        $effective.mode | Should -BeExactly 'Single'
        $effective.transport | Should -BeExactly 'None'
        $effective.identity.kind | Should -BeExactly 'Offline'
        $effective.provenance.clientCountSource | Should -BeExactly 'BuiltInDefault'
    }

    It '拒绝未知离线身份类型及 Single 多窗口歧义' {
        (Get-Command Resolve-MmtlScenarioProfile -ErrorAction SilentlyContinue) | Should -Not -BeNull
        $config = [pscustomobject]@{
            configVersion = 3; defaultProfile = 'single'; javaHomes = [pscustomobject]@{}
            profiles = [pscustomobject]@{ single = [pscustomobject]@{
                project = 'demo'; clientCount = 2
                identity = [pscustomobject]@{ kind = 'Microsoft' }
                multiplayer = [pscustomobject]@{ transport = 'None' }
            } }
        }
        { Resolve-MmtlScenarioProfile -Config $config -ProfileName 'single' } | Should -Throw '*CONFIG_IDENTITY_KIND_UNSUPPORTED*'
        $config.profiles.single.identity.kind = 'Offline'
        { Resolve-MmtlScenarioProfile -Config $config -ProfileName 'single' } | Should -Throw '*CONFIG_SCENARIO_CLIENT_COUNT_CONFLICT*'
    }

    It '拒绝 v3 的无效数量、传输方式和与规范化路径冲突的旧 mode' {
        $config=[pscustomobject]@{configVersion=3;defaultProfile='p';javaHomes=[pscustomobject]@{};profiles=[pscustomobject]@{p=[pscustomobject]@{project='demo';clientCount=2;multiplayer=[pscustomobject]@{transport='Auto'}}}}
        $config.profiles.p.clientCount=0
        { Resolve-MmtlScenarioProfile -Config $config } | Should -Throw '*CONFIG_CLIENT_COUNT_INVALID*'
        $config.profiles.p.clientCount=2
        $config.profiles.p.multiplayer.transport='Remote'
        { Resolve-MmtlScenarioProfile -Config $config } | Should -Throw '*CONFIG_TRANSPORT_INVALID*'
        $config.profiles.p.multiplayer.transport='Auto'
        $config.profiles.p | Add-Member -NotePropertyName mode -NotePropertyValue 'Single'
        { Resolve-MmtlScenarioProfile -Config $config } | Should -Throw '*CONFIG_SCENARIO_MODE_CONFLICT*'
    }
}
