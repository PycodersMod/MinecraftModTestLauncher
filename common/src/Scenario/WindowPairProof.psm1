Set-StrictMode -Version Latest

function New-MmtlWindowPairProofResult {
    param(
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][string]$ReasonCode,
        [Parameter(Mandatory)]$ClientA,
        [Parameter(Mandatory)]$ClientB,
        [object]$WindowA,
        [object]$WindowB,
        [object]$Interval,
        [object[]]$ReadyEvents=@(),
        [object[]]$EvidenceRefs=@()
    )
    [pscustomobject][ordered]@{
        passed=$Passed
        clientAPid=if($ClientA -and $ClientA.PSObject.Properties['processId']){[int]$ClientA.processId}else{$null}
        clientBPid=if($ClientB -and $ClientB.PSObject.Properties['processId']){[int]$ClientB.processId}else{$null}
        clientAWindowId=if($WindowA){[string]$WindowA.windowId}else{$null}
        clientBWindowId=if($WindowB){[string]$WindowB.windowId}else{$null}
        simultaneousIntervalUtc=$Interval
        readyEvents=@($ReadyEvents)
        evidenceRefs=@($EvidenceRefs)
        reasonCode=$ReasonCode
    }
}

function ConvertTo-MmtlWindowPairUtc {
    param([AllowNull()][string]$Value)
    $parsed=[DateTimeOffset]::MinValue
    if([string]::IsNullOrWhiteSpace($Value) -or -not [DateTimeOffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)){return $null}
    return $parsed.ToUniversalTime()
}

function Test-MmtlWindowPairReadyEvent {
    param([Parameter(Mandatory)]$Client,[Parameter(Mandatory)][string]$SessionId)
    if(-not $Client.PSObject.Properties['readyEvent'] -or -not $Client.readyEvent){return $false}
    $event=$Client.readyEvent
    $allowedCodes=switch([string]$Client.role){
        'Client' {@('AGENT_CLIENT_READY')}
        'Host' {@('AGENT_CLIENT_READY','INTEGRATED_SERVER_READY')}
        'Guest' {@('AGENT_CLIENT_READY','AGENT_GUEST_CONNECTED')}
        default {@()}
    }
    if([string]$event.sessionId -cne $SessionId -or [string]$event.role -cne [string]$Client.role -or [int]$event.pid -ne [int]$Client.processId -or [string]$event.processIdentity -cne [string]$Client.processIdentity -or [string]$event.sourceType -cne 'Agent' -or [string]$event.eventCode -notin $allowedCodes){return $false}
    return $null -ne (ConvertTo-MmtlWindowPairUtc -Value ([string]$event.timestampUtc))
}

function Test-MmtlWindowPairProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ClientA,
        [Parameter(Mandatory)]$ClientB,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PlatformObservations,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId
    )

    $emptyInterval=$null
    if([string]$ClientA.role -notin @('Client','Host','Guest') -or [string]$ClientB.role -notin @('Client','Host','Guest')){
        return New-MmtlWindowPairProofResult -Passed $false -ReasonCode 'WINDOW_PAIR_ROLE_NOT_CLIENT' -ClientA $ClientA -ClientB $ClientB -Interval $emptyInterval
    }
    if([string]$ClientA.sessionId -cne $SessionId -or [string]$ClientB.sessionId -cne $SessionId){
        return New-MmtlWindowPairProofResult -Passed $false -ReasonCode 'WINDOW_PAIR_SESSION_MISMATCH' -ClientA $ClientA -ClientB $ClientB -Interval $emptyInterval
    }
    if([int]$ClientA.processId -lt 1 -or [int]$ClientB.processId -lt 1 -or [string]::IsNullOrWhiteSpace([string]$ClientA.processIdentity) -or [string]::IsNullOrWhiteSpace([string]$ClientB.processIdentity)){
        return New-MmtlWindowPairProofResult -Passed $false -ReasonCode 'WINDOW_PAIR_PROCESS_IDENTITY_INVALID' -ClientA $ClientA -ClientB $ClientB -Interval $emptyInterval
    }
    if([int]$ClientA.processId -eq [int]$ClientB.processId -or [string]$ClientA.processIdentity -ceq [string]$ClientB.processIdentity){
        return New-MmtlWindowPairProofResult -Passed $false -ReasonCode 'WINDOW_PAIR_PROCESS_ID_NOT_DISTINCT' -ClientA $ClientA -ClientB $ClientB -Interval $emptyInterval
    }
    if(-not (Test-MmtlWindowPairReadyEvent -Client $ClientA -SessionId $SessionId) -or -not (Test-MmtlWindowPairReadyEvent -Client $ClientB -SessionId $SessionId)){
        return New-MmtlWindowPairProofResult -Passed $false -ReasonCode 'WINDOW_PAIR_READY_EVENT_INVALID' -ClientA $ClientA -ClientB $ClientB -Interval $emptyInterval
    }

    $readyA=ConvertTo-MmtlWindowPairUtc -Value ([string]$ClientA.readyEvent.timestampUtc)
    $readyB=ConvertTo-MmtlWindowPairUtc -Value ([string]$ClientB.readyEvent.timestampUtc)
    $simultaneous=[Collections.Generic.List[object]]::new()
    $duplicateWindowId=$false
    foreach($snapshot in $PlatformObservations){
        if([string]$snapshot.sessionId -cne $SessionId){continue}
        $at=ConvertTo-MmtlWindowPairUtc -Value ([string]$snapshot.observedAtUtc)
        if(-not $at -or $at -lt $readyA -or $at -lt $readyB){continue}
        $windows=@($snapshot.windows|Where-Object{[bool]$_.visible -and [string]$_.windowKind -in @('TopLevel','GameClient')})
        $windowA=@($windows|Where-Object{[int]$_.processId -eq [int]$ClientA.processId -and [string]$_.processIdentity -ceq [string]$ClientA.processIdentity})|Select-Object -First 1
        $windowB=@($windows|Where-Object{[int]$_.processId -eq [int]$ClientB.processId -and [string]$_.processIdentity -ceq [string]$ClientB.processIdentity})|Select-Object -First 1
        if(-not $windowA -or -not $windowB){continue}
        if([string]$windowA.windowId -ceq [string]$windowB.windowId){$duplicateWindowId=$true;continue}
        $observationId=if($snapshot.PSObject.Properties['observationId']){[string]$snapshot.observationId}else{$at.ToString('o')}
        $simultaneous.Add([pscustomobject]@{at=$at;windowA=$windowA;windowB=$windowB;observationId=$observationId})
    }
    if($duplicateWindowId){
        return New-MmtlWindowPairProofResult -Passed $false -ReasonCode 'WINDOW_PAIR_WINDOW_ID_NOT_DISTINCT' -ClientA $ClientA -ClientB $ClientB -Interval $emptyInterval -ReadyEvents @($ClientA.readyEvent,$ClientB.readyEvent)
    }
    if($simultaneous.Count -lt 2){
        return New-MmtlWindowPairProofResult -Passed $false -ReasonCode 'WINDOW_PAIR_NO_SIMULTANEOUS_OBSERVATION' -ClientA $ClientA -ClientB $ClientB -Interval $emptyInterval -ReadyEvents @($ClientA.readyEvent,$ClientB.readyEvent)
    }
    $ordered=@($simultaneous.ToArray()|Sort-Object at)
    $start=[DateTimeOffset]$ordered[0].at;$end=[DateTimeOffset]$ordered[-1].at
    if($end -le $start){
        return New-MmtlWindowPairProofResult -Passed $false -ReasonCode 'WINDOW_PAIR_NO_SIMULTANEOUS_OBSERVATION' -ClientA $ClientA -ClientB $ClientB -Interval $emptyInterval -ReadyEvents @($ClientA.readyEvent,$ClientB.readyEvent)
    }
    $windowA=$ordered[-1].windowA;$windowB=$ordered[-1].windowB
    $interval=[pscustomobject][ordered]@{start=$start.ToString('o');end=$end.ToString('o')}
    $refs=@($ordered|ForEach-Object{[pscustomobject]@{observationId=$_.observationId;observedAtUtc=$_.at.ToString('o')}})
    return New-MmtlWindowPairProofResult -Passed $true -ReasonCode 'WINDOW_PAIR_PROVEN' -ClientA $ClientA -ClientB $ClientB -WindowA $windowA -WindowB $windowB -Interval $interval -ReadyEvents @($ClientA.readyEvent,$ClientB.readyEvent) -EvidenceRefs $refs
}

Export-ModuleMember -Function Test-MmtlWindowPairProof
