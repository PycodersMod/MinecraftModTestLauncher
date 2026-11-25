Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'AgentProvider.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../Scenario/ScenarioOrchestrator.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../SessionLock.psm1') -Force

function Assert-MmtlAgentActionPath {
    param([string]$Session,[string]$Path)
    $root=[IO.Path]::GetFullPath($Session);$full=[IO.Path]::GetFullPath($Path)
    if(-not(Test-MmtlAgentPathInsideRoot -Root $root -Target $full)){throw 'SCENARIO_AGENT_ACTION_PATH_ESCAPE'}
    $current=$root
    if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_AGENT_ACTION_REPARSE_POINT'}
    foreach($part in ($full.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) -split '[\\/]'|Where-Object{$_})){$current=Join-Path $current $part;if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_AGENT_ACTION_REPARSE_POINT'}}}
    return $full
}

function Get-MmtlAgentActionSignature {
    param([Parameter(Mandatory)][string]$Token,[Parameter(Mandatory)][string]$Payload)
    $hmac=[Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Token))
    try{return [Convert]::ToHexString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Payload))).ToLowerInvariant()}finally{$hmac.Dispose()}
}

function Get-MmtlSharedBlockMarkerStateHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{1,80}$')][string]$SessionId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')][string]$MarkerId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$')][string]$DimensionKey,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][ValidateRange(-64,320)][int]$Y,
        [Parameter(Mandatory)][int]$Z
    )
    if($X -lt -64 -or $X -gt 64 -or $Z -lt -64 -or $Z -gt 64){throw 'SCENARIO_SHARED_MARKER_COORDINATES_INVALID'}
    $canonical="mmtl-block-marker-v1|$SessionId|$MarkerId|$DimensionKey|$X|$Y|$Z|minecraft:gold_block"
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
}

function New-MmtlAgentActionRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][ValidateSet('SEND_COMMAND','SCREENSHOT','PLACE_BLOCK_MARKER','OBSERVE_BLOCK_MARKER')][string]$Action,
        [string]$Command,
        [string]$ActorActionId,
        [string]$MarkerId,
        [string]$DimensionKey,
        [int]$X,
        [int]$Y,
        [int]$Z,
        [switch]$PermissionGranted
    )
    $session=[IO.Path]::GetFullPath($SessionPath)
    $status=Get-MmtlScenarioStatus -SessionPath $session
    if($Role -notin @('Host','Guest','Client')){throw 'SCENARIO_AGENT_ACTION_ROLE_INVALID'}
    $registryPath=Assert-MmtlAgentActionPath -Session $session -Path (Join-Path $session 'pids.json')
    if(-not(Test-Path -LiteralPath $registryPath -PathType Leaf)){throw 'SCENARIO_PROCESS_REGISTRY_MISSING'}
    $entries=@(Get-Content -LiteralPath $registryPath -Raw|ConvertFrom-Json -ErrorAction Stop)
    $processRole=if($Role -eq 'Guest' -and [string]$status.plan.mode -eq 'IntegratedLAN'){'Client'}else{$Role}
    $guestNames=@($status.plan.roles|Where-Object role -eq $Role|ForEach-Object username)
    $entry=@($entries|Where-Object{[string]$_.Role -ceq $processRole -and ($Role -ne 'Guest' -or [string]$_.Username -in $guestNames)})|Select-Object -First 1
    if(-not $entry -or [int]$entry.PID -lt 1){throw 'SCENARIO_ACTION_TARGET_NOT_MANAGED'}
    $isSharedMarker=$Action -in @('PLACE_BLOCK_MARKER','OBSERVE_BLOCK_MARKER')
    if($isSharedMarker){
        if(($Action -eq 'PLACE_BLOCK_MARKER' -and $Role -cne 'Host') -or ($Action -eq 'OBSERVE_BLOCK_MARKER' -and $Role -cne 'Guest')){throw 'SCENARIO_SHARED_MARKER_ROLE_INVALID'}
        foreach($coordinate in @('X','Y','Z')){if(-not $PSBoundParameters.ContainsKey($coordinate)){throw 'SCENARIO_SHARED_MARKER_COORDINATES_REQUIRED'}}
    }elseif($Action -eq 'SEND_COMMAND'){$null=Assert-MmtlScenarioAction -Action $Action -Role $Role -Command $Command -TargetManaged -PermissionGranted:$PermissionGranted.IsPresent}
    $tokenPath=Assert-MmtlAgentActionPath -Session $session -Path (Join-Path $session 'agent/session-token.txt')
    if(-not(Test-Path -LiteralPath $tokenPath -PathType Leaf)){throw 'SCENARIO_AGENT_TOKEN_MISSING'}
    $tokenItem=Get-Item -LiteralPath $tokenPath -Force;if($tokenItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_AGENT_ACTION_REPARSE_POINT'}
    $token=[IO.File]::ReadAllText($tokenPath)
    if($token -notmatch '^[A-Za-z0-9._-]{32,128}$'){throw 'SCENARIO_AGENT_TOKEN_INVALID'}
    $id=[guid]::NewGuid().ToString('N');$command64=if($isSharedMarker){''}else{[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Command))};$output=if($Action -eq 'SCREENSHOT'){"screenshots/$Role/$id.png"}else{''}
    if($isSharedMarker){
        $stateHash=Get-MmtlSharedBlockMarkerStateHash -SessionId ([string]$status.sessionId) -MarkerId $MarkerId -DimensionKey $DimensionKey -X $X -Y $Y -Z $Z
        $actorId=if($Action -eq 'PLACE_BLOCK_MARKER'){$id}else{$ActorActionId}
        if([string]$actorId -notmatch '^[a-f0-9]{32}$'){throw 'SCENARIO_SHARED_MARKER_ACTOR_ACTION_INVALID'}
        $signed="$($status.sessionId)|$Role|$id|$Action|||$actorId|$MarkerId|$DimensionKey|$X|$Y|$Z|$stateHash"
        $request=[ordered]@{schemaVersion=1;sessionId=[string]$status.sessionId;role=$Role;actionId=$id;action=$Action;commandBase64='';outputRelativePath='';actorActionId=$actorId;markerId=$MarkerId;dimensionKey=$DimensionKey;x=$X;y=$Y;z=$Z;stateSha256=$stateHash;signature=(Get-MmtlAgentActionSignature -Token $token -Payload $signed)}
    }else{
        $signed="$($status.sessionId)|$Role|$id|$Action|$command64|$output"
        $request=[ordered]@{schemaVersion=1;sessionId=[string]$status.sessionId;role=$Role;actionId=$id;action=$Action;commandBase64=$command64;outputRelativePath=$output;signature=(Get-MmtlAgentActionSignature -Token $token -Payload $signed)}
    }
    $directory=Assert-MmtlAgentActionPath -Session $session -Path (Join-Path $session 'agent-actions')
    if(-not(Test-Path -LiteralPath $directory)){$null=New-Item -ItemType Directory -Path $directory}
    $queue=Assert-MmtlAgentActionPath -Session $session -Path (Join-Path $directory ($Role.ToLowerInvariant()+'.jsonl'))
    $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
    try{[IO.File]::AppendAllText($queue,(($request|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))}finally{Remove-MmtlSessionLock -Lock $lock}
    return [pscustomobject]@{actionId=$id;requestPath=$queue;eventPath=(Join-Path $session ("agent-events/{0}.jsonl" -f $Role.ToLowerInvariant()));sessionId=[string]$status.sessionId;role=$Role}
}

function Wait-MmtlAgentAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[ValidateRange(1,600)][int]$TimeoutSeconds=60)
    $session=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([string]$Request.requestPath));$event=Assert-MmtlAgentActionPath -Session $session -Path ("{0}{1}agent-events{1}{2}.jsonl" -f $session,[IO.Path]::DirectorySeparatorChar,([string]$Request.role).ToLowerInvariant())
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do{
        if(Test-Path -LiteralPath $event -PathType Leaf){foreach($line in [IO.File]::ReadAllLines($event)){
            try{$record=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
            if([string]$record.sessionId -cne [string]$Request.sessionId -or [string]$record.actionId -cne [string]$Request.actionId){continue}
            if([string]$record.eventType -eq 'ACTION_COMPLETED'){return [pscustomobject]@{completed=$true;actionId=$Request.actionId;role=$Request.role}}
            if([string]$record.eventType -eq 'ACTION_FAILED'){throw 'SCENARIO_AGENT_ACTION_FAILED'}
        }}
        Start-Sleep -Milliseconds 200
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'SCENARIO_AGENT_ACTION_TIMEOUT'
}

function Invoke-MmtlAgentAction {
    param([string]$SessionPath,[string]$Role,[string]$Action,[string]$Command,[int]$TimeoutSeconds=60,[switch]$PermissionGranted)
    $request=New-MmtlAgentActionRequest -SessionPath $SessionPath -Role $Role -Action $Action -Command $Command -PermissionGranted:$PermissionGranted.IsPresent
    Wait-MmtlAgentAction -Request $request -TimeoutSeconds $TimeoutSeconds
}

Export-ModuleMember -Function Get-MmtlAgentActionSignature,Get-MmtlSharedBlockMarkerStateHash,New-MmtlAgentActionRequest,Wait-MmtlAgentAction,Invoke-MmtlAgentAction
