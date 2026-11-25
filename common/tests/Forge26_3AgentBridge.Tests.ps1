BeforeAll {
    $script:repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:bridgeRoot = Join-Path $script:repositoryRoot 'common/agent/bridges/forge-26.3'
    Import-Module (Join-Path $script:repositoryRoot 'common/src/Agent/AgentProvider.psm1') -Force
}

Describe 'Forge 26.3 exact Agent bridge' {
    It 'pins the latest frozen Forge candidate, Java 25, and Gradle 9.7.1' {
        $build = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'build.gradle') -Raw
        $wrapper = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'gradle/wrapper/gradle-wrapper.properties') -Raw
        $build | Should -Match 'net\.minecraftforge:forge:26\.3-66\.0\.9'
        $build | Should -Match 'JavaLanguageVersion\.of\(25\)'
        $wrapper | Should -Match 'gradle-9\.7\.1-bin\.zip'
    }

    It 'declares exact 26.3 Forge and Minecraft runtime bounds' {
        $metadata = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'src/main/resources/META-INF/mods.toml') -Raw
        $metadata | Should -Match 'versionRange="\[66,67\)"'
        $metadata | Should -Match 'versionRange="\[26\.3,26\.4\)"'
    }

    It 'publishes the integrated server only through LAN scope and the loopback mixin' {
        $agentRoot = Join-Path $script:bridgeRoot 'src/main/java/org/pycodersmod/mmtl/agent'
        $events = Get-Content -LiteralPath (Join-Path $agentRoot 'MmtlForgeClientEvents.java') -Raw
        $invoker = Get-Content -LiteralPath (Join-Path $agentRoot 'mixin/IntegratedServerInvoker.java') -Raw
        $loopback = Get-Content -LiteralPath (Join-Path $agentRoot 'mixin/IntegratedServerLoopbackMixin.java') -Raw
        $events | Should -Match 'MultiplayerScope\.LAN'
        $invoker | Should -Match 'MultiplayerScope'
        $loopback | Should -Match 'MinecraftServer\$MultiplayerScope;I'
        $loopback | Should -Match 'selectBindAddress'
    }

    It 'builds and stages an exact Forge 26.3 provider manifest with the artifact hash' {
        $build = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'build.gradle') -Raw
        $build | Should -Match "providerId:\s*'forge-26\.3'"
        $build | Should -Match "minecraftVersions:\s*\['26\.3'\]"
        $build | Should -Match "loaderVersions:\s*\['26\.3-66\.0\.9'\]"
        $build | Should -Match 'SHA-256'
        $build | Should -Match 'FMLModType'
        $build | Should -Match 'Java 8 bytecode'
    }

    It 'resolves only the exact staged Forge 26.3 Loader provider and verifies its artifact hash' {
        $agentRoot = Join-Path $script:repositoryRoot 'common/agent'
        $provider = Get-MmtlAgentProviderStatus -AgentRoot $agentRoot -LoaderId Forge -MinecraftVersion '26.3' -LoaderVersion '26.3-66.0.9'
        $provider.status | Should -BeExactly 'Supported'
        $provider.providerId | Should -BeExactly 'forge-26.3'
        $provider.minJavaMajor | Should -Be 25
        $provider.roles | Should -Contain 'Host'
        $provider.roles | Should -Contain 'Guest'
        $provider.sha256 | Should -Match '^[a-f0-9]{64}$'
        (Get-MmtlAgentProviderStatus -AgentRoot $agentRoot -LoaderId Forge -MinecraftVersion '26.3' -LoaderVersion '26.3-66.0.8').status | Should -BeExactly 'Unsupported'
    }
}
