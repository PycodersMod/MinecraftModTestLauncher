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

    It '只有当前 Session Host nonce 的成功发布事件且 loopback 端口正在监听时才就绪' {
        $started=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='event-started';eventType='AGENT_STARTED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='agent started'}
        [IO.File]::AppendAllText($script:eventPath,(($started|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $record=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Host';eventId='event-1';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='listener ready';port=$script:port}
        [IO.File]::AppendAllText($script:eventPath,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $result=Wait-MmtlAgentIntegratedLanReady -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -PortProbe {param($candidate) $candidate -eq 25565}
        $result.ready | Should -BeTrue
        $result.bindAddress | Should -BeExactly '127.0.0.1'
        $result.event.metadata.port | Should -Be 25565
    }

    It '忽略错误 Session/nonce 和非目标端口，不向 Guest 放行' {
        $record=[pscustomobject]@{schemaVersion=1;sessionId='other_session';role='Host';eventId='event-2';eventType='LAN_PUBLISHED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=('b'*64);summary='listener ready';port=25566}
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
        [IO.File]::AppendAllText($script:eventPath,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $result=Wait-MmtlAgentGuestJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID
        $result.ready | Should -BeTrue
        $result.role | Should -Be 'Guest'
    }

    It 'rejects wrong port and times out without granting readiness' {
        $record=[pscustomobject]@{schemaVersion=1;sessionId=$script:sessionId;role='Guest';eventId='guest-2';eventType='GUEST_CONNECTED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');sessionNonceHash=$script:nonceHash;summary='wrong port';port=25566}
        [IO.File]::AppendAllText($script:eventPath,(($record|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        {Wait-MmtlAgentGuestJoined -SessionPath $script:session -EventPath $script:eventPath -SessionId $script:sessionId -ExpectedNonceHash $script:nonceHash -Port $script:port -ProcessId $PID -TimeoutSeconds 1 -PollMilliseconds 100} | Should -Throw '*AGENT_GUEST_JOIN_TIMEOUT*'
    }
}
