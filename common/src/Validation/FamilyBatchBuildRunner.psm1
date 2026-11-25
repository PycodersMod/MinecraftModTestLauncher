Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'FamilyBatchPolicy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationMatrixShardRunner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'FailureClustering.psm1') -Force

function Get-MmtlFamilyBatchFixtureHash {
    param([Parameter(Mandatory)]$Fixture)
    $json=ConvertTo-Json -InputObject $Fixture -Depth 30 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Invoke-MmtlFamilyBatchBuild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Batch,
        [Parameter(Mandatory)][object[]]$CurrentInputs,
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)][object[]]$Jobs,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [ValidateRange(1,1)][int]$MaxBuildWorkers=1,
        [ValidateRange(1,10)][int]$MaxAttempts=3,
        [AllowEmptyCollection()][string[]]$AllowedOwners=@(),
        [string]$BuildJavaHome,
        [string]$GradleHomeRoot,
        [ValidateRange(1,7200)][int]$TimeoutSeconds=1800,
        [string]$GoalProgressRunRoot,
        [switch]$Clean
    )

    $snapshot=Test-MmtlBatchSnapshot -Batch $Batch -CurrentInputs $CurrentInputs
    if(-not $snapshot.valid){throw "FAMILY_BATCH_SNAPSHOT_REJECTED:$($snapshot.reasonCode)"}
    if([string]$Universe.catalogHash -cne [string]$Batch.universeHash){throw 'FAMILY_BATCH_UNIVERSE_MISMATCH'}

    $recipesById=@{};foreach($recipe in $CurrentInputs){$id=[string]$recipe.targetId;if($recipesById.ContainsKey($id)){throw "FAMILY_BATCH_RECIPE_DUPLICATE:$id"};$recipesById[$id]=$recipe}
    $universeById=@{};foreach($target in $Universe.targets){$id=[string]$target.targetId;if($universeById.ContainsKey($id)){throw "FAMILY_BATCH_UNIVERSE_DUPLICATE:$id"};$universeById[$id]=$target}
    $jobsById=@{};foreach($job in $Jobs){$id=[string]$job.targetId;if([string]::IsNullOrWhiteSpace($id) -or $jobsById.ContainsKey($id)){throw "FAMILY_BATCH_JOB_DUPLICATE_OR_EMPTY:$id"};$jobsById[$id]=$job}

    $targets=[Collections.Generic.List[object]]::new();$selectedJobs=[Collections.Generic.List[object]]::new()
    foreach($frozen in $Batch.targets){
        $id=[string]$frozen.targetId
        if(-not $recipesById.ContainsKey($id) -or -not $universeById.ContainsKey($id) -or -not $jobsById.ContainsKey($id)){throw "FAMILY_BATCH_INPUT_MISSING:$id"}
        $recipe=$recipesById[$id];$universeTarget=$universeById[$id];$job=$jobsById[$id]
        if([string]$universeTarget.availability -cne 'Available' -or [string]$universeTarget.loaderId -cne [string]$Batch.loaderId -or [string]$universeTarget.minecraftId -cne [string]$frozen.minecraftId){throw "FAMILY_BATCH_UNIVERSE_TARGET_MISMATCH:$id"}
        if([string]$universeTarget.sourceHash -cne [string]$frozen.sourceHash -or [string]$universeTarget.sourceHash -cne [string]$recipe.sourceHash){throw "FAMILY_BATCH_SOURCE_IDENTITY_MISMATCH:$id"}
        if([string]$job.project.Loader -cne [string]$Batch.loaderId -or [string]$job.project.MinecraftVersion -cne [string]$frozen.minecraftId -or [string]$job.project.LoaderVersion -cne [string]$frozen.loaderVersion){throw "FAMILY_BATCH_PROJECT_TARGET_MISMATCH:$id"}
        if([int]$job.project.JavaMajor -ne [int]$frozen.buildJavaMajor){throw "FAMILY_BATCH_BUILD_JAVA_MISMATCH:$id"}
        if([string]$job.target.targetId -cne $id -or [string]$job.target.minecraftId -cne [string]$frozen.minecraftId -or [string]$job.target.loaderVersion -cne [string]$frozen.loaderVersion -or [string]$job.target.loaderStack.primary.id -cne [string]$Batch.loaderId -or [string]$job.target.loaderStack.primary.version -cne [string]$frozen.loaderVersion){throw "FAMILY_BATCH_TARGET_PAYLOAD_MISMATCH:$id"}
        if($recipe.PSObject.Properties['sourceFixture']){
            if(-not $job.target.PSObject.Properties['sourceFixture'] -or -not $job.target.sourceFixture){throw "FAMILY_BATCH_SOURCE_FIXTURE_MISSING:$id"}
            if((Get-MmtlFamilyBatchFixtureHash -Fixture $recipe.sourceFixture) -cne (Get-MmtlFamilyBatchFixtureHash -Fixture $job.target.sourceFixture)){throw "FAMILY_BATCH_SOURCE_FIXTURE_MISMATCH:$id"}
        }
        foreach($field in @('universeHash','sourceHash','toolchainHash','targetSpecHash')){if([string]$job.cacheIdentity.$field -cne [string]$frozen.$field){throw "BATCH_JOB_IDENTITY_MISMATCH:$id"}}
        if([string]$job.cacheIdentity.targetId -cne $id){throw "BATCH_JOB_IDENTITY_MISMATCH:$id"}
        $targetCopy=$universeTarget.PSObject.Copy()
        foreach($field in @('sourceHash','toolchainHash','targetSpecHash')){$targetCopy|Add-Member -NotePropertyName $field -NotePropertyValue ([string]$frozen.$field) -Force}
        $targets.Add($targetCopy);$selectedJobs.Add($job)
    }
    if($selectedJobs.Count -ne [int]$Batch.targetCount){throw 'FAMILY_BATCH_JOB_SET_INCOMPLETE'}

    $chunk=[pscustomobject][ordered]@{loaderId=[string]$Batch.loaderId;familyId=[string]$Batch.familyId;targetCount=$targets.Count;targets=@($targets.ToArray())}
    $shard=[pscustomobject][ordered]@{schemaVersion=1;universeHash=[string]$Batch.universeHash;manifestHash=[string]$Batch.batchInputSha256;batchId=[string]$Batch.batchId;shardIndex=0;shardCount=1;targetCount=$targets.Count;chunkCount=1;chunks=@($chunk)}
    $run=Invoke-MmtlValidationMatrixShard -Shard $shard -Jobs @($selectedJobs.ToArray()) -RuntimeRoot $RuntimeRoot -MaxAttempts $MaxAttempts -AllowedOwners $AllowedOwners -BuildJavaHome $BuildJavaHome -GradleHomeRoot $GradleHomeRoot -TimeoutSeconds $TimeoutSeconds -GoalProgressRunRoot $GoalProgressRunRoot -Clean:$Clean
    $failedAttempts=[Collections.Generic.List[object]]::new()
    foreach($targetState in @($run.runState.targets|Where-Object status -in @('Failed','Blocked'))){$failedAttempts.Add([pscustomobject]@{targetId=[string]$targetState.targetId;attemptId=[string]$Batch.batchId+'-'+[string]$targetState.attempts;loaderId=[string]$Batch.loaderId;familyId=[string]$Batch.familyId;adapterId=([string]$Batch.loaderId+':'+([string]$Batch.adapterSha256).Substring(0,12));reasonCode=if($targetState.failureCode){[string]$targetState.failureCode}else{'UNKNOWN_REASON'}})}
    $failureClusters=Group-MmtlFailureAttempts -Attempts @($failedAttempts.ToArray())
    [pscustomobject][ordered]@{batchId=[string]$Batch.batchId;batchInputSha256=[string]$Batch.batchInputSha256;universeHash=[string]$Batch.universeHash;targetIds=@($Batch.targets.targetId);maxBuildWorkers=$MaxBuildWorkers;maxAttempts=$MaxAttempts;status=[string]$run.status;results=@($run.results);failureClusters=@($failureClusters);runStatePath=[string]$run.runState.statePath}
}

Export-ModuleMember -Function Invoke-MmtlFamilyBatchBuild
