Set-StrictMode -Version Latest

function Get-MmtlFamilyBatchHash {
    param([Parameter(Mandatory)]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 20 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function New-MmtlFamilyBatchSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Recipes,
        [Parameter(Mandatory)][ValidateRange(0,100000)][int]$BatchOrdinal,
        [ValidateRange(1,40)][int]$MaxBatchSize = 40,
        [DateTimeOffset]$CreatedAtUtc = [DateTimeOffset]::UtcNow
    )
    if ($Recipes.Count -eq 0) { throw 'BATCH_EMPTY' }
    if ($Recipes.Count -gt $MaxBatchSize) { throw "BATCH_SIZE_LIMIT:$MaxBatchSize" }
    $first = $Recipes[0]
    $loaderId = [string]$first.loaderId
    $familyId = [string]$first.familyId
    $universeHash = [string]$first.universeHash
    $familyRuleSha256=[string]$first.familyRuleSha256
    $adapterSha256=[string]$first.adapterSha256
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($recipe in $Recipes) {
        if ([string]$recipe.status -cne 'RecipeReady') { throw "BATCH_RECIPE_NOT_READY:$([string]$recipe.targetId)" }
        if ([string]$recipe.loaderId -cne $loaderId -or [string]$recipe.familyId -cne $familyId) { throw 'BATCH_FAMILY_MISMATCH' }
        if ([string]$recipe.universeHash -cne $universeHash) { throw 'BATCH_UNIVERSE_MISMATCH' }
        if ([string]$recipe.familyRuleSha256 -cne $familyRuleSha256 -or [string]$recipe.adapterSha256 -cne $adapterSha256) { throw 'BATCH_FAMILY_INPUT_HASH_MISMATCH' }
        $targetId = [string]$recipe.targetId
        if (-not $seen.Add($targetId)) { throw "BATCH_TARGET_DUPLICATE:$targetId" }
        foreach ($field in @('sourceHash','toolchainHash','targetSpecHash','recipeSha256')) {
            if ([string]$recipe.$field -notmatch '^[a-f0-9]{64}$') { throw "BATCH_RECIPE_HASH_INVALID:${targetId}:$field" }
        }
        foreach ($field in @('familyRuleSha256','adapterSha256')) { if ([string]$recipe.$field -notmatch '^[a-f0-9]{64}$') { throw "BATCH_RECIPE_HASH_INVALID:${targetId}:$field" } }
        $buildToolId=if($recipe.build -is [Collections.IDictionary] -and $recipe.build.Contains('buildToolId')){[string]$recipe.build['buildToolId']}elseif($recipe.build.PSObject.Properties['buildToolId']){[string]$recipe.build.buildToolId}else{'Loom'}
        $buildToolVersion=if($recipe.build -is [Collections.IDictionary] -and $recipe.build.Contains('buildToolVersion')){[string]$recipe.build['buildToolVersion']}elseif($recipe.build.PSObject.Properties['buildToolVersion']){[string]$recipe.build.buildToolVersion}else{[string]$recipe.build.loomVersion}
        $targets.Add([pscustomobject][ordered]@{
            targetId=$targetId; minecraftId=[string]$recipe.minecraftId; familyId=$familyId; loaderId=$loaderId; familyRuleSha256=$familyRuleSha256; adapterSha256=$adapterSha256
            universeHash=$universeHash; sourceHash=[string]$recipe.sourceHash; toolchainHash=[string]$recipe.toolchainHash
            targetSpecHash=[string]$recipe.targetSpecHash; loaderVersion=[string]$recipe.build.loaderVersion
            buildToolId=$buildToolId; buildToolVersion=$buildToolVersion
            buildJavaMajor=[int]$recipe.build.buildJavaMajor; runtimeJavaMajor=[int]$recipe.build.runtimeJavaMajor; gradleVersion=[string]$recipe.build.gradleVersion; loomVersion=[string]$recipe.build.loomVersion; recipeSha256=[string]$recipe.recipeSha256
        })
    }
    $orderedTargets = @($targets.ToArray() | Sort-Object targetId -CaseSensitive)
    $smokeTargetIds = @($orderedTargets | Select-Object -First ([Math]::Min(5,$orderedTargets.Count)) | ForEach-Object targetId)
    if ($orderedTargets.Count -gt 5) { $smokeTargetIds += [string]$orderedTargets[-1].targetId }
    $core = [pscustomobject][ordered]@{
        schemaVersion=1; loaderId=$loaderId; familyId=$familyId; familyRuleSha256=$familyRuleSha256; adapterSha256=$adapterSha256; universeHash=$universeHash
        batchOrdinal=$BatchOrdinal; targetCount=$orderedTargets.Count; targets=$orderedTargets; smokeTargetIds=$smokeTargetIds
    }
    $hash = Get-MmtlFamilyBatchHash -Value $core
    [pscustomobject][ordered]@{
        schemaVersion=1; batchId="familybatch-$hash"; batchInputSha256=$hash; loaderId=$loaderId; familyId=$familyId; familyRuleSha256=$familyRuleSha256; adapterSha256=$adapterSha256
        universeHash=$universeHash; batchOrdinal=$BatchOrdinal; targetCount=$orderedTargets.Count; targets=$orderedTargets
        smokeTargetIds=$smokeTargetIds; createdAtUtc=$CreatedAtUtc.ToUniversalTime().ToString('o')
    }
}

function Test-MmtlFamilyBatchSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    $errors = [Collections.Generic.List[string]]::new()
    try {
        if ([int]$Snapshot.schemaVersion -ne 1) { throw 'BATCH_SCHEMA_UNSUPPORTED' }
        if ([int]$Snapshot.targetCount -ne @($Snapshot.targets).Count -or [int]$Snapshot.targetCount -lt 1 -or [int]$Snapshot.targetCount -gt 40) { throw 'BATCH_TARGET_COUNT_INVALID' }
        $core = [pscustomobject][ordered]@{
            schemaVersion=1; loaderId=[string]$Snapshot.loaderId; familyId=[string]$Snapshot.familyId; familyRuleSha256=[string]$Snapshot.familyRuleSha256; adapterSha256=[string]$Snapshot.adapterSha256; universeHash=[string]$Snapshot.universeHash
            batchOrdinal=[int]$Snapshot.batchOrdinal; targetCount=[int]$Snapshot.targetCount
            targets=@($Snapshot.targets | Sort-Object targetId -CaseSensitive); smokeTargetIds=@($Snapshot.smokeTargetIds)
        }
        $hash = Get-MmtlFamilyBatchHash -Value $core
        if ($hash -cne [string]$Snapshot.batchInputSha256 -or "familybatch-$hash" -cne [string]$Snapshot.batchId) { $errors.Add('BATCH_SNAPSHOT_HASH_MISMATCH') }
        if (@($Snapshot.targets.targetId | Select-Object -Unique).Count -ne @($Snapshot.targets).Count) { $errors.Add('BATCH_TARGET_DUPLICATE') }
    } catch { $errors.Add([string]$_.Exception.Message) }
    [pscustomobject][ordered]@{ isValid=($errors.Count -eq 0); errors=@($errors.ToArray()) }
}

function New-MmtlFamilyBatches {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Recipes,[ValidateRange(1,40)][int]$MaxBatchSize=30)
    if ($Recipes.Count -eq 0) { throw 'BATCH_INVENTORY_EMPTY' }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $universeHash=[string]$Recipes[0].universeHash
    $ready=[Collections.Generic.List[object]]::new();$deferred=[Collections.Generic.List[object]]::new()
    foreach($recipe in $Recipes){
        $id=[string]$recipe.targetId
        if([string]::IsNullOrWhiteSpace($id) -or -not $seen.Add($id)){throw "BATCH_INVENTORY_DUPLICATE_OR_EMPTY_TARGET:$id"}
        if([string]$recipe.universeHash -cne $universeHash){throw "BATCH_INVENTORY_UNIVERSE_MISMATCH:$id"}
        if([string]$recipe.status -ceq 'RecipeReady'){$ready.Add($recipe)}
        else{$deferred.Add([pscustomobject][ordered]@{targetId=$id;loaderId=[string]$recipe.loaderId;minecraftId=[string]$recipe.minecraftId;familyId=[string]$recipe.familyId;status=[string]$recipe.status;reasonCode=if($recipe.PSObject.Properties['reasonCode']){[string]$recipe.reasonCode}else{[string]$recipe.status}})}
    }
    $groups=@{}
    foreach($recipe in $ready){$key="$( [string]$recipe.loaderId )`0$( [string]$recipe.familyId )";if(-not $groups.ContainsKey($key)){$groups[$key]=[Collections.Generic.List[object]]::new()};$groups[$key].Add($recipe)}
    $batches=[Collections.Generic.List[object]]::new();$keys=[string[]]@($groups.Keys);[Array]::Sort($keys,[StringComparer]::Ordinal)
    foreach($key in $keys){$sep=$key.IndexOf([char]0);$group=@($groups[$key].ToArray()|Sort-Object targetId -CaseSensitive);for($offset=0;$offset -lt $group.Count;$offset+=$MaxBatchSize){$end=[Math]::Min($offset+$MaxBatchSize,$group.Count);$part=@($group[$offset..($end-1)]);$ordinal=[int]($offset/$MaxBatchSize);$batches.Add((New-MmtlFamilyBatchSnapshot -Recipes $part -BatchOrdinal $ordinal -MaxBatchSize $MaxBatchSize))}}
    $coverage=@($Recipes|Sort-Object targetId -CaseSensitive|ForEach-Object{[pscustomobject][ordered]@{targetId=[string]$_.targetId;status=[string]$_.status;recipeSha256=if($_.PSObject.Properties['recipeSha256']){[string]$_.recipeSha256}else{$null}}})
    [pscustomobject][ordered]@{schemaVersion=1;universeHash=$universeHash;targetCount=$Recipes.Count;readyTargetCount=$ready.Count;pendingTargetCount=$deferred.Count;batchCount=$batches.Count;batches=@($batches.ToArray());deferredTargets=@($deferred.ToArray());coverageSha256=(Get-MmtlFamilyBatchHash -Value $coverage)}
}

function Test-MmtlBatchSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Batch,[Parameter(Mandatory)][object[]]$CurrentInputs)
    $base=Test-MmtlFamilyBatchSnapshot -Snapshot $Batch
    if(-not $base.isValid){return [pscustomobject]@{valid=$false;reasonCode=[string]$base.errors[0]}}
    $byId=@{};foreach($recipe in $CurrentInputs){$id=[string]$recipe.targetId;if($byId.ContainsKey($id)){return [pscustomobject]@{valid=$false;reasonCode='BATCH_CURRENT_INPUT_DUPLICATE'}};$byId[$id]=$recipe}
    $subset=[Collections.Generic.List[object]]::new()
    foreach($target in $Batch.targets){$id=[string]$target.targetId;if(-not $byId.ContainsKey($id)){return [pscustomobject]@{valid=$false;reasonCode='BATCH_CURRENT_INPUT_MISSING'}};$subset.Add($byId[$id])}
    try{$current=New-MmtlFamilyBatchSnapshot -Recipes @($subset.ToArray()) -BatchOrdinal ([int]$Batch.batchOrdinal) -MaxBatchSize ([Math]::Max(1,[int]$Batch.targetCount))}catch{return [pscustomobject]@{valid=$false;reasonCode='BATCH_INPUTS_CHANGED'}}
    if([string]$current.batchInputSha256 -cne [string]$Batch.batchInputSha256){return [pscustomobject]@{valid=$false;reasonCode='BATCH_INPUTS_CHANGED'}}
    [pscustomobject]@{valid=$true;reasonCode='BATCH_INPUTS_MATCH'}
}

function Get-MmtlFamilyBatchNextTargets {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Batch,[object[]]$ExistingAttempts=@(),[object[]]$ActiveAssignments=@(),[ValidateRange(0,10)][int]$MaxRetries=2,[int]$MaxTargets=0,[DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow)
    $passed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$failures=@{}
    foreach($attempt in $ExistingAttempts){if([string]$attempt.dimension -cne 'BuildExact' -or -not [bool]$attempt.isFreshExecution){continue};$id=[string]$attempt.targetId;if([string]$attempt.status -ceq 'PASS'){[void]$passed.Add($id)}elseif([string]$attempt.status -in @('FAIL','TIMEOUT','BLOCKED')){$failures[$id]=[int]$failures[$id]+1}}
    $active=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($assignment in $ActiveAssignments){if([string]$assignment.status -ceq 'Running' -and [DateTimeOffset]$assignment.leaseExpiresAtUtc -gt $NowUtc){[void]$active.Add([string]$assignment.targetId)}}
    $next=[Collections.Generic.List[string]]::new()
    foreach($target in @($Batch.targets|Sort-Object targetId -CaseSensitive)){$id=[string]$target.targetId;if($passed.Contains($id)-or $active.Contains($id)-or ([int]$failures[$id] -ge (1+$MaxRetries))){continue};$next.Add($id);if($MaxTargets -gt 0 -and $next.Count -ge $MaxTargets){break}}
    @($next.ToArray())
}

function Set-MmtlFamilyBatchAssignments {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Batch,[Parameter(Mandatory)][string]$AssignmentPath,[Parameter(Mandatory)][string]$WorkerId,[ValidateRange(1,40)][int]$MaxTargets=1,[ValidateRange(1,1440)][int]$LeaseMinutes=30,[object[]]$ExistingAttempts=@(),[DateTimeOffset]$NowUtc=[DateTimeOffset]::UtcNow)
    if(-not (Test-MmtlFamilyBatchSnapshot -Snapshot $Batch).isValid){throw 'BATCH_ASSIGNMENT_SNAPSHOT_INVALID'}
    $path=[IO.Path]::GetFullPath($AssignmentPath);$parent=[IO.Path]::GetDirectoryName($path);[void][IO.Directory]::CreateDirectory($parent);$lockPath="$path.lock";$lock=$null
    for($i=0;$i -lt 50 -and -not $lock;$i++){try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{Start-Sleep -Milliseconds 50}}
    if(-not $lock){throw 'BATCH_ASSIGNMENT_LOCK_BUSY'}
    try{
        if(Test-Path -LiteralPath $path -PathType Leaf){$registry=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -ErrorAction Stop;if([string]$registry.batchInputSha256 -cne [string]$Batch.batchInputSha256){throw 'BATCH_ASSIGNMENT_IDENTITY_MISMATCH'};$assignments=[Collections.Generic.List[object]]::new();foreach($item in @($registry.assignments)){$assignments.Add($item)}}else{$assignments=[Collections.Generic.List[object]]::new()}
        for($i=0;$i -lt $assignments.Count;$i++){if([string]$assignments[$i].status -ceq 'Running' -and [DateTimeOffset]$assignments[$i].leaseExpiresAtUtc -le $NowUtc){$assignments[$i].status='Expired';$assignments[$i]|Add-Member -NotePropertyName endedAtUtc -NotePropertyValue $NowUtc.ToUniversalTime().ToString('o') -Force}}
        $chosen=@(Get-MmtlFamilyBatchNextTargets -Batch $Batch -ExistingAttempts $ExistingAttempts -ActiveAssignments @($assignments.ToArray()) -MaxTargets $MaxTargets -NowUtc $NowUtc)
        foreach($id in $chosen){$assignments.Add([pscustomobject][ordered]@{targetId=$id;workerId=$WorkerId;status='Running';startedAtUtc=$NowUtc.ToUniversalTime().ToString('o');leaseExpiresAtUtc=$NowUtc.AddMinutes($LeaseMinutes).ToUniversalTime().ToString('o')})}
        $registryOut=[pscustomobject][ordered]@{schemaVersion=1;batchId=[string]$Batch.batchId;batchInputSha256=[string]$Batch.batchInputSha256;assignments=@($assignments.ToArray());updatedAtUtc=$NowUtc.ToUniversalTime().ToString('o')}
        $temp="$path.$([Guid]::NewGuid().ToString('N')).tmp";$bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $registryOut -Depth 20));$stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()};if(Test-Path -LiteralPath $path){[IO.File]::Move($temp,$path,$true)}else{[IO.File]::Move($temp,$path)}
        [pscustomobject][ordered]@{workerId=$WorkerId;batchId=[string]$Batch.batchId;targetIds=$chosen;assignmentPath=$path;status=if($chosen.Count){'Reserved'}else{'NoWorkAvailable'}}
    }finally{$lock.Dispose()}
}

Export-ModuleMember -Function New-MmtlFamilyBatchSnapshot,Test-MmtlFamilyBatchSnapshot,New-MmtlFamilyBatches,Test-MmtlBatchSnapshot,Get-MmtlFamilyBatchNextTargets,Set-MmtlFamilyBatchAssignments
