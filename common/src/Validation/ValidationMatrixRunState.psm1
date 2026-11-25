Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TargetIdentity.psm1') -Force

function Get-MmtlValidationMatrixStatePath {
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][object]$Shard)
    if([string]$Shard.manifestHash -notmatch '^[a-f0-9]{64}$' -or [string]$Shard.universeHash -notmatch '^[a-f0-9]{64}$'){throw 'RUN_STATE_IDENTITY_INVALID:hash'}
    if([int]$Shard.shardIndex -lt 0 -or [int]$Shard.shardCount -lt 1 -or [int]$Shard.shardIndex -ge [int]$Shard.shardCount){throw 'RUN_STATE_IDENTITY_INVALID:shard'}
    $root=[IO.Path]::GetFullPath($RuntimeRoot)
    $directory=Join-Path (Join-Path $root 'validation-matrix') ([string]$Shard.manifestHash)
    [IO.Path]::GetFullPath((Join-Path $directory ('shard-{0}-of-{1}.json' -f [int]$Shard.shardIndex,[int]$Shard.shardCount)))
}

function Enter-MmtlValidationMatrixTargetLeases {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][object]$Shard)
    $targetIds=[string[]]@($Shard.chunks|ForEach-Object{$_.targets}|ForEach-Object{[string]$_.targetId})
    if($targetIds.Count -eq 0 -or @($targetIds|Where-Object{-not(Test-MmtlExactTargetId -TargetId $_)}).Count -gt 0){throw 'RUN_STATE_LEASE_TARGET_SET_INVALID'}
    [Array]::Sort($targetIds,[StringComparer]::Ordinal)
    if(@($targetIds|Select-Object -Unique).Count -ne $targetIds.Count){throw 'RUN_STATE_LEASE_TARGET_SET_INVALID'}
    $root=[IO.Path]::GetFullPath($RuntimeRoot)
    [void][IO.Directory]::CreateDirectory($root)
    if(([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RUN_STATE_LEASE_REPARSE_DIRECTORY'}
    $matrixRoot=Join-Path $root 'validation-matrix';[void][IO.Directory]::CreateDirectory($matrixRoot)
    if(([IO.File]::GetAttributes($matrixRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RUN_STATE_LEASE_REPARSE_DIRECTORY'}
    $leaseRoot=Join-Path $matrixRoot 'target-leases';[void][IO.Directory]::CreateDirectory($leaseRoot)
    if(([IO.File]::GetAttributes($leaseRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RUN_STATE_LEASE_REPARSE_DIRECTORY'}
    $streams=[Collections.Generic.List[IO.FileStream]]::new()
    try{
        foreach($targetId in $targetIds){
            $storageKey=Get-MmtlValidationTargetStorageKey -TargetId $targetId
            $path=Join-Path $leaseRoot ($storageKey+'.lease')
            if((Test-Path -LiteralPath $path) -and (([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'RUN_STATE_LEASE_REPARSE_FILE'}
            try{$stream=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{throw "RUN_STATE_TARGET_ALREADY_ACTIVE:$targetId"}
            $streams.Add($stream)
            $record=[pscustomobject][ordered]@{targetId=$targetId;processId=$PID;universeHash=[string]$Shard.universeHash;manifestHash=[string]$Shard.manifestHash;shardIndex=[int]$Shard.shardIndex;shardCount=[int]$Shard.shardCount;acquiredAt=[DateTimeOffset]::UtcNow.ToString('o')}
            $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $record -Compress))
            $stream.SetLength(0);$stream.Position=0;$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
        }
        [pscustomobject][ordered]@{targetIds=$targetIds;streams=@($streams.ToArray());processId=$PID;runtimeRoot=$root;universeHash=[string]$Shard.universeHash;manifestHash=[string]$Shard.manifestHash;shardIndex=[int]$Shard.shardIndex;shardCount=[int]$Shard.shardCount}
    }catch{
        foreach($stream in $streams){try{$stream.Dispose()}catch{}}
        throw
    }
}

function Exit-MmtlValidationMatrixTargetLeases {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lease)
    foreach($stream in @($Lease.streams)){if($stream){$stream.Dispose()}}
}

function Assert-MmtlValidationMatrixTargetLease {
    param([Parameter(Mandatory)]$Lease,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][object]$Shard)
    $expected=[string[]]@($Shard.chunks|ForEach-Object{$_.targets}|ForEach-Object{[string]$_.targetId});[Array]::Sort($expected,[StringComparer]::Ordinal)
    $actual=[string[]]@($Lease.targetIds);[Array]::Sort($actual,[StringComparer]::Ordinal)
    if([IO.Path]::GetFullPath([string]$Lease.runtimeRoot) -cne [IO.Path]::GetFullPath($RuntimeRoot) -or [string]$Lease.manifestHash -cne [string]$Shard.manifestHash -or [string]$Lease.universeHash -cne [string]$Shard.universeHash -or [int]$Lease.shardIndex -ne [int]$Shard.shardIndex -or [int]$Lease.shardCount -ne [int]$Shard.shardCount -or (ConvertTo-Json -InputObject $actual -Compress) -cne (ConvertTo-Json -InputObject $expected -Compress) -or @($Lease.streams).Count -ne $expected.Count){throw 'RUN_STATE_LEASE_IDENTITY_MISMATCH'}
    foreach($stream in $Lease.streams){if(-not $stream -or -not $stream.CanWrite){throw 'RUN_STATE_LEASE_NOT_ACTIVE'}}
}

function ConvertTo-MmtlValidationMatrixStateTargets {
    param([Parameter(Mandatory)][object]$Shard)
    $targets=[Collections.Generic.List[object]]::new()
    foreach($chunk in @($Shard.chunks)){
        foreach($target in @($chunk.targets)){
            foreach($name in @('targetId','targetSpecHash','sourceHash','toolchainHash')){if(-not $target.PSObject.Properties[$name]){throw "RUN_STATE_TARGET_IDENTITY_MISSING:$name"}}
            if(-not(Test-MmtlExactTargetId -TargetId ([string]$target.targetId)) -or [string]$target.targetSpecHash -notmatch '^[a-f0-9]{64}$' -or [string]$target.sourceHash -notmatch '^[a-f0-9]{64}$' -or [string]$target.toolchainHash -notmatch '^[a-f0-9]{64}$'){throw 'RUN_STATE_TARGET_IDENTITY_INVALID'}
            $targets.Add([pscustomobject][ordered]@{targetId=[string]$target.targetId;targetSpecHash=[string]$target.targetSpecHash;sourceHash=[string]$target.sourceHash;toolchainHash=[string]$target.toolchainHash;loaderId=[string]$chunk.loaderId;familyId=[string]$chunk.familyId;status='Pending';attempts=0;interruptedPreviousAttempt=$false;failureCode=$null;evidencePath=$null;evidenceSha256=$null;cached=$false;startedAt=$null;endedAt=$null})
        }
    }
    $ids=[string[]]@($targets|ForEach-Object targetId);[Array]::Sort($ids,[StringComparer]::Ordinal)
    if(@($ids|Select-Object -Unique).Count -ne $ids.Count -or $ids.Count -ne [int]$Shard.targetCount){throw 'RUN_STATE_TARGET_SET_INVALID'}
    $byId=@{};foreach($target in $targets){$byId[$target.targetId]=$target}
    @($ids|ForEach-Object{$byId[$_]})
}

function Enter-MmtlValidationMatrixStateLock {
    param([Parameter(Mandatory)][string]$StatePath,[ValidateRange(1,120)][int]$TimeoutSeconds=30)
    $directory=Split-Path -Parent $StatePath;[void][IO.Directory]::CreateDirectory($directory)
    if(([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RUN_STATE_REPARSE_DIRECTORY'}
    $lockPath=$StatePath+'.lock';$deadline=[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTimeOffset]::UtcNow -lt $deadline){
        try{return ,([IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))}
        catch [IO.IOException]{Start-Sleep -Milliseconds 50}
    }
    throw 'RUN_STATE_LOCK_TIMEOUT'
}

function Write-MmtlValidationMatrixRunState {
    param([Parameter(Mandatory)][object]$State)
    $path=[string]$State.statePath;$directory=Split-Path -Parent $path
    [void][IO.Directory]::CreateDirectory($directory)
    if((Test-Path -LiteralPath $directory) -and (([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'RUN_STATE_REPARSE_DIRECTORY'}
    $persisted=[ordered]@{}
    foreach($property in $State.PSObject.Properties){if($property.Name -cne 'statePath'){$persisted[$property.Name]=$property.Value}}
    $json=ConvertTo-Json -InputObject ([pscustomobject]$persisted) -Depth 30
    $schema=Join-Path $PSScriptRoot '../../schemas/validation-matrix-run-state.schema.json'
    if(-not(Test-Json -Json $json -SchemaFile $schema -ErrorAction SilentlyContinue)){throw 'RUN_STATE_SCHEMA_INVALID'}
    $temporary=Join-Path $directory ('.state-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{[IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false));if(Test-Path -LiteralPath $path){[IO.File]::Move($temporary,$path,$true)}else{[IO.File]::Move($temporary,$path)}}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}

function New-MmtlValidationMatrixRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Shard,[Parameter(Mandatory)][string]$RuntimeRoot,[ValidateRange(1,10)][int]$MaxAttempts=2,[AllowNull()][object]$TargetLease)
    $expectedTargets=@(ConvertTo-MmtlValidationMatrixStateTargets -Shard $Shard)
    $ownsTargetLease=$false
    if($TargetLease){Assert-MmtlValidationMatrixTargetLease -Lease $TargetLease -RuntimeRoot $RuntimeRoot -Shard $Shard}
    else{$TargetLease=Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $RuntimeRoot -Shard $Shard;$ownsTargetLease=$true}
    try{
    $path=Get-MmtlValidationMatrixStatePath -RuntimeRoot $RuntimeRoot -Shard $Shard
    $lock=Enter-MmtlValidationMatrixStateLock -StatePath $path
    try{
        if(Test-Path -LiteralPath $path -PathType Leaf){
            $savedJson=[IO.File]::ReadAllText($path);$schema=Join-Path $PSScriptRoot '../../schemas/validation-matrix-run-state.schema.json'
            if(-not(Test-Json -Json $savedJson -SchemaFile $schema -ErrorAction SilentlyContinue)){throw 'RUN_STATE_SCHEMA_INVALID'}
            $saved=ConvertFrom-Json -InputObject $savedJson -ErrorAction Stop
            $expectedIdentity=[ordered]@{schemaVersion=1;universeHash=[string]$Shard.universeHash;manifestHash=[string]$Shard.manifestHash;shardIndex=[int]$Shard.shardIndex;shardCount=[int]$Shard.shardCount;targetCount=[int]$Shard.targetCount;maxAttempts=$MaxAttempts}
            foreach($name in $expectedIdentity.Keys){if($saved.PSObject.Properties[$name] -and $saved.$name -cne $expectedIdentity[$name]){throw "RUN_STATE_IDENTITY_MISMATCH:$name"}elseif(-not $saved.PSObject.Properties[$name]){throw "RUN_STATE_IDENTITY_MISMATCH:$name"}}
            $savedIdentity=@($saved.targets|ForEach-Object{[pscustomobject]@{targetId=$_.targetId;targetSpecHash=$_.targetSpecHash;sourceHash=$_.sourceHash;toolchainHash=$_.toolchainHash;loaderId=$_.loaderId;familyId=$_.familyId}})
            $expectedTargetIdentity=@($expectedTargets|ForEach-Object{[pscustomobject]@{targetId=$_.targetId;targetSpecHash=$_.targetSpecHash;sourceHash=$_.sourceHash;toolchainHash=$_.toolchainHash;loaderId=$_.loaderId;familyId=$_.familyId}})
            if((ConvertTo-Json -InputObject $savedIdentity -Depth 10 -Compress) -cne (ConvertTo-Json -InputObject $expectedTargetIdentity -Depth 10 -Compress)){throw 'RUN_STATE_IDENTITY_MISMATCH:targets'}
            $state=[pscustomobject]$saved;$state|Add-Member -NotePropertyName statePath -NotePropertyValue $path
            $changed=$false
            foreach($target in $state.targets){
                if(-not $target.PSObject.Properties['cached']){$target|Add-Member -NotePropertyName cached -NotePropertyValue $false;$changed=$true}
                if($target.status -ceq 'Running'){$target.interruptedPreviousAttempt=$true;$target.endedAt=[DateTimeOffset]::UtcNow.ToString('o');if([int]$target.attempts -ge [int]$state.maxAttempts){$target.status='Blocked';$target.failureCode='RUN_INTERRUPTED_ATTEMPT_LIMIT'}else{$target.status='Pending'};$changed=$true}
            }
            if($changed){$state.revision=[int]$state.revision+1;$state.updatedAt=[DateTimeOffset]::UtcNow.ToString('o');Write-MmtlValidationMatrixRunState -State $state}
            return $state
        }
        $now=[DateTimeOffset]::UtcNow.ToString('o')
        $state=[pscustomobject][ordered]@{schemaVersion=1;universeHash=[string]$Shard.universeHash;manifestHash=[string]$Shard.manifestHash;shardIndex=[int]$Shard.shardIndex;shardCount=[int]$Shard.shardCount;targetCount=[int]$Shard.targetCount;maxAttempts=$MaxAttempts;revision=0;createdAt=$now;updatedAt=$now;targets=$expectedTargets;statePath=$path}
        Write-MmtlValidationMatrixRunState -State $state
        return $state
    }finally{$lock.Dispose()}
    }finally{if($ownsTargetLease){Exit-MmtlValidationMatrixTargetLeases -Lease $TargetLease}}
}

function Get-MmtlValidationMatrixRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Shard,[Parameter(Mandatory)][string]$RuntimeRoot,[ValidateRange(1,10)][int]$MaxAttempts=2,[AllowNull()][object]$TargetLease)
    $path=Get-MmtlValidationMatrixStatePath -RuntimeRoot $RuntimeRoot -Shard $Shard
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'RUN_STATE_NOT_FOUND'}
    New-MmtlValidationMatrixRunState -Shard $Shard -RuntimeRoot $RuntimeRoot -MaxAttempts $MaxAttempts -TargetLease $TargetLease
}

function Set-MmtlValidationMatrixTargetStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$State,[Parameter(Mandatory)][string]$TargetId,[Parameter(Mandatory)][ValidateSet('Running','Passed','Failed','Blocked')][string]$Status,[string]$FailureCode,[string]$EvidencePath,[switch]$Cached)
    $lock=Enter-MmtlValidationMatrixStateLock -StatePath ([string]$State.statePath)
    try{
    $statePath=[string]$State.statePath
    $disk=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($statePath)) -ErrorAction Stop
    if([int]$disk.revision -ne [int]$State.revision){throw 'RUN_STATE_STALE_WRITER'}
    $State=[pscustomobject]$disk;$State|Add-Member -NotePropertyName statePath -NotePropertyValue $statePath
    $target=@($State.targets|Where-Object targetId -CEQ $TargetId)
    if($target.Count -ne 1){throw 'RUN_STATE_TARGET_NOT_FOUND'}
    $item=$target[0]
    $allowed=if($item.status -ceq 'Pending'){@('Running')}elseif($item.status -in @('Failed','Blocked')){@('Running')}elseif($item.status -ceq 'Running'){@('Passed','Failed','Blocked')}else{@()}
    if($Status -notin $allowed){throw "RUN_STATE_TRANSITION_INVALID:$($item.status)->$Status"}
    $now=[DateTimeOffset]::UtcNow.ToString('o')
    if($Status -ceq 'Running'){
        if([int]$item.attempts -ge [int]$State.maxAttempts){throw 'RUN_STATE_ATTEMPT_LIMIT_REACHED'}
        $item.attempts=[int]$item.attempts+1;$item.startedAt=$now;$item.endedAt=$null;$item.failureCode=$null;$item.evidencePath=$null;$item.evidenceSha256=$null;$item.cached=$false;$item.interruptedPreviousAttempt=$false
    }else{$item.endedAt=$now}
    if($Status -ceq 'Passed'){
        if(-not $EvidencePath){throw 'RUN_STATE_PASS_REQUIRES_EVIDENCE'}
        $root=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent ([string]$State.statePath)))
        $full=[IO.Path]::GetFullPath($EvidencePath);$fullRoot=[IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar);$prefix=$fullRoot+[IO.Path]::DirectorySeparatorChar
        $pathComparison=if([IO.Path]::DirectorySeparatorChar -eq [char]92){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        if(-not $full.StartsWith($prefix,$pathComparison) -or -not(Test-Path -LiteralPath $full -PathType Leaf)){throw 'RUN_STATE_EVIDENCE_PATH_INVALID'}
        if(([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RUN_STATE_EVIDENCE_REPARSE_FILE'}
        $ancestor=Split-Path -Parent $full
        while($ancestor.StartsWith($fullRoot,$pathComparison)){
            if(Test-Path -LiteralPath $ancestor){if(([IO.File]::GetAttributes($ancestor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'RUN_STATE_EVIDENCE_REPARSE_PATH'}}
            if($ancestor.Equals($fullRoot,$pathComparison)){break}
            $parent=Split-Path -Parent $ancestor;if(-not $parent -or $parent -ceq $ancestor){break};$ancestor=$parent
        }
        $evidenceJson=[IO.File]::ReadAllText($full);$evidenceSchema=Join-Path $PSScriptRoot '../../schemas/validation-evidence.schema.json'
        if(-not(Test-Json -Json $evidenceJson -SchemaFile $evidenceSchema -ErrorAction SilentlyContinue)){throw 'RUN_STATE_EVIDENCE_SCHEMA_INVALID'}
        $evidence=ConvertFrom-Json -InputObject $evidenceJson -ErrorAction Stop
        if([string]$evidence.targetId -cne $TargetId -or [string]$evidence.result -cne 'PASSED'){throw 'RUN_STATE_EVIDENCE_IDENTITY_INVALID'}
        if(-not $evidence.PSObject.Properties['compatibilityIdentity'] -or [string]$evidence.compatibilityIdentity.targetId -cne $TargetId -or [string]$evidence.compatibilityIdentity.universeHash -cne [string]$State.universeHash -or [string]$evidence.compatibilityIdentity.sourceHash -cne [string]$item.sourceHash -or [string]$evidence.compatibilityIdentity.toolchainHash -cne [string]$item.toolchainHash -or [string]$evidence.compatibilityIdentity.targetSpecHash -cne [string]$item.targetSpecHash){throw 'RUN_STATE_EVIDENCE_IDENTITY_INVALID'}
        $item.evidencePath=[IO.Path]::GetRelativePath($root,$full).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
        $item.evidenceSha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        $item.cached=[bool]$Cached
    }elseif($Status -in @('Failed','Blocked')){if([string]::IsNullOrWhiteSpace($FailureCode)){throw 'RUN_STATE_FAILURE_CODE_REQUIRED'};$item.failureCode=$FailureCode;$item.cached=$false}
    $item.status=$Status;$State.revision=[int]$State.revision+1;$State.updatedAt=$now;Write-MmtlValidationMatrixRunState -State $State;$State
    }finally{$lock.Dispose()}
}

Export-ModuleMember -Function New-MmtlValidationMatrixRunState,Get-MmtlValidationMatrixRunState,Set-MmtlValidationMatrixTargetStatus,Enter-MmtlValidationMatrixTargetLeases,Exit-MmtlValidationMatrixTargetLeases
