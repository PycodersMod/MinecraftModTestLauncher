Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MmtlAcceptanceDimensionAliases = [ordered]@{
    BuildExact = @('BuildExact', 'BuildVerified')
    RuntimeBinding = @('RuntimeBinding')
    ClientLaunch = @('ClientLaunch', 'LaunchCheck')
    MultiWindow = @('MultiWindow')
    SingleAssertion = @('SingleAssertion')
    MultiplayerJoinAndAssertion = @('MultiplayerJoinAndAssertion', 'Multiplayer')
    TargetReport = @('TargetReport')
    SafeStop = @('SafeStop')
    AgentBuild = @('AgentBuild')
    AgentInjection = @('AgentInjection')
    DedicatedServer = @('DedicatedServer')
    NativeIntegratedLAN = @('NativeIntegratedLAN')
    HistoricalDedicatedEquivalent = @('HistoricalDedicatedEquivalent')
    AgentApplicability = @('AgentApplicability')
    DedicatedApplicability = @('DedicatedApplicability')
}

function Get-MmtlAcceptanceProperty {
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-MmtlAcceptanceIndexedReference {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$EvidenceIndex,
        [Parameter(Mandatory)][string]$TargetSpecHash,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AdapterSha256,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ToolchainHash,
        [Parameter(Mandatory)][string]$Dimension,
        [Parameter(Mandatory)][AllowEmptyString()][string]$EvidencePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$EvidenceSha256
    )
    if ([string]::IsNullOrWhiteSpace($EvidencePath) -or [IO.Path]::IsPathRooted($EvidencePath) -or $EvidencePath.Contains('\') -or
        @($EvidencePath -split '/' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or $EvidenceSha256 -cnotmatch '^[a-f0-9]{64}$') { return $false }
    $aliases = @($script:MmtlAcceptanceDimensionAliases[$Dimension])
    if ($aliases.Count -eq 0) { $aliases = @($Dimension) }
    $entries = Get-MmtlAcceptanceProperty $EvidenceIndex 'entries'
    if ($null -eq $entries) { return $false }
    $matches = @($entries | Where-Object {
        [string](Get-MmtlAcceptanceProperty $_ 'targetId') -ceq [string](Get-MmtlAcceptanceProperty $Target 'targetId') -and
        [string](Get-MmtlAcceptanceProperty $_ 'targetSpecHash') -ceq $TargetSpecHash -and
        [string](Get-MmtlAcceptanceProperty $_ 'adapterSha256') -ceq $AdapterSha256 -and
        [string](Get-MmtlAcceptanceProperty $_ 'toolchainHash') -ceq $ToolchainHash -and
        [string](Get-MmtlAcceptanceProperty $_ 'dimension') -cin $aliases -and
        [string](Get-MmtlAcceptanceProperty $_ 'evidencePath') -ceq $EvidencePath -and
        [string](Get-MmtlAcceptanceProperty $_ 'evidenceSha256') -ceq $EvidenceSha256
    })
    return $matches.Count -eq 1
}

function Get-MmtlAcceptanceStage {
    param([AllowNull()]$Report, [Parameter(Mandatory)][string]$Dimension)
    $stages = Get-MmtlAcceptanceProperty -InputObject $Report -Name 'stageResults'
    if ($null -eq $stages) { return $null }
    $aliases = @($script:MmtlAcceptanceDimensionAliases[$Dimension])
    $matches = @($stages | Where-Object { [string](Get-MmtlAcceptanceProperty -InputObject $_ -Name 'dimension') -in $aliases })
    if ($matches.Count -ne 1) { return $null }
    return $matches[0]
}

function Test-MmtlAcceptanceEvidence {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]$Stage,
        [Parameter(Mandatory)]$EvidenceIndex,
        [Parameter(Mandatory)][string]$RunId
    )

    if ([string](Get-MmtlAcceptanceProperty $Stage 'status') -cne 'PASS' -or -not [bool](Get-MmtlAcceptanceProperty $Stage 'freshExecution') -or [string](Get-MmtlAcceptanceProperty $Report 'runId') -cne $RunId) { return $false }
    $refsValue = Get-MmtlAcceptanceProperty $Stage 'evidenceRefs'
    $hashesValue = Get-MmtlAcceptanceProperty $Stage 'evidenceSha256'
    if ($null -eq $refsValue -or $null -eq $hashesValue) { return $false }
    $refs = @($refsValue)
    $hashes = @($hashesValue)
    if ($refs.Count -eq 0 -or $refs.Count -ne $hashes.Count) { return $false }
    $identity = Get-MmtlAcceptanceProperty $Report 'compatibilityIdentity'
    if ($null -eq $identity -or [string](Get-MmtlAcceptanceProperty $identity 'targetId') -cne [string](Get-MmtlAcceptanceProperty $Target 'targetId') -or
        [string](Get-MmtlAcceptanceProperty $identity 'universeHash') -cne [string](Get-MmtlAcceptanceProperty $EvidenceIndex 'universeHash') -or
        [string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash') -notmatch '^[a-f0-9]{64}$' -or
        [string](Get-MmtlAcceptanceProperty $identity 'adapterSha256') -notmatch '^[a-f0-9]{64}$' -or
        [string](Get-MmtlAcceptanceProperty $identity 'toolchainHash') -notmatch '^[a-f0-9]{64}$') { return $false }
    $sourceHash = Get-MmtlAcceptanceProperty $identity 'sourceHash'
    if ($null -ne $sourceHash -and [string]$sourceHash -cne [string](Get-MmtlAcceptanceProperty $Target 'sourceHash')) { return $false }
    $indexEntries = Get-MmtlAcceptanceProperty $EvidenceIndex 'entries'
    if ($null -eq $indexEntries) { return $false }
    $stageDimension = [string](Get-MmtlAcceptanceProperty $Stage 'dimension')
    $expectedIndexDimensions = @($script:MmtlAcceptanceDimensionAliases.GetEnumerator() | Where-Object { $_.Value -contains $stageDimension } | ForEach-Object { $_.Value })
    if ($expectedIndexDimensions.Count -eq 0) { $expectedIndexDimensions = @($stageDimension) }
    foreach ($index in 0..($refs.Count - 1)) {
        $ref = [string]$refs[$index]
        $hash = [string]$hashes[$index]
        if (-not $ref -or [IO.Path]::IsPathRooted($ref) -or $ref.Contains('\') -or @($ref -split '/' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) { return $false }
        if ($hash -cnotmatch '^[a-f0-9]{64}$') { return $false }
        $matches = @($indexEntries | Where-Object {
            [string](Get-MmtlAcceptanceProperty $_ 'targetId') -ceq [string](Get-MmtlAcceptanceProperty $Target 'targetId') -and
            [string](Get-MmtlAcceptanceProperty $_ 'targetSpecHash') -ceq [string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash') -and
            [string](Get-MmtlAcceptanceProperty $_ 'adapterSha256') -ceq [string](Get-MmtlAcceptanceProperty $identity 'adapterSha256') -and
            [string](Get-MmtlAcceptanceProperty $_ 'toolchainHash') -ceq [string](Get-MmtlAcceptanceProperty $identity 'toolchainHash') -and
            [string](Get-MmtlAcceptanceProperty $_ 'dimension') -cin $expectedIndexDimensions -and
            [string](Get-MmtlAcceptanceProperty $_ 'evidencePath') -ceq $ref -and
            [string](Get-MmtlAcceptanceProperty $_ 'evidenceSha256') -ceq $hash
        })
        if ($matches.Count -ne 1) { return $false }
    }
    return $true
}

function Test-MmtlSingleAssertionProof {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]$EvidenceIndex,
        [int]$ClientCount = 2,
        [AllowNull()]$WindowPairProof
    )
    $proof = Get-MmtlAcceptanceProperty $Report 'singleProof'
    $event = Get-MmtlAcceptanceProperty $proof 'agentEvent'
    $metadata = Get-MmtlAcceptanceProperty $event 'metadata'
    if ($null -eq $proof -or $null -eq $event -or $null -eq $metadata -or -not [bool](Get-MmtlAcceptanceProperty $proof 'passed')) { return $false }
    $sessionId = [string](Get-MmtlAcceptanceProperty $Report 'sessionId')
    $clientPid = [int](Get-MmtlAcceptanceProperty $proof 'clientPid')
    $clientIdentity = [string](Get-MmtlAcceptanceProperty $proof 'clientProcessIdentity')
    if (-not $sessionId -or $clientPid -lt 1 -or -not $clientIdentity) { return $false }
    if ($ClientCount -eq 1) {
        if ([string](Get-MmtlAcceptanceProperty $event 'role') -notin @('Client','Host')) { return $false }
    }
    elseif (-not [bool](Get-MmtlAcceptanceProperty $WindowPairProof 'passed') -or
        [int](Get-MmtlAcceptanceProperty $WindowPairProof 'clientAPid') -lt 1 -or
        [int](Get-MmtlAcceptanceProperty $WindowPairProof 'clientBPid') -lt 1 -or
        [int](Get-MmtlAcceptanceProperty $WindowPairProof 'clientAPid') -eq [int](Get-MmtlAcceptanceProperty $WindowPairProof 'clientBPid') -or
        [int]$clientPid -notin @([int](Get-MmtlAcceptanceProperty $WindowPairProof 'clientAPid'), [int](Get-MmtlAcceptanceProperty $WindowPairProof 'clientBPid')) -or
        -not [string](Get-MmtlAcceptanceProperty $WindowPairProof 'clientAWindowId') -or
        -not [string](Get-MmtlAcceptanceProperty $WindowPairProof 'clientBWindowId') -or
        [string](Get-MmtlAcceptanceProperty $WindowPairProof 'clientAWindowId') -ceq [string](Get-MmtlAcceptanceProperty $WindowPairProof 'clientBWindowId')) { return $false }
    if ([string](Get-MmtlAcceptanceProperty $event 'sessionId') -cne $sessionId -or
        [int](Get-MmtlAcceptanceProperty $event 'schemaVersion') -ne 1 -or
        [string](Get-MmtlAcceptanceProperty $event 'role') -notin @('Client','Host','Guest') -or
        [int](Get-MmtlAcceptanceProperty $event 'pid') -ne $clientPid -or
        [string](Get-MmtlAcceptanceProperty $event 'processIdentity') -cne $clientIdentity -or
        [string](Get-MmtlAcceptanceProperty $event 'sourceType') -cne 'Agent' -or
        [string](Get-MmtlAcceptanceProperty $event 'eventCode') -cne 'AGENT_SHARED_STATE_WRITTEN') { return $false }
    if ($ClientCount -gt 1) {
        $readyEvents = @(Get-MmtlAcceptanceProperty $WindowPairProof 'readyEvents')
        $interval = Get-MmtlAcceptanceProperty $WindowPairProof 'simultaneousIntervalUtc'
        $intervalStart = [DateTimeOffset]::MinValue
        $intervalEnd = [DateTimeOffset]::MinValue
        $intervalValid = $readyEvents.Count -eq 2 -and $null -ne $interval -and
            [DateTimeOffset]::TryParse([string](Get-MmtlAcceptanceProperty $interval 'start'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$intervalStart) -and
            [DateTimeOffset]::TryParse([string](Get-MmtlAcceptanceProperty $interval 'end'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$intervalEnd) -and
            $intervalEnd -gt $intervalStart
        if (-not $intervalValid) { return $false }
        $matchingReady = @($readyEvents | Where-Object {
            [string](Get-MmtlAcceptanceProperty $_ 'sessionId') -ceq $sessionId -and
            [int](Get-MmtlAcceptanceProperty $_ 'pid') -eq $clientPid -and
            [string](Get-MmtlAcceptanceProperty $_ 'processIdentity') -ceq $clientIdentity -and
            [string](Get-MmtlAcceptanceProperty $_ 'role') -ceq [string](Get-MmtlAcceptanceProperty $event 'role') -and
            [string](Get-MmtlAcceptanceProperty $_ 'sourceType') -ceq 'Agent'
        })
        if ($matchingReady.Count -ne 1) { return $false }
    }
    $eventAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string](Get-MmtlAcceptanceProperty $event 'timestampUtc'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$eventAt)) { return $false }
    if (-not [string](Get-MmtlAcceptanceProperty $metadata 'agentEventId') -or
        -not [bool](Get-MmtlAcceptanceProperty $metadata 'agentNonceVerified') -or
        [string](Get-MmtlAcceptanceProperty $metadata 'sourceCategory') -cne 'AGENT_OBSERVATION' -or
        [string](Get-MmtlAcceptanceProperty $metadata 'actionId') -notmatch '^[a-f0-9]{32}$' -or
        [string](Get-MmtlAcceptanceProperty $metadata 'protocolId') -cne 'mmtl-block-marker-v1' -or
        [string](Get-MmtlAcceptanceProperty $metadata 'operationCode') -cne 'PLACE_BLOCK_MARKER' -or
        [string](Get-MmtlAcceptanceProperty $metadata 'markerId') -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
        [string](Get-MmtlAcceptanceProperty $metadata 'stateSha256') -notmatch '^[a-f0-9]{64}$' -or
        -not [bool](Get-MmtlAcceptanceProperty $metadata 'observed') -or
        [string](Get-MmtlAcceptanceProperty $metadata 'worldKey') -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or
        [string](Get-MmtlAcceptanceProperty $metadata 'dimensionKey') -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or
        [string](Get-MmtlAcceptanceProperty $metadata 'playerIdentity') -notmatch '^[A-Za-z0-9._:-]{1,80}$') { return $false }
    $identity = Get-MmtlAcceptanceProperty $Report 'compatibilityIdentity'
    return Test-MmtlAcceptanceIndexedReference -Target $Target -EvidenceIndex $EvidenceIndex `
        -TargetSpecHash ([string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash')) `
        -AdapterSha256 ([string](Get-MmtlAcceptanceProperty $identity 'adapterSha256')) `
        -ToolchainHash ([string](Get-MmtlAcceptanceProperty $identity 'toolchainHash')) `
        -Dimension 'SingleAssertion' `
        -EvidencePath ([string](Get-MmtlAcceptanceProperty $proof 'evidencePath')) `
        -EvidenceSha256 ([string](Get-MmtlAcceptanceProperty $proof 'evidenceSha256'))
}

function Test-MmtlHistoricalServerRunProof {
    param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$Report,[AllowNull()]$Proof)
    if($null -eq $Proof -or -not [bool](Get-MmtlAcceptanceProperty $Proof 'passed')){return $false}
    $targetId=[string](Get-MmtlAcceptanceProperty $Target 'targetId')
    $minecraftId=[string](Get-MmtlAcceptanceProperty $Target 'minecraftId')
    if([string](Get-MmtlAcceptanceProperty $Target 'minecraftType') -cne 'release' -or $minecraftId -notmatch '^\d+\.\d+(?:\.\d+)?$'){return $false}
    try{$targetVersion=[version]($minecraftId+'.0')}catch{return $false}
    if($targetVersion -ge [version]'1.3.1' -or [string](Get-MmtlAcceptanceProperty $Proof 'targetId') -cne $targetId -or [string](Get-MmtlAcceptanceProperty $Proof 'minecraftId') -cne $minecraftId){return $false}

    $artifact=Get-MmtlAcceptanceProperty $Proof 'artifact'
    $scenario=Get-MmtlAcceptanceProperty (Get-MmtlAcceptanceProperty $Report 'scenarioConfiguration') 'effective'
    $expectedArtifact=Get-MmtlAcceptanceProperty $scenario 'historicalServerArtifact'
    if($null -eq $artifact -or $null -eq $expectedArtifact -or
        [string](Get-MmtlAcceptanceProperty $artifact 'targetId') -cne [string](Get-MmtlAcceptanceProperty $expectedArtifact 'targetId') -or
        [string](Get-MmtlAcceptanceProperty $artifact 'minecraftId') -cne [string](Get-MmtlAcceptanceProperty $expectedArtifact 'minecraftId') -or
        [string](Get-MmtlAcceptanceProperty $artifact 'trust') -cne [string](Get-MmtlAcceptanceProperty $expectedArtifact 'trust') -or
        [string](Get-MmtlAcceptanceProperty $artifact 'sourceType') -cne [string](Get-MmtlAcceptanceProperty $expectedArtifact 'sourceType') -or
        [string](Get-MmtlAcceptanceProperty $artifact 'artifactSha256') -cne [string](Get-MmtlAcceptanceProperty $expectedArtifact 'artifactSha256') -or
        [string](Get-MmtlAcceptanceProperty $artifact 'catalogSha256') -cne [string](Get-MmtlAcceptanceProperty $expectedArtifact 'catalogSha256') -or
        [string](Get-MmtlAcceptanceProperty $artifact 'sourceEvidenceSha256') -cne [string](Get-MmtlAcceptanceProperty $expectedArtifact 'sourceEvidenceSha256') -or
        [string](Get-MmtlAcceptanceProperty $artifact 'targetId') -cne $targetId -or
        [string](Get-MmtlAcceptanceProperty $artifact 'minecraftId') -cne $minecraftId -or
        [string](Get-MmtlAcceptanceProperty $artifact 'trust') -cne 'VerifiedHistorical' -or
        [string](Get-MmtlAcceptanceProperty $artifact 'sourceType') -notin @('OfficialManifest','VerifiedLocalArchive') -or
        [string](Get-MmtlAcceptanceProperty $artifact 'artifactSha256') -notmatch '^(?i:[a-f0-9]{64})$' -or
        [string](Get-MmtlAcceptanceProperty $artifact 'catalogSha256') -notmatch '^(?i:[a-f0-9]{64})$' -or
        [string](Get-MmtlAcceptanceProperty $artifact 'sourceEvidenceSha256') -notmatch '^(?i:[a-f0-9]{64})$'){return $false}

    $server=Get-MmtlAcceptanceProperty $Proof 'serverProcess'
    $serverPid=[int](Get-MmtlAcceptanceProperty $server 'pid')
    $port=[int](Get-MmtlAcceptanceProperty $server 'listenerPort')
    $startedAt=[DateTimeOffset]::MinValue
    if($null -eq $server -or $serverPid -lt 1 -or [string](Get-MmtlAcceptanceProperty $server 'role') -cne 'DedicatedServer' -or
        -not [string](Get-MmtlAcceptanceProperty $server 'processIdentity') -or $port -lt 1 -or $port -gt 65535 -or
        -not [string](Get-MmtlAcceptanceProperty $server 'readyEventId') -or
        -not [DateTimeOffset]::TryParse([string](Get-MmtlAcceptanceProperty $server 'startedAtUtc'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$startedAt)){return $false}

    $consent=Get-MmtlAcceptanceProperty $Proof 'eulaConsent'
    $acceptedAt=[DateTimeOffset]::MinValue
    if($null -eq $consent -or -not [bool](Get-MmtlAcceptanceProperty $consent 'accepted') -or
        [string](Get-MmtlAcceptanceProperty $consent 'authorizationRef') -notmatch '^[A-Za-z0-9._:-]{1,120}$' -or
        [string](Get-MmtlAcceptanceProperty $consent 'eulaSha256') -notmatch '^(?i:[a-f0-9]{64})$' -or
        -not [DateTimeOffset]::TryParse([string](Get-MmtlAcceptanceProperty $consent 'acceptedAtUtc'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$acceptedAt)){return $false}

    $stop=Get-MmtlAcceptanceProperty $Proof 'stopProof'
    $stoppedPids=@(Get-MmtlAcceptanceProperty $stop 'stoppedProcessIds' | ForEach-Object {[int]$_})
    $releasedPorts=@(Get-MmtlAcceptanceProperty $stop 'releasedPorts' | ForEach-Object {[int]$_})
    return $null -ne $stop -and [bool](Get-MmtlAcceptanceProperty $stop 'processTreeStopped') -and
        [bool](Get-MmtlAcceptanceProperty $stop 'listenerPortsReleased') -and $serverPid -in $stoppedPids -and $port -in $releasedPorts
}

function Test-MmtlExactGoalAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)]$EvidenceIndex,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$TargetReports,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId
    )

    $reasons = [Collections.Generic.List[string]]::new()
    $missingRefs = [Collections.Generic.List[string]]::new()
    $invalidRefs = [Collections.Generic.List[string]]::new()
    $targets = @(Get-MmtlAcceptanceProperty $Universe 'targets')
    $reportList = @($TargetReports)
    $targetDimensionResults = [Collections.Generic.List[object]]::new()
    $expectedUniverseHash = [string](Get-MmtlAcceptanceProperty $Universe 'catalogHash')
    if ($expectedUniverseHash -notmatch '^[a-f0-9]{64}$' -or [string](Get-MmtlAcceptanceProperty $EvidenceIndex 'universeHash') -cne $expectedUniverseHash) {
        $reasons.Add('UNIVERSE_HASH_MISMATCH')
    }
    if ($targets.Count -ne 1631) { $reasons.Add('FROZEN_UNIVERSE_COUNT_MISMATCH') }

    $targetIds = @($targets | ForEach-Object { [string](Get-MmtlAcceptanceProperty $_ 'targetId') })
    if (@($targetIds | Select-Object -Unique).Count -ne $targetIds.Count) { $reasons.Add('UNIVERSE_TARGET_ID_DUPLICATE') }
    $fullPassed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $counts = [ordered]@{
        buildExactPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        runtimeBindingPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        realClientPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        multiWindowPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        singlePass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        multiplayerPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        nativeLanPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        historicalDedicatedEquivalentPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        targetReportPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        safeStopPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        agentAndDedicatedPass = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }

    $externalBlocked = 0
    $consentRequired = 0
    $safetyBlocked = 0
    $internalPending = 0
    $invalidTargetIdentity = 0
    foreach ($target in $targets) {
        $targetId = [string](Get-MmtlAcceptanceProperty $target 'targetId')
        $reports = @($reportList | Where-Object { [string](Get-MmtlAcceptanceProperty $_ 'targetId') -ceq $targetId })
        if ($reports.Count -ne 1) {
            $internalPending++
            $missingRefs.Add("$targetId/report")
            $targetDimensionResults.Add([pscustomobject][ordered]@{
                targetId = $targetId
                clientCount = $null
                dimensions = [pscustomobject][ordered]@{
                    ClientLaunch='Missing'; SingleAssertion='Missing'; MultiWindow='Missing'
                    IntegratedLanPublished='Missing'; GuestJoined='Missing'; SharedWorldAssertion='Missing'
                    HistoricalDedicatedEquivalent='Missing'; Multiplayer='Missing'; TargetReport='Missing'; SafeStop='Missing'
                }
            })
            continue
        }
        $report = $reports[0]
        $targetFailed = $false
        $scenarioConfiguration = Get-MmtlAcceptanceProperty $report 'scenarioConfiguration'
        $effectiveScenario = Get-MmtlAcceptanceProperty $scenarioConfiguration 'effective'
        $rawClientCount = Get-MmtlAcceptanceProperty $effectiveScenario 'clientCount'
        if ($null -eq $rawClientCount) { $rawClientCount = Get-MmtlAcceptanceProperty $report 'clientCount' }
        $clientCount = 0
        if ($null -eq $rawClientCount -or $rawClientCount -is [bool] -or -not [int]::TryParse([string]$rawClientCount, [ref]$clientCount) -or $clientCount -lt 1) {
            $clientCount = 0
            $targetFailed = $true
            $missingRefs.Add("$targetId/ScenarioConfiguration/clientCount")
            $reasons.Add('FULL_GOAL_CLIENT_COUNT_MISSING_OR_INVALID')
        }
        elseif ($clientCount -ne 2) {
            $targetFailed = $true
            $reasons.Add('FULL_GOAL_CLIENT_COUNT_MUST_BE_TWO')
        }
        if ([string](Get-MmtlAcceptanceProperty $report 'runId') -cne $RunId -or -not [bool](Get-MmtlAcceptanceProperty $report 'freshExecution')) { $targetFailed = $true }
        $identity = Get-MmtlAcceptanceProperty $report 'compatibilityIdentity'
        $identityInvalid = $null -eq $identity -or [string](Get-MmtlAcceptanceProperty $identity 'targetId') -cne $targetId -or
            [string](Get-MmtlAcceptanceProperty $identity 'universeHash') -cne $expectedUniverseHash -or
            [string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash') -notmatch '^[a-f0-9]{64}$' -or
            [string](Get-MmtlAcceptanceProperty $identity 'adapterSha256') -notmatch '^[a-f0-9]{64}$' -or
            [string](Get-MmtlAcceptanceProperty $identity 'toolchainHash') -notmatch '^[a-f0-9]{64}$' -or
            [string](Get-MmtlAcceptanceProperty $report 'loaderId') -cne [string](Get-MmtlAcceptanceProperty $target 'loaderId') -or
            [string](Get-MmtlAcceptanceProperty $report 'minecraftId') -cne [string](Get-MmtlAcceptanceProperty $target 'minecraftId') -or
            [string](Get-MmtlAcceptanceProperty $report 'loaderVersion') -notmatch '^\S.{0,127}$'
        if ($identityInvalid) { $invalidTargetIdentity++; $targetFailed = $true }
        $targetSourceHash = Get-MmtlAcceptanceProperty $target 'sourceHash'
        $identitySourceHash = Get-MmtlAcceptanceProperty $identity 'sourceHash'
        if ($null -ne $targetSourceHash -and [string]$identitySourceHash -cne [string]$targetSourceHash) { $invalidTargetIdentity++; $targetFailed = $true }
        $loaderCandidates = @(Get-MmtlAcceptanceProperty $target 'loaderVersionCandidates')
        if ($loaderCandidates.Count -gt 0 -and [string](Get-MmtlAcceptanceProperty $report 'loaderVersion') -cnotin @($loaderCandidates | ForEach-Object { [string]$_ })) { $invalidTargetIdentity++; $targetFailed = $true }

        $requiredStages = @('BuildExact','RuntimeBinding','ClientLaunch','MultiWindow','SingleAssertion','MultiplayerJoinAndAssertion','TargetReport','SafeStop')
        $stagePass = @{}
        foreach ($dimension in $requiredStages + @('AgentBuild','AgentInjection','DedicatedServer','NativeIntegratedLAN','HistoricalDedicatedEquivalent')) {
            $stage = Get-MmtlAcceptanceStage -Report $report -Dimension $dimension
            $passed = $null -ne $stage -and (Test-MmtlAcceptanceEvidence -Target $target -Report $report -Stage $stage -EvidenceIndex $EvidenceIndex -RunId $RunId)
            $stagePass[$dimension] = $passed
            if (-not $passed -and $dimension -in $requiredStages) {
                $targetFailed = $true
                $missingRefs.Add("$targetId/$dimension")
                $stageDimension = [string](Get-MmtlAcceptanceProperty $stage 'dimension')
                $expectedIndexDimensions = @($script:MmtlAcceptanceDimensionAliases.GetEnumerator() | Where-Object { $_.Value -contains $stageDimension } | ForEach-Object { $_.Value })
                if ($expectedIndexDimensions.Count -eq 0) { $expectedIndexDimensions = @($stageDimension) }
                if ($null -ne $stage) {
                    $stageRefs = Get-MmtlAcceptanceProperty $stage 'evidenceRefs'
                    $stageHashes = Get-MmtlAcceptanceProperty $stage 'evidenceSha256'
                    if ($null -ne $stageRefs -and $null -ne $stageHashes) {
                        $refs = @($stageRefs)
                        $hashes = @($stageHashes)
                        for ($refIndex = 0; $refIndex -lt [Math]::Max($refs.Count, $hashes.Count); $refIndex++) {
                            $ref = if ($refIndex -lt $refs.Count) { [string]$refs[$refIndex] } else { '' }
                            $hash = if ($refIndex -lt $hashes.Count) { [string]$hashes[$refIndex] } else { '' }
                            $safeRef = -not [string]::IsNullOrWhiteSpace($ref) -and -not [IO.Path]::IsPathRooted($ref) -and -not $ref.Contains('\') -and @($ref -split '/' | Where-Object { $_ -in @('', '.', '..') }).Count -eq 0
                            $indexed = if ($safeRef -and $hash -cmatch '^[a-f0-9]{64}$' -and $null -ne $identity) {
                                @((Get-MmtlAcceptanceProperty $EvidenceIndex 'entries') | Where-Object {
                                    [string](Get-MmtlAcceptanceProperty $_ 'targetId') -ceq $targetId -and
                                    [string](Get-MmtlAcceptanceProperty $_ 'targetSpecHash') -ceq [string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash') -and
                            [string](Get-MmtlAcceptanceProperty $_ 'adapterSha256') -ceq [string](Get-MmtlAcceptanceProperty $identity 'adapterSha256') -and
                            [string](Get-MmtlAcceptanceProperty $_ 'toolchainHash') -ceq [string](Get-MmtlAcceptanceProperty $identity 'toolchainHash') -and
                                    [string](Get-MmtlAcceptanceProperty $_ 'dimension') -cin $expectedIndexDimensions -and
                                    [string](Get-MmtlAcceptanceProperty $_ 'evidencePath') -ceq $ref -and
                                    [string](Get-MmtlAcceptanceProperty $_ 'evidenceSha256') -ceq $hash
                                }).Count -eq 1
                            } else { $false }
                            if (-not $safeRef -or $hash -cnotmatch '^[a-f0-9]{64}$' -or -not $indexed) { $invalidRefs.Add("$targetId/$($dimension):$ref") }
                        }
                    }
                }
            }
        }

        if ($stagePass.BuildExact) { $null = $counts.buildExactPass.Add($targetId) }
        if ($stagePass.RuntimeBinding) { $null = $counts.runtimeBindingPass.Add($targetId) }
        if ($stagePass.ClientLaunch) { $null = $counts.realClientPass.Add($targetId) }

        $window = Get-MmtlAcceptanceProperty $report 'windowPairProof'
        $windowReadyEvents = @(Get-MmtlAcceptanceProperty $window 'readyEvents')
        $windowIntervals = Get-MmtlAcceptanceProperty $window 'simultaneousIntervalUtc'
        $windowStart = [DateTimeOffset]::MinValue
        $windowEnd = [DateTimeOffset]::MinValue
        $windowIntervalValid = $null -ne $windowIntervals -and
            [DateTimeOffset]::TryParse([string](Get-MmtlAcceptanceProperty $windowIntervals 'start'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$windowStart) -and
            [DateTimeOffset]::TryParse([string](Get-MmtlAcceptanceProperty $windowIntervals 'end'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$windowEnd) -and
            $windowEnd -gt $windowStart
        $readyPidA = if ($windowReadyEvents.Count -eq 2) { [int](Get-MmtlAcceptanceProperty $windowReadyEvents[0] 'pid') } else { 0 }
        $readyPidB = if ($windowReadyEvents.Count -eq 2) { [int](Get-MmtlAcceptanceProperty $windowReadyEvents[1] 'pid') } else { 0 }
        $readyIdentityA = if ($windowReadyEvents.Count -eq 2) { [string](Get-MmtlAcceptanceProperty $windowReadyEvents[0] 'processIdentity') } else { '' }
        $readyIdentityB = if ($windowReadyEvents.Count -eq 2) { [string](Get-MmtlAcceptanceProperty $windowReadyEvents[1] 'processIdentity') } else { '' }
        $windowValid = $clientCount -eq 2 -and $stagePass.MultiWindow -and $null -ne $window -and [bool](Get-MmtlAcceptanceProperty $window 'passed') -and
            [int](Get-MmtlAcceptanceProperty $window 'clientAPid') -gt 0 -and [int](Get-MmtlAcceptanceProperty $window 'clientBPid') -gt 0 -and [int](Get-MmtlAcceptanceProperty $window 'clientAPid') -ne [int](Get-MmtlAcceptanceProperty $window 'clientBPid') -and
            [string](Get-MmtlAcceptanceProperty $window 'clientAWindowId') -and [string](Get-MmtlAcceptanceProperty $window 'clientBWindowId') -and [string](Get-MmtlAcceptanceProperty $window 'clientAWindowId') -cne [string](Get-MmtlAcceptanceProperty $window 'clientBWindowId') -and
            $windowIntervalValid -and $windowReadyEvents.Count -eq 2 -and $readyPidA -eq [int](Get-MmtlAcceptanceProperty $window 'clientAPid') -and $readyPidB -eq [int](Get-MmtlAcceptanceProperty $window 'clientBPid') -and
            $readyPidA -ne $readyPidB -and $readyIdentityA -and $readyIdentityB -and $readyIdentityA -cne $readyIdentityB
        if ($windowValid) { $null = $counts.multiWindowPass.Add($targetId) } else { $targetFailed = $true; $missingRefs.Add("$targetId/WindowPairProof") }

        $singleValid = $stagePass.SingleAssertion -and (Test-MmtlSingleAssertionProof -Target $target -Report $report -EvidenceIndex $EvidenceIndex -ClientCount $(if ($clientCount -gt 0) { $clientCount } else { 2 }) -WindowPairProof (Get-MmtlAcceptanceProperty $report 'windowPairProof'))
        if ($singleValid) { $null = $counts.singlePass.Add($targetId) } else { $targetFailed = $true; $missingRefs.Add("$targetId/SingleAssertionProof") }

        $world = Get-MmtlAcceptanceProperty $report 'worldProof'
        $actor = Get-MmtlAcceptanceProperty $world 'actorA'
        $observer = Get-MmtlAcceptanceProperty $world 'observerB'
        $actionProof = Get-MmtlAcceptanceProperty $world 'actionProof'
        $observationProof = Get-MmtlAcceptanceProperty $world 'observationProof'
        $sharedWorldKey = [string](Get-MmtlAcceptanceProperty $world 'sharedWorldKey')
        $actorPlayer = [string](Get-MmtlAcceptanceProperty $actor 'playerIdentity')
        $observerPlayer = [string](Get-MmtlAcceptanceProperty $observer 'playerIdentity')
        $worldValid = $stagePass.MultiplayerJoinAndAssertion -and $null -ne $world -and [bool](Get-MmtlAcceptanceProperty $world 'passed') -and
            $sharedWorldKey -and $actorPlayer -and $observerPlayer -and $actorPlayer -cne $observerPlayer -and
            [int](Get-MmtlAcceptanceProperty $actor 'processId') -gt 0 -and [int](Get-MmtlAcceptanceProperty $observer 'processId') -gt 0 -and
            [int](Get-MmtlAcceptanceProperty $actor 'processId') -ne [int](Get-MmtlAcceptanceProperty $observer 'processId') -and
            [int](Get-MmtlAcceptanceProperty $actionProof 'processId') -eq [int](Get-MmtlAcceptanceProperty $actor 'processId') -and
            [int](Get-MmtlAcceptanceProperty $observationProof 'processId') -eq [int](Get-MmtlAcceptanceProperty $observer 'processId') -and
            [string](Get-MmtlAcceptanceProperty $actionProof 'stateSha256') -match '^[a-f0-9]{64}$' -and
            [string](Get-MmtlAcceptanceProperty $actionProof 'stateSha256') -ceq [string](Get-MmtlAcceptanceProperty $observationProof 'stateSha256') -and
            [string](Get-MmtlAcceptanceProperty $actionProof 'eventId') -and [string](Get-MmtlAcceptanceProperty $observationProof 'eventId')
        $path = [string](Get-MmtlAcceptanceProperty $report 'multiplayerPath')
        $historicalServerProofValid = if ($path -ceq 'HistoricalDedicatedEquivalent') {
            Test-MmtlHistoricalServerRunProof -Target $target -Report $report -Proof (Get-MmtlAcceptanceProperty $report 'historicalServerProof')
        } else { $false }
        if ($path -ceq 'HistoricalDedicatedEquivalent' -and -not $historicalServerProofValid) {
            $targetFailed = $true
            $reasons.Add('HISTORICAL_SERVER_PROOF_INVALID')
            $missingRefs.Add("$targetId/HistoricalServerProof")
        }
        if (($stagePass.NativeIntegratedLAN -and $stagePass.HistoricalDedicatedEquivalent) -or
            ($path -ceq 'NativeIntegratedLAN' -and $stagePass.HistoricalDedicatedEquivalent) -or
            ($path -ceq 'HistoricalDedicatedEquivalent' -and $stagePass.NativeIntegratedLAN)) {
            $targetFailed = $true
            $reasons.Add('MULTIPLAYER_PATH_EVIDENCE_CONFLICT')
            $missingRefs.Add("$targetId/MultiplayerPathExclusiveEvidence")
        }
        if ($worldValid -and $path -ceq 'NativeIntegratedLAN' -and $stagePass.NativeIntegratedLAN -and -not $stagePass.HistoricalDedicatedEquivalent) {
            $null = $counts.multiplayerPass.Add($targetId); $null = $counts.nativeLanPass.Add($targetId)
        }
        elseif ($worldValid -and $path -ceq 'HistoricalDedicatedEquivalent' -and $historicalServerProofValid -and $stagePass.HistoricalDedicatedEquivalent -and -not $stagePass.NativeIntegratedLAN -and [bool](Get-MmtlAcceptanceProperty $report 'historicalPathEligibilityVerified') -and
            [string](Get-MmtlAcceptanceProperty $target 'minecraftType') -ceq 'release' -and
            [string](Get-MmtlAcceptanceProperty $target 'minecraftId') -match '^\d+\.\d+(\.\d+)?$' -and
            [version]('{0}.0' -f [string](Get-MmtlAcceptanceProperty $target 'minecraftId')) -lt [version]'1.3.1') {
            $null = $counts.multiplayerPass.Add($targetId); $null = $counts.historicalDedicatedEquivalentPass.Add($targetId)
        }
        else { $targetFailed = $true; $missingRefs.Add("$targetId/MultiplayerJoinAndAssertion") }

        $reportProof = Get-MmtlAcceptanceProperty $report 'reportProof'
        $reportJsonRef = [string](Get-MmtlAcceptanceProperty $reportProof 'jsonRef')
        $reportMarkdownRef = [string](Get-MmtlAcceptanceProperty $reportProof 'markdownRef')
        $reportJsonHash = [string](Get-MmtlAcceptanceProperty $reportProof 'jsonSha256')
        $reportMarkdownHash = [string](Get-MmtlAcceptanceProperty $reportProof 'markdownSha256')
        $reportValid = $stagePass.TargetReport -and $null -ne $reportProof -and [bool](Get-MmtlAcceptanceProperty $reportProof 'schemaValidated') -and
            (Test-MmtlAcceptanceIndexedReference -Target $target -EvidenceIndex $EvidenceIndex -TargetSpecHash ([string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash')) -AdapterSha256 ([string](Get-MmtlAcceptanceProperty $identity 'adapterSha256')) -ToolchainHash ([string](Get-MmtlAcceptanceProperty $identity 'toolchainHash')) -Dimension 'TargetReport' -EvidencePath $reportJsonRef -EvidenceSha256 $reportJsonHash) -and
            (Test-MmtlAcceptanceIndexedReference -Target $target -EvidenceIndex $EvidenceIndex -TargetSpecHash ([string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash')) -AdapterSha256 ([string](Get-MmtlAcceptanceProperty $identity 'adapterSha256')) -ToolchainHash ([string](Get-MmtlAcceptanceProperty $identity 'toolchainHash')) -Dimension 'TargetReport' -EvidencePath $reportMarkdownRef -EvidenceSha256 $reportMarkdownHash)
        if ($reportValid) { $null = $counts.targetReportPass.Add($targetId) } else { $targetFailed = $true; $missingRefs.Add("$targetId/TargetReport") }

        $stop = Get-MmtlAcceptanceProperty $report 'stopProof'
        $stopValid = $stagePass.SafeStop -and $null -ne $stop -and [bool](Get-MmtlAcceptanceProperty $stop 'processTreeStopped') -and [bool](Get-MmtlAcceptanceProperty $stop 'listenerPortsReleased')
        if ($stopValid) { $null = $counts.safeStopPass.Add($targetId) } else { $targetFailed = $true; $missingRefs.Add("$targetId/SafeStop") }

        $targetMinecraftId=[string](Get-MmtlAcceptanceProperty $target 'minecraftId')
        $targetIsOldRelease=[string](Get-MmtlAcceptanceProperty $target 'minecraftType') -ceq 'release' -and $targetMinecraftId -match '^\d+\.\d+(?:\.\d+)?$' -and [version]($targetMinecraftId+'.0') -lt [version]'1.3.1'
        $integratedLanStatus = if ($targetIsOldRelease -and -not $stagePass.NativeIntegratedLAN) { 'UnsupportedByMinecraftVersion' } elseif ($path -ceq 'HistoricalDedicatedEquivalent') { if ($stagePass.NativeIntegratedLAN) { 'Failed' } else { 'NotApplicable' } } elseif ($stagePass.NativeIntegratedLAN -and -not $stagePass.HistoricalDedicatedEquivalent) { 'PASS' } elseif ($stagePass.NativeIntegratedLAN) { 'Failed' } else { 'Missing' }
        $guestJoinedStatus = if ($stagePass.MultiplayerJoinAndAssertion -and $null -ne $world -and [bool](Get-MmtlAcceptanceProperty $world 'passed')) { 'PASS' } elseif ($stagePass.MultiplayerJoinAndAssertion) { 'Failed' } else { 'Missing' }
        $sharedWorldStatus = if ($worldValid) { 'PASS' } elseif ($stagePass.MultiplayerJoinAndAssertion) { 'Failed' } else { 'Missing' }
        $multiplayerStatus = if ($clientCount -eq 1) { 'NotRequested' } elseif ($counts.multiplayerPass.Contains($targetId)) { 'PASS' } elseif ($stagePass.MultiplayerJoinAndAssertion) { 'Failed' } else { 'Missing' }
        $historicalStatus = if ($path -ceq 'HistoricalDedicatedEquivalent' -and $historicalServerProofValid -and $stagePass.HistoricalDedicatedEquivalent -and -not $stagePass.NativeIntegratedLAN) { 'PASS' } elseif ($path -ceq 'HistoricalDedicatedEquivalent') { 'Failed' } elseif ($targetIsOldRelease) { 'NotRequested' } else { 'NotApplicable' }
        $targetDimensionResults.Add([pscustomobject][ordered]@{
            targetId = $targetId
            clientCount = if ($clientCount -gt 0) { $clientCount } else { $null }
            dimensions = [pscustomobject][ordered]@{
                ClientLaunch = if ($stagePass.ClientLaunch) { 'PASS' } else { 'Missing' }
                SingleAssertion = if ($singleValid) { 'PASS' } elseif ($stagePass.SingleAssertion) { 'Failed' } else { 'Missing' }
                MultiWindow = if ($windowValid) { 'PASS' } elseif ($stagePass.MultiWindow) { 'Failed' } else { 'Missing' }
                IntegratedLanPublished = $integratedLanStatus
                HistoricalDedicatedEquivalent = $historicalStatus
                GuestJoined = $guestJoinedStatus
                SharedWorldAssertion = $sharedWorldStatus
                Multiplayer = $multiplayerStatus
                TargetReport = if ($reportValid) { 'PASS' } elseif ($stagePass.TargetReport) { 'Failed' } else { 'Missing' }
                SafeStop = if ($stopValid) { 'PASS' } elseif ($stagePass.SafeStop) { 'Failed' } else { 'Missing' }
            }
        })

        $requirements = Get-MmtlAcceptanceProperty $report 'capabilityRequirements'
        $agentValid = $false
        $dedicatedValid = $false
        if ($null -ne $requirements) {
            if ([string](Get-MmtlAcceptanceProperty $requirements 'agent') -ceq 'Required') { $agentValid = $stagePass.AgentBuild -and $stagePass.AgentInjection }
            elseif ([string](Get-MmtlAcceptanceProperty $requirements 'agent') -ceq 'NotApplicable') {
                $agentEvidence = Get-MmtlAcceptanceProperty $report 'agentApplicabilityEvidence'
                $agentValid = [string](Get-MmtlAcceptanceProperty $report 'agentNotApplicableReason') -and $null -ne $agentEvidence -and
                    (Test-MmtlAcceptanceIndexedReference -Target $target -EvidenceIndex $EvidenceIndex -TargetSpecHash ([string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash')) -AdapterSha256 ([string](Get-MmtlAcceptanceProperty $identity 'adapterSha256')) -ToolchainHash ([string](Get-MmtlAcceptanceProperty $identity 'toolchainHash')) -Dimension 'AgentApplicability' -EvidencePath ([string](Get-MmtlAcceptanceProperty $agentEvidence 'evidencePath')) -EvidenceSha256 ([string](Get-MmtlAcceptanceProperty $agentEvidence 'evidenceSha256')))
            }
            if ([string](Get-MmtlAcceptanceProperty $requirements 'dedicatedServer') -ceq 'Required') { $dedicatedValid = $stagePass.DedicatedServer }
            elseif ([string](Get-MmtlAcceptanceProperty $requirements 'dedicatedServer') -ceq 'NotApplicable') {
                $dedicatedEvidence = Get-MmtlAcceptanceProperty $report 'dedicatedApplicabilityEvidence'
                $dedicatedValid = [string](Get-MmtlAcceptanceProperty $report 'dedicatedNotApplicableReason') -and $null -ne $dedicatedEvidence -and
                    (Test-MmtlAcceptanceIndexedReference -Target $target -EvidenceIndex $EvidenceIndex -TargetSpecHash ([string](Get-MmtlAcceptanceProperty $identity 'targetSpecHash')) -AdapterSha256 ([string](Get-MmtlAcceptanceProperty $identity 'adapterSha256')) -ToolchainHash ([string](Get-MmtlAcceptanceProperty $identity 'toolchainHash')) -Dimension 'DedicatedApplicability' -EvidencePath ([string](Get-MmtlAcceptanceProperty $dedicatedEvidence 'evidencePath')) -EvidenceSha256 ([string](Get-MmtlAcceptanceProperty $dedicatedEvidence 'evidenceSha256')))
            }
        }
        if ($agentValid -and $dedicatedValid) { $null = $counts.agentAndDedicatedPass.Add($targetId) }
        else { $targetFailed = $true; $missingRefs.Add("$targetId/AgentOrDedicatedApplicability") }

        switch ([string](Get-MmtlAcceptanceProperty $report 'blockerClass')) {
            'EXTERNAL_BLOCKED' { $externalBlocked++; $targetFailed = $true }
            'CONSENT_REQUIRED' { $consentRequired++; $targetFailed = $true }
            'SAFETY_BLOCKED' { $safetyBlocked++; $targetFailed = $true }
            'INTERNAL_PENDING' { $internalPending++; $targetFailed = $true }
        }
        if (-not $targetFailed -and [string](Get-MmtlAcceptanceProperty $report 'overallResult') -ceq 'PASS') { $null = $fullPassed.Add($targetId) }
    }

    if ($reportList.Count -ne $targets.Count -or $fullPassed.Count -ne $targets.Count) { $reasons.Add('REQUIRED_EXACT_TARGET_EVIDENCE_INCOMPLETE') }
    if ($counts.multiplayerPass.Count -ne $targets.Count) { $reasons.Add('REQUIRED_MULTIPLAYER_EVIDENCE_MISSING') }
    if ($externalBlocked -gt 0) { $reasons.Add('EXTERNAL_BLOCKED_TARGETS_REMAIN') }
    if ($consentRequired -gt 0) { $reasons.Add('CONSENT_REQUIRED_TARGETS_REMAIN') }
    if ($safetyBlocked -gt 0) { $reasons.Add('SAFETY_BLOCKED_TARGETS_REMAIN') }
    if ($internalPending -gt 0) { $reasons.Add('INTERNAL_PENDING_TARGETS_REMAIN') }
    if ($invalidTargetIdentity -gt 0) { $reasons.Add('TARGET_REPORT_IDENTITY_INVALID') }
    if ($missingRefs.Count -gt 0) { $reasons.Add('REQUIRED_EVIDENCE_REFERENCES_MISSING_OR_INVALID') }
    if ($invalidRefs.Count -gt 0) { $reasons.Add('INVALID_EVIDENCE_REFERENCES') }

    $repoGates = @(Get-MmtlAcceptanceProperty $EvidenceIndex 'repositoryGates')
    $repositoryGatesPassed = $repoGates.Count -gt 0 -and @($repoGates | Where-Object { [string](Get-MmtlAcceptanceProperty $_ 'status') -cne 'PASS' }).Count -eq 0
    if (-not $repositoryGatesPassed) { $reasons.Add('WHOLE_REPOSITORY_GATES_NOT_VERIFIED') }
    $verdict = if ($reasons.Count -eq 0 -and $fullPassed.Count -eq 1631) { 'PASS' } else { 'PARTIAL' }

    $dimensionStatusCounts = [ordered]@{}
    foreach ($dimensionName in @('ClientLaunch','SingleAssertion','MultiWindow','IntegratedLanPublished','HistoricalDedicatedEquivalent','GuestJoined','SharedWorldAssertion','Multiplayer','TargetReport','SafeStop')) {
        $dimensionStatuses = @($targetDimensionResults | ForEach-Object { [string](Get-MmtlAcceptanceProperty (Get-MmtlAcceptanceProperty $_ 'dimensions') $dimensionName) })
        $dimensionStatusCounts[$dimensionName] = [pscustomobject][ordered]@{
            pass = @($dimensionStatuses | Where-Object { $_ -ceq 'PASS' }).Count
            notRequested = @($dimensionStatuses | Where-Object { $_ -ceq 'NotRequested' }).Count
            notApplicable = @($dimensionStatuses | Where-Object { $_ -ceq 'NotApplicable' }).Count
            missing = @($dimensionStatuses | Where-Object { $_ -ceq 'Missing' }).Count
            failed = @($dimensionStatuses | Where-Object { $_ -ceq 'Failed' }).Count
        }
    }

    return [pscustomobject][ordered]@{
        goalVerdict = $verdict
        exactTotal = $targets.Count
        buildExactPass = $counts.buildExactPass.Count
        runtimeBindingPass = $counts.runtimeBindingPass.Count
        realClientPass = $counts.realClientPass.Count
        multiWindowPass = $counts.multiWindowPass.Count
        singlePass = $counts.singlePass.Count
        multiplayerPass = $counts.multiplayerPass.Count
        nativeLanPass = $counts.nativeLanPass.Count
        historicalDedicatedEquivalentPass = $counts.historicalDedicatedEquivalentPass.Count
        targetReportPass = $counts.targetReportPass.Count
        safeStopPass = $counts.safeStopPass.Count
        agentAndDedicatedPass = $counts.agentAndDedicatedPass.Count
        fullTargetPassUnique = $fullPassed.Count
        externalBlocked = $externalBlocked
        consentRequired = $consentRequired
        safetyBlocked = $safetyBlocked
        internalPending = $internalPending
        invalidTargetIdentity = $invalidTargetIdentity
        missingEvidenceRefs = @($missingRefs | Select-Object -Unique)
        invalidEvidenceRefs = @($invalidRefs | Select-Object -Unique)
        targetDimensionResults = @($targetDimensionResults)
        dimensionStatusCounts = [pscustomobject]$dimensionStatusCounts
        reasons = @($reasons | Select-Object -Unique)
    }
}

Export-ModuleMember -Function Test-MmtlExactGoalAcceptance
