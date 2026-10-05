BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
    Import-Module (Join-Path $source 'Observation/DedicatedServerObserver.psm1') -Force
}

Describe 'Dedicated Server Observer loopback readiness' {
    It '同时要求登记身份、ready marker 与 localhost listener 才产生 READY' {
        $session = Join-Path $TestDrive ('session_server_' + [guid]::NewGuid().ToString('N'))
        $runtime = Join-Path $session 'Server'
        New-Item -ItemType Directory -Path (Join-Path $runtime 'logs') -Force | Out-Null
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0); $listener.Start()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            ('[Server thread/INFO]: Done (1.2s)! For help, type help' + "`n" + "[Server thread/INFO]: Starting Minecraft server on 127.0.0.1:$port") | Set-Content (Join-Path $runtime 'logs/latest.log')
            @([pscustomobject]@{PID=22;Role='Server';StartIdentity='server-start';RuntimeDirectory=$runtime;StatePath=(Join-Path $session 'process-22.exit.json')}) | ConvertTo-Json | Set-Content (Join-Path $session 'pids.json')
            [IO.Path]::GetFileName($session) | Set-Content (Join-Path $runtime 'mmtl-session.id') -NoNewline
            $lookup = { param($processId) [pscustomobject]@{ProcessId=$processId;StartIdentity='server-start'} }
            $identity = { param($process,$entry) $process.StartIdentity -ceq $entry.StartIdentity }
            $result = Invoke-MmtlDedicatedServerObserver -SessionPath $session -Port $port -ProcessLookup $lookup -IdentityCheck $identity
            $result.servers[0].ready | Should -BeTrue
            $result.servers[0].listening | Should -BeTrue
            (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'SERVER_READY'
            (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'SERVER_LISTENING'
        } finally { $listener.Stop() }
    }

    It '外部地址不可达或进程身份不匹配时不得记录 READY' {
        $session = Join-Path $TestDrive ('session_server_' + [guid]::NewGuid().ToString('N'))
        $runtime = Join-Path $session 'Server'; New-Item -ItemType Directory -Path (Join-Path $runtime 'logs') -Force | Out-Null
        '[Server thread/INFO]: Done (1.2s)! For help, type "help"' | Set-Content (Join-Path $runtime 'logs/latest.log')
        @([pscustomobject]@{PID=22;Role='Server';StartIdentity='server-start';RuntimeDirectory=$runtime}) | ConvertTo-Json | Set-Content (Join-Path $session 'pids.json')
        [IO.Path]::GetFileName($session) | Set-Content (Join-Path $runtime 'mmtl-session.id') -NoNewline
        $lookup = { param($processId) [pscustomobject]@{ProcessId=$processId;StartIdentity='other'} }
        $result = Invoke-MmtlDedicatedServerObserver -SessionPath $session -Port 1 -ProcessLookup $lookup -IdentityCheck {param($process,$entry) $process.StartIdentity -ceq $entry.StartIdentity}
        $result.servers[0].ready | Should -BeFalse
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Not -Contain 'SERVER_READY'
    }
}
