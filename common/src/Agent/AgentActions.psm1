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

function New-MmtlAgentActionRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$Role,[Parameter(Mandatory)][ValidateSet('SEND_COMMAND','SCREENSHOT')][string]$Action,[string]$Command,[switch]$PermissionGranted)
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
    if($Action -eq 'SEND_COMMAND'){$null=Assert-MmtlScenarioAction -Action $Action -Role $Role -Command $Command -TargetManaged -PermissionGranted:$PermissionGranted.IsPresent}
    $tokenPath=Assert-MmtlAgentActionPath -Session $session -Path (Join-Path $session 'agent/session-token.txt')
    if(-not(Test-Path -LiteralPath $tokenPath -PathType Leaf)){throw 'SCENARIO_AGENT_TOKEN_MISSING'}
    $tokenItem=Get-Item -LiteralPath $tokenPath -Force;if($tokenItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_AGENT_ACTION_REPARSE_POINT'}
    $token=[IO.File]::ReadAllText($tokenPath)
    if($token -notmatch '^[A-Za-z0-9._-]{32,128}$'){throw 'SCENARIO_AGENT_TOKEN_INVALID'}
    $id=[guid]::NewGuid().ToString('N');$command64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Command));$output=if($Action -eq 'SCREENSHOT'){"screenshots/$Role/$id.png"}else{''}
    $signed="$($status.sessionId)|$Role|$id|$Action|$command64|$output"
    $request=[ordered]@{schemaVersion=1;sessionId=[string]$status.sessionId;role=$Role;actionId=$id;action=$Action;commandBase64=$command64;outputRelativePath=$output;signature=(Get-MmtlAgentActionSignature -Token $token -Payload $signed)}
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

Export-ModuleMember -Function Get-MmtlAgentActionSignature,New-MmtlAgentActionRequest,Wait-MmtlAgentAction,Invoke-MmtlAgentAction
