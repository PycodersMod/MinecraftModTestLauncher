BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:modulePath = Join-Path $script:repoRoot 'src/Compatibility/GoalProgress.psm1'
    $script:cliPath = Join-Path (Split-Path -Parent $script:repoRoot) 'tools/Get-MmtlGoalProgress.ps1'
    Import-Module $script:modulePath -Force

    function New-TestCliAttempt {
        [pscustomobject][ordered]@{
            eventType='Attempt';attemptId=([guid]::NewGuid().ToString('N'));loaderId='Fabric';minecraftId='1.21.11';targetId='Fabric@1.21.11'
            loaderVersion='0.19.5';familyId='fabric-loom-remap-build-launch-plan-v1';adapterId='FabricLoom';batchId='cli-batch-1';batchInputSha256=('f'*64)
            universeHash=('a'*64);sourceHash=('b'*64);toolchainHash=('c'*64);targetSpecHash=('d'*64)
            dimension='BuildExact';status='PASS';attemptNumber=1;isFreshExecution=$true;startedAtUtc='2026-10-15T16:05:00Z';endedAtUtc='2026-10-15T16:05:10Z'
            durationSeconds=10;workerTestSeconds=10;cumulativeRepairSeconds=0;failureReason=$null;evidencePaths=@('evidence/fixture.json');evidenceSha256=@(('e'*64));nextAction='continue'
        }
    }
}

Describe 'MMTL Goal progress read-only CLI' {
    It 'loads explicit exact acceptance inputs and reports partial when target reports are missing' {
        $runRoot = Join-Path $TestDrive 'cli-exact-acceptance'
        $universePath = Join-Path $TestDrive 'universe.json'
        $indexPath = Join-Path $TestDrive 'evidence-index.json'
        $reportsPath = Join-Path $TestDrive 'target-reports'
        $null = New-Item -ItemType Directory -Path $reportsPath
        $hash = 'a' * 64
        $targets = @(
            for ($index = 0; $index -lt 1631; $index++) {
                $loader = 'Loader' + $index.ToString('D4')
                [pscustomobject]@{ targetId = "$loader@1.0"; loaderId = $loader; minecraftId = '1.0' }
            }
        )
        [pscustomobject]@{ catalogHash = $hash; targets = $targets } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $universePath
        [pscustomobject]@{ universeHash = $hash; entries = @(); repositoryGates = @() } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $indexPath
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'cli-exact-acceptance' -UniverseHash $hash -UniverseTargetCount 1631 -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null

        $output = & $script:cliPath -RunRoot $runRoot -UniversePath $universePath -EvidenceIndexPath $indexPath -TargetReportsDirectory $reportsPath -Json
        $summary = ($output -join "`n") | ConvertFrom-Json

        $summary.fullTargetPassUnique | Should -Be 0
        $summary.fullTargetPassBlockedReason | Should -BeExactly 'REQUIRED_EXACT_TARGET_EVIDENCE_INCOMPLETE'
        $summary.exactTargetAcceptance.goalVerdict | Should -BeExactly 'PARTIAL'
        $summary.exactTargetAcceptance.exactTotal | Should -Be 1631
    }

    It 'prints a stable JSON summary for an existing run' {
        $runRoot = Join-Path $TestDrive 'cli-json'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'cli-json' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        Write-MmtlGoalAttemptEvent -RunRoot $runRoot -Event (New-TestCliAttempt) | Out-Null

        $output = & $script:cliPath -RunRoot $runRoot -Json
        $summary = ($output -join "`n") | ConvertFrom-Json

        $summary.runId | Should -BeExactly 'cli-json'
        $summary.buildExactPassUnique | Should -Be 1
        $summary.fullTargetPassUnique | Should -Be 0
    }

    It 'does not create or modify a run when invoked as a read-only query' {
        $runRoot = Join-Path $TestDrive 'cli-read-only'
        Start-MmtlGoalProgressRun -RunRoot $runRoot -RunId 'cli-read-only' -UniverseHash ('a' * 64) -StartedAtUtc '2026-10-15T16:00:57Z' | Out-Null
        $before = @((Get-ChildItem -LiteralPath $runRoot -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Get-FileHash $_.FullName -Algorithm SHA256).Hash }))

        $null = & $script:cliPath -RunRoot $runRoot -Json
        $after = @((Get-ChildItem -LiteralPath $runRoot -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Get-FileHash $_.FullName -Algorithm SHA256).Hash }))

        $after | Should -Be $before
    }

    It 'refuses a missing run without initializing files' {
        $runRoot = Join-Path $TestDrive 'cli-missing'

        { & $script:cliPath -RunRoot $runRoot -Json } | Should -Throw

        Test-Path -LiteralPath $runRoot | Should -BeFalse
    }
}
