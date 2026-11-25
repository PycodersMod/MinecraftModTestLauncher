Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TargetIdentity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationMatrixChunks.psm1') -Force

function Test-MmtlMatrixProvisioningProjectRoot {
    param([Parameter(Mandatory)][string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    if(-not(Test-Path -LiteralPath $current -PathType Container)){throw 'MATRIX_PROJECT_PATH_NOT_FOUND'}
    $root=[IO.Path]::GetPathRoot($current)
    $relative=$current.Substring($root.Length)
    $cursor=$root
    foreach($part in @($relative -split '[\\/]+'|Where-Object{$_})){
        $cursor=[IO.Path]::Combine($cursor,$part)
        if(-not(Test-Path -LiteralPath $cursor)){throw 'MATRIX_PROJECT_PATH_NOT_FOUND'}
        if(([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'MATRIX_PROJECT_ROOT_REPARSE'}
    }
    return $current
}

function Get-MmtlValidationMatrixJobsHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest)
    $core=[pscustomobject][ordered]@{
        schemaVersion=[int]$Manifest.schemaVersion
        manifestHash=[string]$Manifest.manifestHash
        jobs=@($Manifest.jobs)
    }
    $payload=ConvertTo-Json -InputObject $core -Depth 40 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload))).ToLowerInvariant()
}

function Test-MmtlValidationMatrixJobsManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Manifest)
    $errors=[Collections.Generic.List[string]]::new()
    foreach($job in @($Manifest.jobs)){
        $scenario=$job.scenario
        if($null -eq $scenario -or [int]$scenario.clientCount -ne 2 -or [string]$scenario.identityKind -cne 'Offline' -or [string]$scenario.transportPolicy -cne 'NativeIntegratedLANOrExplicitHistoricalDedicatedEquivalent'){
            $errors.Add("MATRIX_JOB_SCENARIO_CONTRACT_INVALID:$([string]$job.targetId)")
            continue
        }
        $required=[string[]]@('BuildExactPass','RuntimeBindingPass','ClientLaunchPass','MultiWindowPass','SingleAssertionPass','MultiplayerJoinAndAssertionPass','TargetReportPass','SafeStopPass')
        foreach($dimension in $required){if($dimension -cnotin @($scenario.requiredDimensions|ForEach-Object{[string]$_})){$errors.Add("MATRIX_JOB_SCENARIO_DIMENSION_MISSING:$([string]$job.targetId):$dimension")}}
    }
    if([string]$Manifest.jobsHash -cnotmatch '^[a-f0-9]{64}$' -or [string]$Manifest.jobsHash -cne (Get-MmtlValidationMatrixJobsHash -Manifest $Manifest)){$errors.Add('MATRIX_JOB_SET_HASH_MISMATCH')}
    [pscustomobject][ordered]@{isValid=($errors.Count -eq 0);errors=@($errors.ToArray())}
}

function New-MmtlValidationMatrixJobs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$MatrixManifest,
        [Parameter(Mandatory)][object]$Universe,
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][object]$FamilyManifest,
        [Parameter(Mandatory)][object]$ProvisioningManifest,
        [Parameter(Mandatory)][string]$ProvisioningRoot,
        [object]$FamilyBatchSnapshot,
        [object[]]$BatchRecipes
    )
    if([int]$ProvisioningManifest.schemaVersion -ne 1){throw 'MATRIX_PROVISIONING_SCHEMA_VERSION_INVALID'}
    if([string]$ProvisioningManifest.manifestHash -cne [string]$MatrixManifest.manifestHash){throw 'MATRIX_PROVISIONING_MANIFEST_HASH_MISMATCH'}
    $provisioningJson=ConvertTo-Json -InputObject $ProvisioningManifest -Depth 40
    $provisioningSchema=Join-Path $PSScriptRoot '..\..\schemas\validation-matrix-provisioning-manifest.schema.json'
    if(-not(Test-Json -Json $provisioningJson -SchemaFile $provisioningSchema -ErrorAction SilentlyContinue)){throw 'MATRIX_PROVISIONING_SCHEMA_INVALID'}
    if(-not(Test-Path -LiteralPath $ProvisioningRoot -PathType Container)){throw 'MATRIX_PROVISIONING_ROOT_NOT_FOUND'}
    $provisionRoot=Test-MmtlMatrixProvisioningProjectRoot -Path $ProvisioningRoot

    $manifestCheck=Test-MmtlValidationMatrixChunkManifest -Manifest $MatrixManifest -Ledger $Ledger -Universe $Universe -FamilyManifest $FamilyManifest
    if(-not $manifestCheck.isValid){throw "MATRIX_MANIFEST_INVALID:$($manifestCheck.errors -join ';')"}

    $expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $expectedGroups=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($chunk in @($MatrixManifest.chunks)){
        foreach($target in @($chunk.targets)){
            $id=[string]$target.targetId
            if(-not $expected.TryAdd($id,$target)){throw "MATRIX_MANIFEST_TARGET_DUPLICATE:$id"}
            $expectedGroups[$id]=[pscustomobject]@{loaderId=[string]$chunk.loaderId;familyId=[string]$chunk.familyId}
        }
    }
    $universeById=@{};foreach($target in @($Universe.targets)){$universeById[[string]$target.targetId]=$target}
    $ledgerById=@{};foreach($target in @($Ledger.targets)){$ledgerById[[string]$target.targetId]=$target}

    if($PSBoundParameters.ContainsKey('FamilyBatchSnapshot')){
        if(-not $PSBoundParameters.ContainsKey('BatchRecipes') -or $null -eq $BatchRecipes){throw 'FAMILY_BATCH_CURRENT_RECIPES_REQUIRED'}
        Import-Module (Join-Path $PSScriptRoot 'FamilyBatchPolicy.psm1') -Force
        $batchCheck=Test-MmtlFamilyBatchSnapshot -Snapshot $FamilyBatchSnapshot
        if(-not $batchCheck.isValid){throw "FAMILY_BATCH_SNAPSHOT_REJECTED:$($batchCheck.errors -join ';')"}
        $inputsCheck=Test-MmtlBatchSnapshot -Batch $FamilyBatchSnapshot -CurrentInputs $BatchRecipes
        if(-not $inputsCheck.valid){throw "FAMILY_BATCH_INPUTS_REJECTED:$($inputsCheck.reasonCode)"}
        if([string]$FamilyBatchSnapshot.universeHash -cne [string]$MatrixManifest.universeHash -or [string]$MatrixManifest.universeHash -cne [string]$Universe.catalogHash){throw 'FAMILY_BATCH_UNIVERSE_MISMATCH'}
        $selected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($target in @($FamilyBatchSnapshot.targets)){
            $id=[string]$target.targetId
            if(-not $expected.ContainsKey($id) -or -not $universeById.ContainsKey($id) -or -not $ledgerById.ContainsKey($id)){throw "FAMILY_BATCH_TARGET_NOT_IN_MATRIX:$id"}
            $matrixTarget=$expected[$id];$group=$expectedGroups[$id];$frozen=$universeById[$id];$ledgerTarget=$ledgerById[$id]
            if([string]$group.loaderId -cne [string]$FamilyBatchSnapshot.loaderId -or [string]$group.familyId -cne [string]$FamilyBatchSnapshot.familyId -or [string]$frozen.loaderId -cne [string]$target.loaderId -or [string]$frozen.minecraftId -cne [string]$target.minecraftId){throw "FAMILY_BATCH_TARGET_SCOPE_MISMATCH:$id"}
            if([string]$matrixTarget.sourceHash -cne [string]$target.sourceHash -or [string]$frozen.sourceHash -cne [string]$target.sourceHash -or [string]$ledgerTarget.sourceHash -cne [string]$target.sourceHash -or [string]$ledgerTarget.toolchainHash -cne [string]$target.toolchainHash -or [string]$ledgerTarget.targetSpecHash -cne [string]$target.targetSpecHash){throw "FAMILY_BATCH_TARGET_IDENTITY_MISMATCH:$id"}
            $candidateVersions=[string[]]@(Get-MmtlLoaderVersionCandidateValues -Candidates $frozen.loaderVersionCandidates)
            if([string]$target.loaderVersion -cnotin $candidateVersions){throw "FAMILY_BATCH_LOADER_VERSION_UNPINNED:$id"}
            $selected.Add($id,$matrixTarget)
        }
        $expected=$selected
    }

    $provisioningById=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach($entry in @($ProvisioningManifest.entries)){
        $id=[string]$entry.targetId
        if([string]::IsNullOrWhiteSpace($id)){throw 'MATRIX_PROVISIONING_TARGET_ID_REQUIRED'}
        if(-not $provisioningById.TryAdd($id,$entry)){throw "MATRIX_PROVISIONING_DUPLICATE:$id"}
        if(-not $expected.ContainsKey($id)){throw "MATRIX_PROVISIONING_TARGET_UNEXPECTED:$id"}
    }
    foreach($id in $expected.Keys){if(-not $provisioningById.ContainsKey($id)){throw "MATRIX_PROVISIONING_SET_INCOMPLETE:$id"}}
    if($provisioningById.Count -ne $expected.Count){throw 'MATRIX_PROVISIONING_SET_INCOMPLETE'}

    $jobs=[Collections.Generic.List[object]]::new();$projectPathCache=@{}
    [string[]]$orderedTargetIds=@($expected.Keys);[Array]::Sort($orderedTargetIds,[StringComparer]::Ordinal)
    foreach($id in $orderedTargetIds){
        $frozen=$universeById[$id];$ledgerTarget=$ledgerById[$id];$entry=$provisioningById[$id]
        if([string]$frozen.availability -cne 'Available'){throw "MATRIX_PROVISIONING_TARGET_UNAVAILABLE:$id"}
        $version=[string]$entry.loaderVersion
        $candidateVersions=[string[]]@(Get-MmtlLoaderVersionCandidateValues -Candidates $frozen.loaderVersionCandidates)
        if($version -cnotin $candidateVersions){throw "MATRIX_PROVISIONING_LOADER_VERSION_UNPINNED:$id"}
        $task=[string]$entry.task
        $allowedTasks=[string[]]@($entry.sourceFixture.allowedTasks|ForEach-Object{[string]$_})
        if([string]::IsNullOrWhiteSpace($task) -or $task -cnotin $allowedTasks){throw "MATRIX_PROVISIONING_TASK_NOT_ALLOWED:$id"}
        $projectPath=[string]$entry.projectPath
        if(-not $projectPathCache.ContainsKey($projectPath)){
            $resolvedProjectPath=$projectPath
            if(-not [IO.Path]::IsPathRooted($resolvedProjectPath)){$resolvedProjectPath=Join-Path $provisionRoot $resolvedProjectPath}
            $projectPathCache[$projectPath]=Test-MmtlMatrixProvisioningProjectRoot -Path $resolvedProjectPath
        }
        $projectPath=[string]$projectPathCache[$projectPath]
        $project=[ordered]@{minecraftVersion=[string]$frozen.minecraftId;loader=[string]$frozen.loaderId;loaderVersion=$version;wrapper=[string]$entry.wrapper}
        foreach($name in @('javaMajor','toolchain','toolchainVersion','buildSystem','buildSystemVersion')){
            if($entry.PSObject.Properties[$name]){$project[$name]=$entry.$name}
        }
        $agentHash=$null
        if($entry.PSObject.Properties['agentHash'] -and $null -ne $entry.agentHash){
            $agentHash=[string]$entry.agentHash
            if($agentHash -cnotmatch '^[a-f0-9]{64}$'){throw "MATRIX_PROVISIONING_AGENT_HASH_INVALID:$id"}
        }
        $target=[ordered]@{
            targetId=$id
            minecraftId=[string]$frozen.minecraftId
            loaderVersion=$version
            loaderStack=[ordered]@{primary=[ordered]@{id=[string]$frozen.loaderId;version=$version}}
            sourceFixture=$entry.sourceFixture
            task=$task
        }
        $cache=[ordered]@{
            targetId=$id
            universeHash=[string]$MatrixManifest.universeHash
            sourceHash=[string]$ledgerTarget.sourceHash
            toolchainHash=[string]$ledgerTarget.toolchainHash
            targetSpecHash=[string]$ledgerTarget.targetSpecHash
            agentHash=$agentHash
        }
        $scenario=[pscustomobject][ordered]@{
            clientCount=2
            identityKind='Offline'
            transportPolicy='NativeIntegratedLANOrExplicitHistoricalDedicatedEquivalent'
            requiredDimensions=@('BuildExactPass','RuntimeBindingPass','ClientLaunchPass','MultiWindowPass','SingleAssertionPass','MultiplayerJoinAndAssertionPass','TargetReportPass','SafeStopPass')
        }
        $jobs.Add([pscustomobject][ordered]@{targetId=$id;projectPath=$projectPath;project=[pscustomobject]$project;target=[pscustomobject]$target;cacheIdentity=[pscustomobject]$cache;scenario=$scenario})
    }
    $result=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=[string]$MatrixManifest.manifestHash;jobs=@($jobs.ToArray());jobsHash=$null}
    $result.jobsHash=Get-MmtlValidationMatrixJobsHash -Manifest $result
    return $result
}

Export-ModuleMember -Function New-MmtlValidationMatrixJobs,Get-MmtlValidationMatrixJobsHash,Test-MmtlValidationMatrixJobsManifest
