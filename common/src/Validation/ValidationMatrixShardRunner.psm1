Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ValidationMatrixRunState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationMatrixTargetRunner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../Compatibility/EvidenceStore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../Compatibility/GoalProgress.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TargetIdentity.psm1') -Force

function Sync-MmtlValidationMatrixGoalProgress {
    param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][object]$Shard,[Parameter(Mandatory)][hashtable]$JobsById,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$GoalRoot)

    foreach($targetState in @($State.targets)){
        $wasInterrupted=([bool]$targetState.interruptedPreviousAttempt -and $targetState.status -ceq 'Pending') -or ([string]$targetState.failureCode -ceq 'RUN_INTERRUPTED_ATTEMPT_LIMIT')
        if($targetState.status -notin @('Passed','Failed','Blocked') -and -not $wasInterrupted){continue}
        if(-not $targetState.startedAt -or -not $targetState.endedAt -or [int]$targetState.attempts -lt 1){continue}
        $job=$JobsById[[string]$targetState.targetId]
        $loaderId=[string]$job.project.Loader;$minecraftId=[string]$job.project.MinecraftVersion
        $targetId=$loaderId+'@'+$minecraftId
        if($targetState.status -ceq 'Passed'){$status=if([bool]$targetState.cached){'CACHED'}else{'PASS'}}
        elseif($wasInterrupted){$status='TIMEOUT'}
        elseif($targetState.status -ceq 'Blocked'){$status='BLOCKED'}
        else{$status='FAIL'}

        $start=[DateTimeOffset]::Parse([string]$targetState.startedAt).ToUniversalTime()
        $end=[DateTimeOffset]::Parse([string]$targetState.endedAt).ToUniversalTime()
        if($end -lt $start){throw "MATRIX_GOAL_RECOVERY_TIME_INVALID:$targetId"}
        $duration=($end-$start).TotalSeconds
        $evidencePaths=@();$evidenceSha256=@()
        if($targetState.evidencePath){
            $runtimeFull=[IO.Path]::GetFullPath($RuntimeRoot)
            $evidenceFull=[IO.Path]::GetFullPath((Join-Path $runtimeFull ([string]$targetState.evidencePath)))
            $relativeRuntimeEvidence=[IO.Path]::GetRelativePath($runtimeFull,$evidenceFull)
            if($relativeRuntimeEvidence -eq '..' -or $relativeRuntimeEvidence.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relativeRuntimeEvidence)){throw "MATRIX_GOAL_RECOVERY_EVIDENCE_PATH_INVALID:$targetId"}
            if(-not(Test-Path -LiteralPath $evidenceFull -PathType Leaf) -or (([IO.File]::GetAttributes($evidenceFull) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw "MATRIX_GOAL_RECOVERY_EVIDENCE_MISSING_OR_REPARSE:$targetId"}
            $actualEvidenceHash=(Get-FileHash -LiteralPath $evidenceFull -Algorithm SHA256).Hash.ToLowerInvariant()
            if([string]$targetState.evidenceSha256 -cne $actualEvidenceHash){throw "MATRIX_GOAL_RECOVERY_EVIDENCE_HASH_MISMATCH:$targetId"}
            $relativeEvidence=[IO.Path]::GetRelativePath($GoalRoot,$evidenceFull)
            if($relativeEvidence -eq '..' -or $relativeEvidence.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relativeEvidence)){throw "MATRIX_GOAL_RECOVERY_EVIDENCE_OUTSIDE_RUN_ROOT:$targetId"}
            $evidencePaths=@($relativeEvidence.Replace('\','/'));$evidenceSha256=@($actualEvidenceHash)
        }
        if($status -eq 'PASS' -and $evidencePaths.Count -eq 0){throw "MATRIX_GOAL_RECOVERY_PASS_EVIDENCE_MISSING:$targetId"}

        $event=[pscustomobject][ordered]@{
            eventType='Attempt';attemptId=('recovered-'+[guid]::NewGuid().ToString('N'));workerId='recovered-from-matrix-state'
            loaderId=$loaderId;minecraftId=$minecraftId;targetId=$targetId;loaderVersion=[string]$job.target.loaderVersion
            familyId=[string]$targetState.familyId;adapterId=if($job.target.PSObject.Properties['adapterId']){[string]$job.target.adapterId}else{[string]$targetState.familyId}
            batchId=if($Shard.PSObject.Properties['batchId']){[string]$Shard.batchId}else{('matrix-{0}-shard-{1}-of-{2}' -f [string]$Shard.manifestHash,[int]$Shard.shardIndex,[int]$Shard.shardCount)};batchInputSha256=[string]$Shard.manifestHash
            universeHash=[string]$Shard.universeHash;sourceHash=[string]$targetState.sourceHash;toolchainHash=[string]$targetState.toolchainHash;targetSpecHash=[string]$targetState.targetSpecHash
            dimension='BuildExact';status=$status;attemptNumber=[int]$targetState.attempts;isFreshExecution=($status -ne 'CACHED')
            startedAtUtc=$start.ToString('o');endedAtUtc=$end.ToString('o');durationSeconds=$duration;workerTestSeconds=$duration
            durationBasis=if($wasInterrupted){'RecoveryDetectionUpperBound'}else{'PersistedMatrixRunState'}
            cumulativeRepairSeconds=0;failureReason=if($wasInterrupted -and -not $targetState.failureCode){'RUN_INTERRUPTED_RECOVERED_AT_RESUME'}else{$targetState.failureCode}
            evidencePaths=$evidencePaths;evidenceSha256=$evidenceSha256
            nextAction=if($status -in @('PASS','CACHED')){'continue-family-batch'}else{'classify-root-cause-and-retry-within-budget'}
        }
        if(-not (Test-MmtlGoalAttemptRecorded -RunRoot $GoalRoot -Event $event)){
            Write-MmtlGoalAttemptEvent -RunRoot $GoalRoot -Event $event | Out-Null
        }
    }
}

function Resolve-MmtlValidationMatrixJobProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Job)
    if(-not $Job.PSObject.Properties['projectPath']){
        if(-not $Job.project.PSObject.Properties['Root'] -or [string]::IsNullOrWhiteSpace([string]$Job.project.Root)){throw 'MATRIX_PROJECT_PATH_MISSING'}
        return $Job.project
    }
    $path=[string]$Job.projectPath
    if(-not [IO.Path]::IsPathRooted($path)){throw 'MATRIX_PROJECT_PATH_NOT_ABSOLUTE'}
    $full=[IO.Path]::GetFullPath($path)
    if(-not(Test-Path -LiteralPath $full -PathType Container)){throw 'MATRIX_PROJECT_PATH_NOT_FOUND'}
    $root=[IO.Path]::GetPathRoot($full);$relative=$full.Substring($root.Length);$cursor=$root
    foreach($part in @($relative -split '[\\/]+'|Where-Object{$_})){
        $cursor=[IO.Path]::Combine($cursor,$part)
        if(-not(Test-Path -LiteralPath $cursor)){throw 'MATRIX_PROJECT_PATH_NOT_FOUND'}
        if(([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'MATRIX_PROJECT_ROOT_REPARSE'}
    }
    $project=$Job.project.PSObject.Copy()
    $project|Add-Member -NotePropertyName Root -NotePropertyValue $full -Force
    $buildSystemProperty=$project.PSObject.Properties['buildSystem']
    if($buildSystemProperty -and $buildSystemProperty.Value -is [string]){
        $buildSystemId=[string]$buildSystemProperty.Value
        $buildSystemVersionProperty=$project.PSObject.Properties['buildSystemVersion']
        $buildSystemVersion=if($buildSystemVersionProperty){[string]$buildSystemVersionProperty.Value}else{$null}
        $buildSystemProperty.Value=[pscustomobject][ordered]@{id=$buildSystemId;version=$buildSystemVersion}
    }
    return $project
}

function Invoke-MmtlValidationMatrixShard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Shard,
        [Parameter(Mandatory)][object[]]$Jobs,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [ValidateRange(1,10)][int]$MaxAttempts=3,
        [AllowEmptyCollection()][string[]]$AllowedOwners=@(),
        [string]$BuildJavaHome,
        [string]$GradleHomeRoot,
        [ValidateRange(1,7200)][int]$TimeoutSeconds=1800,
        [string]$GoalProgressRunRoot,
        [switch]$Clean
    )
    $targetLeases=Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $RuntimeRoot -Shard $Shard
    try{
    $state=New-MmtlValidationMatrixRunState -Shard $Shard -RuntimeRoot $RuntimeRoot -MaxAttempts $MaxAttempts -TargetLease $targetLeases
    $goalRoot=$null
    if($GoalProgressRunRoot){
        $goalRoot=[IO.Path]::GetFullPath($GoalProgressRunRoot)
        $null=Get-MmtlGoalProgressSummary -RunRoot $goalRoot
        $goalMetadata=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $goalRoot 'run.json'))) -ErrorAction Stop
        if([string]$goalMetadata.universeHash -cne [string]$Shard.universeHash){throw 'MATRIX_GOAL_UNIVERSE_HASH_MISMATCH'}
        if([int]$goalMetadata.universeTargetCount -lt [int]$Shard.targetCount){throw 'MATRIX_GOAL_UNIVERSE_TARGET_COUNT_MISMATCH'}
        $runtimeFull=[IO.Path]::GetFullPath($RuntimeRoot)
        $relativeRuntime=[IO.Path]::GetRelativePath($goalRoot,$runtimeFull)
        if($relativeRuntime -eq '..' -or $relativeRuntime.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relativeRuntime)){throw 'MATRIX_GOAL_RUNTIME_ROOT_OUTSIDE_RUN_ROOT'}
    }
    $jobsById=@{}
    $projectsById=@{}
    $frozenTargetsById=@{}
    foreach($chunk in @($Shard.chunks)){foreach($frozenTarget in @($chunk.targets)){$frozenTargetsById[[string]$frozenTarget.targetId]=[pscustomobject]@{target=$frozenTarget;loaderId=[string]$chunk.loaderId}}}
    foreach($job in $Jobs){
        if(-not $job.PSObject.Properties['targetId'] -or -not(Test-MmtlExactTargetId -TargetId ([string]$job.targetId))){throw 'MATRIX_JOB_TARGET_ID_INVALID'}
        if($jobsById.ContainsKey([string]$job.targetId)){throw "MATRIX_JOB_DUPLICATE:$($job.targetId)"}
        foreach($name in @('target','project','cacheIdentity')){if(-not $job.PSObject.Properties[$name] -or -not $job.$name){throw "MATRIX_JOB_FIELD_MISSING:$name"}}
        if([string]$job.target.targetId -cne [string]$job.targetId){throw "MATRIX_JOB_TARGET_MISMATCH:$($job.targetId)"}
        $jobsById[[string]$job.targetId]=$job
    }
    if($jobsById.Count -ne [int]$Shard.targetCount){throw 'MATRIX_JOB_SET_INCOMPLETE'}
    foreach($target in @($state.targets)){
        if(-not $jobsById.ContainsKey([string]$target.targetId)){throw "MATRIX_JOB_MISSING:$($target.targetId)"}
        $job=$jobsById[[string]$target.targetId]
        $frozen=$frozenTargetsById[[string]$target.targetId]
        foreach($name in @('MinecraftVersion','Loader','LoaderVersion')){if(-not $job.project.PSObject.Properties[$name]){throw "MATRIX_PROJECT_TARGET_METADATA_MISSING:$($target.targetId):$name"}}
        $candidateVersions=[string[]]@(Get-MmtlLoaderVersionCandidateValues -Candidates $frozen.target.loaderVersionCandidates)
        if([string]$job.project.MinecraftVersion -cne [string]$frozen.target.minecraftId -or [string]$job.project.Loader -cne [string]$frozen.loaderId -or [string]$job.project.LoaderVersion -cnotin $candidateVersions){throw "MATRIX_PROJECT_TARGET_MISMATCH:$($target.targetId)"}
        if(-not $job.target.PSObject.Properties['minecraftId'] -or -not $job.target.PSObject.Properties['loaderStack'] -or -not $job.target.loaderStack.primary -or -not $job.target.PSObject.Properties['loaderVersion']){throw "MATRIX_TARGET_METADATA_MISSING:$($target.targetId)"}
        if([string]$job.target.minecraftId -cne [string]$frozen.target.minecraftId -or [string]$job.target.loaderStack.primary.id -cne [string]$frozen.loaderId -or [string]$job.target.loaderVersion -cnotin $candidateVersions -or [string]$job.target.loaderVersion -cne [string]$job.target.loaderStack.primary.version){throw "MATRIX_TARGET_METADATA_MISMATCH:$($target.targetId)"}
        $identity=ConvertTo-MmtlCompatibilityCacheIdentity -Identity $job.cacheIdentity
        if($identity.targetId -cne [string]$target.targetId -or $identity.universeHash -cne [string]$state.universeHash -or $identity.sourceHash -cne [string]$target.sourceHash -or $identity.toolchainHash -cne [string]$target.toolchainHash -or $identity.targetSpecHash -cne [string]$target.targetSpecHash){throw "MATRIX_JOB_IDENTITY_MISMATCH:$($target.targetId)"}
        if($goalRoot -and [string]$target.targetId -cne ([string]$job.project.Loader+'@'+[string]$job.project.MinecraftVersion)){throw "MATRIX_GOAL_EXACT_TARGET_ID_MISMATCH:$($target.targetId)"}
        $projectsById[[string]$target.targetId]=Resolve-MmtlValidationMatrixJobProject -Job $job
    }
    if($goalRoot){Sync-MmtlValidationMatrixGoalProgress -State $state -Shard $Shard -JobsById $jobsById -RuntimeRoot $RuntimeRoot -GoalRoot $goalRoot}

    $results=[Collections.Generic.List[object]]::new()
    foreach($target in @($state.targets)){
        if($target.status -in @('Passed','Blocked')){continue}
        if([int]$target.attempts -ge [int]$state.maxAttempts){continue}
        $job=$jobsById[[string]$target.targetId]
        $attemptStarted=[DateTimeOffset]::UtcNow
        $attemptWatch=[Diagnostics.Stopwatch]::StartNew()
        $run=$null;$runError=$null
        try{
            $run=Invoke-MmtlValidationMatrixTarget -State $state -TargetId ([string]$target.targetId) -Project $projectsById[[string]$target.targetId] -Target $job.target -RuntimeRoot $RuntimeRoot -GradleHomeRoot $GradleHomeRoot -CacheIdentity $job.cacheIdentity -AllowedOwners $AllowedOwners -BuildJavaHome $BuildJavaHome -TimeoutSeconds $TimeoutSeconds -Clean:$Clean
            $state=$run.runState
        }catch{
            $runError=[string]$_.Exception.Message
            $state=Get-MmtlValidationMatrixRunState -Shard $Shard -RuntimeRoot $RuntimeRoot -MaxAttempts $MaxAttempts -TargetLease $targetLeases
        }
        $attemptWatch.Stop()
        $attemptEnded=[DateTimeOffset]::UtcNow
        $elapsed=[Math]::Max(0,$attemptWatch.Elapsed.TotalSeconds)
        if($goalRoot){
            $resultName=if($runError){'FAIL'}elseif([bool]$run.cached){'CACHED'}else{switch([string]$run.result.result){'PASSED'{'PASS'}'BLOCKED'{'BLOCKED'}default{'FAIL'}}}
            $evidencePaths=@();$evidenceSha256=@()
            $evidencePath=if($run -and $run.result -and $run.result.evidencePath){[string]$run.result.evidencePath}else{$null}
            if($evidencePath -and (Test-Path -LiteralPath $evidencePath -PathType Leaf)){
                $evidenceFull=[IO.Path]::GetFullPath($evidencePath)
                $relativeEvidence=[IO.Path]::GetRelativePath($goalRoot,$evidenceFull)
                if($relativeEvidence -eq '..' -or $relativeEvidence.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relativeEvidence)){throw 'MATRIX_GOAL_EVIDENCE_OUTSIDE_RUN_ROOT'}
                if(([IO.File]::GetAttributes($evidenceFull) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'MATRIX_GOAL_EVIDENCE_REPARSE_FILE'}
                $evidencePaths=@($relativeEvidence.Replace('\','/'))
                $evidenceSha256=@((Get-FileHash -LiteralPath $evidenceFull -Algorithm SHA256).Hash.ToLowerInvariant())
            }
            if($resultName -eq 'PASS' -and $evidencePaths.Count -eq 0){throw 'MATRIX_GOAL_PASS_EVIDENCE_MISSING'}
            $loaderId=[string]$job.project.Loader;$minecraftId=[string]$job.project.MinecraftVersion
            $failure=if($runError){$runError}elseif($run -and $run.result.failureCode -and [string]$run.result.failureCode -ne 'NONE'){[string]$run.result.failureCode}else{$null}
            $event=[pscustomobject][ordered]@{
                eventType='Attempt';attemptId=[guid]::NewGuid().ToString('N');workerId="pid:$PID"
                loaderId=$loaderId;minecraftId=$minecraftId;targetId=($loaderId+'@'+$minecraftId)
                loaderVersion=[string]$job.target.loaderVersion;familyId=[string]$target.familyId
                adapterId=if($job.target.PSObject.Properties['adapterId']){[string]$job.target.adapterId}else{[string]$target.familyId}
                batchId=if($Shard.PSObject.Properties['batchId']){[string]$Shard.batchId}else{('matrix-{0}-shard-{1}-of-{2}' -f [string]$Shard.manifestHash,[int]$Shard.shardIndex,[int]$Shard.shardCount)};batchInputSha256=[string]$Shard.manifestHash
                dimension='BuildExact';status=$resultName;attemptNumber=([int]$target.attempts+1);isFreshExecution=($resultName -ne 'CACHED')
                startedAtUtc=$attemptStarted.ToString('o');endedAtUtc=$attemptEnded.ToString('o');durationSeconds=$elapsed;workerTestSeconds=$elapsed
                cumulativeRepairSeconds=0;failureReason=$failure;evidencePaths=$evidencePaths;evidenceSha256=$evidenceSha256
                universeHash=[string]$Shard.universeHash;sourceHash=[string]$target.sourceHash;toolchainHash=[string]$target.toolchainHash;targetSpecHash=[string]$target.targetSpecHash
                nextAction=if($resultName -eq 'PASS'){'continue-family-batch'}elseif($resultName -eq 'CACHED'){'schedule-fresh-validation'}else{'classify-root-cause-and-retry-within-budget'}
            }
            Write-MmtlGoalAttemptEvent -RunRoot $goalRoot -Event $event | Out-Null
        }
        if($runError){$results.Add([pscustomobject]@{targetId=[string]$target.targetId;result='FAILED';cached=$false;error=$runError})}
        else{$results.Add([pscustomobject]@{targetId=[string]$target.targetId;result=[string]$run.result.result;cached=[bool]$run.cached;error=$null})}
    }
    $state=Get-MmtlValidationMatrixRunState -Shard $Shard -RuntimeRoot $RuntimeRoot -MaxAttempts $MaxAttempts -TargetLease $targetLeases
    $counts=[ordered]@{}
    foreach($status in @('Pending','Running','Passed','Failed','Blocked')){$counts[$status]=@($state.targets|Where-Object status -CEQ $status).Count}
    $overall=if($counts.Pending -gt 0 -or $counts.Running -gt 0){'INCOMPLETE'}elseif($counts.Failed -gt 0 -or $counts.Blocked -gt 0){'PARTIAL'}else{'PASSED'}
    [pscustomobject][ordered]@{schemaVersion=1;status=$overall;universeHash=[string]$Shard.universeHash;manifestHash=[string]$Shard.manifestHash;shardIndex=[int]$Shard.shardIndex;shardCount=[int]$Shard.shardCount;targetCount=[int]$state.targetCount;statusCounts=[pscustomobject]$counts;results=@($results.ToArray());runState=$state}
    }finally{Exit-MmtlValidationMatrixTargetLeases -Lease $targetLeases}
}

Export-ModuleMember -Function Invoke-MmtlValidationMatrixShard,Resolve-MmtlValidationMatrixJobProject
