Set-StrictMode -Version Latest

$script:RuntimeEventModule=Import-Module (Join-Path $PSScriptRoot '../Observation/RuntimeEvents.psm1') -PassThru
$script:AgentProviderModule=Import-Module (Join-Path $PSScriptRoot 'AgentProvider.psm1') -PassThru
$script:AgentEventMap=@{
    AGENT_STARTED='AGENT_STARTED'
    PLAYER_JOINED='PLAYER_JOINED'
    CLIENT_READY='AGENT_CLIENT_READY'
    WORLD_JOINED='AGENT_WORLD_JOINED'
    INTEGRATED_SERVER_READY='INTEGRATED_SERVER_READY'
    OFFLINE_AUTH_ENABLED='OFFLINE_AUTH_ENABLED'
    LAN_PUBLISH_REQUESTED='LAN_PUBLISH_REQUESTED'
    LAN_PUBLISHED='LAN_PORT_PUBLISHED'
    LAN_PUBLISH_FAILED='LAN_PUBLISH_FAILED'
    GUEST_CONNECTING='GUEST_CONNECTING'
    CLIENT_INITIALIZED='CLIENT_INITIALIZED'
    GUEST_CONNECT_REQUESTED='GUEST_CONNECT_REQUESTED'
    GUEST_CONNECTION_FAILED='GUEST_CONNECTION_FAILED'
    GUEST_HANDSHAKE_PROGRESS='GUEST_HANDSHAKE_PROGRESS'
    GUEST_LOGIN_PACKET_RECEIVED='GUEST_LOGIN_PACKET_RECEIVED'
    GUEST_CHANNEL_STATE='GUEST_CHANNEL_STATE'
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
    foreach($property in $agentEvent.PSObject.Properties.Name){if($property -match '(?i)token|password|secret|credential|raw|path|account|username'){throw 'AGENT_EVENT_SENSITIVE_FIELD_REJECTED'};if($property -notin @('schemaVersion','eventId','timestampUtc','eventType','summary','sessionId','role','sessionNonceHash','port','actionId','bindAddress','playerName')){throw 'AGENT_EVENT_PROPERTY_UNSUPPORTED'}}
    if([string]$agentEvent.eventType -eq 'LAN_PUBLISHED'){
        if(-not $agentEvent.PSObject.Properties['port'] -or -not $agentEvent.PSObject.Properties['bindAddress']){throw 'AGENT_LAN_PUBLISH_EVENT_INCOMPLETE'}
        $address=$null;if(-not [Net.IPAddress]::TryParse([string]$agentEvent.bindAddress,[ref]$address) -or -not [Net.IPAddress]::IsLoopback($address)){throw 'AGENT_LAN_BIND_NOT_LOOPBACK'}
    }
    if([string]$agentEvent.eventType -eq 'PLAYER_JOINED' -and (-not $agentEvent.PSObject.Properties['playerName'] -or [string]$agentEvent.playerName -notmatch '^[A-Za-z0-9_]{1,16}$')){throw 'AGENT_PLAYER_JOIN_EVENT_INCOMPLETE'}
    if($agentEvent.PSObject.Properties['actionId'] -and [string]$agentEvent.actionId -notmatch '^[a-f0-9]{32}$'){throw 'AGENT_EVENT_ACTION_ID_INVALID'}
    $metadata=@{agentEventId=[string]$agentEvent.eventId;sourceCategory=if($agentEvent.eventType -eq 'AGENT_ERROR'){'MMTL_INFRASTRUCTURE'}else{'AGENT_OBSERVATION'}}
    if($agentEvent.PSObject.Properties['port']){$metadata.port=[int]$agentEvent.port}
    if($agentEvent.PSObject.Properties['actionId']){$metadata.actionId=[string]$agentEvent.actionId}
    if($agentEvent.PSObject.Properties['bindAddress']){$metadata.bindAddress=[string]$agentEvent.bindAddress}
    if($agentEvent.PSObject.Properties['playerName']){$metadata.playerName=[string]$agentEvent.playerName}
    return & $script:RuntimeEventModule {param($sid,$role,$pidValue,$identity,$code,$summary,$time,$meta) New-MmtlRuntimeEvent -SessionId $sid -Role $role -ProcessId $pidValue -ProcessIdentity $identity -SourceType Agent -EventCode $code -Summary $summary -TimestampUtc $time -Metadata $meta} $ExpectedSessionId $ExpectedRole $ProcessId $ProcessIdentity $script:AgentEventMap[[string]$agentEvent.eventType] ([string]$agentEvent.summary) ([string]$agentEvent.timestampUtc) $metadata
}

function Test-MmtlLoopbackTcpPort {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,[ValidateRange(50,5000)][int]$TimeoutMilliseconds=250)
    $client=[Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
    try{$task=$client.ConnectAsync([Net.IPAddress]::Loopback,$Port);try{return [bool]($task.Wait($TimeoutMilliseconds) -and $client.Connected)}catch{return $false}}
    finally{$client.Dispose()}
}

function Assert-MmtlAgentEventPathSafe {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$current=[IO.Path]::GetPathRoot($full)
    foreach($part in ($full.Substring($current.Length) -split '[\\/]'|Where-Object{$_})){$current=Join-Path $current $part;if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AGENT_EVENT_PATH_REPARSE_POINT'}}}
    if(-not(& $script:AgentProviderModule {param($r,$p) Test-MmtlAgentPathInsideRoot -Root $r -Target $p} $Root $full)){throw 'AGENT_EVENT_PATH_OUTSIDE_SESSION'}
    return $full
}

function Get-MmtlAgentEventSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [ValidateRange(1, 10)][int]$RetryCount = 3,
        [ValidateRange(1, 100)][int]$RetryDelayMilliseconds = 5
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $stream = $null
        try {
            $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
            $snapshotLength = [int64]$stream.Length
            if ($snapshotLength -gt 67108864) { throw [IO.InvalidDataException]::new('AGENT_EVENT_FILE_TOO_LARGE') }

            $buffer = [byte[]]::new([int]$snapshotLength)
            $offset = 0
            while ($offset -lt $buffer.Length) {
                $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
                if ($read -le 0) { break }
                $offset += $read
            }
            $stream.Dispose()
            $stream = $null

            $lastNewline = -1
            for ($index = $offset - 1; $index -ge 0; $index--) {
                if ($buffer[$index] -eq 10) { $lastNewline = $index; break }
            }
            if ($lastNewline -lt 0) {
                return [pscustomobject]@{ success = $true; lines = @(); readError = $null }
            }

            $encoding = [Text.UTF8Encoding]::new($false, $true)
            $text = $encoding.GetString($buffer, 0, $lastNewline + 1)
            $lines = @($text.Split([char]10, [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.TrimEnd([char]13) })
            return [pscustomobject]@{ success = $true; lines = $lines; readError = $null }
        }
        catch [IO.IOException] {
            $lastError = $_.Exception
            if ($attempt -lt $RetryCount) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    return [pscustomobject]@{
        success = $false
        lines = @()
        readError = "AGENT_EVENT_READ_UNAVAILABLE after $RetryCount attempts: $($lastError.Message)"
    }
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
        [scriptblock]$ListenerProbe
    )
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    if(-not(Test-Path -LiteralPath $session -PathType Container) -or -not(Test-Path -LiteralPath $event -PathType Leaf)){throw 'AGENT_EVENT_WORKSPACE_MISSING'}
    if(-not $PortProbe){$PortProbe={param($candidate) Test-MmtlLoopbackTcpPort -Port $candidate}}
    if(-not $ListenerProbe){$ListenerProbe={param($candidate) @(Get-NetTCPConnection -State Listen -LocalPort $candidate -ErrorAction Stop|ForEach-Object{[string]$_.LocalAddress})}}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastReadError=$null
    do{
        $snapshot=Get-MmtlAgentEventSnapshot -Path $event
        if($snapshot.success){$lastReadError=$null}else{$lastReadError=$snapshot.readError}
        foreach($line in $snapshot.lines){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole Host -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $agentRecord=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if(-not $agentRecord -or -not $agentRecord.PSObject.Properties['port']){continue}
            if([int]$agentRecord.port -ne $Port){continue}
            if([string]$agentRecord.eventType -eq 'LAN_PUBLISH_FAILED'){throw 'AGENT_LAN_PUBLISH_FAILED'}
            if([string]$agentRecord.eventType -eq 'LAN_PUBLISHED' -and (& $PortProbe $Port)){
                if(-not $agentRecord.PSObject.Properties['bindAddress']){throw 'AGENT_LAN_PUBLISH_EVENT_INCOMPLETE'}
                $eventAddress=$null;if(-not [Net.IPAddress]::TryParse([string]$agentRecord.bindAddress,[ref]$eventAddress) -or -not [Net.IPAddress]::IsLoopback($eventAddress)){throw 'AGENT_LAN_BIND_NOT_LOOPBACK'}
                try{$listenerAddresses=@(& $ListenerProbe $Port)}catch{throw 'AGENT_LAN_LISTENER_QUERY_FAILED'}
                if(-not $listenerAddresses.Count){continue}
                foreach($listenerAddressText in $listenerAddresses){$listenerAddress=$null;if(-not [Net.IPAddress]::TryParse([string]$listenerAddressText,[ref]$listenerAddress) -or -not [Net.IPAddress]::IsLoopback($listenerAddress)){throw 'AGENT_LAN_BIND_NOT_LOOPBACK'}}
                try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_HOST_PROCESS_EXITED'}
                return [pscustomobject][ordered]@{ready=$true;sessionId=$SessionId;port=$Port;bindAddress=[string]$agentRecord.bindAddress;listenerAddresses=$listenerAddresses;event=$observation;detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
            }
        }
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_HOST_PROCESS_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    if($lastReadError){throw "AGENT_LAN_READY_TIMEOUT: $lastReadError"};throw 'AGENT_LAN_READY_TIMEOUT'
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
        [ValidateNotNullOrEmpty()][string]$ProcessIdentity='unobserved-process'
    )
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    if(-not(Test-Path -LiteralPath $session -PathType Container) -or -not(Test-Path -LiteralPath $event -PathType Leaf)){throw 'AGENT_EVENT_WORKSPACE_MISSING'}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastReadError=$null
    do{
        $snapshot=Get-MmtlAgentEventSnapshot -Path $event
        if($snapshot.success){$lastReadError=$null}else{$lastReadError=$snapshot.readError}
        foreach($line in $snapshot.lines){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole Guest -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $record=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if($record -and [string]$record.eventType -ceq 'GUEST_CONNECTION_FAILED' -and $record.PSObject.Properties['port'] -and [int]$record.port -eq $Port){throw "GUEST_LOGIN_DISCONNECTED: $([string]$record.summary)"}
            if(-not $record -or [string]$record.eventType -ne 'GUEST_CONNECTED' -or -not $record.PSObject.Properties['port'] -or [int]$record.port -ne $Port){continue}
            try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_GUEST_PROCESS_EXITED'}
            return [pscustomobject][ordered]@{ready=$true;sessionId=$SessionId;role='Guest';port=$Port;endpoint='127.0.0.1';event=$observation;detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        }
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_GUEST_PROCESS_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    if($lastReadError){throw "AGENT_GUEST_JOIN_TIMEOUT: $lastReadError"};throw 'AGENT_GUEST_JOIN_TIMEOUT'
}

function Wait-MmtlAgentWorldJoined {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$EventPath,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,[Parameter(Mandatory)][ValidateSet('Client','Host','Guest')][string]$Role,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,[ValidateRange(1,600)][int]$TimeoutSeconds=180,[ValidateRange(50,5000)][int]$PollMilliseconds=200,[Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,[ValidateNotNullOrEmpty()][string]$ProcessIdentity='unobserved-process')
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    if(-not(Test-Path -LiteralPath $session -PathType Container) -or -not(Test-Path -LiteralPath $event -PathType Leaf)){throw 'AGENT_EVENT_WORKSPACE_MISSING'}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastReadError=$null
    do{
        $snapshot=Get-MmtlAgentEventSnapshot -Path $event
        if($snapshot.success){$lastReadError=$null}else{$lastReadError=$snapshot.readError}
        foreach($line in $snapshot.lines){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole $Role -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $record=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if($Role -eq 'Guest' -and $record -and [string]$record.eventType -ceq 'GUEST_CONNECTION_FAILED'){
                throw "GUEST_LOGIN_DISCONNECTED: $([string]$record.summary)"
            }
            if([string]$record.eventType -ceq 'WORLD_JOINED'){try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_WORLD_CLIENT_EXITED'};return [pscustomobject][ordered]@{ready=$true;role=$Role;sessionId=$SessionId;event=$observation;detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}}
        }
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_WORLD_CLIENT_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    if($lastReadError){throw "AGENT_WORLD_JOIN_TIMEOUT: $lastReadError"};throw 'AGENT_WORLD_JOIN_TIMEOUT'
}

function Wait-MmtlAgentHostPlayersJoined {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$EventPath,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,[Parameter(Mandatory)][string[]]$PlayerNames,[ValidateRange(1,600)][int]$TimeoutSeconds=120,[ValidateRange(50,5000)][int]$PollMilliseconds=200,[Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,[ValidateNotNullOrEmpty()][string]$ProcessIdentity='unobserved-process')
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    $expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($name in $PlayerNames){if($name -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'AGENT_EXPECTED_PLAYER_NAME_INVALID'};$null=$expected.Add($name)}
    if(-not $expected.Count){throw 'AGENT_EXPECTED_PLAYER_NAMES_REQUIRED'}
    $joined=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$evidence=[Collections.Generic.List[object]]::new();$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastReadError=$null
    do{
        $snapshot=Get-MmtlAgentEventSnapshot -Path $event
        if($snapshot.success){$lastReadError=$null}else{$lastReadError=$snapshot.readError}
        foreach($line in $snapshot.lines){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole Host -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $record=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if([string]$record.eventType -ceq 'PLAYER_JOINED' -and [string]$record.playerName -in $expected){if($joined.Add([string]$record.playerName)){$evidence.Add($observation)}}
        }
        if($joined.Count -eq $expected.Count){try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_HOST_PROCESS_EXITED'};return [pscustomobject][ordered]@{ready=$true;sessionId=$SessionId;expectedPlayers=@($expected);joinedPlayers=@($joined);events=@($evidence.ToArray());detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}}
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_HOST_PROCESS_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    if($lastReadError){throw "AGENT_HOST_PLAYER_JOIN_TIMEOUT: $lastReadError"};throw 'AGENT_HOST_PLAYER_JOIN_TIMEOUT'
}

function Wait-MmtlAgentClientReady {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$EventPath,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,[Parameter(Mandatory)][ValidateSet('Client','Host','Guest')][string]$Role='Client',[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,[ValidateRange(1,600)][int]$TimeoutSeconds=180,[ValidateRange(50,5000)][int]$PollMilliseconds=200,[Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,[ValidateNotNullOrEmpty()][string]$ProcessIdentity='unobserved-process')
    $session=[IO.Path]::GetFullPath($SessionPath);$event=Assert-MmtlAgentEventPathSafe -Root $session -Path $EventPath
    if(-not(Test-Path -LiteralPath $session -PathType Container) -or -not(Test-Path -LiteralPath $event -PathType Leaf)){throw 'AGENT_EVENT_WORKSPACE_MISSING'}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastReadError=$null
    do{
        $snapshot=Get-MmtlAgentEventSnapshot -Path $event
        if($snapshot.success){$lastReadError=$null}else{$lastReadError=$snapshot.readError}
        foreach($line in $snapshot.lines){
            if(-not $line){continue}
            try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $SessionId -ExpectedRole $Role -ExpectedNonceHash $ExpectedNonceHash -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity}catch{continue}
            $record=$line|ConvertFrom-Json -ErrorAction SilentlyContinue
            if($Role -eq 'Guest' -and $record -and [string]$record.eventType -ceq 'GUEST_CONNECTION_FAILED'){
                throw "GUEST_LOGIN_DISCONNECTED: $([string]$record.summary)"
            }
            if([string]$record.eventType -eq 'CLIENT_READY'){
                try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_CLIENT_PROCESS_EXITED'}
                return [pscustomobject][ordered]@{ready=$true;sessionId=$SessionId;role=$Role;event=$observation;detectedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
            }
        }
        try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}catch{throw 'AGENT_CLIENT_PROCESS_EXITED'}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    if($lastReadError){throw "AGENT_CLIENT_READY_TIMEOUT: $lastReadError"};throw 'AGENT_CLIENT_READY_TIMEOUT'
}

Export-ModuleMember -Function ConvertFrom-MmtlAgentEventLine,Get-MmtlAgentEventSnapshot,Test-MmtlLoopbackTcpPort,Wait-MmtlAgentIntegratedLanReady,Wait-MmtlAgentGuestJoined,Wait-MmtlAgentClientReady,Wait-MmtlAgentWorldJoined,Wait-MmtlAgentHostPlayersJoined
