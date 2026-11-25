BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repoRoot 'common/src/Scenario/WindowPairProof.psm1') -Force

    function New-TestReadyEvent {
        param([string]$Role,[int]$ProcessId,[string]$ProcessIdentity,[string]$EventCode,[string]$TimestampUtc)
        [pscustomobject]@{
            sessionId = 'session-proof-1'
            role = $Role
            pid = $ProcessId
            processIdentity = $ProcessIdentity
            sourceType = 'Agent'
            eventCode = $EventCode
            timestampUtc = $TimestampUtc
        }
    }

    function New-TestClient {
        param([string]$Role,[int]$ProcessId,[string]$ProcessIdentity,[string]$ReadyCode,[string]$ReadyAt)
        [pscustomobject]@{
            sessionId = 'session-proof-1'
            role = $Role
            processId = $ProcessId
            processIdentity = $ProcessIdentity
            readyEvent = New-TestReadyEvent -Role $Role -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity -EventCode $ReadyCode -TimestampUtc $ReadyAt
        }
    }

    function New-TestPlatformSnapshot {
        param([string]$At,[int]$PidA = 101,[int]$PidB = 202,[long]$WindowA = 1001,[long]$WindowB = 2002)
        [pscustomobject]@{
            sessionId = 'session-proof-1'
            observedAtUtc = $At
            windows = @(
                [pscustomobject]@{ processId=$PidA;processIdentity='process-a-start-1';windowId=$WindowA;visible=$true;windowKind='TopLevel' }
                [pscustomobject]@{ processId=$PidB;processIdentity='process-b-start-1';windowId=$WindowB;visible=$true;windowKind='TopLevel' }
            )
        }
    }

    $script:clientA = New-TestClient -Role Host -ProcessId 101 -ProcessIdentity 'process-a-start-1' -ReadyCode 'INTEGRATED_SERVER_READY' -ReadyAt '2026-10-16T10:00:00Z'
    $script:clientB = New-TestClient -Role Guest -ProcessId 202 -ProcessIdentity 'process-b-start-1' -ReadyCode 'AGENT_GUEST_CONNECTED' -ReadyAt '2026-10-16T10:00:01Z'
    $script:snapshots = @(
        (New-TestPlatformSnapshot -At '2026-10-16T10:00:02Z')
        (New-TestPlatformSnapshot -At '2026-10-16T10:00:04Z')
    )
}

Describe '真实客户端双窗口证明' {
    It '仅当两个独立、就绪的客户端 PID 和窗口在同一 Session 同时可见时通过' {
        $proof = Test-MmtlWindowPairProof -ClientA $script:clientA -ClientB $script:clientB -PlatformObservations $script:snapshots -SessionId 'session-proof-1'

        $proof.passed | Should -BeTrue
        $proof.clientAPid | Should -Be 101
        $proof.clientBPid | Should -Be 202
        $proof.clientAWindowId | Should -Be 1001
        $proof.clientBWindowId | Should -Be 2002
        $proof.simultaneousIntervalUtc.start | Should -Be '2026-10-16T10:00:02.0000000+00:00'
        $proof.simultaneousIntervalUtc.end | Should -Be '2026-10-16T10:00:04.0000000+00:00'
    }

    It '拒绝把同一个 PID 当成两个客户端' {
        $samePid = New-TestClient -Role Guest -ProcessId 101 -ProcessIdentity 'process-a-start-1' -ReadyCode 'AGENT_GUEST_CONNECTED' -ReadyAt '2026-10-16T10:00:01Z'

        $proof = Test-MmtlWindowPairProof -ClientA $script:clientA -ClientB $samePid -PlatformObservations $script:snapshots -SessionId 'session-proof-1'

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'WINDOW_PAIR_PROCESS_ID_NOT_DISTINCT'
    }

    It '拒绝没有共同可见时间段的先后窗口观察' {
        $onlyA = New-TestPlatformSnapshot -At '2026-10-16T10:00:02Z' -PidB 999 -WindowB 2999
        $onlyB = New-TestPlatformSnapshot -At '2026-10-16T10:00:04Z' -PidA 999 -WindowA 1999

        $proof = Test-MmtlWindowPairProof -ClientA $script:clientA -ClientB $script:clientB -PlatformObservations @($onlyA,$onlyB) -SessionId 'session-proof-1'

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'WINDOW_PAIR_NO_SIMULTANEOUS_OBSERVATION'
    }

    It '拒绝重复窗口句柄和非客户端 Dedicated Server 窗口' {
        $duplicate = @(New-TestPlatformSnapshot -At '2026-10-16T10:00:02Z' -WindowB 1001; New-TestPlatformSnapshot -At '2026-10-16T10:00:04Z' -WindowB 1001)
        $duplicateProof = Test-MmtlWindowPairProof -ClientA $script:clientA -ClientB $script:clientB -PlatformObservations $duplicate -SessionId 'session-proof-1'
        $duplicateProof.passed | Should -BeFalse
        $duplicateProof.reasonCode | Should -BeExactly 'WINDOW_PAIR_WINDOW_ID_NOT_DISTINCT'

        $server = New-TestClient -Role Server -ProcessId 303 -ProcessIdentity 'server-start-1' -ReadyCode 'SERVER_READY' -ReadyAt '2026-10-16T10:00:01Z'
        $serverProof = Test-MmtlWindowPairProof -ClientA $script:clientA -ClientB $server -PlatformObservations $script:snapshots -SessionId 'session-proof-1'
        $serverProof.passed | Should -BeFalse
        $serverProof.reasonCode | Should -BeExactly 'WINDOW_PAIR_ROLE_NOT_CLIENT'
    }
}
