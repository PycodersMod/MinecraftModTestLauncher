Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-MmtlGoalRunRoot {
    param([Parameter(Mandatory)][string]$RunRoot)

    $full = [IO.Path]::GetFullPath($RunRoot)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) -eq $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) {
        throw 'RUN_ROOT_CANNOT_BE_FILESYSTEM_ROOT'
    }

    $cursor = $root
    $relative = $full.Substring($root.Length)
    foreach ($segment in ($relative -split '[\\/]+' | Where-Object { $_ })) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) {
                throw 'RUN_ROOT_REPARSE_PATH'
            }
        }
    }

    return $full
}

function Get-MmtlGoalRunMetadata {
    param([Parameter(Mandatory)][string]$RunRoot)

    $full = Assert-MmtlGoalRunRoot -RunRoot $RunRoot
    $metadataPath = Join-Path $full 'run.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { throw 'GOAL_RUN_NOT_INITIALIZED' }
    return Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -ErrorAction Stop
}

function ConvertTo-MmtlGoalCanonicalJson {
    param([Parameter(Mandatory)]$Value)
    return ConvertTo-Json -InputObject $Value -Depth 40 -Compress
}

function Get-MmtlGoalSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-MmtlGoalUtcTimestamp {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]::new($Value)).ToUniversalTime() }
    return ([DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
}

function Protect-MmtlGoalText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }
    $safe = [regex]::Replace($Text, '(?i)(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|Bearer\s+[^\s"'']+)', '<REDACTED_TOKEN>')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z]:\\[^\s"'']+', '<REDACTED_PATH>')
    $safe = [regex]::Replace($safe, '(?<![A-Za-z0-9])/(?:home|mnt|tmp)/[^\s"'']+', '<REDACTED_PATH>')
    return $safe
}

function ConvertTo-MmtlGoalSafeRecord {
    param([Parameter(Mandatory)]$Record)
    $safe = [ordered]@{}
    foreach ($property in $Record.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [string]) { $value = Protect-MmtlGoalText -Text $value }
        elseif ($value -is [Array]) {
            $value = @($value | ForEach-Object { if ($_ -is [string]) { Protect-MmtlGoalText -Text $_ } else { $_ } })
        }
        $safe[$property.Name] = $value
    }
    return [pscustomobject]$safe
}

function ConvertFrom-MmtlGoalJournalText {
    param([Parameter(Mandatory)][string]$Text)

    $completeText = $Text
    $incomplete = 0
    if ($Text.Length -gt 0 -and -not $Text.EndsWith("`n", [StringComparison]::Ordinal)) {
        $lastBreak = $Text.LastIndexOf("`n")
        $completeText = if ($lastBreak -ge 0) { $Text.Substring(0, $lastBreak + 1) } else { '' }
        $incomplete = 1
    }

    $records = [Collections.Generic.List[object]]::new()
    $invalid = 0
    foreach ($line in ($completeText -split "`n")) {
        $candidate = $line.TrimEnd("`r")
        if (-not $candidate) { continue }
        try {
            $value = $candidate | ConvertFrom-Json -ErrorAction Stop
            if (-not $value -or -not $value.eventType) { $invalid++; continue }
            $records.Add($value)
        }
        catch { $invalid++ }
    }

    return [pscustomobject]@{ records = @($records.ToArray()); incompleteTrailingLineCount = $incomplete; invalidLineCount = $invalid }
}

function Read-MmtlGoalJournal {
    param([Parameter(Mandatory)][string]$RunRoot)

    $full = Assert-MmtlGoalRunRoot -RunRoot $RunRoot
    $journalPath = Join-Path $full 'events.jsonl'
    if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        return [pscustomobject]@{ records = @(); incompleteTrailingLineCount = 0; invalidLineCount = 0 }
    }
    $stream = $null
    for ($retry = 0; $retry -lt 100; $retry++) {
        try {
            $stream = [IO.FileStream]::new($journalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            break
        }
        catch [IO.IOException] {
            if ($retry -eq 99) { throw 'GOAL_JOURNAL_READ_LOCK_TIMEOUT' }
            Start-Sleep -Milliseconds 20
        }
    }
    try {
        $buffer = [byte[]]::new([int]$stream.Length)
        $read = 0
        while ($read -lt $buffer.Length) { $count = $stream.Read($buffer, $read, $buffer.Length - $read); if ($count -eq 0) { break }; $read += $count }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $read)
    }
    finally { $stream.Dispose() }
    return ConvertFrom-MmtlGoalJournalText -Text $text
}

function Enter-MmtlGoalAttemptLock {
    param([Parameter(Mandatory)][string]$RunRoot)
    $full = Assert-MmtlGoalRunRoot -RunRoot $RunRoot
    $name = 'MMTLGoalProgress_' + (Get-MmtlGoalSha256 -Text $full.ToLowerInvariant())
    $mutex = [Threading.Mutex]::new($false, $name)
    $acquired = $false
    try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(60)) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { $mutex.Dispose(); throw 'GOAL_ATTEMPT_LOCK_TIMEOUT' }
    return $mutex
}

function Exit-MmtlGoalAttemptLock {
    param([Parameter(Mandatory)][Threading.Mutex]$Mutex)
    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

function Add-MmtlGoalJournalRecord {
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$IdentityProperty,
        [string]$IdentityHash
    )

    $full = Assert-MmtlGoalRunRoot -RunRoot $RunRoot
    $null = Get-MmtlGoalRunMetadata -RunRoot $full
    $identity = [string]$Record.$IdentityProperty
    if (-not $identity) { throw "EVENT_ID_REQUIRED:$IdentityProperty" }

    $payloadJson = ConvertTo-MmtlGoalCanonicalJson -Value $Record
    $payloadHash = if ($IdentityHash) { $IdentityHash } else { Get-MmtlGoalSha256 -Text $payloadJson }
    $persistedRecord = [ordered]@{}
    foreach ($property in $Record.PSObject.Properties) { $persistedRecord[$property.Name] = $property.Value }
    $persistedRecord.runId = [string](Get-MmtlGoalRunMetadata -RunRoot $full).runId
    $persistedRecord.eventHash = $payloadHash
    $persistedRecord.recordedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $line = ConvertTo-MmtlGoalCanonicalJson -Value ([pscustomobject]$persistedRecord)
    $lineBytes = [Text.UTF8Encoding]::new($false).GetBytes($line + "`n")
    $journalPath = Join-Path $full 'events.jsonl'

    $stream = $null
    for ($retry = 0; $retry -lt 100; $retry++) {
        try {
            $stream = [IO.FileStream]::new($journalPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            break
        }
        catch [IO.IOException] {
            if ($retry -eq 99) { throw 'GOAL_JOURNAL_LOCK_TIMEOUT' }
            Start-Sleep -Milliseconds 20
        }
    }

    try {
        $existingText = ''
        if ($stream.Length -gt 0) {
            $stream.Position = 0
            $buffer = [byte[]]::new([int]$stream.Length)
            $read = 0
            while ($read -lt $buffer.Length) { $count = $stream.Read($buffer, $read, $buffer.Length - $read); if ($count -eq 0) { break }; $read += $count }
            $existingText = [Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, $read)
            $parsed = ConvertFrom-MmtlGoalJournalText -Text $existingText
            foreach ($old in $parsed.records) {
                $oldIdentity = $old.PSObject.Properties[$IdentityProperty]
                if (-not $oldIdentity -or [string]$oldIdentity.Value -cne $identity) { continue }
                if ([string]$old.eventHash -cne $payloadHash) { throw "ATTEMPT_ID_CONTENT_CONFLICT:$identity" }
                return [pscustomobject]@{ persisted = $true; duplicate = $true; eventHash = $payloadHash; eventId = $identity }
            }
        }

        $stream.Position = $stream.Length
        if ($stream.Length -gt 0 -and $existingText.Length -gt 0 -and -not $existingText.EndsWith("`n", [StringComparison]::Ordinal)) {
            $stream.WriteByte(10)
        }
        $stream.Write($lineBytes, 0, $lineBytes.Length)
        $stream.Flush($true)
        return [pscustomobject]@{ persisted = $true; duplicate = $false; eventHash = $payloadHash; eventId = $identity }
    }
    finally { $stream.Dispose() }
}

function Start-MmtlGoalProgressRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$UniverseHash,
        [ValidateRange(0, 100000)][int]$UniverseTargetCount = 0,
        [DateTimeOffset]$StartedAtUtc = [DateTimeOffset]::UtcNow
    )

    $full = Assert-MmtlGoalRunRoot -RunRoot $RunRoot
    $null = New-Item -ItemType Directory -Path $full -Force
    $metadataPath = Join-Path $full 'run.json'
    if (Test-Path -LiteralPath $metadataPath) { throw 'GOAL_RUN_ALREADY_EXISTS' }
    $metadata = [pscustomobject][ordered]@{
        schemaVersion = 1
        runId = $RunId
        universeHash = $UniverseHash
        universeTargetCount = $UniverseTargetCount
        startedAtUtc = $StartedAtUtc.ToUniversalTime().ToString('o')
        phase = 'Active'
    }
    $json = ConvertTo-MmtlGoalCanonicalJson -Value $metadata
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [IO.FileStream]::new($metadataPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    return $metadata
}

function Write-MmtlGoalAttemptEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunRoot, [Parameter(Mandatory)]$Event)

    $required = @('attemptId','loaderId','minecraftId','targetId','loaderVersion','familyId','adapterId','batchId','batchInputSha256','universeHash','sourceHash','toolchainHash','targetSpecHash','dimension','status','attemptNumber','isFreshExecution','startedAtUtc','endedAtUtc','durationSeconds','workerTestSeconds','cumulativeRepairSeconds','evidencePaths','evidenceSha256','nextAction')
    foreach ($name in $required) { if (-not $Event.PSObject.Properties[$name]) { throw "ATTEMPT_FIELD_REQUIRED:$name" } }
    if ([string]$Event.eventType -cne 'Attempt') { throw 'ATTEMPT_EVENT_TYPE_INVALID' }
    if ([string]$Event.targetId -cne ([string]$Event.loaderId + '@' + [string]$Event.minecraftId)) { throw 'ATTEMPT_EXACT_TARGET_ID_MISMATCH' }
    if ([string]$Event.status -notin @('PASS','FAIL','BLOCKED','TIMEOUT','CACHED')) { throw 'ATTEMPT_STATUS_INVALID' }
    foreach ($name in @('batchInputSha256','universeHash','sourceHash','toolchainHash','targetSpecHash')) {
        if ([string]$Event.$name -cnotmatch '^[a-f0-9]{64}$') { throw "ATTEMPT_HASH_INVALID:$name" }
    }
    $metadata = Get-MmtlGoalRunMetadata -RunRoot $RunRoot
    if ([string]$Event.universeHash -cne [string]$metadata.universeHash) { throw 'ATTEMPT_UNIVERSE_HASH_MISMATCH' }
    if ([string]$Event.status -ceq 'CACHED' -and [bool]$Event.isFreshExecution) { throw 'CACHED_EVENT_CANNOT_BE_FRESH' }
    if ([int]$Event.attemptNumber -lt 1) { throw 'ATTEMPT_NUMBER_INVALID' }
    if ([double]$Event.durationSeconds -lt 0 -or [double]$Event.workerTestSeconds -lt 0 -or [double]$Event.cumulativeRepairSeconds -lt 0) { throw 'ATTEMPT_DURATION_INVALID' }

    $started = ConvertTo-MmtlGoalUtcTimestamp -Value $Event.startedAtUtc
    $ended = ConvertTo-MmtlGoalUtcTimestamp -Value $Event.endedAtUtc
    if ($ended -lt $started) { throw 'ATTEMPT_END_BEFORE_START' }
    if ([Math]::Abs(($ended - $started).TotalSeconds - [double]$Event.durationSeconds) -gt 1.0) { throw 'ATTEMPT_DURATION_MISMATCH' }
    foreach ($path in @($Event.evidencePaths)) {
        $value = [string]$path
        if (-not $value -or [IO.Path]::IsPathRooted($value) -or $value.Contains('\') -or @($value -split '/' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) { throw 'ATTEMPT_EVIDENCE_PATH_INVALID' }
    }
    $evidencePaths = @($Event.evidencePaths)
    $evidenceDigests = @($Event.evidenceSha256)
    if ($evidencePaths.Count -ne $evidenceDigests.Count) { throw 'ATTEMPT_EVIDENCE_DIGEST_COUNT_MISMATCH' }
    foreach ($digest in $evidenceDigests) {
        if ([string]$digest -cnotmatch '^[a-f0-9]{64}$') { throw 'ATTEMPT_EVIDENCE_DIGEST_INVALID' }
    }
    if ([string]$Event.status -ceq 'PASS' -and [bool]$Event.isFreshExecution -and $evidencePaths.Count -eq 0) { throw 'ATTEMPT_PASS_EVIDENCE_REQUIRED' }

    $attemptLock = Enter-MmtlGoalAttemptLock -RunRoot $RunRoot
    try {
        $safeEvent = ConvertTo-MmtlGoalSafeRecord -Record $Event
        $priorJournal = Read-MmtlGoalJournal -RunRoot $RunRoot
        $sameAttemptId = @($priorJournal.records | Where-Object { $_.eventType -ceq 'Attempt' -and $_.attemptId -ceq $safeEvent.attemptId } | Select-Object -First 1)
        if ($sameAttemptId.Count -gt 0) {
            $safeEvent.attemptNumber = [int]$sameAttemptId[0].attemptNumber
        } else {
            $priorExactAttempts = @($priorJournal.records | Where-Object { $_.eventType -ceq 'Attempt' -and $_.targetId -ceq $safeEvent.targetId -and $_.dimension -ceq $safeEvent.dimension })
            $safeEvent.attemptNumber = $priorExactAttempts.Count + 1
        }
        $identityHash = Get-MmtlGoalSha256 -Text (ConvertTo-MmtlGoalCanonicalJson -Value $safeEvent)
        $before = Get-MmtlGoalProgressSummary -RunRoot $RunRoot
        $passCounts = [ordered]@{
        BuildExact=$before.buildExactPassUnique; RuntimeBinding=$before.runtimeBindingPassUnique
        ClientLaunch=$before.clientLaunchPassUnique; MultiWindow=$before.multiWindowPassUnique
        SingleAssertion=$before.singleAssertionPassUnique
        MultiplayerJoinAndAssertion=$before.multiplayerJoinAndAssertionPassUnique
        DedicatedServer=$before.dedicatedServerPassUnique; AgentBuild=$before.agentBuildPassUnique
        AgentInjection=$before.agentInjectionPassUnique; TargetReport=$before.targetReportPassUnique
        SafeStop=$before.safeStopPassUnique; NativeLAN=$before.nativeLanPassUnique
        HistoricalDedicatedEquivalent=$before.historicalDedicatedEquivalentPassUnique
        MultiplayerPath=$before.multiplayerPathPassUnique
        }
        $dimensionAliases = @{
        BuildExact=@('BuildExact','BuildExactPass'); RuntimeBinding=@('RuntimeBinding','RuntimeBindingPass')
        ClientLaunch=@('ClientLaunch','ClientLaunchPass'); MultiWindow=@('MultiWindow','MultiWindowPass')
        SingleAssertion=@('SingleAssertion','SingleAssertionPass','AgentSingleAssertion')
        MultiplayerJoinAndAssertion=@('MultiplayerJoinAndAssertion','MultiplayerJoinAndAssertionPass')
        DedicatedServer=@('DedicatedServer','DedicatedServerPass','DedicatedValidation')
        AgentBuild=@('AgentBuild','AgentBuildPass'); AgentInjection=@('AgentInjection','AgentInjectionPass')
        TargetReport=@('TargetReport','TargetReportPass'); SafeStop=@('SafeStop','SafeStopPass')
        NativeLAN=@('NativeIntegratedLAN','NativeLAN','NativeLan','NativeLanPass')
        HistoricalDedicatedEquivalent=@('HistoricalDedicatedEquivalent','HistoricalDedicatedEquivalentPass')
        }
        if ($safeEvent.status -ceq 'PASS' -and [bool]$safeEvent.isFreshExecution) {
        foreach ($name in $dimensionAliases.Keys) {
            if ([string]$safeEvent.dimension -notin $dimensionAliases[$name]) { continue }
            $priorJournal = Read-MmtlGoalJournal -RunRoot $RunRoot
            $alreadyPassed = @($priorJournal.records | Where-Object {
                $_.eventType -ceq 'Attempt' -and $_.status -ceq 'PASS' -and [bool]$_.isFreshExecution -and
                $_.targetId -ceq $safeEvent.targetId -and $_.dimension -in $dimensionAliases[$name]
            }).Count -gt 0
            if (-not $alreadyPassed) { $passCounts[$name]++ }
            break
        }
        }
        $safeEvent.cumulativeRepairSeconds = $before.adaptationActiveElapsedSeconds
        $safeEvent | Add-Member -NotePropertyName cumulativeGoalWallElapsedSeconds -NotePropertyValue $before.goalWallElapsedSeconds -Force
        $safeEvent | Add-Member -NotePropertyName cumulativeGoalActiveElapsedSeconds -NotePropertyValue $before.goalActiveElapsedSeconds -Force
        $safeEvent | Add-Member -NotePropertyName dimensionPassCounts -NotePropertyValue ([pscustomobject]$passCounts) -Force
        $result = Add-MmtlGoalJournalRecord -RunRoot $RunRoot -Record $safeEvent -IdentityProperty 'attemptId' -IdentityHash $identityHash
    }
    finally { Exit-MmtlGoalAttemptLock -Mutex $attemptLock }
    Write-Host ("[{0}] {1} loader={2} family={3} batch={4} {5}={6} attempt={7} {8}s unique(build/launch/multi/nativeLAN/historicalMP/multiplayer/report)={9}/{10}/{11}/{12}/{13}/{14}/{15} active={16}s" -f $safeEvent.loaderId,$safeEvent.minecraftId,$safeEvent.loaderVersion,$safeEvent.familyId,$safeEvent.batchId,$safeEvent.dimension,$safeEvent.status,$safeEvent.attemptNumber,$safeEvent.durationSeconds,$passCounts.BuildExact,$passCounts.ClientLaunch,$passCounts.MultiWindow,$passCounts.NativeLAN,$passCounts.HistoricalDedicatedEquivalent,$passCounts.MultiplayerPath,$passCounts.TargetReport,$before.goalActiveElapsedSeconds)
    if (-not $result.duplicate) { Invoke-MmtlGoalPeriodicSummary -RunRoot $RunRoot }
    return $result
}

function Write-MmtlGoalWorkInterval {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunRoot, [Parameter(Mandatory)]$Interval)

    foreach ($name in @('intervalId','category','startedAtUtc','endedAtUtc')) { if (-not $Interval.PSObject.Properties[$name]) { throw "WORK_INTERVAL_FIELD_REQUIRED:$name" } }
    if ([string]$Interval.category -notin @('WorkerTest','BatchPreparation','Adaptation','Infrastructure','HistoricalServerPreparation')) { throw 'WORK_INTERVAL_CATEGORY_INVALID' }
    if ([string]$Interval.category -ceq 'Adaptation' -and -not [string]$Interval.issueId) { throw 'ADAPTATION_ISSUE_ID_REQUIRED' }
    $start = ConvertTo-MmtlGoalUtcTimestamp -Value $Interval.startedAtUtc
    $end = ConvertTo-MmtlGoalUtcTimestamp -Value $Interval.endedAtUtc
    if ($end -lt $start) { throw 'WORK_INTERVAL_END_BEFORE_START' }
    $record = [ordered]@{ eventType='WorkInterval' }
    foreach ($property in $Interval.PSObject.Properties) { $record[$property.Name] = $property.Value }
    $record.durationSeconds = ($end - $start).TotalSeconds
    $result = Add-MmtlGoalJournalRecord -RunRoot $RunRoot -Record ([pscustomobject]$record) -IdentityProperty 'intervalId'
    if (-not $result.duplicate) { Invoke-MmtlGoalPeriodicSummary -RunRoot $RunRoot }
    return $result
}

function Test-MmtlGoalAttemptRecorded {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunRoot,[Parameter(Mandatory)]$Event)

    $journal = Read-MmtlGoalJournal -RunRoot $RunRoot
    foreach ($record in @($journal.records | Where-Object eventType -CEQ 'Attempt')) {
        if ([string]$record.targetId -cne [string]$Event.targetId -or
            [string]$record.dimension -cne [string]$Event.dimension -or
            [string]$record.batchId -cne [string]$Event.batchId -or
            [string]$record.batchInputSha256 -cne [string]$Event.batchInputSha256 -or
            [string]$record.status -cne [string]$Event.status -or
            [string]$record.universeHash -cne [string]$Event.universeHash -or
            [string]$record.sourceHash -cne [string]$Event.sourceHash -or
            [string]$record.toolchainHash -cne [string]$Event.toolchainHash -or
            [string]$record.targetSpecHash -cne [string]$Event.targetSpecHash) { continue }
        $recordStarted = (ConvertTo-MmtlGoalUtcTimestamp -Value $record.startedAtUtc).UtcTicks
        $eventStarted = (ConvertTo-MmtlGoalUtcTimestamp -Value $Event.startedAtUtc).UtcTicks
        $recordEnded = (ConvertTo-MmtlGoalUtcTimestamp -Value $record.endedAtUtc).UtcTicks
        $eventEnded = (ConvertTo-MmtlGoalUtcTimestamp -Value $Event.endedAtUtc).UtcTicks
        $recordWorker = if ($record.PSObject.Properties['workerId']) { [string]$record.workerId } else { 'legacy-unattributed:' + [string]$record.attemptId }
        $eventWorker = if ($Event.PSObject.Properties['workerId']) { [string]$Event.workerId } else { 'legacy-unattributed:' + [string]$Event.attemptId }
        $hasRecoveryWorker = $recordWorker -ceq 'recovered-from-matrix-state' -or $eventWorker -ceq 'recovered-from-matrix-state'
        if ([int]$record.attemptNumber -ne [int]$Event.attemptNumber) {
            if ($hasRecoveryWorker) {
                $recordStartSecond = (ConvertTo-MmtlGoalUtcTimestamp -Value $record.startedAtUtc).ToUnixTimeSeconds()
                $eventStartSecond = (ConvertTo-MmtlGoalUtcTimestamp -Value $Event.startedAtUtc).ToUnixTimeSeconds()
                $recordEndSecond = (ConvertTo-MmtlGoalUtcTimestamp -Value $record.endedAtUtc).ToUnixTimeSeconds()
                $eventEndSecond = (ConvertTo-MmtlGoalUtcTimestamp -Value $Event.endedAtUtc).ToUnixTimeSeconds()
                if ($recordStartSecond -ne $eventStartSecond -or $recordEndSecond -ne $eventEndSecond) { continue }
            } elseif ($recordStarted -ne $eventStarted -or $recordEnded -ne $eventEnded) { continue }
        }
        if ($recordWorker -cne $eventWorker -and $recordWorker -cne 'recovered-from-matrix-state' -and $eventWorker -cne 'recovered-from-matrix-state') { continue }
        $recordEvidenceCount = @($record.evidenceSha256).Count
        $eventEvidenceCount = @($Event.evidenceSha256).Count
        $isEvidenceOmittedByRecovery = $hasRecoveryWorker -and ([string]$record.status -ceq 'FAIL') -and ($recordEvidenceCount -eq 0 -or $eventEvidenceCount -eq 0)
        if (-not $isEvidenceOmittedByRecovery -and (ConvertTo-MmtlGoalCanonicalJson -Value @($record.evidenceSha256)) -cne (ConvertTo-MmtlGoalCanonicalJson -Value @($Event.evidenceSha256))) { continue }
        return $true
    }
    return $false
}

function Set-MmtlGoalRunPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][ValidateSet('Paused','Resumed','Finished')][string]$Phase,
        [DateTimeOffset]$AtUtc = [DateTimeOffset]::UtcNow
    )

    $metadata = Get-MmtlGoalRunMetadata -RunRoot $RunRoot
    $journal = Read-MmtlGoalJournal -RunRoot $RunRoot
    $current = 'Active'
    foreach ($record in $journal.records | Where-Object eventType -CEQ 'Phase') { $current = [string]$record.phase }
    $valid = switch ($Phase) {
        'Paused' { $current -in @('Active','Resumed') }
        'Resumed' { $current -ceq 'Paused' }
        'Finished' { $current -in @('Active','Resumed') }
    }
    if (-not $valid) { throw "GOAL_PHASE_TRANSITION_INVALID:$current->$Phase" }
    $previousTime = ConvertTo-MmtlGoalUtcTimestamp -Value $metadata.startedAtUtc
    foreach ($record in $journal.records | Where-Object eventType -CEQ 'Phase') {
        $previousTime = ConvertTo-MmtlGoalUtcTimestamp -Value $record.atUtc
    }
    if ($AtUtc.ToUniversalTime() -lt $previousTime) { throw 'GOAL_PHASE_TIME_REGRESSION' }
    $record = [pscustomobject][ordered]@{ eventType='Phase'; eventId=[guid]::NewGuid().ToString('N'); phase=$Phase; atUtc=$AtUtc.ToUniversalTime().ToString('o') }
    $result = Add-MmtlGoalJournalRecord -RunRoot $RunRoot -Record $record -IdentityProperty 'eventId'
    Invoke-MmtlGoalPeriodicSummary -RunRoot $RunRoot
    return $result
}

function Measure-MmtlGoalIntervalUnion {
    param([object[]]$Intervals)
    $seconds = 0.0
    foreach ($group in ($Intervals | Group-Object { if ($_.category -eq 'Adaptation') { [string]$_.issueId } else { [string]$_.category } })) {
        $ordered = @($group.Group | Sort-Object { (ConvertTo-MmtlGoalUtcTimestamp -Value $_.startedAtUtc).UtcTicks })
        $begin = $null; $finish = $null
        foreach ($item in $ordered) {
            $a = ConvertTo-MmtlGoalUtcTimestamp -Value $item.startedAtUtc
            $b = ConvertTo-MmtlGoalUtcTimestamp -Value $item.endedAtUtc
            if ($null -eq $begin) { $begin=$a; $finish=$b; continue }
            if ($a -le $finish) { if ($b -gt $finish) { $finish=$b } }
            else { $seconds += ($finish - $begin).TotalSeconds; $begin=$a; $finish=$b }
        }
        if ($null -ne $begin) { $seconds += ($finish - $begin).TotalSeconds }
    }
    return [long][Math]::Round($seconds)
}

function Get-MmtlGoalProgressSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [DateTimeOffset]$AsOfUtc = [DateTimeOffset]::UtcNow,
        [AllowNull()][object]$AcceptanceUniverse,
        [AllowNull()][object]$AcceptanceEvidenceIndex,
        [AllowNull()][AllowEmptyCollection()][object[]]$TargetReports
    )

    $metadata = Get-MmtlGoalRunMetadata -RunRoot $RunRoot
    $journal = Read-MmtlGoalJournal -RunRoot $RunRoot
    $attempts = @($journal.records | Where-Object eventType -CEQ 'Attempt')
    $intervals = @($journal.records | Where-Object eventType -CEQ 'WorkInterval')
    $phases = @($journal.records | Where-Object eventType -CEQ 'Phase')
    $start = ConvertTo-MmtlGoalUtcTimestamp -Value $metadata.startedAtUtc
    $end = $AsOfUtc.ToUniversalTime()
    $pauseStart = $null
    $pausedSeconds = 0.0
    $phase = 'Active'
    foreach ($item in $phases) {
        $at = ConvertTo-MmtlGoalUtcTimestamp -Value $item.atUtc
        switch ([string]$item.phase) {
            'Paused' { $pauseStart=$at; $phase='Paused' }
            'Resumed' { if ($null -ne $pauseStart) { $pausedSeconds += ($at - $pauseStart).TotalSeconds }; $pauseStart=$null; $phase='Resumed' }
            'Finished' { $end=$at; $phase='Finished' }
        }
    }
    if ($null -ne $pauseStart) { $pausedSeconds += ($end - $pauseStart).TotalSeconds }
    $wall = [Math]::Max(0, ($end - $start).TotalSeconds)
    $active = [Math]::Max(0, $wall - $pausedSeconds)

    $freshPass = @($attempts | Where-Object { $_.status -ceq 'PASS' -and [bool]$_.isFreshExecution })
    function Get-UniqueTargetCount([string[]]$Dimensions) {
        @($freshPass | Where-Object { [string]$_.dimension -in $Dimensions } | Select-Object -ExpandProperty targetId -Unique).Count
    }
    $workSeconds = 0.0
    $uniqueAttemptCount = 0
    $workAttemptsByIdentity = @{}
    foreach ($attempt in $attempts) {
        $startedAt = (ConvertTo-MmtlGoalUtcTimestamp -Value $attempt.startedAtUtc).ToString('o')
        $endedAt = (ConvertTo-MmtlGoalUtcTimestamp -Value $attempt.endedAtUtc).ToString('o')
        $workIdentity = ConvertTo-MmtlGoalCanonicalJson -Value ([ordered]@{
            targetId=[string]$attempt.targetId
            dimension=[string]$attempt.dimension
            status=[string]$attempt.status
            batchInputSha256=[string]$attempt.batchInputSha256
            startedAtUtc=$startedAt
            endedAtUtc=$endedAt
            evidenceSha256=@($attempt.evidenceSha256)
        })
        $workerId = if ($attempt.PSObject.Properties['workerId']) { [string]$attempt.workerId } else { 'legacy-unattributed:' + [string]$attempt.attemptId }
        if (-not $workAttemptsByIdentity.ContainsKey($workIdentity)) {
            $workAttemptsByIdentity[$workIdentity]=[Collections.Generic.List[string]]::new()
        }
        $knownWorkers = $workAttemptsByIdentity[$workIdentity]
        $sameWorker = $workerId -in $knownWorkers
        $hasRecoveryRecord = 'recovered-from-matrix-state' -in $knownWorkers
        $isRecoveryRecord = $workerId -ceq 'recovered-from-matrix-state'
        if ($knownWorkers.Count -gt 0 -and ($sameWorker -or $hasRecoveryRecord -or $isRecoveryRecord)) { continue }
        $knownWorkers.Add($workerId)
        $uniqueAttemptCount++
        $workSeconds += [double]$attempt.workerTestSeconds
    }
    foreach ($interval in @($intervals | Where-Object category -CEQ 'WorkerTest')) {
        $workSeconds += [double]$interval.durationSeconds
    }
    $batch = Measure-MmtlGoalIntervalUnion -Intervals @($intervals | Where-Object category -CEQ 'BatchPreparation')
    $adaptation = Measure-MmtlGoalIntervalUnion -Intervals @($intervals | Where-Object category -CEQ 'Adaptation')
    $infra = Measure-MmtlGoalIntervalUnion -Intervals @($intervals | Where-Object category -CEQ 'Infrastructure')
    $historical = Measure-MmtlGoalIntervalUnion -Intervals @($intervals | Where-Object category -CEQ 'HistoricalServerPreparation')
    $report = Get-UniqueTargetCount -Dimensions @('TargetReport','TargetReportPass')
    $build = Get-UniqueTargetCount -Dimensions @('BuildExact','BuildExactPass')
    $launch = Get-UniqueTargetCount -Dimensions @('ClientLaunch','ClientLaunchPass')
    $multi = Get-UniqueTargetCount -Dimensions @('MultiWindow','MultiWindowPass')
    $multiplayer = Get-UniqueTargetCount -Dimensions @('MultiplayerJoinAndAssertion','MultiplayerJoinAndAssertionPass')
    $runtime = Get-UniqueTargetCount -Dimensions @('RuntimeBinding','RuntimeBindingPass')
    $single = Get-UniqueTargetCount -Dimensions @('SingleAssertion','SingleAssertionPass','AgentSingleAssertion')
    $dedicated = Get-UniqueTargetCount -Dimensions @('DedicatedServer','DedicatedServerPass','DedicatedValidation')
    $agentBuild = Get-UniqueTargetCount -Dimensions @('AgentBuild','AgentBuildPass')
    $agentInjection = Get-UniqueTargetCount -Dimensions @('AgentInjection','AgentInjectionPass')
    $safeStop = Get-UniqueTargetCount -Dimensions @('SafeStop','SafeStopPass')
    $nativeLan = Get-UniqueTargetCount -Dimensions @('NativeIntegratedLAN','NativeLAN','NativeLan','NativeLanPass')
    $historicalDedicatedEquivalent = Get-UniqueTargetCount -Dimensions @('HistoricalDedicatedEquivalent','HistoricalDedicatedEquivalentPass')
    $multiplayerPathTargets = @($freshPass | Where-Object { [string]$_.dimension -in @('NativeIntegratedLAN','NativeLAN','NativeLan','NativeLanPass','HistoricalDedicatedEquivalent','HistoricalDedicatedEquivalentPass') } | Select-Object -ExpandProperty targetId -Unique)

    $acceptanceInputs = @(@('AcceptanceUniverse','AcceptanceEvidenceIndex','TargetReports') | Where-Object { $PSBoundParameters.ContainsKey($_) })
    $exactAcceptance = $null
    $fullTargetPass = 0
    $fullTargetBlockedReason = 'TARGET_REPORT_ACCEPTANCE_INPUTS_NOT_SUPPLIED'
    if ($acceptanceInputs.Count -gt 0 -and $acceptanceInputs.Count -lt 3) {
        $fullTargetBlockedReason = 'TARGET_REPORT_ACCEPTANCE_INPUTS_INCOMPLETE'
    }
    elseif ($acceptanceInputs.Count -eq 3) {
        Import-Module (Join-Path $PSScriptRoot 'ExactGoalAcceptance.psm1') -Force
        $exactAcceptance = Test-MmtlExactGoalAcceptance -Universe $AcceptanceUniverse -EvidenceIndex $AcceptanceEvidenceIndex -TargetReports $TargetReports -RunId ([string]$metadata.runId)
        $fullTargetPass = [int]$exactAcceptance.fullTargetPassUnique
        if ([string]$exactAcceptance.goalVerdict -cne 'PASS') {
            $fullTargetBlockedReason = if (@($exactAcceptance.reasons).Count -gt 0) { [string]@($exactAcceptance.reasons)[0] } else { 'EXACT_TARGET_ACCEPTANCE_PARTIAL' }
        }
        else { $fullTargetBlockedReason = $null }
    }

    return [pscustomobject][ordered]@{
        runId = [string]$metadata.runId
        universeTargetCount = [int]$metadata.universeTargetCount
        phase = $phase
        attemptCount = $uniqueAttemptCount
        invalidLineCount = $journal.invalidLineCount
        incompleteTrailingLineCount = $journal.incompleteTrailingLineCount
        buildExactPassUnique = $build
        runtimeBindingPassUnique = $runtime
        clientLaunchPassUnique = $launch
        multiWindowPassUnique = $multi
        singleAssertionPassUnique = $single
        multiplayerPassUnique = $multiplayer
        multiplayerJoinAndAssertionPassUnique = $multiplayer
        dedicatedServerPassUnique = $dedicated
        agentBuildPassUnique = $agentBuild
        agentInjectionPassUnique = $agentInjection
        targetReportPassUnique = $report
        safeStopPassUnique = $safeStop
        nativeLanPassUnique = $nativeLan
        historicalDedicatedEquivalentPassUnique = $historicalDedicatedEquivalent
        multiplayerPathPassUnique = $multiplayerPathTargets.Count
        fullTargetPassUnique = $fullTargetPass
        fullTargetPassBlockedReason = $fullTargetBlockedReason
        exactTargetAcceptance = if ($null -eq $exactAcceptance) { $null } else { [pscustomobject][ordered]@{
            goalVerdict = [string]$exactAcceptance.goalVerdict
            exactTotal = [int]$exactAcceptance.exactTotal
            fullTargetPassUnique = [int]$exactAcceptance.fullTargetPassUnique
            multiplayerPassUnique = [int]$exactAcceptance.multiplayerPass
            targetDimensionResults = @($exactAcceptance.targetDimensionResults)
            dimensionStatusCounts = $exactAcceptance.dimensionStatusCounts
            reasons = @($exactAcceptance.reasons)
        }}
        goalWallElapsedSeconds = [long][Math]::Round($wall)
        goalActiveElapsedSeconds = [long][Math]::Round($active)
        workerTestElapsedSeconds = [long][Math]::Round([double]$workSeconds)
        batchPreparationElapsedSeconds = $batch
        adaptationActiveElapsedSeconds = $adaptation
        infrastructureElapsedSeconds = $infra
        historicalServerPreparationElapsedSeconds = $historical
        dimensionPassCounts = [pscustomobject][ordered]@{
            BuildExact=$build; RuntimeBinding=$runtime; ClientLaunch=$launch; MultiWindow=$multi
            SingleAssertion=$single; MultiplayerJoinAndAssertion=$multiplayer; DedicatedServer=$dedicated
            AgentBuild=$agentBuild; AgentInjection=$agentInjection; TargetReport=$report; SafeStop=$safeStop
            NativeIntegratedLAN=$nativeLan; HistoricalDedicatedEquivalent=$historicalDedicatedEquivalent
            MultiplayerPath=$multiplayerPathTargets.Count
        }
    }
}

function Invoke-MmtlGoalPeriodicSummary {
    param([Parameter(Mandatory)][string]$RunRoot)

    $metadata = Get-MmtlGoalRunMetadata -RunRoot $RunRoot
    $journal = Read-MmtlGoalJournal -RunRoot $RunRoot
    $workEvents = @($journal.records | Where-Object eventType -in @('Attempt','WorkInterval'))
    if ($workEvents.Count -eq 0) { return }

    $now = [DateTimeOffset]::UtcNow
    $summaries = @($journal.records | Where-Object eventType -CEQ 'Summary')
    $lastSummaryAt = if ($summaries.Count -gt 0) {
        ConvertTo-MmtlGoalUtcTimestamp -Value $summaries[-1].generatedAtUtc
    }
    else {
        ConvertTo-MmtlGoalUtcTimestamp -Value $metadata.startedAtUtc
    }
    $countDue = ($workEvents.Count % 25) -eq 0
    $timeDue = ($now - $lastSummaryAt).TotalMinutes -ge 30
    if (-not ($countDue -or $timeDue)) { return }

    $summary = Get-MmtlGoalProgressSummary -RunRoot $RunRoot -AsOfUtc $now
    $trigger = if ($countDue) { 'EventThreshold' } else { 'TimeThreshold' }
    $event = [pscustomobject][ordered]@{
        eventType = 'Summary'
        summaryId = [guid]::NewGuid().ToString('N')
        generatedAtUtc = $now.ToString('o')
        trigger = $trigger
        workEventCount = $workEvents.Count
        summary = $summary
    }
    $null = Add-MmtlGoalJournalRecord -RunRoot $RunRoot -Record $event -IdentityProperty 'summaryId'
    Write-Host ("[SUMMARY:{0}] events={1} Build={2} Runtime={3} Launch={4} MultiWindow={5} NativeLAN={6} HistoricalDedicatedEquivalent={7} MultiplayerPath={8} Multiplayer={9} Reports={10} Full={11} wall={12}s active={13}s worker={14}s repair={15}s" -f $trigger,$workEvents.Count,$summary.buildExactPassUnique,$summary.runtimeBindingPassUnique,$summary.clientLaunchPassUnique,$summary.multiWindowPassUnique,$summary.nativeLanPassUnique,$summary.historicalDedicatedEquivalentPassUnique,$summary.multiplayerPathPassUnique,$summary.multiplayerJoinAndAssertionPassUnique,$summary.targetReportPassUnique,$summary.fullTargetPassUnique,$summary.goalWallElapsedSeconds,$summary.goalActiveElapsedSeconds,$summary.workerTestElapsedSeconds,$summary.adaptationActiveElapsedSeconds)
}

Export-ModuleMember -Function Start-MmtlGoalProgressRun, Write-MmtlGoalAttemptEvent, Test-MmtlGoalAttemptRecorded, Write-MmtlGoalWorkInterval, Set-MmtlGoalRunPhase, Get-MmtlGoalProgressSummary
