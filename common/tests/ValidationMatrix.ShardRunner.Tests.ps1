BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:platformRoot=Split-Path -Parent $script:repoRoot
    $script:goalProgressModule=Import-Module (Join-Path $script:repoRoot 'src/Compatibility/GoalProgress.psm1') -Force -PassThru
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force -Global
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        Import-Module (Join-Path $script:platformRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
        Register-MmtlWindowsPlatform -RepositoryRoot $script:platformRoot
    }elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){
        Import-Module (Join-Path $script:platformRoot 'linux/src/LinuxPlatformProvider.psm1') -Force
        Register-MmtlLinuxPlatform -RepositoryRoot $script:platformRoot
    }else{
        Import-Module (Join-Path $script:platformRoot 'macos/src/MacOSPlatformProvider.psm1') -Force
        Register-MmtlMacOSPlatform -RepositoryRoot $script:platformRoot
    }
    $script:runStateModule=Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationMatrixRunState.psm1') -Force -PassThru
    Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationMatrixShardRunner.psm1') -Force
    $script:shard=[pscustomobject]@{schemaVersion=1;universeHash=('a'*64);manifestHash=('b'*64);shardIndex=0;shardCount=1;targetCount=2;chunks=@([pscustomobject]@{loaderId='Fabric';familyId='fabric-family';targets=@(
        [pscustomobject]@{targetId='fabric-1.20.1';minecraftId='1.20.1';loaderVersionCandidates=@('0.15.0');targetSpecHash=('d'*64);sourceHash=('e'*64);toolchainHash=('c'*64)},
        [pscustomobject]@{targetId='fabric-1.20.2';minecraftId='1.20.1';loaderVersionCandidates=@('0.15.0');targetSpecHash=('f'*64);sourceHash=('0'*64);toolchainHash=('c'*64)}
    )})}
    $script:jobs=@(foreach($target in $script:shard.chunks[0].targets){[pscustomobject]@{targetId=$target.targetId;target=[pscustomobject]@{targetId=$target.targetId;minecraftId='1.20.1';loaderVersion='0.15.0';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric';version='0.15.0'}};sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}};project=[pscustomobject]@{Root='C:/fixture';MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0'};cacheIdentity=[pscustomobject]@{targetId=$target.targetId;universeHash=('a'*64);sourceHash=$target.sourceHash;toolchainHash=('c'*64);targetSpecHash=$target.targetSpecHash;agentHash=$null}}})
    function New-TestShardState { param($Shard,[string]$Root,[int]$MaxAttempts=2) & $script:runStateModule { param($s,$r,$m) New-MmtlValidationMatrixRunState -Shard $s -RuntimeRoot $r -MaxAttempts $m } $Shard $Root $MaxAttempts }
    function Set-TestShardState { param($State,[string]$TargetId,[string]$Status,[string]$FailureCode) & $script:runStateModule { param($s,$id,$st,$c) Set-MmtlValidationMatrixTargetStatus -State $s -TargetId $id -Status $st -FailureCode $c } $State $TargetId $Status $FailureCode }
    function Get-TestShardState { param($Shard,[string]$Root,[int]$MaxAttempts=2) & $script:runStateModule { param($s,$r,$m) Get-MmtlValidationMatrixRunState -Shard $s -RuntimeRoot $r -MaxAttempts $m } $Shard $Root $MaxAttempts }
    function Set-TestGradleWrapper { param([string]$ProjectRoot,[string]$WindowsBody,[string]$UnixBody) if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){Set-Content -LiteralPath (Join-Path $ProjectRoot 'gradlew.bat') -Value $WindowsBody -Encoding ascii}else{$path=Join-Path $ProjectRoot 'gradlew';Set-Content -LiteralPath $path -Value $UnixBody -Encoding utf8;& chmod +x $path} }
}

Describe 'Validation matrix shard orchestration' {
    It 'resolves the validated provisioned projectPath as the project Root' {
        $projectPath=Join-Path $TestDrive 'provisioned-project';$null=New-Item -ItemType Directory -Path $projectPath -Force
        $job=[pscustomobject]@{projectPath=$projectPath;project=[pscustomobject]@{Root='legacy-root';Loader='Fabric';buildSystem='Gradle';buildSystemVersion='9.7.1'}}
        $resolved=Resolve-MmtlValidationMatrixJobProject -Job $job
        $resolved.Root | Should -BeExactly ([IO.Path]::GetFullPath($projectPath))
        $resolved.Loader | Should -BeExactly 'Fabric'
        $resolved.BuildSystem.id | Should -BeExactly 'Gradle'
        $resolved.BuildSystem.version | Should -BeExactly '9.7.1'
    }

    It 'rejects incomplete or duplicate exact-target job sets before running any target' {
        $calls=[pscustomobject]@{count=0}
        Mock -CommandName Invoke-MmtlValidationMatrixTarget -ModuleName ValidationMatrixTargetRunner -MockWith ({$calls.count++;throw 'must not run'}.GetNewClosure())
        $root=Join-Path $TestDrive 'incomplete'
        { Invoke-MmtlValidationMatrixShard -Shard $script:shard -Jobs @($script:jobs[0]) -RuntimeRoot $root } | Should -Throw '*MATRIX_JOB_SET_INCOMPLETE*'
        $calls.count | Should -Be 0
        { Invoke-MmtlValidationMatrixShard -Shard $script:shard -Jobs @($script:jobs[0],$script:jobs[0]) -RuntimeRoot $root } | Should -Throw '*MATRIX_JOB_DUPLICATE*'
    }

    It 'rejects a job cache identity with a different frozen toolchain hash before running any target' {
        $calls=[pscustomobject]@{count=0}
        Mock -CommandName Invoke-MmtlValidationMatrixTarget -ModuleName ValidationMatrixShardRunner -MockWith ({$calls.count++;throw 'must not run'}.GetNewClosure())
        $badJobs=@($script:jobs | ForEach-Object{$copy=$_.PSObject.Copy();$copy.cacheIdentity=$_.cacheIdentity.PSObject.Copy();$copy.cacheIdentity.toolchainHash=('9'*64);$copy})
        { Invoke-MmtlValidationMatrixShard -Shard $script:shard -Jobs $badJobs -RuntimeRoot (Join-Path $TestDrive 'wrong-toolchain') } | Should -Throw '*MATRIX_JOB_IDENTITY_MISMATCH*'
        $calls.count | Should -Be 0
    }

    It 'rejects project Minecraft or Loader metadata outside the frozen exact target before running any target' {
        $calls=[pscustomobject]@{count=0}
        Mock -CommandName Invoke-MmtlValidationMatrixTarget -ModuleName ValidationMatrixShardRunner -MockWith ({$calls.count++;throw 'must not run'}.GetNewClosure())
        foreach($property in @('MinecraftVersion','Loader','LoaderVersion')){
            $badJobs=@($script:jobs | ForEach-Object{$copy=$_.PSObject.Copy();$copy.project=$_.project.PSObject.Copy();$copy.project.$property=if($property -eq 'MinecraftVersion'){'1.21.1'}elseif($property -eq 'Loader'){'Quilt'}else{'0.16.0'};$copy})
            { Invoke-MmtlValidationMatrixShard -Shard $script:shard -Jobs $badJobs -RuntimeRoot (Join-Path $TestDrive "wrong-$property") } | Should -Throw '*MATRIX_PROJECT_TARGET_MISMATCH*'
        }
        $calls.count | Should -Be 0
    }

    It 'rejects target payload metadata outside the frozen exact target before running any target' {
        $calls=[pscustomobject]@{count=0}
        Mock -CommandName Invoke-MmtlValidationMatrixTarget -ModuleName ValidationMatrixShardRunner -MockWith ({$calls.count++;throw 'must not run'}.GetNewClosure())
        $badJobs=@($script:jobs | ForEach-Object{$copy=$_.PSObject.Copy();$copy.target=$_.target.PSObject.Copy();$copy.target.loaderStack=$_.target.loaderStack.PSObject.Copy();$copy.target.loaderStack.primary=$_.target.loaderStack.primary.PSObject.Copy();$copy.target.loaderStack.primary.id='Quilt';$copy})
        { Invoke-MmtlValidationMatrixShard -Shard $script:shard -Jobs $badJobs -RuntimeRoot (Join-Path $TestDrive 'wrong-target-payload') } | Should -Throw '*MATRIX_TARGET_METADATA_MISMATCH*'
        $calls.count | Should -Be 0
    }

    It 'holds every exact-target lease throughout target execution and releases on failure' {
        $runtime=Join-Path $TestDrive 'runtime-target-lease';$observed=[pscustomobject]@{called=0;locked=0;unlocked=0;otherErrors=@()};$shard=$script:shard;$stateModule=$script:runStateModule
        $mock={
            $observed.called++
            try{$probe=& $stateModule {param($r,$s) Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $r -Shard $s} $runtime $shard;& $stateModule {param($l) Exit-MmtlValidationMatrixTargetLeases -Lease $l} $probe;$observed.unlocked++}
            catch{if([string]$_.Exception.Message -like '*RUN_STATE_TARGET_ALREADY_ACTIVE*'){$observed.locked++}else{$observed.otherErrors+=([string]$_.Exception.Message);throw}}
            throw 'TEST_TARGET_STOPPED'
        }.GetNewClosure()
        Mock -CommandName Invoke-MmtlValidationMatrixTarget -ModuleName ValidationMatrixShardRunner -MockWith $mock
        $result=Invoke-MmtlValidationMatrixShard -Shard $script:shard -Jobs $script:jobs -RuntimeRoot $runtime
        $result.status | Should -BeExactly 'INCOMPLETE'
        $result.results.Count | Should -Be 2
        $observed.called | Should -Be 2
        $observed.otherErrors | Should -BeNullOrEmpty
        $observed.locked | Should -Be 2
        $observed.unlocked | Should -Be 0
        $after=& $script:runStateModule {param($r,$s) Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $r -Shard $s} $runtime $script:shard
        & $script:runStateModule {param($l) Exit-MmtlValidationMatrixTargetLeases -Lease $l} $after
    }

    It 'continues after a real wrapper failure, retries only that target, and skips passed targets' {
        $goalRoot=Join-Path $TestDrive 'goal-progress-resume';$runtime=Join-Path $goalRoot 'runtime';$projects=@();$jobs=@();$fixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}
        $exactTargets=@($script:shard.chunks[0].targets|ForEach-Object{$_.PSObject.Copy()})
        $exactTargets[0].targetId='Fabric@1.20.1';$exactTargets[0].minecraftId='1.20.1'
        $exactTargets[1].targetId='Fabric@1.20.2';$exactTargets[1].minecraftId='1.20.2'
        $exactChunk=$script:shard.chunks[0].PSObject.Copy();$exactChunk.targets=$exactTargets
        $testShard=$script:shard.PSObject.Copy();$testShard.chunks=@($exactChunk)
        foreach($target in $testShard.chunks[0].targets){
            $index=if($target.targetId -eq 'Fabric@1.20.1'){1}else{2};$projectRoot=Join-Path $TestDrive "project-$index";$null=New-Item -ItemType Directory -Path $projectRoot -Force
            $marker=Join-Path $TestDrive "wrapper-$index-runs.txt";$winMarker=$marker.Replace('"','""');$unixMarker=$marker.Replace("'","'\''")
            if($index -eq 1){$win="@echo first-failed>>`"$winMarker`"`r`n@exit /b 1";$unix="#!/bin/sh`necho first-failed >> '$unixMarker'`nexit 1"}
            else{$win="@echo second-passed>>`"$winMarker`"`r`n@if not exist build\libs mkdir build\libs`r`n@echo artifact>build\libs\marker.jar`r`n@exit /b 0";$unix="#!/bin/sh`necho second-passed >> '$unixMarker'`nmkdir -p build/libs`necho artifact > build/libs/marker.jar`nexit 0"}
            Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody $win -UnixBody $unix
            $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion=$target.minecraftId;Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
            $jobs+=,[pscustomobject]@{targetId=$target.targetId;target=[pscustomobject]@{targetId=$target.targetId;minecraftId=$target.minecraftId;loaderVersion='0.15.0';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric';version='0.15.0'}};sourceFixture=$fixture};project=$project;cacheIdentity=[pscustomobject]@{targetId=$target.targetId;universeHash=$testShard.universeHash;sourceHash=$target.sourceHash;toolchainHash=('c'*64);targetSpecHash=$target.targetSpecHash;agentHash=$null};marker=$marker;projectRoot=$projectRoot;wrapperIndex=$index}
        }
        & $script:goalProgressModule {param($r) Start-MmtlGoalProgressRun -RunRoot $r -RunId 'matrix-recovery-run' -UniverseHash ('a'*64) -UniverseTargetCount 1631 | Out-Null} $goalRoot
        $first=Invoke-MmtlValidationMatrixShard -Shard $testShard -Jobs $jobs -RuntimeRoot $runtime -TimeoutSeconds 30 -GoalProgressRunRoot $goalRoot
        $first.status | Should -BeExactly 'PARTIAL'
        $first.statusCounts.Failed | Should -Be 1
        $first.statusCounts.Passed | Should -Be 1
        $first.results.Count | Should -Be 2
        (Get-Content -LiteralPath $jobs[0].marker).Count | Should -Be 1
        (Get-Content -LiteralPath $jobs[1].marker).Count | Should -Be 1

        $win="@echo first-retried>>`"$($jobs[0].marker)`"`r`n@if not exist build\libs mkdir build\libs`r`n@echo artifact>build\libs\marker.jar`r`n@exit /b 0";$unix="#!/bin/sh`necho first-retried >> '$($jobs[0].marker.Replace("'","'\''"))'`nmkdir -p build/libs`necho artifact > build/libs/marker.jar`nexit 0"
        Set-TestGradleWrapper -ProjectRoot $jobs[0].projectRoot -WindowsBody $win -UnixBody $unix
        $second=Invoke-MmtlValidationMatrixShard -Shard $testShard -Jobs $jobs -RuntimeRoot $runtime -TimeoutSeconds 30 -GoalProgressRunRoot $goalRoot
        $second.status | Should -BeExactly 'PASSED'
        $second.statusCounts.Passed | Should -Be 2
        $second.results.Count | Should -Be 1
        (Get-Content -LiteralPath $jobs[0].marker).Count | Should -Be 2
        (Get-Content -LiteralPath $jobs[1].marker).Count | Should -Be 1
        $journalPath=Join-Path $goalRoot 'events.jsonl'
        $journalLines=[IO.File]::ReadAllLines($journalPath)
        $keptLines=[Collections.Generic.List[string]]::new()
        foreach($line in $journalLines){$record=$line|ConvertFrom-Json;if(-not($record.eventType -ceq 'Attempt' -and $record.targetId -ceq 'Fabric@1.20.1' -and [int]$record.attemptNumber -eq 2 -and $record.status -ceq 'PASS')){$keptLines.Add($line)}}
        [IO.File]::WriteAllLines($journalPath,$keptLines.ToArray(),[Text.UTF8Encoding]::new($false))
        $third=Invoke-MmtlValidationMatrixShard -Shard $testShard -Jobs $jobs -RuntimeRoot $runtime -TimeoutSeconds 30 -GoalProgressRunRoot $goalRoot
        $third.status | Should -BeExactly 'PASSED'
        $third.results.Count | Should -Be 0
        $recoveredSummary=& $script:goalProgressModule {param($r) Get-MmtlGoalProgressSummary -RunRoot $r} $goalRoot
        $recoveredRecords=[IO.File]::ReadAllLines($journalPath)|ForEach-Object{$_|ConvertFrom-Json}
        $recoveredSummary.buildExactPassUnique | Should -Be 2
        @($recoveredRecords|Where-Object eventType -CEQ 'Attempt').Count | Should -Be 3
    }

    It 'writes each exact Build attempt to the goal progress journal with durable evidence reference' {
        $goalRoot=Join-Path $TestDrive 'goal-progress'
        $runtime=Join-Path $goalRoot 'runtime'
        $evidence=Join-Path $runtime 'validation/evidence-build.json'
        $null=New-Item -ItemType Directory -Path (Split-Path -Parent $evidence) -Force
        [IO.File]::WriteAllText($evidence,'{}',[Text.UTF8Encoding]::new($false))
        & $script:goalProgressModule {param($r) Start-MmtlGoalProgressRun -RunRoot $r -RunId 'matrix-goal-run' -UniverseHash ('a'*64) -UniverseTargetCount 1631 | Out-Null} $goalRoot

        $target=$script:shard.chunks[0].targets[0].PSObject.Copy()
        $target.targetId='Fabric@1.20.1'
        $target.minecraftId='1.20.1'
        $chunk=[pscustomobject]@{loaderId='Fabric';familyId='fabric-adapter-family-v1';targets=@($target)}
        $shard=[pscustomobject]@{schemaVersion=1;universeHash=('a'*64);manifestHash=('b'*64);shardIndex=0;shardCount=1;targetCount=1;chunks=@($chunk)}
        $sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}
        $job=[pscustomobject]@{
            targetId='Fabric@1.20.1'
            target=[pscustomobject]@{targetId='Fabric@1.20.1';minecraftId='1.20.1';loaderVersion='0.15.0';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric';version='0.15.0'}};sourceFixture=$sourceFixture}
            project=[pscustomobject]@{Root=(Join-Path $TestDrive 'project');MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0'}
            cacheIdentity=[pscustomobject]@{targetId='Fabric@1.20.1';universeHash=('a'*64);sourceHash=$target.sourceHash;toolchainHash=$target.toolchainHash;targetSpecHash=$target.targetSpecHash;agentHash=$null}
        }
        $stateModule=$script:runStateModule
        $mock={
            param($State,$TargetId,$Project,$Target,$RuntimeRoot,$CacheIdentity)
            [pscustomobject]@{targetId=$TargetId;result=[pscustomobject]@{result='PASSED';failureCode='NONE';evidencePath=$evidence;durationSeconds=0.1};runState=$State;cached=$false}
        }.GetNewClosure()
        Mock -CommandName Invoke-MmtlValidationMatrixTarget -ModuleName ValidationMatrixShardRunner -MockWith $mock

        $result=Invoke-MmtlValidationMatrixShard -Shard $shard -Jobs @($job) -RuntimeRoot $runtime -GoalProgressRunRoot $goalRoot
        $summary=& $script:goalProgressModule {param($r) Get-MmtlGoalProgressSummary -RunRoot $r} $goalRoot
        $records=[IO.File]::ReadAllLines((Join-Path $goalRoot 'events.jsonl'))|ForEach-Object{$_|ConvertFrom-Json}
        $attempt=@($records|Where-Object eventType -CEQ 'Attempt')
        $result.results[0].result | Should -BeExactly 'PASSED'
        $summary.buildExactPassUnique | Should -Be 1
        $attempt.Count | Should -Be 1
        $attempt[0].targetId | Should -BeExactly 'Fabric@1.20.1'
        $attempt[0].familyId | Should -BeExactly 'fabric-adapter-family-v1'
        $attempt[0].adapterId | Should -BeExactly 'fabric-adapter-family-v1'
        $attempt[0].status | Should -BeExactly 'PASS'
        $attempt[0].attemptNumber | Should -Be 1
        $attempt[0].batchInputSha256 | Should -BeExactly $shard.manifestHash
        $attempt[0].isFreshExecution | Should -BeTrue
        $attempt[0].evidencePaths[0] | Should -BeExactly 'runtime/validation/evidence-build.json'
        $attempt[0].evidenceSha256[0] | Should -BeExactly (Get-FileHash -LiteralPath $evidence -Algorithm SHA256).Hash.ToLowerInvariant()
        $attempt[0].sourceHash | Should -BeExactly $target.sourceHash
        $attempt[0].targetSpecHash | Should -BeExactly $target.targetSpecHash
        $attempt[0].toolchainHash | Should -BeExactly $target.toolchainHash
    }

    It 'records an interrupted matrix attempt as TIMEOUT before scheduling the retry' {
        $goalRoot=Join-Path $TestDrive 'goal-progress-interrupted';$runtime=Join-Path $goalRoot 'runtime'
        $target=$script:shard.chunks[0].targets[0].PSObject.Copy();$target.targetId='Fabric@1.20.1';$target.minecraftId='1.20.1'
        $chunk=$script:shard.chunks[0].PSObject.Copy();$chunk.targets=@($target)
        $shard=[pscustomobject]@{schemaVersion=1;universeHash=('a'*64);manifestHash=('9'*64);shardIndex=0;shardCount=1;targetCount=1;chunks=@($chunk)}
        $job=$script:jobs[0].PSObject.Copy();$job.targetId='Fabric@1.20.1';$job.target=$job.target.PSObject.Copy();$job.target.targetId='Fabric@1.20.1';$job.target.minecraftId='1.20.1';$job.project=$job.project.PSObject.Copy();$job.cacheIdentity=$job.cacheIdentity.PSObject.Copy();$job.cacheIdentity.targetId='Fabric@1.20.1'
        & $script:goalProgressModule {param($r) Start-MmtlGoalProgressRun -RunRoot $r -RunId 'matrix-interrupted-run' -UniverseHash ('a'*64) -UniverseTargetCount 1631 | Out-Null} $goalRoot
        $state=& $script:runStateModule {param($s,$r) New-MmtlValidationMatrixRunState -Shard $s -RuntimeRoot $r -MaxAttempts 2} $shard $runtime
        $null=& $script:runStateModule {param($s) Set-MmtlValidationMatrixTargetStatus -State $s -TargetId 'Fabric@1.20.1' -Status Running} $state
        Mock -CommandName Invoke-MmtlValidationMatrixTarget -ModuleName ValidationMatrixShardRunner -MockWith {throw 'SIMULATED_WORKER_INTERRUPTION'}

        $null=Invoke-MmtlValidationMatrixShard -Shard $shard -Jobs @($job) -RuntimeRoot $runtime -GoalProgressRunRoot $goalRoot -MaxAttempts 2
        $records=[IO.File]::ReadAllLines((Join-Path $goalRoot 'events.jsonl'))|ForEach-Object{$_|ConvertFrom-Json}
        $timeout=@($records|Where-Object{$_.eventType -ceq 'Attempt' -and $_.status -ceq 'TIMEOUT'})
        $timeout.Count | Should -Be 1
        $timeout[0].targetId | Should -BeExactly 'Fabric@1.20.1'
        $timeout[0].attemptNumber | Should -Be 1
        $timeout[0].durationBasis | Should -BeExactly 'RecoveryDetectionUpperBound'
        $timeout[0].failureReason | Should -BeExactly 'RUN_INTERRUPTED_RECOVERED_AT_RESUME'
    }
}
