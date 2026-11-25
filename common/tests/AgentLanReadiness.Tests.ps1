BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src/Agent/AgentProvider.psm1') -Force
    Import-Module (Join-Path $root 'src/Agent/AgentEvents.psm1') -Force
}

Describe 'MMTL Forge IntegratedLAN readiness gate' {
    BeforeEach {
        $script:session=Join-Path $TestDrive ('session-'+[guid]::NewGuid().ToString('N'))
        $script:eventPath=Join-Path $script:session 'agent-events/host.jsonl'
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:eventPath) -Force|Out-Null
        [IO.File]::WriteAllText($script:eventPath,'',[Text.UTF8Encoding]::new($false))
        $script:sessionId='session_a'
        $script:nonceHash='a'*64
        $script:port=25565
    }

    It '要求 Host LAN_PUBLISHED 携带发布时的世界身份' {
        $record=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='host-lan-incomplete';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='listener ready';port=$script:port;bindAddress='127.0.0.1'}
        {ConvertFrom-MmtlAgentEventLine -Line ($record|ConvertTo-Json -Compress) -ExpectedSessionId $script:sessionId -ExpectedRole Host -ExpectedNonceHash $script:nonceHash -ProcessId $PID -ProcessIdentity 'host-process'} | Should -Throw '*AGENT_LAN_PUBLISH_EVENT_INCOMPLETE*'
    }

    It '要求 Guest WORLD_JOINED 携带实际连接端口' {
        $record=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-world-no-port';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='guest entered world';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='guest-uuid'}
        {ConvertFrom-MmtlAgentEventLine -Line ($record|ConvertTo-Json -Compress) -ExpectedSessionId $script:sessionId -ExpectedRole Guest -ExpectedNonceHash $script:nonceHash -ProcessId $PID -ProcessIdentity 'guest-process'} | Should -Throw '*AGENT_WORLD_JOINED_EVENT_INCOMPLETE*'
    }

    It 'Single Client 必须收到当前 Session 的真实 WORLD_JOINED 才算进入受管世界' {
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Client';eventId='single-world-1';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='single client entered managed world';worldKey=$script:sessionId;dimensionKey='minecraft:overworld';playerIdentity='single-player-uuid'}
        [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $result=Wait-MmtlAgentWorldJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -ProcessId $PID -ExpectedWorldKey $script:sessionId -ExpectedDimensionKey 'minecraft:overworld'
        $result.ready | Should -BeTrue
        $result.world.worldKey | Should -BeExactly $script:sessionId
        $result.world.playerIdentity | Should -BeExactly 'single-player-uuid'
    }

    It '拒绝其他 world identity 的 Single WORLD_JOINED' {
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Client';eventId='single-world-wrong';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='wrong world';worldKey='another-session';dimensionKey='minecraft:overworld';playerIdentity='single-player-uuid'}
        [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentWorldJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -ProcessId $PID -TimeoutSeconds 1 -PollMilliseconds 100 -ExpectedWorldKey $script:sessionId -ExpectedDimensionKey 'minecraft:overworld'} | Should -Throw '*AGENT_WORLD_IDENTITY_MISMATCH*'
    }

    It '只有当前 Session Host nonce 的成功发布事件且 loopback 端口正在监听时才就绪' {
        $started=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='event-started';eventType='AGENT_STARTED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='agent started'}
        [IO.File]::AppendAllText($script:eventPath,(($started|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $record=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='event-1';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='listener ready';port=$script:port;bindAddress='127.0.0.1';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='world-1';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='host entered world';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
        [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        [IO.File]::AppendAllText($script:eventPath,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $result=Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -PortProbe {param($candidate) $candidate -eq 25565} -ListenerOwnerProbe {param($candidate) @($PID)}
        $result.ready | Should -BeTrue
        $result.bindAddress | Should -BeExactly '127.0.0.1'
        $result.event.metadata.port | Should -Be 25565
        $result.world.worldKey | Should -BeExactly 'world-session-a'
    }

    It '只有 LAN 发布但缺少同 Host WORLD_JOINED 身份事件时不得放行 Guest' {
        $record=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='event-lan-only';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='listener ready';port=$script:port;bindAddress='127.0.0.1';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
        [IO.File]::AppendAllText($script:eventPath,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -TimeoutSeconds 1 -PollMilliseconds 100 -ProcessId $PID -PortProbe {$true}} | Should -Throw '*AGENT_LAN_READY_TIMEOUT*'
    }

    It '拒绝 Host WORLD_JOINED 与 LAN_PUBLISHED 不同的世界身份' {
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='host-world';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='host entered world';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
        $lan=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='host-lan';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='listener ready';port=$script:port;bindAddress='127.0.0.1';worldKey='world-session-other';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
        [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"+($lan|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -PortProbe {$true} -ListenerOwnerProbe {param($candidatePort) @($PID)}} | Should -Throw '*AGENT_LAN_WORLD_IDENTITY_MISMATCH*'
    }

    It 'TCP 可连接但 listener PID 不属于受管 Host 进程树时拒绝就绪' {
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='world-owner-check';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='host entered world';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
        $lan=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='lan-owner-check';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='listener ready';port=$script:port;bindAddress='127.0.0.1';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
        [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"+($lan|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -PortProbe {$true} -ListenerOwnerProbe {param($candidatePort) @(999999)}} | Should -Throw '*AGENT_LAN_LISTENER_PROCESS_MISMATCH*'
    }

    It '真实 loopback listener 的 owner PID 可通过受管 Host 进程树交叉核验' {
        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
        try {
            $port=[int]$listener.LocalEndpoint.Port
            $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='world-real-owner';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='host entered world';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
            $lan=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='lan-real-owner';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='listener ready';port=$port;bindAddress='127.0.0.1';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='host-uuid'}
            [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"+($lan|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
            $result=Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $port -ProcessId $PID -TimeoutSeconds 3
            $result.ready | Should -BeTrue
            $result.port | Should -Be $port
        }finally{$listener.Stop()}
    }

    It 'Host process 已中断时立即终止 readiness wait' {
        {Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId 2147483000 -TimeoutSeconds 1 -PollMilliseconds 100 -PortProbe {$true}} | Should -Throw '*AGENT_HOST_PROCESS_EXITED*'
    }

    It '忽略错误 Session/nonce 和非目标端口，不向 Guest 放行' {
        $record=[pscustomobject]@{schemaVersion=1;sessionId='other_session';role='Host';eventId='event-2';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=('b'*64);summary='listener ready';port=25566;bindAddress='127.0.0.1'}
        [IO.File]::AppendAllText($script:eventPath,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        { Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -TimeoutSeconds 1 -PollMilliseconds 100 -ProcessId $PID -PortProbe { $true } } | Should -Throw '*AGENT_LAN_READY_TIMEOUT*'
    }

    It '发布失败、Session 外 event sink 和 TCP 未监听均 fail closed' {
        $failed=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='event-3';eventType='LAN_PUBLISH_FAILED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='publish failed';port=$script:port}
        [IO.File]::AppendAllText($script:eventPath,(($failed|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        { Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -PortProbe { $true } } | Should -Throw '*AGENT_LAN_PUBLISH_FAILED*'
        { Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath (Join-Path $TestDrive 'outside.jsonl') -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID } | Should -Throw '*AGENT_EVENT_PATH_OUTSIDE_SESSION*'

        $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=[int]$listener.LocalEndpoint.Port
        try { Test-MmtlLoopbackTcpPort -Port $port | Should -BeTrue }
        finally { $listener.Stop() }
        Test-MmtlLoopbackTcpPort -Port $port | Should -BeFalse
    }
}

Describe 'MMTL Forge Guest join readiness gate' {
    BeforeEach {
        $script:session=Join-Path $TestDrive ('guest-session-'+[guid]::NewGuid().ToString('N'))
        $script:eventPath=Join-Path $script:session 'agent-events/guest.jsonl'
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:eventPath) -Force|Out-Null
        [IO.File]::WriteAllText($script:eventPath,'',[Text.UTF8Encoding]::new($false))
        $script:sessionId='session_guest';$script:nonceHash='c'*64;$script:port=25565
    }

    It 'only accepts a matching Guest loopback world-join event and live process' {
        $connecting=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-started';eventType='GUEST_CONNECTING';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='guest connecting'}
        [IO.File]::AppendAllText($script:eventPath,(($connecting|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $record=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-1';eventType='GUEST_CONNECTED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='joined loopback host';port=$script:port}
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-world-1';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='guest entered world';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='guest-uuid';port=$script:port}
        [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        [IO.File]::AppendAllText($script:eventPath,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $result=Wait-MmtlAgentGuestJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -ExpectedWorldKey 'world-session-a' -ExpectedDimensionKey 'minecraft:overworld'
        $result.ready | Should -BeTrue
        $result.role | Should -Be 'Guest'
        $result.world.worldKey | Should -BeExactly 'world-session-a'
    }

    It '拒绝加入不同 world identity 的 Guest' {
        $connected=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-connected-other';eventType='GUEST_CONNECTED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='joined another world';port=$script:port}
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-world-other';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='guest entered other world';worldKey='wrong-world';dimensionKey='minecraft:overworld';playerIdentity='guest-uuid';port=$script:port}
        [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"+($connected|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentGuestJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -ExpectedWorldKey 'world-session-a' -ExpectedDimensionKey 'minecraft:overworld'} | Should -Throw '*AGENT_GUEST_WORLD_MISMATCH*'
    }

    It 'rejects wrong port and times out without granting readiness' {
        $record=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-2';eventType='GUEST_CONNECTED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='wrong port';port=25566}
        [IO.File]::AppendAllText($script:eventPath,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentGuestJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -TimeoutSeconds 1 -PollMilliseconds 100 -ExpectedWorldKey 'world-session-a' -ExpectedDimensionKey 'minecraft:overworld'} | Should -Throw '*AGENT_GUEST_JOIN_TIMEOUT*'
    }

    It '拒绝 Guest WORLD_JOINED 与实际连接端口不一致' {
        $connected=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-connect-correct';eventType='GUEST_CONNECTED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='joined loopback host';port=$script:port}
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-world-wrong-port';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='guest entered world';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='guest-uuid';port=25566}
        [IO.File]::AppendAllText($script:eventPath,(($connected|ConvertTo-Json -Compress)+"`n"+($world|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentGuestJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -ExpectedWorldKey 'world-session-a' -ExpectedDimensionKey 'minecraft:overworld'} | Should -Throw '*AGENT_GUEST_PORT_MISMATCH*'
    }

    It 'Guest process exits before both connection observations and is reported interrupted' {
        $world=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-exited-world';eventType='WORLD_JOINED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='guest entered world';worldKey='world-session-a';dimensionKey='minecraft:overworld';playerIdentity='guest-uuid';port=$script:port}
        $connected=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-exited-join';eventType='GUEST_CONNECTED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='guest connected';port=$script:port}
        [IO.File]::AppendAllText($script:eventPath,(($world|ConvertTo-Json -Compress)+"`n"+($connected|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentGuestJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId 2147483000 -ExpectedWorldKey 'world-session-a' -ExpectedDimensionKey 'minecraft:overworld'} | Should -Throw '*AGENT_GUEST_PROCESS_EXITED*'
    }
}
