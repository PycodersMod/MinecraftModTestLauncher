BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src/Agent/AgentProvider.psm1') -Force
    Import-Module (Join-Path $root 'src/Agent/AgentEvents.psm1') -Force
}

Describe 'MMTL Agent Provider 与 Session 握手' {
    It 'validates the packaged Forge Agent provider and its staged artifact' {
        $baselineRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $status = Get-MmtlAgentProviderStatus -AgentRoot (Join-Path $baselineRoot 'common/agent') -LoaderId Forge -MinecraftVersion '1.20.1'
        $status.status | Should -BeExactly 'Supported'
        $status.providerId | Should -BeExactly 'forge-1.20.1'
        $status.sha256 | Should -BeExactly $status.sha256.ToLowerInvariant()
    }

    BeforeEach {
        $script:agentRoot = Join-Path $TestDrive 'agent-root'
        $script:providerRoot = Join-Path $script:agentRoot 'providers/forge-1.20.1'
        New-Item -ItemType Directory -Path $script:providerRoot -Force | Out-Null
        $script:artifact = Join-Path $script:providerRoot 'mmtl-agent.jar'
        [IO.File]::WriteAllBytes($script:artifact,[byte[]](1,3,3,7,9))
        $script:sha = (Get-FileHash -LiteralPath $script:artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = [ordered]@{
            schemaVersion = 1; providerId = 'forge-1.20.1'; loaderId = 'Forge'; minecraftVersions = @('1.20.1')
            agentVersion = '0.1.0'; artifact = 'providers/forge-1.20.1/mmtl-agent.jar'; sha256 = $script:sha
            minJavaMajor = 17; roles = @('Host','Guest','Client'); capabilities = @('IntegratedServerEvents','LanPublishObservation')
        }
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:providerRoot 'agent-manifest.json')
        $script:manifestPath = Join-Path $script:providerRoot 'agent-manifest.json'
        $script:session = Join-Path $TestDrive 'runtime/sessions/session_a'
        New-Item -ItemType Directory -Path $script:session -Force | Out-Null
        @{sessionId='session_a'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:session 'session.json')
        $script:token = 'session-nonce-' + [guid]::NewGuid().ToString('N')
    }

    It '按 Loader/Minecraft 版本匹配支持契约并验证工件 SHA-256' {
        $provider = Get-MmtlAgentProviderStatus -AgentRoot $script:agentRoot -LoaderId Forge -MinecraftVersion '1.20.1'
        $provider.status | Should -BeExactly 'Supported'
        $provider.agentVersion | Should -BeExactly '0.1.0'
        $provider.sha256 | Should -BeExactly $script:sha
        $provider.capabilities | Should -Contain 'LanPublishObservation'
        Test-Json -Json (Get-Content -LiteralPath $script:manifestPath -Raw) -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/agent-manifest-v1.schema.json') | Should -BeTrue
    }

    It '不支持的版本和缺失工件 fail closed' {
        (Get-MmtlAgentProviderStatus -AgentRoot $script:agentRoot -LoaderId Forge -MinecraftVersion '1.20.2').reason | Should -BeExactly 'AGENT_VERSION_UNSUPPORTED'
        Remove-Item -LiteralPath $script:artifact -Force
        (Get-MmtlAgentProviderStatus -AgentRoot $script:agentRoot -LoaderId Forge -MinecraftVersion '1.20.1').reason | Should -BeExactly 'AGENT_ARTIFACT_MISSING'
    }

    It '拒绝 SHA 不匹配、越界工件路径和不支持角色' {
        $manifestPath = Join-Path $script:providerRoot 'agent-manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.sha256 = '0' * 64
        $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
        (Get-MmtlAgentProviderStatus -AgentRoot $script:agentRoot -LoaderId Forge -MinecraftVersion '1.20.1').reason | Should -BeExactly 'AGENT_ARTIFACT_HASH_MISMATCH'
        $manifest.sha256 = $script:sha; $manifest.artifact = '../../outside.jar'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
        (Get-MmtlAgentProviderStatus -AgentRoot $script:agentRoot -LoaderId Forge -MinecraftVersion '1.20.1').reason | Should -BeExactly 'AGENT_MANIFEST_INVALID'
        $manifest.artifact = 'providers/forge-1.20.1/mmtl-agent.jar'; $manifest.roles = @('Server')
        $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath
        $provider = Get-MmtlAgentProviderStatus -AgentRoot $script:agentRoot -LoaderId Forge -MinecraftVersion '1.20.1'
        { New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Guest -SessionToken $script:token } | Should -Throw '*AGENT_ROLE_UNSUPPORTED*'
    }

    It '将受支持工件复制到 Session 并将 Agent 与 event sink 绑定在 Session 内' {
        $provider = Get-MmtlAgentProviderStatus -AgentRoot $script:agentRoot -LoaderId Forge -MinecraftVersion '1.20.1'
        { New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_b -Role Host -SessionToken $script:token } | Should -Throw '*AGENT_SESSION_ID_MISMATCH*'
        $forgedProvider = $provider.PSObject.Copy();$forgedProvider.artifactPath = Join-Path $TestDrive 'outside.jar'
        { New-MmtlAgentLaunchBinding -Provider $forgedProvider -SessionPath $script:session -SessionId session_a -Role Host -SessionToken $script:token } | Should -Throw '*AGENT_ARTIFACT_OUTSIDE_PROVIDER_ROOT*'
        $binding = New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Host -SessionToken $script:token

        Test-MmtlAgentPathInsideRoot -Root $script:session -Target $binding.artifactPath | Should -BeTrue
        (Get-MmtlAgentRuntimeModJars -ModJars @() -Binding $binding) | Should -Be @($binding.artifactPath)
        (Get-MmtlAgentRuntimeModJars -ModJars @($script:artifact) -Binding $binding) | Should -Be @($script:artifact,$binding.artifactPath)
        Test-MmtlAgentPathInsideRoot -Root $script:session -Target $binding.eventSink | Should -BeTrue
        (Get-FileHash -LiteralPath $binding.artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $script:sha
        $binding.jvmArgs -join ' ' | Should -Match 'mmtl\.agent\.sessionTokenFile='
        $binding.jvmArgs -join ' ' | Should -Not -Match [regex]::Escape($script:token)
        (Get-Content -LiteralPath (Join-Path $script:session 'agent/session-token.txt') -Raw) | Should -BeExactly $script:token
        $binding.PSObject.Properties.Name | Should -Not -Contain 'sessionToken'
        $binding.sessionNonceHash | Should -Be (([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:token)))).ToLowerInvariant())
        $lanBinding = New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Host -SessionToken $script:token -IntegratedLanPort 25565
        $lanBinding.jvmArgs | Should -Contain '-Dmmtl.agent.integratedLanPort=25565'
        $lanBinding.integratedLanPort | Should -Be 25565
        { New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Guest -SessionToken $script:token -IntegratedLanPort 25565 } | Should -Throw '*AGENT_LAN_PUBLISH_HOST_ONLY*'
        { New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Guest -SessionToken $script:token } | Should -Throw '*AGENT_GUEST_LOOPBACK_PORT_REQUIRED*'
        $guestBinding = New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Guest -SessionToken $script:token -ExpectedLoopbackPort 25565
        $guestBinding.jvmArgs | Should -Contain '-Dmmtl.agent.expectedLoopbackPort=25565'
        $worldBinding=New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Host -SessionToken $script:token -AutoCreateWorld -WorldName 'MMTL-Test' -WorldGameMode creative -WorldDifficulty peaceful -WorldSeed 42 -WorldAllowCommands
        $worldBinding.jvmArgs | Should -Contain '-Dmmtl.agent.autoCreateWorld=true'
        $worldBinding.jvmArgs | Should -Contain '-Dmmtl.agent.worldGameMode=creative'
        $worldBinding.jvmArgs | Should -Contain '-Dmmtl.agent.worldAllowCommands=true'
        $singleWorldBinding=New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Client -SessionToken $script:token -AutoCreateWorld -WorldName 'MMTL-Single'
        $singleWorldBinding.jvmArgs | Should -Contain '-Dmmtl.agent.autoCreateWorld=true'
        {New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Guest -SessionToken $script:token -ExpectedLoopbackPort 25565 -AutoCreateWorld} | Should -Throw '*AGENT_WORLD_CREATE_HOST_ONLY*'
        {New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $script:session -SessionId session_a -Role Host -SessionToken $script:token -AutoCreateWorld -WorldName '../outside'} | Should -Throw '*AGENT_WORLD_NAME_INVALID*'
    }

    It '验证 Agent Event nonce/session/role 并映射到 Runtime Event，Agent 错误归为基础设施' {
        $nonceHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:token)))).ToLowerInvariant()
        $line = [pscustomobject]@{schemaVersion=1;sessionId='session_a';role='Guest';eventId='evt-1';eventType='AGENT_ERROR';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$nonceHash;summary='agent hook failed';port=25565} | ConvertTo-Json -Compress
        Test-Json -Json $line -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/agent-event-v1.schema.json') | Should -BeTrue
        $event = ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId session_a -ExpectedRole Guest -ExpectedNonceHash $nonceHash -ProcessId 77 -ProcessIdentity 'start-77'
        $event.eventCode | Should -BeExactly 'AGENT_ERROR'
        $event.sourceType | Should -BeExactly 'Agent'
        $event.metadata.sourceCategory | Should -BeExactly 'MMTL_INFRASTRUCTURE'
        $event.metadata.port | Should -Be 25565
        { ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId session_b -ExpectedRole Guest -ExpectedNonceHash $nonceHash -ProcessId 77 -ProcessIdentity 'start-77' } | Should -Throw '*AGENT_EVENT_SESSION_MISMATCH*'
        $lineObject = $line | ConvertFrom-Json; $lineObject.eventType = 'LAN_PUBLISH_FAILED'; $line = $lineObject | ConvertTo-Json -Compress
        Test-Json -Json $line -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/agent-event-v1.schema.json') | Should -BeTrue
        $failedEvent=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId session_a -ExpectedRole Guest -ExpectedNonceHash $nonceHash -ProcessId 77 -ProcessIdentity 'start-77'
        $failedEvent.eventCode | Should -BeExactly 'LAN_PUBLISH_FAILED'
        $failedEvent.metadata.port | Should -Be 25565
        $expectedCodes=@{AGENT_STARTED='AGENT_STARTED';CLIENT_READY='AGENT_CLIENT_READY';CLIENT_INITIALIZED='CLIENT_INITIALIZED';GUEST_CONNECT_REQUESTED='GUEST_CONNECT_REQUESTED';GUEST_CONNECTION_FAILED='GUEST_CONNECTION_FAILED';GUEST_LOGIN_PACKET_RECEIVED='GUEST_LOGIN_PACKET_RECEIVED';GUEST_CHANNEL_STATE='GUEST_CHANNEL_STATE';WORLD_JOINED='AGENT_WORLD_JOINED';PLAYER_JOINED='PLAYER_JOINED';WORLD_CREATE_REQUESTED='WORLD_CREATE_REQUESTED';WORLD_CREATE_SUBMITTED='WORLD_CREATE_SUBMITTED';INTEGRATED_SERVER_READY='INTEGRATED_SERVER_READY';OFFLINE_AUTH_ENABLED='OFFLINE_AUTH_ENABLED';GUEST_CONNECTING='GUEST_CONNECTING';WORLD_JOIN_TIMEOUT='WORLD_JOIN_TIMEOUT';LAN_PUBLISH_TIMEOUT='LAN_PUBLISH_TIMEOUT';GUEST_JOIN_TIMEOUT='GUEST_JOIN_TIMEOUT'}
        foreach($eventType in $expectedCodes.Keys){$lineObject.eventType=$eventType;if($eventType -eq 'PLAYER_JOINED'){$lineObject|Add-Member -NotePropertyName playerName -NotePropertyValue 'Dev_1' -Force};$line=$lineObject|ConvertTo-Json -Compress;(ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId session_a -ExpectedRole Guest -ExpectedNonceHash $nonceHash -ProcessId 77 -ProcessIdentity 'start-77').eventCode | Should -BeExactly $expectedCodes[$eventType]}
        $line | Should -Not -Match [regex]::Escape($script:token)
    }

    It 'validates Guest handshake progress events and maps them into Runtime Events' {
        $nonceHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:token)))).ToLowerInvariant()
        $line = [pscustomobject]@{schemaVersion=1;sessionId='session_a';role='Guest';eventId='evt-handshake';eventType='GUEST_HANDSHAKE_PROGRESS';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$nonceHash;summary='handler=handleIndexedMessage packet=S2CRegistry sequence=4';port=25565} | ConvertTo-Json -Compress
        Test-Json -Json $line -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/agent-event-v1.schema.json') | Should -BeTrue
        $event = ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId session_a -ExpectedRole Guest -ExpectedNonceHash $nonceHash -ProcessId 77 -ProcessIdentity 'start-77'
        $event.eventCode | Should -BeExactly 'GUEST_HANDSHAKE_PROGRESS'
        $event.metadata.port | Should -Be 25565
    }

    It 'validates decoded Guest login packet events and maps them into Runtime Events' {
        $nonceHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:token)))).ToLowerInvariant()
        $line = [pscustomobject]@{schemaVersion=1;sessionId='session_a';role='Guest';eventId='evt-login-packet';eventType='GUEST_LOGIN_PACKET_RECEIVED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$nonceHash;summary='decoded inbound login packet=ClientboundCustomQueryPacket';port=25565} | ConvertTo-Json -Compress
        Test-Json -Json $line -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/agent-event-v1.schema.json') | Should -BeTrue
        $event = ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId session_a -ExpectedRole Guest -ExpectedNonceHash $nonceHash -ProcessId 77 -ProcessIdentity 'start-77'
        $event.eventCode | Should -BeExactly 'GUEST_LOGIN_PACKET_RECEIVED'
        $event.metadata.port | Should -Be 25565
    }

    It '为相同 Session 中的多个 Guest 使用独立事件文件' {
        $provider=Get-MmtlAgentProviderStatus -AgentRoot $script:agentRoot -LoaderId Forge -MinecraftVersion '1.20.1'
        $testToken='session-nonce-'+[guid]::NewGuid().ToString('N')
        $isolatedSession=Join-Path $script:session 'multiple-guests';New-Item -ItemType Directory -Path $isolatedSession -Force|Out-Null
        @{sessionId='session_a'}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $isolatedSession 'session.json')
        $guestOne=New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $isolatedSession -SessionId session_a -Role Guest -SessionToken $testToken -ExpectedLoopbackPort 25565 -InstanceId Guest-01
        $guestTwo=New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $isolatedSession -SessionId session_a -Role Guest -SessionToken $testToken -ExpectedLoopbackPort 25565 -InstanceId Guest-02
        $guestOne.eventSink | Should -Not -BeExactly $guestTwo.eventSink
        [IO.Path]::GetFileName($guestOne.eventSink) | Should -BeExactly 'guest-guest-01.jsonl'
        [IO.Path]::GetFileName($guestTwo.eventSink) | Should -BeExactly 'guest-guest-02.jsonl'
    }
}
