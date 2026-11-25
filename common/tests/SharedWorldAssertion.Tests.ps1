BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:modulePath = Join-Path $script:repoRoot 'common/src/Scenario/SharedWorldAssertion.psm1'

    function New-SharedWorldEvent {
        param(
            [string]$Role,
            [int]$ProcessId,
            [string]$Identity,
            [string]$Code,
            [string]$At,
            [hashtable]$Metadata
        )
        if (-not $Metadata.ContainsKey('sourceCategory')) { $Metadata.sourceCategory = 'AGENT_OBSERVATION' }
        $Metadata.agentNonceVerified = $true
        [pscustomobject]@{
            schemaVersion = 1
            sessionId = 'shared-world-session'
            role = $Role
            pid = $ProcessId
            processIdentity = $Identity
            sourceType = 'Agent'
            eventCode = $Code
            timestampUtc = $At
            summary = 'verified test event'
            metadata = [pscustomobject]$Metadata
        }
    }

    function New-SharedWorldEvidence {
        $world = 'world-key-7a3f'
        $dimension = 'minecraft:overworld'
        $action = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $marker = 'mmtl-marker-01'
        $stateHash = 'b' * 64
        $actor = @(
            (New-SharedWorldEvent Host 101 actor-process AGENT_CLIENT_READY '2026-10-16T10:00:00Z' @{agentEventId='actor-ready'}),
            (New-SharedWorldEvent Host 101 actor-process AGENT_WORLD_JOINED '2026-10-16T10:00:02Z' @{agentEventId='actor-world';worldKey=$world;dimensionKey=$dimension;playerIdentity='player-uuid-actor'}),
            (New-SharedWorldEvent Host 101 actor-process AGENT_SHARED_STATE_WRITTEN '2026-10-16T10:00:07Z' @{agentEventId='actor-write';worldKey=$world;dimensionKey=$dimension;playerIdentity='player-uuid-actor';actionId=$action;protocolId='mmtl-block-marker-v1';operationCode='PLACE_BLOCK_MARKER';markerId=$marker;stateSha256=$stateHash;observed=$true})
        )
        $observer = @(
            (New-SharedWorldEvent Guest 202 guest-process AGENT_CLIENT_READY '2026-10-16T10:00:01Z' @{agentEventId='guest-ready'}),
            (New-SharedWorldEvent Guest 202 guest-process AGENT_GUEST_CONNECTED '2026-10-16T10:00:05Z' @{agentEventId='guest-connected';port=25565}),
            (New-SharedWorldEvent Guest 202 guest-process AGENT_WORLD_JOINED '2026-10-16T10:00:06Z' @{agentEventId='guest-world';worldKey=$world;dimensionKey=$dimension;playerIdentity='player-uuid-guest';port=25565}),
            (New-SharedWorldEvent Guest 202 guest-process AGENT_SHARED_STATE_OBSERVED '2026-10-16T10:00:09Z' @{agentEventId='guest-observe';worldKey=$world;dimensionKey=$dimension;playerIdentity='player-uuid-guest';actorActionId=$action;protocolId='mmtl-block-marker-v1';observationCode='OBSERVE_BLOCK_MARKER';markerId=$marker;stateSha256=$stateHash;observed=$true})
        )
        $hostEvents = @(
            (New-SharedWorldEvent Host 101 actor-process INTEGRATED_SERVER_READY '2026-10-16T10:00:01Z' @{agentEventId='server-ready';worldKey=$world;dimensionKey=$dimension}),
            (New-SharedWorldEvent Host 101 actor-process LAN_PORT_PUBLISHED '2026-10-16T10:00:04Z' @{agentEventId='lan-published';port=25565;bindAddress='127.0.0.1';worldKey=$world;dimensionKey=$dimension;playerIdentity='player-uuid-actor'})
        )
        $spec = [pscustomobject]@{
            schemaVersion = 1
            assertionId = 'marker-cross-player-v1'
            protocolId = 'mmtl-block-marker-v1'
            operationCode = 'PLACE_BLOCK_MARKER'
            observationCode = 'OBSERVE_BLOCK_MARKER'
            actionId = $action
            markerId = $marker
            expectedStateSha256 = $stateHash
        }
        [pscustomobject]@{actor=$actor;observer=$observer;host=$hostEvents;spec=$spec}
    }

    if (Test-Path -LiteralPath $script:modulePath) {
        Import-Module $script:modulePath -Force
    }
}

Describe '双玩家同世界与真实共享状态断言' {
    It '只有 actor 写入且独立 observer 观察到相同 marker 状态时通过' {
        $evidence = New-SharedWorldEvidence

        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec

        $proof.passed | Should -BeTrue
        $proof.sharedWorldKey | Should -BeExactly 'world-key-7a3f'
        $proof.actorA.processId | Should -Be 101
        $proof.observerB.processId | Should -Be 202
        $proof.actionProof.markerId | Should -BeExactly 'mmtl-marker-01'
        $proof.observationProof.stateSha256 | Should -BeExactly ('b' * 64)
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_ASSERTION_PASS'
    }

    It '只有两个客户端 ready 不通过' {
        $evidence = New-SharedWorldEvidence
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents @($evidence.actor[0]) -ClientBEvents @($evidence.observer[0]) -HostOrServerEvents @() -AssertionSpec $evidence.spec

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_JOIN_EVIDENCE_MISSING'
    }

    It '没有双方 WORLD_JOINED 证据时不通过' {
        $evidence = New-SharedWorldEvidence
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents @($evidence.actor[0]) -ClientBEvents @($evidence.observer[0]) -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_JOIN_EVIDENCE_MISSING'
    }

    It '世界或维度身份不同不得通过' {
        $evidence = New-SharedWorldEvidence
        $evidence.observer[2].metadata.worldKey = 'another-world'
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_IDENTITY_MISMATCH'
    }

    It 'Guest 的实际加入端口必须与 Host 发布端口一致' {
        $evidence = New-SharedWorldEvidence
        $evidence.observer[1].metadata.port = 25566
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_GUEST_PORT_MISMATCH'
    }

    It 'Guest WORLD_JOINED 报告的端口必须与其 loopback 连接事件一致' {
        $evidence = New-SharedWorldEvidence
        $evidence.observer[2].metadata.port = 25566
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_GUEST_PORT_MISMATCH'
    }

    It '命令发送或完成但没有实际共享状态变化证据不得通过' {
        $evidence = New-SharedWorldEvidence
        $evidence.actor[2].eventCode = 'ACTION_COMPLETED'
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_ACTION_PROOF_MISSING'
    }

    It 'actor 写入但 observer 未独立观察不得通过' {
        $evidence = New-SharedWorldEvidence
        $evidence.observer = @($evidence.observer | Where-Object eventCode -ne 'AGENT_SHARED_STATE_OBSERVED')
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_OBSERVATION_PROOF_MISSING'
    }

    It '同一玩家身份的双化名不得通过' {
        $evidence = New-SharedWorldEvidence
        $evidence.observer[2].metadata.playerIdentity = 'player-uuid-actor'
        $evidence.observer[3].metadata.playerIdentity = 'player-uuid-actor'
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec

        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_PLAYER_IDENTITY_NOT_DISTINCT'
    }

    It '拒绝跨 Session、非 Agent 事件、未验证的伪造事件和非 loopback listener' {
        $evidence = New-SharedWorldEvidence
        $evidence.actor[2].sessionId = 'other-session'
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec
        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_EVENT_IDENTITY_INVALID'

        $evidence = New-SharedWorldEvidence
        $evidence.actor[2].sourceType = 'Stdout'
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec
        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_EVENT_IDENTITY_INVALID'

        $evidence = New-SharedWorldEvidence
        $evidence.actor[2].metadata.PSObject.Properties.Remove('agentEventId')
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec
        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_EVENT_IDENTITY_INVALID'

        $evidence = New-SharedWorldEvidence
        $evidence.actor[2].metadata.agentNonceVerified = $false
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec
        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_EVENT_IDENTITY_INVALID'

        $evidence = New-SharedWorldEvidence
        $evidence.host[1].metadata.bindAddress = '0.0.0.0'
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec
        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_LISTENER_NOT_LOOPBACK'
    }

    It '拒绝 AssertionSpec 非法或动作和观察无法关联的证据' {
        $evidence = New-SharedWorldEvidence
        $evidence.spec.actionId = 'not-an-action-id'
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec
        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_ASSERTION_SPEC_INVALID'

        $evidence = New-SharedWorldEvidence
        $evidence.observer[3].metadata.actorActionId = 'cccccccccccccccccccccccccccccccc'
        $proof = Test-MmtlSharedWorldAssertion -SessionId 'shared-world-session' -ClientAEvents $evidence.actor -ClientBEvents $evidence.observer -HostOrServerEvents $evidence.host -AssertionSpec $evidence.spec
        $proof.passed | Should -BeFalse
        $proof.reasonCode | Should -BeExactly 'SHARED_WORLD_ACTION_OBSERVATION_MISMATCH'
    }
}
