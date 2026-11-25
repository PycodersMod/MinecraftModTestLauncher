Set-StrictMode -Version Latest

function Get-MmtlProofValue {
    param([AllowNull()]$InputObject,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject -or $null -eq $InputObject.PSObject.Properties[$Name]) { return $null }
    return $InputObject.$Name
}

function ConvertTo-MmtlProofTime {
    param([AllowNull()][string]$Value)
    $parsed = [DateTimeOffset]::MinValue
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)) { return $null }
    return $parsed.ToUniversalTime()
}

function Test-MmtlVerifiedAgentEvent {
    param([AllowNull()]$Event,[Parameter(Mandatory)][string]$SessionId,[Parameter(Mandatory)][string[]]$Roles)
    if ($null -eq $Event) { return $false }
    foreach ($field in @('schemaVersion','sessionId','role','pid','processIdentity','sourceType','eventCode','timestampUtc','metadata')) {
        if ($null -eq $Event.PSObject.Properties[$field]) { return $false }
    }
    if ([int]$Event.schemaVersion -ne 1 -or [string]$Event.sessionId -cne $SessionId -or [string]$Event.role -notin $Roles) { return $false }
    if ([int]$Event.pid -lt 1 -or [string]::IsNullOrWhiteSpace([string]$Event.processIdentity) -or [string]$Event.sourceType -cne 'Agent') { return $false }
    if ($null -eq (ConvertTo-MmtlProofTime ([string]$Event.timestampUtc))) { return $false }
    $metadata = $Event.metadata
    if ($null -eq $metadata -or [string]::IsNullOrWhiteSpace([string](Get-MmtlProofValue $metadata 'agentEventId'))) { return $false }
    if (-not [bool](Get-MmtlProofValue $metadata 'agentNonceVerified')) { return $false }
    if ([string](Get-MmtlProofValue $metadata 'sourceCategory') -cne 'AGENT_OBSERVATION') { return $false }
    return $true
}

function New-MmtlSharedWorldAssertionResult {
    param([bool]$Passed,[string]$ReasonCode,[string]$SharedWorldKey='',$ActorA=$null,$ObserverB=$null,$ActionProof=$null,$ObservationProof=$null,[string[]]$EvidenceRefs=@())
    [pscustomobject][ordered]@{
        passed = $Passed
        sharedWorldKey = $SharedWorldKey
        actorA = $ActorA
        observerB = $ObserverB
        actionProof = $ActionProof
        observationProof = $ObservationProof
        reasonCode = $ReasonCode
        evidenceRefs = @($EvidenceRefs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    }
}

function Test-MmtlSharedWorldAssertion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,
        [AllowEmptyCollection()][object[]]$ClientAEvents=@(),
        [AllowEmptyCollection()][object[]]$ClientBEvents=@(),
        [AllowEmptyCollection()][object[]]$HostOrServerEvents=@(),
        [Parameter(Mandatory)]$AssertionSpec
    )

    $specValid = [int](Get-MmtlProofValue $AssertionSpec 'schemaVersion') -eq 1 -and
        [string](Get-MmtlProofValue $AssertionSpec 'assertionId') -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -and
        [string](Get-MmtlProofValue $AssertionSpec 'protocolId') -ceq 'mmtl-block-marker-v1' -and
        [string](Get-MmtlProofValue $AssertionSpec 'operationCode') -ceq 'PLACE_BLOCK_MARKER' -and
        [string](Get-MmtlProofValue $AssertionSpec 'observationCode') -ceq 'OBSERVE_BLOCK_MARKER' -and
        [string](Get-MmtlProofValue $AssertionSpec 'actionId') -match '^[a-f0-9]{32}$' -and
        [string](Get-MmtlProofValue $AssertionSpec 'markerId') -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -and
        [string](Get-MmtlProofValue $AssertionSpec 'expectedStateSha256') -match '^[a-f0-9]{64}$'
    if (-not $specValid) { return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_ASSERTION_SPEC_INVALID' }

    $allClientEvents = @($ClientAEvents) + @($ClientBEvents)
    foreach ($event in $allClientEvents) {
        if (-not (Test-MmtlVerifiedAgentEvent -Event $event -SessionId $SessionId -Roles @('Client','Host','Guest'))) {
            return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_EVENT_IDENTITY_INVALID'
        }
    }
    foreach ($event in @($HostOrServerEvents)) {
        if ($null -eq $event -or [string](Get-MmtlProofValue $event 'sessionId') -cne $SessionId -or [string](Get-MmtlProofValue $event 'role') -notin @('Host','Server') -or [int](Get-MmtlProofValue $event 'pid') -lt 1 -or [string]::IsNullOrWhiteSpace([string](Get-MmtlProofValue $event 'processIdentity')) -or [string](Get-MmtlProofValue $event 'sourceType') -notin @('Agent','Observer') -or $null -eq (ConvertTo-MmtlProofTime ([string](Get-MmtlProofValue $event 'timestampUtc')))) {
            return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_EVENT_IDENTITY_INVALID'
        }
        if ([string](Get-MmtlProofValue $event 'sourceType') -ceq 'Agent' -and (-not [bool](Get-MmtlProofValue $event.metadata 'agentNonceVerified') -or [string](Get-MmtlProofValue $event.metadata 'sourceCategory') -cne 'AGENT_OBSERVATION' -or [string]::IsNullOrWhiteSpace([string](Get-MmtlProofValue $event.metadata 'agentEventId')))) {
            return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_EVENT_IDENTITY_INVALID'
        }
    }

    $aReady = @($ClientAEvents | Where-Object { [string]$_.eventCode -ceq 'AGENT_CLIENT_READY' } | Sort-Object { ConvertTo-MmtlProofTime ([string]$_.timestampUtc) } | Select-Object -First 1)
    $bReady = @($ClientBEvents | Where-Object { [string]$_.eventCode -ceq 'AGENT_CLIENT_READY' } | Sort-Object { ConvertTo-MmtlProofTime ([string]$_.timestampUtc) } | Select-Object -First 1)
    $aJoin = @($ClientAEvents | Where-Object { [string]$_.eventCode -ceq 'AGENT_WORLD_JOINED' } | Sort-Object { ConvertTo-MmtlProofTime ([string]$_.timestampUtc) } | Select-Object -First 1)
    $bJoin = @($ClientBEvents | Where-Object { [string]$_.eventCode -ceq 'AGENT_WORLD_JOINED' } | Sort-Object { ConvertTo-MmtlProofTime ([string]$_.timestampUtc) } | Select-Object -First 1)
    if ($aReady.Count -eq 0 -or $bReady.Count -eq 0 -or $aJoin.Count -eq 0 -or $bJoin.Count -eq 0) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_JOIN_EVIDENCE_MISSING'
    }

    $actorProcess = [int]$aReady[0].pid
    $observerProcess = [int]$bReady[0].pid
    if ($actorProcess -eq $observerProcess -or [string]$aReady[0].processIdentity -ceq [string]$bReady[0].processIdentity) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_CLIENT_PROCESS_NOT_DISTINCT'
    }
    if ([int]$aJoin[0].pid -ne $actorProcess -or [string]$aJoin[0].processIdentity -cne [string]$aReady[0].processIdentity -or [int]$bJoin[0].pid -ne $observerProcess -or [string]$bJoin[0].processIdentity -cne [string]$bReady[0].processIdentity) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_EVENT_IDENTITY_INVALID'
    }

    $worldKey = [string](Get-MmtlProofValue $aJoin[0].metadata 'worldKey')
    $dimensionKey = [string](Get-MmtlProofValue $aJoin[0].metadata 'dimensionKey')
    $playerA = [string](Get-MmtlProofValue $aJoin[0].metadata 'playerIdentity')
    $playerB = [string](Get-MmtlProofValue $bJoin[0].metadata 'playerIdentity')
    if ($worldKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or $dimensionKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or [string]::IsNullOrWhiteSpace($playerA) -or [string]::IsNullOrWhiteSpace($playerB)) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_IDENTITY_MISSING'
    }
    if ($worldKey -cne [string](Get-MmtlProofValue $bJoin[0].metadata 'worldKey') -or $dimensionKey -cne [string](Get-MmtlProofValue $bJoin[0].metadata 'dimensionKey')) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_IDENTITY_MISMATCH'
    }
    if ($playerA -ceq $playerB) { return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_PLAYER_IDENTITY_NOT_DISTINCT' }

    $guestConnection = @($ClientBEvents | Where-Object {
        [string]$_.eventCode -ceq 'AGENT_GUEST_CONNECTED' -and
        [string]$_.role -ceq 'Guest' -and
        [int]$_.pid -eq $observerProcess -and
        [string]$_.processIdentity -ceq [string]$bReady[0].processIdentity
    } | Sort-Object { ConvertTo-MmtlProofTime ([string]$_.timestampUtc) } | Select-Object -First 1)
    if ($guestConnection.Count -eq 0) { return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_GUEST_CONNECTION_EVIDENCE_MISSING' $worldKey }
    $guestPort = [int](Get-MmtlProofValue $guestConnection[0].metadata 'port')
    if ($guestPort -lt 1 -or $guestPort -gt 65535) { return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_GUEST_CONNECTION_EVIDENCE_MISSING' $worldKey }

    $serverReady = @($HostOrServerEvents | Where-Object {
        [string](Get-MmtlProofValue $_ 'eventCode') -in @('INTEGRATED_SERVER_READY','SERVER_READY') -and
        [string](Get-MmtlProofValue $_ 'role') -in @('Host','Server') -and
        [string](Get-MmtlProofValue $_.metadata 'worldKey') -ceq $worldKey -and
        [string](Get-MmtlProofValue $_.metadata 'dimensionKey') -ceq $dimensionKey
    } | Select-Object -First 1)
    $listener = @($HostOrServerEvents | Where-Object {
        [string](Get-MmtlProofValue $_ 'eventCode') -in @('LAN_PORT_PUBLISHED','SERVER_LISTENING') -and
        [string](Get-MmtlProofValue $_.metadata 'worldKey') -ceq $worldKey -and
        [string](Get-MmtlProofValue $_.metadata 'dimensionKey') -ceq $dimensionKey -and
        [string](Get-MmtlProofValue $_.metadata 'playerIdentity') -ceq $playerA
    } | Select-Object -First 1)
    if ($listener.Count -gt 0 -and [string](Get-MmtlProofValue $listener[0].metadata 'bindAddress') -cne '127.0.0.1') {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_LISTENER_NOT_LOOPBACK'
    }
    if ($serverReady.Count -eq 0 -or $listener.Count -eq 0 -or [int](Get-MmtlProofValue $listener[0].metadata 'port') -lt 1 -or [int](Get-MmtlProofValue $listener[0].metadata 'port') -gt 65535) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_HOST_OR_LISTENER_EVIDENCE_MISSING'
    }
    if ([int]$serverReady[0].pid -ne [int]$listener[0].pid -or [string]$serverReady[0].processIdentity -cne [string]$listener[0].processIdentity -or [string]$serverReady[0].role -cne [string]$listener[0].role) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_LISTENER_IDENTITY_MISMATCH'
    }
    $guestWorldPort = [int](Get-MmtlProofValue $bJoin[0].metadata 'port')
    if ($guestPort -ne [int](Get-MmtlProofValue $listener[0].metadata 'port') -or $guestWorldPort -ne $guestPort) { return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_GUEST_PORT_MISMATCH' $worldKey }
    $serverReadyAt = ConvertTo-MmtlProofTime ([string]$serverReady[0].timestampUtc)
    $listenerAt = ConvertTo-MmtlProofTime ([string]$listener[0].timestampUtc)
    $actorJoinAt = ConvertTo-MmtlProofTime ([string]$aJoin[0].timestampUtc)
    $observerJoinAt = ConvertTo-MmtlProofTime ([string]$bJoin[0].timestampUtc)
    $actorJoinTooEarly = if ([string]$aJoin[0].role -ceq 'Host') { $actorJoinAt -le $serverReadyAt } else { $actorJoinAt -le $listenerAt }
    if ($listenerAt -le $serverReadyAt -or $actorJoinTooEarly -or $observerJoinAt -le $listenerAt) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_JOIN_TIME_INVALID' $worldKey
    }

    $actionEvent = @($ClientAEvents | Where-Object {
        [string]$_.eventCode -ceq 'AGENT_SHARED_STATE_WRITTEN' -and
        [int]$_.pid -eq $actorProcess -and
        [string]$_.processIdentity -ceq [string]$aReady[0].processIdentity -and
        [string](Get-MmtlProofValue $_.metadata 'actionId') -ceq [string]$AssertionSpec.actionId -and
        [string](Get-MmtlProofValue $_.metadata 'protocolId') -ceq [string]$AssertionSpec.protocolId -and
        [string](Get-MmtlProofValue $_.metadata 'operationCode') -ceq [string]$AssertionSpec.operationCode -and
        [string](Get-MmtlProofValue $_.metadata 'markerId') -ceq [string]$AssertionSpec.markerId -and
        [string](Get-MmtlProofValue $_.metadata 'stateSha256') -ceq [string]$AssertionSpec.expectedStateSha256 -and
        [bool](Get-MmtlProofValue $_.metadata 'observed')
    } | Select-Object -First 1)
    if ($actionEvent.Count -eq 0) { return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_ACTION_PROOF_MISSING' $worldKey }
    if ([string](Get-MmtlProofValue $actionEvent[0].metadata 'worldKey') -cne $worldKey -or [string](Get-MmtlProofValue $actionEvent[0].metadata 'dimensionKey') -cne $dimensionKey -or [string](Get-MmtlProofValue $actionEvent[0].metadata 'playerIdentity') -cne $playerA) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_ACTION_WORLD_MISMATCH' $worldKey
    }
    if ((ConvertTo-MmtlProofTime ([string]$actionEvent[0].timestampUtc)) -le (ConvertTo-MmtlProofTime ([string]$aJoin[0].timestampUtc)) -or (ConvertTo-MmtlProofTime ([string]$actionEvent[0].timestampUtc)) -le (ConvertTo-MmtlProofTime ([string]$bJoin[0].timestampUtc))) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_ACTION_TIME_INVALID' $worldKey
    }

    $observationEvent = @($ClientBEvents | Where-Object {
        [string]$_.eventCode -ceq 'AGENT_SHARED_STATE_OBSERVED' -and
        [int]$_.pid -eq $observerProcess -and
        [string]$_.processIdentity -ceq [string]$bReady[0].processIdentity -and
        [string](Get-MmtlProofValue $_.metadata 'actorActionId') -ceq [string]$AssertionSpec.actionId -and
        [string](Get-MmtlProofValue $_.metadata 'protocolId') -ceq [string]$AssertionSpec.protocolId -and
        [string](Get-MmtlProofValue $_.metadata 'observationCode') -ceq [string]$AssertionSpec.observationCode -and
        [string](Get-MmtlProofValue $_.metadata 'markerId') -ceq [string]$AssertionSpec.markerId -and
        [string](Get-MmtlProofValue $_.metadata 'stateSha256') -ceq [string]$AssertionSpec.expectedStateSha256 -and
        [bool](Get-MmtlProofValue $_.metadata 'observed')
    } | Sort-Object { ConvertTo-MmtlProofTime ([string]$_.timestampUtc) } | Select-Object -First 1)
    if ($observationEvent.Count -eq 0) {
        $hasObservationCode = @($ClientBEvents | Where-Object { [string]$_.eventCode -ceq 'AGENT_SHARED_STATE_OBSERVED' }).Count -gt 0
        if ($hasObservationCode) { return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_ACTION_OBSERVATION_MISMATCH' $worldKey }
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_OBSERVATION_PROOF_MISSING' $worldKey
    }
    if ([string](Get-MmtlProofValue $observationEvent[0].metadata 'worldKey') -cne $worldKey -or [string](Get-MmtlProofValue $observationEvent[0].metadata 'dimensionKey') -cne $dimensionKey -or [string](Get-MmtlProofValue $observationEvent[0].metadata 'playerIdentity') -cne $playerB) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_OBSERVATION_WORLD_MISMATCH' $worldKey
    }
    if ((ConvertTo-MmtlProofTime ([string]$observationEvent[0].timestampUtc)) -le (ConvertTo-MmtlProofTime ([string]$actionEvent[0].timestampUtc))) {
        return New-MmtlSharedWorldAssertionResult $false 'SHARED_WORLD_OBSERVATION_TIME_INVALID' $worldKey
    }

    $actorProof = [pscustomobject][ordered]@{role=[string]$aJoin[0].role;processId=$actorProcess;processIdentity=[string]$aReady[0].processIdentity;playerIdentity=$playerA;protocolId=[string]$AssertionSpec.protocolId;operationCode=[string]$AssertionSpec.operationCode;markerId=[string]$AssertionSpec.markerId;stateSha256=[string]$AssertionSpec.expectedStateSha256;eventId=[string](Get-MmtlProofValue $actionEvent[0].metadata 'agentEventId');timestampUtc=[string]$actionEvent[0].timestampUtc}
    $observerProof = [pscustomobject][ordered]@{role=[string]$bJoin[0].role;processId=$observerProcess;processIdentity=[string]$bReady[0].processIdentity;playerIdentity=$playerB;protocolId=[string]$AssertionSpec.protocolId;observationCode=[string]$AssertionSpec.observationCode;markerId=[string]$AssertionSpec.markerId;stateSha256=[string]$AssertionSpec.expectedStateSha256;eventId=[string](Get-MmtlProofValue $observationEvent[0].metadata 'agentEventId');timestampUtc=[string]$observationEvent[0].timestampUtc}
    $refs = @(
        'agent-event:' + [string](Get-MmtlProofValue $aJoin[0].metadata 'agentEventId'),
        'agent-event:' + [string](Get-MmtlProofValue $bJoin[0].metadata 'agentEventId'),
        'agent-event:' + [string](Get-MmtlProofValue $guestConnection[0].metadata 'agentEventId'),
        'agent-event:' + [string](Get-MmtlProofValue $actionEvent[0].metadata 'agentEventId'),
        'agent-event:' + [string](Get-MmtlProofValue $observationEvent[0].metadata 'agentEventId'),
        'host-event:' + [string](Get-MmtlProofValue $listener[0].metadata 'agentEventId')
    )
    return New-MmtlSharedWorldAssertionResult $true 'SHARED_WORLD_ASSERTION_PASS' $worldKey $actorProof $observerProof $actorProof $observerProof $refs
}

Export-ModuleMember -Function Test-MmtlSharedWorldAssertion
