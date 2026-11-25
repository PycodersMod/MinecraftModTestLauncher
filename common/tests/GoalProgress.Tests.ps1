BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:modulePath = Join-Path $script:repoRoot 'src/Compatibility/GoalProgress.psm1'
    if (Test-Path -LiteralPath $script:modulePath -PathType Leaf) {
        Import-Module $script:modulePath -Force
    }

    function New-TestGoalAttempt {
        param(
            [string]$AttemptId = ([guid]::NewGuid().ToString('N')),
            [string]$WorkerId = 'worker-1',
            [string]$LoaderId = 'Fabric',
            [string]$MinecraftId = '1.21.11',
            [string]$TargetId = 'Fabric@1.21.11',
            [string]$Dimension = 'BuildExact',
            [string]$Status = 'PASS',
            [int]$AttemptNumber = 1,
            [bool]$Fresh = $true,
            [string]$StartedAtUtc = '2026-10-15T16:05:00Z',
            [string]$EndedAtUtc = '2026-10-15T16:05:10Z'
        )

        [pscustomobject][ordered]@{
            eventType = 'Attempt'
            attemptId = $AttemptId
            workerId = $WorkerId
            loaderId = $LoaderId
            minecraftId = $MinecraftId
            targetId = $TargetId
            loaderVersion = '0.19.5'
            familyId = 'fabric-loom-remap-build-launch-plan-v1'
            adapterId = 'FabricLoom'
            batchId = 'fabric-modern-batch-001'
            batchInputSha256 = ('f' * 64)
            universeHash = ('a' * 64)
            sourceHash = ('b' * 64)
            toolchainHash = ('c' * 64)
            targetSpecHash = ('d' * 64)
            dimension = $Dimension
            status = $Status
            attemptNumber = $AttemptNumber
            isFreshExecution = $Fresh
            startedAtUtc = $StartedAtUtc
            endedAtUtc = $EndedAtUtc
            durationSeconds = 10
            workerTestSeconds = 10
            cumulativeRepairSeconds = 0
            failureReason = if ($Status -eq 'PASS') { $null } else { 'TEST_FAILURE' }
            evidencePaths = @('evidence/fixture.json')
            evidenceSha256 = @(('e' * 64))
            nextAction = 'continue batch preparation'
        }
    }
}

Describe 'MMTL Goal progress event journal' {
    It 'reports that exact target report acceptance is not integrated instead of claiming the dimension plan is unfrozen' {
        $runRoot = Join-Path $TestDrive 'run-full-target-gate-status'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-full-target-gate-status' -UniverseHash ('a' * 64) -UniverseTargetCount 1631 -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $summary.fullTargetPassUnique | Should -Be 0
        $summary.fullTargetPassBlockedReason | Should -BeExactly 'TARGET_REPORT_ACCEPTANCE_INPUTS_NOT_SUPPLIED'
    }

    It 'evaluates supplied exact reports with the strict acceptance gate and keeps missing targets partial' {
        $runRoot = Join-Path $TestDrive 'run-report-acceptance-inputs'
        $universeHash = 'a' * 64
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-report-acceptance-inputs' -UniverseHash $universeHash -UniverseTargetCount 1631 -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        $targets = @(
            for ($index = 0; $index -lt 1631; $index++) {
                $loader = 'Loader' + $index.ToString('D4')
                [pscustomobject]@{ targetId = "$loader@1.0"; loaderId = $loader; minecraftId = '1.0' }
            }
        )
        $universe = [pscustomobject]@{ catalogHash = $universeHash; targets = $targets }
        $evidenceIndex = [pscustomobject]@{ universeHash = $universeHash; entries = @(); repositoryGates = @() }

        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot -AcceptanceUniverse $universe -AcceptanceEvidenceIndex $evidenceIndex -TargetReports @()

        $summary.fullTargetPassUnique | Should -Be 0
        $summary.fullTargetPassBlockedReason | Should -BeExactly 'REQUIRED_EXACT_TARGET_EVIDENCE_INCOMPLETE'
        $summary.exactTargetAcceptance.goalVerdict | Should -BeExactly 'PARTIAL'
        $summary.exactTargetAcceptance.exactTotal | Should -Be 1631

        $singleReport = [pscustomobject]@{
            targetId = $targets[0].targetId; loaderId = $targets[0].loaderId; minecraftId = $targets[0].minecraftId
            loaderVersion = 'v1'; runId = 'run-report-acceptance-inputs'; freshExecution = $true; overallResult = 'PARTIAL'
            scenarioConfiguration = [pscustomobject]@{ effective = [pscustomobject]@{ clientCount = 1; transport = 'None' } }
            compatibilityIdentity = [pscustomobject]@{
                targetId = $targets[0].targetId; universeHash = $universeHash; targetSpecHash = ('b' * 64)
                adapterSha256 = ('c' * 64); toolchainHash = ('d' * 64)
            }
            stageResults = @()
        }
        $summarySingle = Get-MmtlGoalProgressSummary -RunRoot $runRoot -AcceptanceUniverse $universe -AcceptanceEvidenceIndex $evidenceIndex -TargetReports @($singleReport)
        $summarySingle.exactTargetAcceptance.multiplayerPassUnique | Should -Be 0
        $summarySingle.exactTargetAcceptance.dimensionStatusCounts.Multiplayer.notRequested | Should -Be 1
        $summarySingle.exactTargetAcceptance.dimensionStatusCounts.SafeStop.pass | Should -Be 0
    }

    It 'persists an exact target dimension attempt before returning and reports the durable result' {
        $runRoot = Join-Path $TestDrive 'run-durable'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-durable' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        $event = New-TestGoalAttempt -AttemptId 'attempt-durable-001'
        $result = Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event
        $lines = [IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl'))

        $result.persisted | Should -BeTrue
        $records = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object eventType -CEQ 'Attempt').Count | Should -Be 1
        ($records | Where-Object eventType -CEQ 'Attempt').attemptId | Should -BeExactly 'attempt-durable-001'
        @($records | Where-Object eventType -CEQ 'Summary').Count | Should -Be 1
    }

    It 'keeps retries but counts only one unique exact target dimension PASS' {
        $runRoot = Join-Path $TestDrive 'run-retry'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-retry' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-retry-001' -Status 'FAIL') | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-retry-002' -Status 'PASS' -AttemptNumber 2) | Out-Null
        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $summary.attemptCount | Should -Be 2
        $summary.buildExactPassUnique | Should -Be 1
        $summary.workerTestElapsedSeconds | Should -Be 20
    }

    It 'reads legacy attempt records without an optional worker id' {
        $runRoot = Join-Path $TestDrive 'run-legacy-worker-id'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-legacy-worker-id' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        $legacy = New-TestGoalAttempt -AttemptId 'attempt-legacy-worker-id'
        $legacy.PSObject.Properties.Remove('workerId')
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $legacy | Out-Null

        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot
        $summary.attemptCount | Should -Be 1
        $summary.workerTestElapsedSeconds | Should -Be 10
    }

    It 'deduplicates replayed matrix work by stable execution evidence even if its attempt number changed' {
        $runRoot = Join-Path $TestDrive 'run-recovered-attempt-deduplication'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-recovered-attempt-deduplication' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        $original = New-TestGoalAttempt -AttemptId 'attempt-recovery-original' -StartedAtUtc '2026-10-15T16:05:00Z' -EndedAtUtc '2026-10-15T16:05:10Z'
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $original | Out-Null

        $recovered = New-TestGoalAttempt -AttemptId 'attempt-recovery-new-id' -AttemptNumber 2 -StartedAtUtc '2026-10-15T16:05:00Z' -EndedAtUtc '2026-10-15T16:05:10Z'
        Test-MmtlGoalAttemptRecorded -RunRoot $runRoot -Event $recovered | Should -BeTrue
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $recovered | Out-Null

        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot
        $records = [IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json }

        $summary.attemptCount | Should -Be 1
        $summary.workerTestElapsedSeconds | Should -Be 10
        $summary.buildExactPassUnique | Should -Be 1
        @($records | Where-Object eventType -CEQ 'Attempt').Count | Should -Be 2
    }

    It 'keeps two workers on one exact target while counting only one unique PASS' {
        $runRoot = Join-Path $TestDrive 'run-two-workers-one-target'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-two-workers-one-target' -UniverseHash ('a' * 64) -StartedAtUtc ([DateTimeOffset]::UtcNow) | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-worker-1' -WorkerId 'worker-1') | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-worker-2' -WorkerId 'worker-2') | Out-Null
        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot
        $attempts = @([IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object eventType -CEQ 'Attempt' | Sort-Object attemptNumber)

        $summary.attemptCount | Should -Be 2
        $summary.buildExactPassUnique | Should -Be 1
        @($attempts | ForEach-Object attemptNumber) | Should -Be @(1, 2)
    }

    It 'treats retrying the same attempt id with identical content as idempotent' {
        $runRoot = Join-Path $TestDrive 'run-identical-replay'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-identical-replay' -UniverseHash ('a' * 64) -StartedAtUtc ([DateTimeOffset]::UtcNow) | Out-Null
        $event = New-TestGoalAttempt -AttemptId 'attempt-replay-identical'
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event | Out-Null
        $replay = Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event
        $records = [IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json }

        $replay.duplicate | Should -BeTrue
        @($records | Where-Object eventType -CEQ 'Attempt').Count | Should -Be 1
    }

    It 'does not count a cached claim as a fresh client launch pass' {
        $runRoot = Join-Path $TestDrive 'run-cache'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-cache' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-cache-001' -Dimension 'ClientLaunch' -Status 'CACHED' -Fresh $false) | Out-Null
        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $summary.clientLaunchPassUnique | Should -Be 0
    }

    It 'rejects a fresh PASS that has no evidence path and digest' {
        $runRoot=Join-Path $TestDrive 'run-pass-without-evidence'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-pass-without-evidence' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        $event=New-TestGoalAttempt -AttemptId 'attempt-no-evidence'
        $event.evidencePaths=@();$event.evidenceSha256=@()
        { Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event } | Should -Throw '*ATTEMPT_PASS_EVIDENCE_REQUIRED*'
    }

    It 'rejects an attempt that claims a different frozen universe' {
        $runRoot=Join-Path $TestDrive 'run-universe-mismatch'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-universe-mismatch' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        $event=New-TestGoalAttempt -AttemptId 'attempt-universe-mismatch'
        $event.universeHash=('f' * 64)

        { Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event } | Should -Throw '*ATTEMPT_UNIVERSE_HASH_MISMATCH*'
    }

    It 'requires a frozen batch input digest' {
        $runRoot=Join-Path $TestDrive 'run-no-batch-input-hash'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-no-batch-input-hash' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        $event=New-TestGoalAttempt -AttemptId 'attempt-no-batch-input-hash'
        $event.PSObject.Properties.Remove('batchInputSha256')

        { Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event } | Should -Throw '*ATTEMPT_FIELD_REQUIRED:batchInputSha256*'
    }

    It 'rejects malformed source and target identity hashes' {
        $runRoot=Join-Path $TestDrive 'run-malformed-hash'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-malformed-hash' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        $event=New-TestGoalAttempt -AttemptId 'attempt-malformed-hash'
        $event.targetSpecHash='not-a-sha256'

        { Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event } | Should -Throw '*ATTEMPT_HASH_INVALID:targetSpecHash*'
    }

    It 'requires one digest for every evidence path' {
        $runRoot=Join-Path $TestDrive 'run-evidence-digest-count'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-evidence-digest-count' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        $event=New-TestGoalAttempt -AttemptId 'attempt-evidence-digest-count'
        $event.evidenceSha256=@()

        { Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event } | Should -Throw '*ATTEMPT_EVIDENCE_DIGEST_COUNT_MISMATCH*'
    }

    It 'reports native LAN and historical dedicated multiplayer paths separately and combined' {
        $runRoot=Join-Path $TestDrive 'run-multiplayer-paths'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-multiplayer-paths' -UniverseHash ('a' * 64) -UniverseTargetCount 1631 -StartedAtUtc ([DateTimeOffset]::UtcNow) | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-native-lan' -Dimension 'NativeIntegratedLAN' -MinecraftId '1.20.1' -TargetId 'Fabric@1.20.1') | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-historical-dedicated' -Dimension 'HistoricalDedicatedEquivalent' -MinecraftId '1.2.5' -TargetId 'Fabric@1.2.5') | Out-Null

        $summary=Get-MmtlGoalProgressSummary -RunRoot $runRoot
        $summary.nativeLanPassUnique | Should -Be 1
        $summary.historicalDedicatedEquivalentPassUnique | Should -Be 1
        $summary.multiplayerPathPassUnique | Should -Be 2
    }

    It 'rejects reusing an attempt id with conflicting event content' {
        $runRoot = Join-Path $TestDrive 'run-conflict'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-conflict' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-conflict-001' -Status 'FAIL') | Out-Null
        { Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-conflict-001' -Status 'PASS') } | Should -Throw '*ATTEMPT_ID_CONTENT_CONFLICT*'
    }

    It 'ignores and reports an incomplete trailing journal line without losing complete events' {
        $runRoot = Join-Path $TestDrive 'run-partial'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-partial' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-partial-001') | Out-Null
        [IO.File]::AppendAllText((Join-Path $runRoot 'events.jsonl'), '{"eventType":"Attempt","attemptId":')
        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $summary.attemptCount | Should -Be 1
        $summary.incompleteTrailingLineCount | Should -Be 1
    }

    It 'keeps later events readable after an incomplete trailing journal line' {
        $runRoot=Join-Path $TestDrive 'run-partial-then-append'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-partial-then-append' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-partial-before') | Out-Null
        [IO.File]::AppendAllText((Join-Path $runRoot 'events.jsonl'), '{"eventType":"Attempt","attemptId":')

        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-partial-after' -Dimension 'ClientLaunch') | Out-Null
        $summary=Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $summary.attemptCount | Should -Be 2
        $summary.incompleteTrailingLineCount | Should -Be 0
        $summary.invalidLineCount | Should -Be 1
        $lines=[IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl'))
        @($lines|ForEach-Object{try{$_|ConvertFrom-Json -ErrorAction Stop}catch{}}|Where-Object eventType -CEQ 'Attempt').Count | Should -Be 2
    }

    It 'subtracts paused intervals from active time while preserving wall time' {
        $runRoot = Join-Path $TestDrive 'run-paused'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-paused' -UniverseHash ('a' * 64) -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null
        Set-MmtlGoalRunPhase -RunRoot $runRoot -Phase 'Paused' -AtUtc '2026-01-01T01:00:00Z' | Out-Null
        Set-MmtlGoalRunPhase -RunRoot $runRoot -Phase 'Resumed' -AtUtc '2026-01-01T03:00:00Z' | Out-Null

        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot -AsOfUtc '2026-01-01T04:00:00Z'

        $summary.goalWallElapsedSeconds | Should -Be 14400
        $summary.goalActiveElapsedSeconds | Should -Be 7200
    }

    It 'includes explicit WorkerTest intervals in the cumulative worker-test time' {
        $runRoot = Join-Path $TestDrive 'run-worker-test-interval'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-worker-test-interval' -UniverseHash ('a' * 64) -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null
        Write-MmtlGoalWorkInterval -RunRoot $runRoot -Interval ([pscustomobject]@{
            intervalId = 'worker-test-interval-001'; category = 'WorkerTest'
            startedAtUtc = '2026-01-01T10:00:00Z'; endedAtUtc = '2026-01-01T10:00:45Z'
        }) | Out-Null

        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $summary.workerTestElapsedSeconds | Should -Be 45
    }

    It 'deduplicates overlapping repair intervals for the same root cause' {
        $runRoot = Join-Path $TestDrive 'run-repair-dedup'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-repair-dedup' -UniverseHash ('a' * 64) -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null
        Write-MmtlGoalWorkInterval -RunRoot $runRoot -Interval ([pscustomobject]@{
            intervalId = 'repair-interval-001'; category = 'Adaptation'; issueId = 'shared-root-cause-1'
            startedAtUtc = '2026-01-01T10:00:00Z'; endedAtUtc = '2026-01-01T11:00:00Z'
        }) | Out-Null
        Write-MmtlGoalWorkInterval -RunRoot $runRoot -Interval ([pscustomobject]@{
            intervalId = 'repair-interval-002'; category = 'Adaptation'; issueId = 'shared-root-cause-1'
            startedAtUtc = '2026-01-01T10:30:00Z'; endedAtUtc = '2026-01-01T12:00:00Z'
        }) | Out-Null

        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $summary.adaptationActiveElapsedSeconds | Should -Be 7200
    }

    It 'normalizes mixed UTC JSON timestamp forms before deduplicating repair intervals' {
        $runRoot = Join-Path $TestDrive 'run-repair-mixed-utc'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-repair-mixed-utc' -UniverseHash ('a' * 64) -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null
        Write-MmtlGoalWorkInterval -RunRoot $runRoot -Interval ([pscustomobject]@{
            intervalId = 'repair-mixed-utc-001'; category = 'Adaptation'; issueId = 'shared-root-cause-mixed-utc'
            startedAtUtc = '2026-01-01T10:00:00Z'; endedAtUtc = '2026-01-01T11:00:00Z'
        }) | Out-Null
        Write-MmtlGoalWorkInterval -RunRoot $runRoot -Interval ([pscustomobject]@{
            intervalId = 'repair-mixed-utc-002'; category = 'Adaptation'; issueId = 'shared-root-cause-mixed-utc'
            startedAtUtc = '2026-01-01T10:30:00+00:00'; endedAtUtc = '2026-01-01T12:00:00+00:00'
        }) | Out-Null

        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $summary.adaptationActiveElapsedSeconds | Should -Be 7200
    }

    It 'records the cumulative unique-dimension snapshot with each new attempt' {
        $runRoot = Join-Path $TestDrive 'run-snapshots'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-snapshots' -UniverseHash ('a' * 64) -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-snapshot-001') | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-snapshot-002' -Dimension 'ClientLaunch') | Out-Null
        $records = @([IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object eventType -CEQ 'Attempt')

        $records[1].dimensionPassCounts.BuildExact | Should -Be 1
        $records[1].dimensionPassCounts.ClientLaunch | Should -Be 1
        $records[1].cumulativeRepairSeconds | Should -Be 0
    }

    It 'keeps the same Minecraft id distinct for different exact loaders' {
        $runRoot = Join-Path $TestDrive 'run-loader-identity'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-loader-identity' -UniverseHash ('a' * 64) -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-fabric-identity') | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-neoforge-identity' -LoaderId 'NeoForge' -TargetId 'NeoForge@1.21.11') | Out-Null

        (Get-MmtlGoalProgressSummary -RunRoot $runRoot).buildExactPassUnique | Should -Be 2
    }

    It 'persists the frozen exact Universe target count in the run summary' {
        $runRoot = Join-Path $TestDrive 'run-universe-count'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-universe-count' -UniverseHash ('a' * 64) -UniverseTargetCount 1631 -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null

        (Get-MmtlGoalProgressSummary -RunRoot $runRoot).universeTargetCount | Should -Be 1631
    }

    It 'rejects evidence paths that escape the run evidence root' {
        $runRoot = Join-Path $TestDrive 'run-path-escape'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-path-escape' -UniverseHash ('a' * 64) -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null
        $event = New-TestGoalAttempt -AttemptId 'attempt-path-escape'
        $event.evidencePaths = @('../outside/evidence.json')

        { Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event } | Should -Throw '*ATTEMPT_EVIDENCE_PATH_INVALID*'
        [IO.File]::Exists((Join-Path $runRoot 'events.jsonl')) | Should -BeFalse
    }

    It 'redacts credentials and absolute machine paths before writing progress events' {
        $runRoot = Join-Path $TestDrive 'run-redaction'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-redaction' -UniverseHash ('a' * 64) -StartedAtUtc '2026-01-01T00:00:00Z' | Out-Null
        $event = New-TestGoalAttempt -AttemptId 'attempt-redaction-001' -Status 'FAIL'
        $syntheticPath = 'C:' + '\Users\fixture-user\.config\mmtl\credentials.json'
        $syntheticToken = 'ghp_' + ('a' * 36)
        $event.failureReason = "Build failed at $syntheticPath with $syntheticToken"
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event | Out-Null
        $journal = [IO.File]::ReadAllText((Join-Path $runRoot 'events.jsonl'))

        $journal | Should -Not -Match ([regex]::Escape($syntheticToken))
        $journal | Should -Not -Match ([regex]::Escape($syntheticPath))
        $journal | Should -Match '<REDACTED_TOKEN>'
        $journal | Should -Match '<REDACTED_PATH>'
    }
    It 'writes a recoverable summary after every twenty-five new test events' {
        $runRoot = Join-Path $TestDrive 'run-periodic-summary'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-periodic-summary' -UniverseHash ('a' * 64) -StartedAtUtc ([DateTimeOffset]::UtcNow) | Out-Null
        for ($index = 1; $index -le 25; $index++) {
            $event = New-TestGoalAttempt -AttemptId ("attempt-periodic-{0:D2}" -f $index)
            Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event $event | Out-Null
        }
        $records = [IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json }

        @($records | Where-Object eventType -CEQ 'Attempt').Count | Should -Be 25
        @($records | Where-Object eventType -CEQ 'Summary').Count | Should -Be 1
    }

    It 'writes a time-threshold summary on the first event after thirty idle minutes' {
        $runRoot = Join-Path $TestDrive 'run-thirty-minute-summary'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-thirty-minute-summary' -UniverseHash ('a' * 64) -StartedAtUtc ([DateTimeOffset]::UtcNow.AddMinutes(-31)) | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestGoalAttempt -AttemptId 'attempt-thirty-minute-001') | Out-Null
        $records = [IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json }

        @($records | Where-Object { $_.eventType -ceq 'Summary' -and $_.trigger -ceq 'TimeThreshold' }).Count | Should -Be 1
    }
}
