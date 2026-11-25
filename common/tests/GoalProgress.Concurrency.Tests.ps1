BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:modulePath = Join-Path $script:repoRoot 'src/Compatibility/GoalProgress.psm1'
    Import-Module $script:modulePath -Force
}

Describe 'MMTL Goal progress concurrent workers' {
    It 'serializes event snapshots and preserves every worker attempt' {
        $runRoot = Join-Path $TestDrive 'run-concurrent-workers'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'run-concurrent-workers' -UniverseHash ('a' * 64) -UniverseTargetCount 1631 -StartedAtUtc ([DateTimeOffset]::UtcNow) | Out-Null

        $workerCount = 4
        $barrier = [Threading.Barrier]::new($workerCount)
        $workers = [Collections.Generic.List[object]]::new()
        try {
            for ($index = 1; $index -le $workerCount; $index++) {
                $powerShell = [PowerShell]::Create()
                $script = {
                    param($ModulePath,$Root,$Worker,$Barrier)
                    Import-Module $ModulePath -Force
                    if (-not $Barrier.SignalAndWait([TimeSpan]::FromSeconds(20))) { throw 'WORKER_BARRIER_TIMEOUT' }
                    $now = [DateTimeOffset]::UtcNow
                    $minecraftId = '1.21.' + ([string](10 + $Worker))
                    $attempt = [pscustomobject][ordered]@{
                        eventType='Attempt';attemptId=("concurrent-{0}" -f $Worker);workerId=("worker-{0}" -f $Worker)
                        loaderId='Fabric';minecraftId=$minecraftId;targetId=("Fabric@{0}" -f $minecraftId);loaderVersion='0.19.5'
                        familyId='fabric-loom-remap-build-launch-plan-v1';adapterId='FabricLoom';batchId='concurrent-test-batch';batchInputSha256=('f'*64)
                        universeHash=('a'*64);sourceHash=('b'*64);toolchainHash=('c'*64);targetSpecHash=('d'*64)
                        dimension='BuildExact';status='PASS';attemptNumber=1;isFreshExecution=$true
                        startedAtUtc=$now.ToString('o');endedAtUtc=$now.ToString('o');durationSeconds=0;workerTestSeconds=1
                        cumulativeRepairSeconds=0;failureReason=$null;evidencePaths=@('evidence/fixture.json');evidenceSha256=@(('e'*64));nextAction='none'
                    }
                    Write-MmtlGoalAttemptEvent -RunRoot $Root -Event $attempt | Out-Null
                }
                $null = $powerShell.AddScript($script).AddArgument($script:modulePath).AddArgument($runRoot).AddArgument($index).AddArgument($barrier)
                $workers.Add([pscustomobject]@{ PowerShell=$powerShell; Async=$powerShell.BeginInvoke() })
            }

            foreach ($worker in $workers) { $null = $worker.PowerShell.EndInvoke($worker.Async) }
        }
        finally {
            foreach ($worker in $workers) { $worker.PowerShell.Dispose() }
            $barrier.Dispose()
        }

        $records = [IO.File]::ReadAllLines((Join-Path $runRoot 'events.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json }
        $attempts = @($records | Where-Object eventType -CEQ 'Attempt' | Sort-Object { $_.dimensionPassCounts.BuildExact })
        $summary = Get-MmtlGoalProgressSummary -RunRoot $runRoot

        $attempts.Count | Should -Be 4
        @($attempts | ForEach-Object { $_.dimensionPassCounts.BuildExact }) | Should -Be @(1,2,3,4)
        $summary.buildExactPassUnique | Should -Be 4
    }
}
