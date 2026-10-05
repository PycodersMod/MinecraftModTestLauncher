BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
    Import-Module (Join-Path $source 'Observation/ProcessObserver.psm1') -Force
}

Describe '只观察 Session 已登记进程' {
    BeforeEach {
        $script:session = Join-Path $TestDrive 'session_01'
        New-Item -ItemType Directory -Path $script:session -Force | Out-Null
        @([pscustomobject]@{ PID=42; Role='Client'; StartIdentity='identity-42'; StatePath=(Join-Path $session 'process-42.exit.json'); LogPath=(Join-Path $session 'client.log') }) |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $session 'pids.json') -Encoding utf8
        $script:identityLookup = { param($process,$entry) [string]$process.StartIdentity -ceq [string]$entry.StartIdentity }
        $script:eventWriter = { param($sessionPath,$event) Write-MmtlRuntimeEvent -SessionPath $sessionPath -Event $event | Out-Null }
    }

    It '对匹配身份的登记进程记录开始事件' {
        $lookup = { param($processId) [pscustomobject]@{ ProcessId=$processId; StartIdentity='identity-42'; Executable='java'; MajorVersion=21 } }
        $result = Invoke-MmtlProcessObserver -SessionPath $session -TimeoutSeconds 0 -ProcessLookup $lookup -IdentityCheck $identityLookup -EventWriter $eventWriter
        $result.processes[0].status | Should -Be 'Running'
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'PROCESS_STARTED'
    }

    It 'PID 存在但启动身份不符时记录 identity lost 且不触碰该进程' {
        $lookup = { param($processId) [pscustomobject]@{ ProcessId=$processId; StartIdentity='different-process' } }
        $result = Invoke-MmtlProcessObserver -SessionPath $session -TimeoutSeconds 0 -ProcessLookup $lookup -IdentityCheck $identityLookup -EventWriter $eventWriter
        $result.processes[0].status | Should -Be 'IdentityLost'
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'PROCESS_IDENTITY_LOST'
    }

    It 'Session 登记进程消失且无退出记录时保留 orphan 状态' {
        $lookup = { param($processId) $null }
        $result = Invoke-MmtlProcessObserver -SessionPath $session -TimeoutSeconds 0 -ProcessLookup $lookup -IdentityCheck $identityLookup -EventWriter $eventWriter
        $result.processes[0].status | Should -Be 'Orphaned'
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'PROCESS_ORPHANED'
    }

    It '读到受限退出状态文件时只记录安全退出元数据' {
        $privateLogPath = Join-Path (Join-Path 'C:\Users' 'Alice') 'secret.log'
        [pscustomobject]@{PID=42;ExitCode=0;FinishedUtc='2026-10-06T00:00:00Z';Error=$privateLogPath;StopRequested=$false} | ConvertTo-Json | Set-Content (Join-Path $session 'process-42.exit.json')
        $lookup = { param($processId) $null }
        $result = Invoke-MmtlProcessObserver -SessionPath $session -TimeoutSeconds 0 -ProcessLookup $lookup -IdentityCheck $identityLookup -EventWriter $eventWriter
        $result.processes[0].status | Should -Be 'Exited'
        $event = Get-MmtlRuntimeEvents -SessionPath $session | Where-Object eventCode -eq 'PROCESS_EXITED'
        $event.summary | Should -Not -Match 'C:\\Users\\Alice'
    }
}
