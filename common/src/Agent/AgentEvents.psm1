Set-StrictMode -Version Latest

$script:RuntimeEventModule=Import-Module (Join-Path $PSScriptRoot '../Observation/RuntimeEvents.psm1') -PassThru
$script:AgentProviderModule=Import-Module (Join-Path $PSScriptRoot 'AgentProvider.psm1') -PassThru
$script:ProcessManagerModule=Import-Module (Join-Path $PSScriptRoot '../ProcessManager.psm1') -PassThru
$script:AgentEventMap=@{
    AGENT_STARTED='AGENT_STARTED'
    CLIENT_READY='AGENT_CLIENT_READY'
    WORLD_JOINED='AGENT_WORLD_JOINED'
    INTEGRATED_SERVER_READY='INTEGRATED_SERVER_READY'
    OFFLINE_AUTH_ENABLED='OFFLINE_AUTH_ENABLED'
    LAN_PUBLISH_REQUESTED='LAN_PUBLISH_REQUESTED'
    LAN_PUBLISHED='LAN_PORT_PUBLISHED'
    LAN_PUBLISH_FAILED='LAN_PUBLISH_FAILED'
    GUEST_CONNECTING='GUEST_CONNECTING'
    GUEST_CONNECTED='AGENT_GUEST_CONNECTED'
    WORLD_CREATE_REQUESTED='WORLD_CREATE_REQUESTED'
    WORLD_CREATE_SUBMITTED='WORLD_CREATE_SUBMITTED'
    WORLD_JOIN_TIMEOUT='WORLD_JOIN_TIMEOUT'
    LAN_PUBLISH_TIMEOUT='LAN_PUBLISH_TIMEOUT'
    GUEST_JOIN_TIMEOUT='GUEST_JOIN_TIMEOUT'
    AGENT_ERROR='AGENT_ERROR'
    ACTION_RECEIVED='ACTION_RECEIVED'
    ACTION_COMPLETED='ACTION_COMPLETED'
    ACTION_FAILED='ACTION_FAILED'
    SHARED_STATE_WRITTEN='AGENT_SHARED_STATE_WRITTEN'
    SHARED_STATE_OBSERVED='AGENT_SHARED_STATE_OBSERVED'
}

function ConvertFrom-MmtlAgentEventLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Line,[Parameter(Mandatory)][string]$ExpectedSessionId,[Parameter(Mandatory)][ValidateSet('Client','Host','Guest','Server')][string]$ExpectedRole,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,[Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProcessIdentity)
    try{$agentEvent=$Line|ConvertFrom-Json -ErrorAction Stop}catch{throw 'AGENT_EVENT_INVALID_JSON'}
    if([int]$agentEvent.schemaVersion -ne 1 -or -not $agentEvent.eventId -or -not $agentEvent.timestampUtc -or -not $agentEvent.eventType -or -not $agentEvent.summary){throw 'AGENT_EVENT_SCHEMA_INVALID'}
    if([string]$agentEvent.sessionId -cne $ExpectedSessionId){throw 'AGENT_EVENT_SESSION_MISMATCH'}
    if([string]$agentEvent.role -cne $ExpectedRole){throw 'AGENT_EVENT_ROLE_MISMATCH'}
    if([string]$agentEvent.sessionNonceHash -cne $ExpectedNonceHash){throw 'AGENT_EVENT_NONCE_MISMATCH'}
    if(-not $script:AgentEventMap.ContainsKey([string]$agentEvent.eventType)){throw 'AGENT_EVENT_TYPE_UNSUPPORTED'}
    $allowedProperties=@('schemaVersion','eventId','timestampUtc','eventType','summary','sessionId','role','sessionNonceHash','port','actionId','actorActionId','worldKey','dimensionKey','playerIdentity','markerId','stateSha256','protocolId','operationCode','observationCode','observed','bindAddress')
    foreach($property in $agentEvent.PSObject.Properties.Name){if($property -match '(?i)token|password|secret|credential|raw|path|account|username'){throw 'AGENT_EVENT_SENSITIVE_FIELD_REJECTED'};if($property -notin $allowedProperties){throw 'AGENT_EVENT_PROPERTY_UNSUPPORTED'}}
    if($agentEvent.PSObject.Properties['actionId'] -and [string]$agentEvent.actionId -notmatch '^[a-f0-9]{32}$'){throw 'AGENT_EVENT_ACTION_ID_INVALID'}
    if($agentEvent.PSObject.Properties['actorActionId'] -and [string]$agentEvent.actorActionId -notmatch '^[a-f0-9]{32}$'){throw 'AGENT_EVENT_ACTION_ID_INVALID'}
    if([string]$agentEvent.eventType -eq 'WORLD_JOINED'){
        foreach($field in @('worldKey','dimensionKey','playerIdentity')){if($null -eq $agentEvent.PSObject.Properties[$field]){throw 'AGENT_WORLD_JOINED_EVENT_INCOMPLETE'}}
        if([string]$agentEvent.worldKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or [string]$agentEvent.dimensionKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or [string]$agentEvent.playerIdentity -notmatch '^[A-Za-z0-9._:-]{1,80}$'){throw 'AGENT_WORLD_JOINED_EVENT_INVALID'}
        if([string]$agentEvent.role -ceq 'Guest'){
            if($null -eq $agentEvent.PSObject.Properties['port']){throw 'AGENT_WORLD_JOINED_EVENT_INCOMPLETE'}
            if([int]$agentEvent.port -lt 1 -or [int]$agentEvent.port -gt 65535){throw 'AGENT_WORLD_JOINED_EVENT_INVALID'}
        }
    }
    if([string]$agentEvent.eventType -eq 'LAN_PUBLISHED'){
        if([string]$agentEvent.role -cne 'Host'){throw 'AGENT_LAN_PUBLISH_ROLE_INVALID'}
        foreach($field in @('port','bindAddress','worldKey','dimensionKey','playerIdentity')){if($null -eq $agentEvent.PSObject.Properties[$field]){throw 'AGENT_LAN_PUBLISH_EVENT_INCOMPLETE'}}
        if([int]$agentEvent.port -lt 1 -or [int]$agentEvent.port -gt 65535){throw 'AGENT_LAN_PUBLISH_EVENT_INVALID'}
        if([string]$agentEvent.bindAddress -cne '127.0.0.1'){throw 'AGENT_LAN_BIND_NOT_LOOPBACK'}
        if([string]$agentEvent.worldKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or [string]$agentEvent.dimensionKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or [string]$agentEvent.playerIdentity -notmatch '^[A-Za-z0-9._:-]{1,80}$'){throw 'AGENT_LAN_PUBLISH_EVENT_INVALID'}
    }
    if([string]$agentEvent.eventType -in @('SHARED_STATE_WRITTEN','SHARED_STATE_OBSERVED')){
        $requiredShared=@('worldKey','dimensionKey','playerIdentity','markerId','stateSha256','protocolId','observed')
        if([string]$agentEvent.eventType -eq 'SHARED_STATE_WRITTEN'){$requiredShared+=@('actionId','operationCode')}else{$requiredShared+=@('actorActionId','observationCode')}
        foreach($field in $requiredShared){if($null -eq $agentEvent.PSObject.Properties[$field]){throw 'AGENT_SHARED_STATE_EVENT_INCOMPLETE'}}
        if([string]$agentEvent.worldKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or [string]$agentEvent.dimensionKey -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$' -or [string]$agentEvent.playerIdentity -notmatch '^[A-Za-z0-9._:-]{1,80}$' -or [string]$agentEvent.markerId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or [string]$agentEvent.stateSha256 -notmatch '^[a-f0-9]{64}$' -or [string]$agentEvent.protocolId -cne 'mmtl-block-marker-v1' -or $agentEvent.observed -isnot [bool] -or $agentEvent.observed -ne $true){throw 'AGENT_SHARED_STATE_EVENT_INVALID'}
        if([string]$agentEvent.eventType -eq 'SHARED_STATE_WRITTEN' -and [string]$agentEvent.operationCode -cne 'PLACE_BLOCK_MARKER'){throw 'AGENT_SHARED_STATE_EVENT_INVALID'}
        if([string]$agentEvent.eventType -eq 'SHARED_STATE_OBSERVED' -and [string]$agentEvent.observationCode -cne 'OBSERVE_BLOCK_MARKER'){throw 'AGENT_SHARED_STATE_EVENT_INVALID'}
    }
    $metadata=@{agentEventId=[string]$agentEvent.eventId;agentNonceVerified=$true;sourceCategory=if($agentEvent.eventType -eq 'AGENT_ERROR'){'MMTL_INFRASTRUCTURE'}else{'AGENT_OBSERVATION'}}
    foreach($field in @('port','actionId','actorActionId','worldKey','dimensionKey','playerIdentity','markerId','stateSha256','protocolId','operationCode','observationCode','observed','bindAddress')){if($agentEvent.PSObject.Properties[$field]){$metadata[$field]=$agentEvent.$field}}
    return & $script:RuntimeEventModule {param($sid,$role,$pidValue,$identity,$code,$summary,$time,$meta) New-MmtlRuntimeEvent -SessionId $sid -Role $role -ProcessId $pidValue -ProcessIdentity $identity -SourceType Agent -EventCode $code -Summary $summary -TimestampUtc $time -Metadata $meta} $ExpectedSessionId $ExpectedRole $ProcessId $ProcessIdentity $script:AgentEventMap[[string]$agentEvent.eventType] ([string]$agentEvent.summary) ([string]$agentEvent.timestampUtc) $metadata
}

function Test-MmtlLoopbackTcpPort {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,[ValidateRange(50,5000)][int]$TimeoutMilliseconds=250)
    $client=[Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try{$task=$client.ConnectAsync([Net.IPAddress]::Loopback,$Port);try{return [bool]($task.Wait($TimeoutMilliseconds) -and $client.Connected)}catch{return $false}}
    finally{$client.Dispose()}
}

function Get-MmtlLoopbackListenerOwnerProcessIds {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port)
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        if(Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue){
            try{return @((Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop|Where-Object LocalAddress -CEQ '127.0.0.1'|ForEach-Object{[int]$_.OwningProcess}))}catch{}
        }
        $netstat=Get-Command netstat -ErrorAction SilentlyContinue
        if($netstat){
            try{$lines=@(& $netstat.Source -ano -p tcp 2>$null);$owners=[Collections.Generic.List[int]]::new();foreach($line in $lines){if($line -match ('(?i)^\s*TCP\s+127\.0\.0\.1:'+ $Port +'\s+\S+\s+LISTENING\s+(?<pid>\d+)\s*$')){$owners.Add([int]$Matches.pid)}};return @($owners.ToArray())}catch{}
        }
    }elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){
        $ss=Get-Command ss -ErrorAction SilentlyContinue
        if($ss){try{$lines=@(& $ss.Source -H -ltnp "sport = :$Port" 2>$null);$owners=[Collections.Generic.List[int]]::new();foreach($line in $lines){if($line -match ('127\.0\.0\.1:'+ $Port +'\s') -or $line -match ('\[::ffff:127\.0\.0\.1\]:'+ $Port +'\s')){foreach($match in [regex]::Matches($line,'pid=(\d+)')){$owners.Add([int]$match.Groups[1].Value)}}};return @($owners.ToArray())}catch{}}
    }else{
        $lsof=Get-Command lsof -ErrorAction SilentlyContinue
        if($lsof){try{$lines=@(& $lsof.Source -nP -iTCP:$Port -sTCP:LISTEN 2>$null);$owners=[Collections.Generic.List[int]]::new();foreach($line in $lines){if($line -match ('^\S+\s+(?<pid>\d+)\s+.*127\.0\.0\.1:'+ $Port +'\s+\(LISTEN\)\s*$')){$owners.Add([int]$Matches.pid)}};return @($owners.ToArray())}catch{}}
    }
    throw 'AGENT_LAN_LISTENER_OWNER_UNAVAILABLE'
}

function Assert-MmtlAgentEventPathSafe {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$current=[IO.Path]::GetPathRoot($full)
    foreach($part in ($full.Substring($current.Length) -split '[\\/]'|Where-Object{$_})){$current=Join-Path $current $part;if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AGENT_EVENT_PATH_REPARSE_POINT'}}}
    if(-not(& $script:AgentProviderModule {param($r,$p) Test-MmtlAgentPathInsideRoot -Root $r -Target $p} $Root $full)){throw 'AGENT_EVENT_PATH_OUTSIDE_SESSION'}
    return $full
}

function Wait-MmtlAgentIntegratedLanReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$EventPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,
        [Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,
        [ValidateRange(1,600)][int]$TimeoutSeconds=60,
        [ValidateRange(50,5000)][int]$PollMilliseconds=200,
        [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,
        [ValidateNotNullOrEmpty()][string]$ProcessIdentity='unobserved-process',
        [scriptblock]$PortProbe,
        [scriptblock]$ListenerOwnerProbe
    )
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    if(-not(Test-Path -LiteralPath $session -PathType Container) -or -not(Test-Path -LiteralPath $event -PathType Leaf)){throw 'AGENT_EVENT_WORKSPACE_MISSING'}
    if(-not $PortProbe){$PortProbe={param($candidate) Test-MmtlLoopbackTcpPort -Port $candidate}}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);$worldRecord=$null;$lanRecord=$null
    do{
        foreach($line in [IO.File]::ReadAllLines($event)){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole Host -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $agentRecord=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if(-not $agentRecord){continue}
            if([string]$agentRecord.eventType -eq 'WORLD_JOINED'){$worldRecord=$agentRecord;continue}
            if([string]$agentRecord.eventType -eq 'LAN_PUBLISH_FAILED' -and $agentRecord.PSObject.Properties['port'] -and [int]$agentRecord.port -eq $Port){throw 'AGENT_LAN_PUBLISH_FAILED'}
            if([string]$agentRecord.eventType -eq 'LAN_PUBLISHED' -and $agentRecord.PSObject.Properties['port'] -and [int]$agentRecord.port -eq $Port){$lanRecord=[pscustomobject]@{record=$agentRecord;observation=$observation}}
        }
        if($worldRecord -and $lanRecord -and (& $PortProbe $Port)){
            if([string]$lanRecord.record.worldKey -cne [string]$worldRecord.worldKey -or [string]$lanRecord.record.dimensionKey -cne [string]$worldRecord.dimensionKey -or [string]$lanRecord.record.playerIdentity -cne [string]$worldRecord.playerIdentity){throw 'AGENT_LAN_WORLD_IDENTITY_MISMATCH'}
            try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_HOST_PROCESS_EXITED'}
            $listenerOwners=@(if($ListenerOwnerProbe){& $ListenerOwnerProbe $Port|ForEach-Object{[int]$_}}else{Get-MmtlLoopbackListenerOwnerProcessIds -Port $Port})
            if(-not $listenerOwners.Count){throw 'AGENT_LAN_LISTENER_OWNER_UNAVAILABLE'}
            try{$managedTree=@(& $script:ProcessManagerModule {param($pidValue) Get-MmtlProcessSnapshot -RootProcessId $pidValue} $ProcessId)}catch{throw 'AGENT_HOST_PROCESS_TREE_UNAVAILABLE'}
            $managedPids=@($managedTree|ForEach-Object{[int]$_.PID})
            if(-not @($listenerOwners|Where-Object{$_ -in $managedPids}).Count){throw 'AGENT_LAN_LISTENER_PROCESS_MISMATCH'}
            return [pscustomobject][ordered]@{ready=$true;sessionId=$SessionId;port=$Port;bindAddress='127.0.0.1';event=$lanRecord.observation;world=[pscustomobject]@{worldKey=[string]$worldRecord.worldKey;dimensionKey=[string]$worldRecord.dimensionKey;playerIdentity=[string]$worldRecord.playerIdentity};detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        }
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_HOST_PROCESS_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'AGENT_LAN_READY_TIMEOUT'
}

function Wait-MmtlAgentGuestJoined {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$EventPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,
        [Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,
        [ValidateRange(1,600)][int]$TimeoutSeconds=120,
        [ValidateRange(50,5000)][int]$PollMilliseconds=200,
        [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,
        [ValidateNotNullOrEmpty()][string]$ProcessIdentity='unobserved-process',
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$')][string]$ExpectedWorldKey,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$')][string]$ExpectedDimensionKey
    )
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    if(-not(Test-Path -LiteralPath $session -PathType Container) -or -not(Test-Path -LiteralPath $event -PathType Leaf)){throw 'AGENT_EVENT_WORKSPACE_MISSING'}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);$worldRecord=$null;$joinRecord=$null
    do{
        foreach($line in [IO.File]::ReadAllLines($event)){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole Guest -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $record=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if(-not $record){continue}
            if([string]$record.eventType -eq 'WORLD_JOINED'){$worldRecord=$record;continue}
            if([string]$record.eventType -eq 'GUEST_CONNECTED' -and $record.PSObject.Properties['port'] -and [int]$record.port -eq $Port){$joinRecord=[pscustomobject]@{record=$record;observation=$observation}}
        }
        if($worldRecord -and $joinRecord){
            if([int]$worldRecord.port -ne $Port){throw 'AGENT_GUEST_PORT_MISMATCH'}
            if($ExpectedWorldKey -and [string]$worldRecord.worldKey -cne $ExpectedWorldKey){throw 'AGENT_GUEST_WORLD_MISMATCH'}
            if($ExpectedDimensionKey -and [string]$worldRecord.dimensionKey -cne $ExpectedDimensionKey){throw 'AGENT_GUEST_WORLD_MISMATCH'}
            try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_GUEST_PROCESS_EXITED'}
            return [pscustomobject][ordered]@{ready=$true;sessionId=$SessionId;role='Guest';port=$Port;endpoint='127.0.0.1';event=$joinRecord.observation;world=[pscustomobject]@{worldKey=[string]$worldRecord.worldKey;dimensionKey=[string]$worldRecord.dimensionKey;playerIdentity=[string]$worldRecord.playerIdentity};detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        }
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_GUEST_PROCESS_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'AGENT_GUEST_JOIN_TIMEOUT'
}

function Wait-MmtlAgentClientReady {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$EventPath,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,[ValidateRange(1,600)][int]$TimeoutSeconds=180,[ValidateRange(50,5000)][int]$PollMilliseconds=200,[Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,[ValidateNotNullOrEmpty()][string]$ProcessIdentity='unobserved-process')
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    if(-not(Test-Path -LiteralPath $session -PathType Container) -or -not(Test-Path -LiteralPath $event -PathType Leaf)){throw 'AGENT_EVENT_WORKSPACE_MISSING'}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do{
        foreach($line in [IO.File]::ReadAllLines($event)){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole Client -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $record=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if([string]$record.eventType -eq 'CLIENT_READY'){
                try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_CLIENT_PROCESS_EXITED'}
                return [pscustomobject][ordered]@{ready=$true;sessionId=$SessionId;role='Client';event=$observation;detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
            }
        }
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_CLIENT_PROCESS_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'AGENT_CLIENT_READY_TIMEOUT'
}

function Wait-MmtlAgentWorldJoined {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$EventPath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,
        [ValidateRange(1,600)][int]$TimeoutSeconds=180,
        [ValidateRange(50,5000)][int]$PollMilliseconds=200,
        [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,
        [ValidateNotNullOrEmpty()][string]$ProcessIdentity='unobserved-process',
        [Parameter(Mandatory)][string]$ExpectedWorldKey,
        [Parameter(Mandatory)][string]$ExpectedDimensionKey
    )
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    if(-not(Test-Path -LiteralPath $session -PathType Container) -or -not(Test-Path -LiteralPath $event -PathType Leaf)){throw 'AGENT_EVENT_WORKSPACE_MISSING'}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do{
        foreach($line in [IO.File]::ReadAllLines($event)){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole Client -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $record=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if([string]$record.eventType -ne 'WORLD_JOINED'){continue}
            if([string]$record.worldKey -cne $ExpectedWorldKey -or [string]$record.dimensionKey -cne $ExpectedDimensionKey){throw 'AGENT_WORLD_IDENTITY_MISMATCH'}
            try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_CLIENT_PROCESS_EXITED'}
            return [pscustomobject][ordered]@{ready=$true;sessionId=$SessionId;role='Client';event=$observation;world=[pscustomobject]@{worldKey=[string]$record.worldKey;dimensionKey=[string]$record.dimensionKey;playerIdentity=[string]$record.playerIdentity};detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        }
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_CLIENT_PROCESS_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'AGENT_WORLD_JOIN_TIMEOUT'
}

Export-ModuleMember -Function ConvertFrom-MmtlAgentEventLine,Test-MmtlLoopbackTcpPort,Wait-MmtlAgentIntegratedLanReady,Wait-MmtlAgentGuestJoined,Wait-MmtlAgentClientReady,Wait-MmtlAgentWorldJoined
