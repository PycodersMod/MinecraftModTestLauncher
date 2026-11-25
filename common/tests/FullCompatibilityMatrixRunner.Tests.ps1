Describe 'Full compatibility matrix runner' {
    BeforeAll {
        $commonRoot=Split-Path -Parent $PSScriptRoot
        $script:repoRoot=Split-Path -Parent $commonRoot
        Import-Module (Join-Path $commonRoot 'src/Validation/FullCompatibilityMatrixRunner.psm1') -Force
        Import-Module (Join-Path $commonRoot 'src/Validation/ValidationMatrixChunks.psm1') -Force
        $script:universe=Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw|ConvertFrom-Json
        $script:ledger=Get-Content (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -Raw|ConvertFrom-Json
        $script:families=Get-Content (Join-Path $script:repoRoot 'compatibility/families.json') -Raw|ConvertFrom-Json
    }

    It 'builds a hidden PowerShell worker command with discrete arguments' {
        $powerShell=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
        $info=New-MmtlFullMatrixShardProcessStartInfo -PowerShellPath $powerShell -WorkerScriptPath $PSCommandPath -WorkingDirectory $PSScriptRoot -Arguments @('-RuntimeRoot','D:\runtime root','-ShardIndex','2','-GoalProgressRunRoot','D:\goal progress root') # public-hygiene: allow-synthetic-path
        $info.UseShellExecute | Should -BeFalse
        $info.CreateNoWindow | Should -BeTrue
        $info.RedirectStandardOutput | Should -BeTrue
        $info.RedirectStandardError | Should -BeTrue
        @($info.ArgumentList) | Should -Be @('-NoProfile','-File',$PSCommandPath,'-RuntimeRoot','D:\runtime root','-ShardIndex','2','-GoalProgressRunRoot','D:\goal progress root') # public-hygiene: allow-synthetic-path
    }

    It 'scales heavy worker admission with current available memory and the configured cap' {
        Get-MmtlFullMatrixMemoryParallelLimit -AvailableGiB 5.99 -RequestedMaximum 8 | Should -Be 0
        Get-MmtlFullMatrixMemoryParallelLimit -AvailableGiB 6 -RequestedMaximum 8 | Should -Be 1
        Get-MmtlFullMatrixMemoryParallelLimit -AvailableGiB 9.99 -RequestedMaximum 8 | Should -Be 1
        Get-MmtlFullMatrixMemoryParallelLimit -AvailableGiB 10 -RequestedMaximum 8 | Should -Be 2
        Get-MmtlFullMatrixMemoryParallelLimit -AvailableGiB 12 -RequestedMaximum 1 | Should -Be 1
        Get-MmtlFullMatrixMemoryParallelLimit -AvailableGiB 12 -RequestedMaximum 8 | Should -Be 2
    }

    It 'runs a worker with an argument containing spaces without a shell window' {
        $powerShell=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
        $worker=Join-Path $TestDrive 'worker with spaces.ps1'
        [IO.File]::WriteAllText($worker,'param([string]$Label); [Console]::Out.WriteLine($Label)',[Text.UTF8Encoding]::new($false))
        $info=New-MmtlFullMatrixShardProcessStartInfo -PowerShellPath $powerShell -WorkerScriptPath $worker -WorkingDirectory $TestDrive -Arguments @('-Label','argument with spaces')
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        $process.Start() | Should -BeTrue
        $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit(15000) | Should -BeTrue
        $process.ExitCode | Should -Be 0
        $stdoutTask.Result.Trim() | Should -BeExactly 'argument with spaces'
        $stderrTask.Result | Should -BeNullOrEmpty
        $process.Dispose()
    }

    It 'stops and reaps only the owned worker process tree during coordinator interruption' {
        $powerShell=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
        $workerPath=Join-Path $TestDrive 'long-running owned worker.ps1'
        [IO.File]::WriteAllText($workerPath,'while($true){Start-Sleep -Seconds 1}',[Text.UTF8Encoding]::new($false))
        $info=New-MmtlFullMatrixShardProcessStartInfo -PowerShellPath $powerShell -WorkerScriptPath $workerPath -WorkingDirectory $TestDrive -Arguments @()
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        $process.Start() | Should -BeTrue
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $worker=[pscustomobject]@{process=$process;processId=[int]$process.Id;stdout=$stdout;stderr=$stderr}
        try {
            $stopped=Stop-MmtlFullMatrixOwnedWorker -Worker $worker -TimeoutSeconds 10
            $stopped.processId | Should -Be $process.Id
            $process.HasExited | Should -BeTrue
            $stopped.exitCode | Should -Not -Be 0
            $stopped.stdout | Should -BeNullOrEmpty
            $stopped.stderr | Should -BeNullOrEmpty
        } finally {
            if(-not $process.HasExited){$process.Kill($true);$process.WaitForExit(5000)|Out-Null}
            $process.Dispose()
        }
    }

    It 'returns passed only when every shard completed successfully' {
        $result=Get-MmtlFullMatrixAggregateStatus -ShardSummaries @(
            [pscustomobject]@{status='PASSED';exitCode=0},
            [pscustomobject]@{status='PASSED';exitCode=0}
        )
        $result.status | Should -BeExactly 'PASSED'
        $result.statusCounts.passed | Should -Be 2
        $summary=[pscustomobject][ordered]@{
            schemaVersion=1;runId='20261010T120000Z_abcd1234';status=$result.status;universeHash=('a'*64);manifestHash=('b'*64);targetCount=1;shardCount=1;maxParallelShards=1;statusCounts=$result.statusCounts
            shards=@([pscustomobject][ordered]@{shardIndex=0;status='PASSED';exitCode=0;processId=123;targetCount=1;statusCounts=[pscustomobject]@{Pending=0;Running=0;Passed=1;Failed=0;Blocked=0};statePath='[RUNTIME_ROOT]/validation-matrix/state.json';summaryPath='shard-0000.summary.json';stdoutPath='shard-0000.stdout.log';stdoutSha256=('c'*64);stderrPath='shard-0000.stderr.log';stderrSha256=('d'*64);error=$null})
            generatedAt=[DateTimeOffset]::UtcNow.ToString('o')
        }
        $schemaPath=Join-Path $commonRoot 'schemas/full-compatibility-matrix-run.schema.json'
        (Test-Json -Json (ConvertTo-Json -InputObject $summary -Depth 20) -SchemaFile $schemaPath) | Should -BeTrue
    }

    It 'keeps failed or incomplete shards from being summarized as passed' {
        (Get-MmtlFullMatrixAggregateStatus -ShardSummaries @([pscustomobject]@{status='FAILED';exitCode=1})).status | Should -BeExactly 'PARTIAL'
        $partial=Get-MmtlFullMatrixAggregateStatus -ShardSummaries @([pscustomobject]@{status='PARTIAL';exitCode=1})
        $partial.statusCounts.partial | Should -Be 1
        (Get-MmtlFullMatrixAggregateStatus -ShardSummaries @([pscustomobject]@{status='INCOMPLETE';exitCode=2})).status | Should -BeExactly 'INCOMPLETE'
        { Get-MmtlFullMatrixAggregateStatus -ShardSummaries @() } | Should -Throw '*MATRIX_SHARDS_EMPTY*'
        { Get-MmtlFullMatrixAggregateStatus -ShardSummaries @([pscustomobject]@{status='UNKNOWN';exitCode=0}) } | Should -Throw '*MATRIX_SHARD_STATUS_INVALID*'
    }

    It 'preflights every frozen target and records a hidden worker result without running builds' {
        $manifest=New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 100
        $projectRoot=Join-Path $TestDrive 'fixture project';$null=New-Item -ItemType Directory -Path $projectRoot -Force
        $jobs=[Collections.Generic.List[object]]::new()
        $ledgerById=@{};foreach($row in $script:ledger.targets){$ledgerById[[string]$row.targetId]=$row}
        foreach($target in @($script:universe.targets|Where-Object availability -CEQ 'Available')){
            $row=$ledgerById[[string]$target.targetId];$firstCandidate=@($target.loaderVersionCandidates|Select-Object -First 1)[0];$version=if($firstCandidate -is [string]){[string]$firstCandidate}elseif($firstCandidate.PSObject.Properties['loaderVersion']){[string]$firstCandidate.loaderVersion}else{[string]$firstCandidate.version}
            $jobs.Add([pscustomobject][ordered]@{
                targetId=[string]$target.targetId;projectPath='fixture project'
                project=[pscustomobject][ordered]@{minecraftVersion=[string]$target.minecraftId;loader=[string]$target.loaderId;loaderVersion=$version;wrapper='gradlew'}
                target=[pscustomobject][ordered]@{targetId=[string]$target.targetId;minecraftId=[string]$target.minecraftId;loaderVersion=$version;loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id=[string]$target.loaderId;version=$version}};sourceFixture=[pscustomobject]@{type='UserProject';source='test';commit='test';license='User-owned';trust='UserOwned';allowedTasks=@('build')};task='build'}
                cacheIdentity=[pscustomobject][ordered]@{targetId=[string]$target.targetId;universeHash=[string]$manifest.universeHash;sourceHash=[string]$row.sourceHash;toolchainHash=[string]$row.toolchainHash;targetSpecHash=[string]$row.targetSpecHash;agentHash=$null}
                scenario=[pscustomobject][ordered]@{clientCount=2;identityKind='Offline';transportPolicy='NativeIntegratedLANOrExplicitHistoricalDedicatedEquivalent';requiredDimensions=@('BuildExactPass','RuntimeBindingPass','ClientLaunchPass','MultiWindowPass','SingleAssertionPass','MultiplayerJoinAndAssertionPass','TargetReportPass','SafeStopPass')}
            })
        }
        $manifestPath=Join-Path $TestDrive 'matrix.json';$jobsPath=Join-Path $TestDrive 'jobs.json'
        [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifest -Depth 30),[Text.UTF8Encoding]::new($false))
        $jobsDocument=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=[string]$manifest.manifestHash;jobs=@($jobs.ToArray());jobsHash=$null}
        $jobsCore=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=[string]$manifest.manifestHash;jobs=@($jobs.ToArray())}
        $jobsPayload=ConvertTo-Json -InputObject $jobsCore -Depth 40 -Compress
        $jobsDocument.jobsHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($jobsPayload))).ToLowerInvariant()
        [IO.File]::WriteAllText($jobsPath,(ConvertTo-Json -InputObject $jobsDocument -Depth 30),[Text.UTF8Encoding]::new($false))
        $workerPath=Join-Path $TestDrive 'fake matrix worker.ps1'
        $worker=@'
param([string]$MatrixManifestPath,[string]$JobsPath,[int]$ShardIndex,[int]$ShardCount,[string]$RuntimeRoot,[string]$OutputPath,[string]$UniversePath,[string]$FamilyManifestPath,[string]$LedgerPath,[int]$MaxAttempts,[int]$TimeoutSeconds,[string[]]$AllowedOwners,[string]$BuildJavaHome,[switch]$Clean)
$manifest=Get-Content -LiteralPath $MatrixManifestPath -Raw|ConvertFrom-Json
$targetCount=0;for($i=$ShardIndex;$i -lt $manifest.chunks.Count;$i+=$ShardCount){$targetCount+=[int]$manifest.chunks[$i].targetCount}
$summary=[pscustomobject][ordered]@{schemaVersion=1;status='PASSED';universeHash=[string]$manifest.universeHash;manifestHash=[string]$manifest.manifestHash;shardIndex=$ShardIndex;shardCount=$ShardCount;targetCount=$targetCount;statusCounts=[pscustomobject]@{Pending=0;Running=0;Passed=$targetCount;Failed=0;Blocked=0};results=@();statePath=(Join-Path $RuntimeRoot 'validation-matrix/state.json')}
[IO.File]::WriteAllText($OutputPath,(ConvertTo-Json -InputObject $summary -Depth 20),[Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine('START:'+ [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
Start-Sleep -Milliseconds 300
[Console]::Out.WriteLine('END:'+ [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
[Console]::Out.WriteLine($RuntimeRoot)
'@
        [IO.File]::WriteAllText($workerPath,$worker,[Text.UTF8Encoding]::new($false))
        $runtime=Join-Path $TestDrive 'runtime root'
        Mock Get-MmtlFullMatrixAvailableMemoryGiB -ModuleName FullCompatibilityMatrixRunner { 9.25 }
        $result=Invoke-MmtlFullCompatibilityMatrix -MatrixManifestPath $manifestPath -JobsPath $jobsPath -ShardCount 2 -MaxParallelShards 1 -MemoryAwareParallelism -RuntimeRoot $runtime -OutputDirectory (Join-Path $TestDrive 'matrix outputs') -WorkerScriptPath $workerPath
        Should -Invoke Get-MmtlFullMatrixAvailableMemoryGiB -Times 1 -Exactly -ModuleName FullCompatibilityMatrixRunner
        $result.status | Should -BeExactly 'PASSED'
        $result.targetCount | Should -Be 1631
        $result.shards.Count | Should -Be 2
        $result.maxParallelShards | Should -Be 1
        $result.shards[0].processId | Should -BeGreaterThan 0
        $result.shards[0].status | Should -BeExactly 'PASSED'
        $result.shards[0].stdoutSha256 | Should -Match '^[a-f0-9]{64}$'
        $stdoutFiles=@($result.shards|ForEach-Object{Get-Content (Join-Path (Split-Path $result.summaryPath) $_.stdoutPath) -Raw})
        $stdoutFiles[0] | Should -Not -Match ([regex]::Escape($runtime))
        $firstEnd=[long]([regex]::Match($stdoutFiles[0],'END:(\d+)').Groups[1].Value)
        $secondStart=[long]([regex]::Match($stdoutFiles[1],'START:(\d+)').Groups[1].Value)
        $secondStart | Should -BeGreaterOrEqual $firstEnd
        $childSummary=Get-Content (Join-Path (Split-Path $result.summaryPath) $result.shards[0].summaryPath) -Raw|ConvertFrom-Json
        $childSummary.statePath | Should -Not -Match ([regex]::Escape($runtime))
        $result.shards[0].statePath | Should -Match '^\[RUNTIME_ROOT\]'
        (Get-Content $result.summaryPath -Raw|ConvertFrom-Json).statusCounts.passed | Should -Be 2
    }

    It 'interrupts an active shard worker and recovers its persisted Running target without overlap' {
        Import-Module (Join-Path $commonRoot 'src/Validation/ValidationMatrixChunks.psm1') -Force
        Import-Module (Join-Path $commonRoot 'src/Validation/ValidationMatrixRunState.psm1') -Force
        $manifest=New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 100
        $projectRoot=Join-Path $TestDrive 'interrupt fixture project';$null=New-Item -ItemType Directory -Path $projectRoot -Force
        $jobs=[Collections.Generic.List[object]]::new();$ledgerById=@{};foreach($row in $script:ledger.targets){$ledgerById[[string]$row.targetId]=$row}
        foreach($target in @($script:universe.targets|Where-Object availability -CEQ 'Available')){
            $row=$ledgerById[[string]$target.targetId];$firstCandidate=@($target.loaderVersionCandidates|Select-Object -First 1)[0];$version=if($firstCandidate -is [string]){[string]$firstCandidate}elseif($firstCandidate.PSObject.Properties['loaderVersion']){[string]$firstCandidate.loaderVersion}else{[string]$firstCandidate.version}
            $jobs.Add([pscustomobject][ordered]@{
                targetId=[string]$target.targetId;projectPath='interrupt fixture project'
                project=[pscustomobject][ordered]@{minecraftVersion=[string]$target.minecraftId;loader=[string]$target.loaderId;loaderVersion=$version;wrapper='gradlew'}
                target=[pscustomobject][ordered]@{targetId=[string]$target.targetId;minecraftId=[string]$target.minecraftId;loaderVersion=$version;loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id=[string]$target.loaderId;version=$version}};sourceFixture=[pscustomobject]@{type='UserProject';source='test';commit='test';license='User-owned';trust='UserOwned';allowedTasks=@('build')};task='build'}
                cacheIdentity=[pscustomobject][ordered]@{targetId=[string]$target.targetId;universeHash=[string]$manifest.universeHash;sourceHash=[string]$row.sourceHash;toolchainHash=[string]$row.toolchainHash;targetSpecHash=[string]$row.targetSpecHash;agentHash=$null}
                scenario=[pscustomobject][ordered]@{clientCount=2;identityKind='Offline';transportPolicy='NativeIntegratedLANOrExplicitHistoricalDedicatedEquivalent';requiredDimensions=@('BuildExactPass','RuntimeBindingPass','ClientLaunchPass','MultiWindowPass','SingleAssertionPass','MultiplayerJoinAndAssertionPass','TargetReportPass','SafeStopPass')}
            })
        }
        $manifestPath=Join-Path $TestDrive 'interrupt matrix.json';$jobsPath=Join-Path $TestDrive 'interrupt jobs.json'
        [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifest -Depth 30),[Text.UTF8Encoding]::new($false))
        $jobsDocument=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=[string]$manifest.manifestHash;jobs=@($jobs.ToArray());jobsHash=$null}
        $jobsCore=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=[string]$manifest.manifestHash;jobs=@($jobs.ToArray())}
        $jobsPayload=ConvertTo-Json -InputObject $jobsCore -Depth 40 -Compress
        $jobsDocument.jobsHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($jobsPayload))).ToLowerInvariant()
        [IO.File]::WriteAllText($jobsPath,(ConvertTo-Json -InputObject $jobsDocument -Depth 30),[Text.UTF8Encoding]::new($false))
        $runtime=Join-Path $TestDrive 'interrupt runtime';$outputDirectory=Join-Path $TestDrive 'interrupt outputs'
        $workerPath=Join-Path $TestDrive 'lease holding worker.ps1';$runStateModule=Join-Path $commonRoot 'src/Validation/ValidationMatrixRunState.psm1'
        $worker=@'
param([string]$MatrixManifestPath,[string]$JobsPath,[int]$ShardIndex,[int]$ShardCount,[string]$RuntimeRoot,[string]$OutputPath,[string]$UniversePath,[string]$FamilyManifestPath,[string]$LedgerPath,[int]$MaxAttempts,[int]$TimeoutSeconds,[string[]]$AllowedOwners,[string]$BuildJavaHome,[switch]$Clean)
$ErrorActionPreference='Stop'
Import-Module '__RUN_STATE_MODULE__' -Force
$manifest=Get-Content -LiteralPath $MatrixManifestPath -Raw|ConvertFrom-Json
$chunks=@($manifest.chunks[$ShardIndex]);$targetCount=[int]$chunks[0].targetCount
$shard=[pscustomobject][ordered]@{schemaVersion=1;universeHash=[string]$manifest.universeHash;manifestHash=[string]$manifest.manifestHash;shardIndex=$ShardIndex;shardCount=$ShardCount;targetCount=$targetCount;chunkCount=1;chunks=$chunks}
$state=New-MmtlValidationMatrixRunState -Shard $shard -RuntimeRoot $RuntimeRoot
$state=Set-MmtlValidationMatrixTargetStatus -State $state -TargetId ([string]$chunks[0].targets[0].targetId) -Status Running
[IO.File]::WriteAllText(($OutputPath+'.ready'),[string]$PID,[Text.UTF8Encoding]::new($false))
while($true){Start-Sleep -Seconds 1}
'@
        $worker=$worker.Replace('__RUN_STATE_MODULE__',$runStateModule.Replace('\','/'))
        [IO.File]::WriteAllText($workerPath,$worker,[Text.UTF8Encoding]::new($false))
        $script:interruptReadyRoot=$outputDirectory
        Mock Start-Sleep -ModuleName FullCompatibilityMatrixRunner {
            $deadline=[DateTimeOffset]::UtcNow.AddSeconds(30);$ready=@()
            while($ready.Count -eq 0 -and [DateTimeOffset]::UtcNow -lt $deadline){
                if(Test-Path -LiteralPath $script:interruptReadyRoot){$ready=@(Get-ChildItem -LiteralPath $script:interruptReadyRoot -Filter '*.ready' -File -Recurse -ErrorAction SilentlyContinue)}
                if($ready.Count -eq 0){[Threading.Thread]::Sleep(50)}
            }
            if($ready.Count -eq 0){throw 'TEST_MATRIX_WORKER_NOT_READY'}
            throw 'SIMULATED_MATRIX_COORDINATOR_INTERRUPTION'
        }
        $shardCount=[int]$manifest.chunkCount
        { Invoke-MmtlFullCompatibilityMatrix -MatrixManifestPath $manifestPath -JobsPath $jobsPath -ShardCount $shardCount -MaxParallelShards 1 -RuntimeRoot $runtime -OutputDirectory $outputDirectory -WorkerScriptPath $workerPath } | Should -Throw '*SIMULATED_MATRIX_COORDINATOR_INTERRUPTION*'
        $readyFiles=@(Get-ChildItem -LiteralPath $outputDirectory -Filter '*.ready' -File -Recurse)
        $readyFiles.Count | Should -Be 1
        $workerPid=[int](Get-Content -LiteralPath $readyFiles[0].FullName -Raw)
        $processStillRunning=$false
        try{$ownedProcess=[Diagnostics.Process]::GetProcessById($workerPid);$processStillRunning=-not $ownedProcess.HasExited;$ownedProcess.Dispose()}catch [ArgumentException]{}
        $processStillRunning | Should -BeFalse
        $runOutput=Split-Path -Parent $readyFiles[0].FullName
        $baseName='shard-{0:D4}-of-{1:D4}' -f 0,$shardCount
        (Test-Path -LiteralPath (Join-Path $runOutput ($baseName+'.stdout.log'))) | Should -BeTrue
        $shard=[pscustomobject][ordered]@{schemaVersion=1;universeHash=[string]$manifest.universeHash;manifestHash=[string]$manifest.manifestHash;shardIndex=0;shardCount=$shardCount;targetCount=[int]$manifest.chunks[0].targetCount;chunkCount=1;chunks=@($manifest.chunks[0])}
        $recovered=New-MmtlValidationMatrixRunState -Shard $shard -RuntimeRoot $runtime
        $interrupted=@($recovered.targets|Where-Object interruptedPreviousAttempt)
        $interrupted.Count | Should -Be 1
        $interrupted[0].status | Should -BeExactly 'Pending'
        $interrupted[0].attempts | Should -Be 1
    }
}
