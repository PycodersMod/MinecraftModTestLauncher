Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\SessionLock.psm1') -Force

function Assert-MmtlScenarioSessionPath {
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=[IO.Path]::GetFullPath($SessionPath)
    if(-not(Test-Path -LiteralPath $session -PathType Container)){throw 'SCENARIO_SESSION_MISSING'}
    $root=[IO.Path]::GetPathRoot($session);$current=$root
    foreach($part in ($session.Substring($root.Length) -split '[\\/]'|Where-Object{$_})){$current=Join-Path $current $part;$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_SESSION_REPARSE_POINT'}}
    return $session
}

function Write-MmtlScenarioAtomicState {
    param([string]$Path,$Value)
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 30)+"`n",[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temp -Destination $Path -Force}
    finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}

function New-MmtlScenarioPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Single','IntegratedLAN','Dedicated')][string]$Mode,
        [Parameter(Mandatory)][ValidateRange(1,8)][int]$Players,
        [string]$HostUsername='MMTL_Host',
        [string]$GuestPrefix='MMTL_C',
        [switch]$AutoCreateWorld,
        [ValidateRange(1,8)][int]$MaximumConcurrentInstances=8,
        [ValidateRange(1,600)][int]$ReadyTimeoutSeconds=180,
        [ValidateRange(1,600)][int]$JoinTimeoutSeconds=120,
        [ValidateRange(1,600)][int]$DurationSeconds=60
    )
    if($Mode -eq 'Single' -and $Players -ne 1){throw 'SCENARIO_SINGLE_REQUIRES_ONE_PLAYER'}
    if($Mode -eq 'IntegratedLAN' -and $Players -lt 2){throw 'SCENARIO_INTEGRATED_LAN_REQUIRES_HOST_AND_GUEST'}
    if($Mode -eq 'Dedicated' -and $Players -lt 1){throw 'SCENARIO_DEDICATED_REQUIRES_CLIENT'}
    foreach($name in @($HostUsername,$GuestPrefix)){if($name -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'SCENARIO_IDENTITY_INVALID'}}
    if($Mode -eq 'IntegratedLAN' -and $GuestPrefix.Length -ge 16){throw 'SCENARIO_GUEST_PREFIX_TOO_LONG'}
    $roles=[Collections.Generic.List[object]]::new()
    if($Mode -eq 'Single'){$roles.Add([pscustomobject]@{role='Client';username=$HostUsername;ordinal=0})}
    elseif($Mode -eq 'IntegratedLAN'){
        $roles.Add([pscustomobject]@{role='Host';username=$HostUsername;ordinal=0})
        for($i=1;$i -lt $Players;$i++){$username="$GuestPrefix$i";if($username.Length -gt 16){throw 'SCENARIO_USERNAME_TOO_LONG'};$roles.Add([pscustomobject]@{role='Guest';username=$username;ordinal=$i})}
    }else{
        $roles.Add([pscustomobject]@{role='Server';username='';ordinal=0})
        for($i=0;$i -lt $Players;$i++){$username=if($i -eq 0){$HostUsername}else{"$GuestPrefix$i"};if($username.Length -gt 16){throw 'SCENARIO_USERNAME_TOO_LONG'};$roles.Add([pscustomobject]@{role='Client';username=$username;ordinal=$i+1})}
    }
    $names=@($roles|Where-Object username|ForEach-Object username)
    if(@($names|Select-Object -Unique).Count -ne $names.Count){throw 'SCENARIO_IDENTITY_COLLISION'}
    if($roles.Count -gt $MaximumConcurrentInstances){throw 'SCENARIO_CONCURRENCY_LIMIT_EXCEEDED'}
    $steps=switch($Mode){
        'Single' {@('Build','CreateSession','StartClient','Observe','Analyze','SafeStop')}
        'IntegratedLAN' {@('Build','CreateSession','StartHost','CreateOrLoadWorld','WaitHostWorld','WaitAgentLanReady','StartGuests','WaitGuestWorlds','Observe','Analyze','SafeStop')}
        'Dedicated' {@('Build','CreateSession','StartServer','WaitServerReady','StartClients','Observe','Analyze','SafeStop')}
    }
    [pscustomobject][ordered]@{schemaVersion=1;mode=$Mode;players=$Players;maximumConcurrentInstances=$MaximumConcurrentInstances;readyTimeoutSeconds=$ReadyTimeoutSeconds;joinTimeoutSeconds=$JoinTimeoutSeconds;durationSeconds=$DurationSeconds;stopPolicy='Always';roles=@($roles);steps=@($steps);autoCreateWorld=[bool]$AutoCreateWorld.IsPresent;nonInteractive=$true;loopbackOnly=($Mode -eq 'IntegratedLAN');requiresAcceptedEula=($Mode -eq 'Dedicated')}
}

function Assert-MmtlScenarioAction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('WAIT','SEND_COMMAND','SCREENSHOT','STOP_ROLE','STOP_ALL')][string]$Action,[string]$Role,[string]$Command,[int]$Seconds=0,[switch]$TargetManaged,[switch]$PermissionGranted)
    switch($Action){
        'WAIT' {if($Seconds -lt 1 -or $Seconds -gt 600){throw 'SCENARIO_WAIT_DURATION_INVALID'}}
        'SEND_COMMAND' {
            if(-not $TargetManaged){throw 'SCENARIO_ACTION_TARGET_NOT_MANAGED'}
            if(-not $PermissionGranted){throw 'SCENARIO_COMMAND_PERMISSION_REQUIRED'}
            if([string]::IsNullOrWhiteSpace($Command) -or $Command.Length -gt 256 -or $Command -match '[\r\n\x00]'){throw 'SCENARIO_COMMAND_INVALID'}
            $commandName=($Command.Trim() -split '\s+',2)[0].TrimStart('/')
            $baseCommand=($commandName -split ':')[-1]
            if($baseCommand -in @('stop','op','deop','save-all','save-off','save-on','whitelist','ban','pardon')){throw 'SCENARIO_COMMAND_FORBIDDEN'}
        }
        'SCREENSHOT' {if(-not $TargetManaged){throw 'SCENARIO_ACTION_TARGET_NOT_MANAGED'}}
        'STOP_ROLE' {if(-not $Role){throw 'SCENARIO_ROLE_REQUIRED'}}
    }
    return [pscustomobject]@{action=$Action;role=$Role;command=$Command;seconds=$Seconds}
}

function Test-MmtlScenarioTransition {
    param([Parameter(Mandatory)][string]$Current,[Parameter(Mandatory)][string]$Next)
    $allowed=@{
        Planned=@('Building','Failed');Building=@('SessionReady','Failed');SessionReady=@('HostStarting','ServerStarting','ClientStarting','Failed')
        HostStarting=@('HostReady','Stopping','Failed');HostReady=@('GuestsStarting','Observing','Stopping','Failed');GuestsStarting=@('GuestsReady','Stopping','Failed');GuestsReady=@('Observing','Stopping','Failed')
        ServerStarting=@('ServerReady','Stopping','Failed');ServerReady=@('ClientsStarting','Stopping','Failed');ClientsStarting=@('ClientsReady','Stopping','Failed');ClientsReady=@('Observing','Stopping','Failed')
        ClientStarting=@('Observing','Stopping','Failed');Observing=@('Analyzing','Stopping','Failed');Analyzing=@('Stopping','Failed');Stopping=@('Completed','Failed','Stopped')
        Completed=@();Failed=@('Stopping','Stopped');Stopped=@()
    }
    return [bool]($allowed.ContainsKey($Current) -and $allowed[$Current] -contains $Next)
}

function Initialize-MmtlScenarioState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,[Parameter(Mandatory)]$Plan)
    $session=Assert-MmtlScenarioSessionPath $SessionPath;$statePath=Join-Path $session 'scenario.json';$eventPath=Join-Path $session 'scenario-events.jsonl'
    $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
    try{
        if(Test-Path -LiteralPath $statePath){throw 'SCENARIO_STATE_ALREADY_EXISTS'}
        if(Test-Path -LiteralPath $eventPath){throw 'SCENARIO_EVENTS_ALREADY_EXIST'}
        $now=[DateTimeOffset]::UtcNow.ToString('o')
        $state=[pscustomobject][ordered]@{schemaVersion=1;sessionId=$SessionId;state='Planned';sequence=1;createdUtc=$now;updatedUtc=$now;plan=$Plan}
        $created=[ordered]@{schemaVersion=1;sessionId=$SessionId;sequence=1;eventCode='SCENARIO_STARTED';state='Planned';role='Launcher';observedAtUtc=$now;summary='Scenario 已通过计划校验并进入 Session。'}
        [IO.File]::WriteAllText($eventPath,(($created|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false));Write-MmtlScenarioAtomicState -Path $statePath -Value $state
        return $state
    }finally{Remove-MmtlSessionLock -Lock $lock}
}

function Set-MmtlScenarioState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidateSet('Planned','Building','SessionReady','HostStarting','HostReady','GuestsStarting','GuestsReady','ServerStarting','ServerReady','ClientsStarting','ClientsReady','ClientStarting','Observing','Analyzing','Stopping','Completed','Failed','Stopped')][string]$NextState,[Parameter(Mandatory)][ValidatePattern('^[A-Z][A-Z0-9_]{1,63}$')][string]$EventCode,[ValidateSet('Launcher','Host','Guest','Client','Server')][string]$Role='Launcher',[string]$Summary='')
    $session=Assert-MmtlScenarioSessionPath $SessionPath;$statePath=Join-Path $session 'scenario.json';$eventPath=Join-Path $session 'scenario-events.jsonl'
    $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
    try{
        if(-not(Test-Path -LiteralPath $statePath -PathType Leaf) -or -not(Test-Path -LiteralPath $eventPath -PathType Leaf)){throw 'SCENARIO_STATE_MISSING'}
        foreach($path in @($statePath,$eventPath)){$item=Get-Item -LiteralPath $path -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_STATE_REPARSE_POINT'}}
        $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -ErrorAction Stop
        if(-not(Test-MmtlScenarioTransition -Current ([string]$state.state) -Next $NextState)){throw 'SCENARIO_TRANSITION_INVALID'}
        if($Summary.Length -gt 240 -or $Summary -match '[\r\n\x00]'){throw 'SCENARIO_EVENT_SUMMARY_INVALID'}
        $sequence=[int]$state.sequence+1;$now=[DateTimeOffset]::UtcNow.ToString('o')
        $event=[ordered]@{schemaVersion=1;sessionId=[string]$state.sessionId;sequence=$sequence;eventCode=$EventCode;state=$NextState;role=$Role;observedAtUtc=$now;summary=$Summary}
        [IO.File]::AppendAllText($eventPath,(($event|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $state.state=$NextState;$state.sequence=$sequence;$state.updatedUtc=$now;Write-MmtlScenarioAtomicState -Path $statePath -Value $state
        return $state
    }finally{Remove-MmtlSessionLock -Lock $lock}
}

function Get-MmtlScenarioStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=Assert-MmtlScenarioSessionPath $SessionPath;$statePath=Join-Path $session 'scenario.json'
    if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){throw 'SCENARIO_STATE_MISSING'}
    $item=Get-Item -LiteralPath $statePath -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_STATE_REPARSE_POINT'}
    return Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -ErrorAction Stop
}

function Add-MmtlScenarioEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidatePattern('^[A-Z][A-Z0-9_]{1,63}$')][string]$EventCode,[ValidateSet('Launcher','Host','Guest','Client','Server')][string]$Role='Launcher',[string]$Summary='')
    $session=Assert-MmtlScenarioSessionPath $SessionPath;$statePath=Join-Path $session 'scenario.json';$eventPath=Join-Path $session 'scenario-events.jsonl'
    $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
    try{
        foreach($path in @($statePath,$eventPath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'SCENARIO_STATE_MISSING'};$item=Get-Item -LiteralPath $path -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_STATE_REPARSE_POINT'}}
        if($Summary.Length -gt 240 -or $Summary -match '[\r\n\x00]'){throw 'SCENARIO_EVENT_SUMMARY_INVALID'}
        $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -ErrorAction Stop;$sequence=[int]$state.sequence+1;$now=[DateTimeOffset]::UtcNow.ToString('o')
        $event=[ordered]@{schemaVersion=1;sessionId=[string]$state.sessionId;sequence=$sequence;eventCode=$EventCode;state=[string]$state.state;role=$Role;observedAtUtc=$now;summary=$Summary}
        [IO.File]::AppendAllText($eventPath,(($event|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        $state.sequence=$sequence;$state.updatedUtc=$now;Write-MmtlScenarioAtomicState -Path $statePath -Value $state
        return $event
    }finally{Remove-MmtlSessionLock -Lock $lock}
}

function Invoke-MmtlScenarioAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][ValidateSet('WAIT','SEND_COMMAND','SCREENSHOT','STOP_ROLE','STOP_ALL')][string]$Action,
        [ValidateSet('Host','Guest','Client','Server')][string]$Role,
        [string]$Command,
        [ValidateRange(0,600)][int]$Seconds=0,
        [switch]$PermissionGranted,
        [scriptblock]$AgentDispatcher,
        [scriptblock]$StopProcess
    )
    $session=Assert-MmtlScenarioSessionPath $SessionPath;$status=Get-MmtlScenarioStatus -SessionPath $session
    if([string]$status.state -in @('Planned','Building','SessionReady','Completed','Stopped')){throw 'SCENARIO_ACTION_STATE_INVALID'}
    $registryPath=Join-Path $session 'pids.json';if(-not(Test-Path -LiteralPath $registryPath -PathType Leaf)){throw 'SCENARIO_PROCESS_REGISTRY_MISSING'};$registryItem=Get-Item -LiteralPath $registryPath -Force;if($registryItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_PROCESS_REGISTRY_REPARSE_POINT'}
    $entries=@(Get-Content -LiteralPath $registryPath -Raw|ConvertFrom-Json -ErrorAction Stop)
    $targetEntries=@()
    if($Action -eq 'STOP_ALL'){$targetEntries=$entries}
    elseif($Role){
        if($Role -eq 'Guest' -and [string]$status.plan.mode -eq 'IntegratedLAN'){$guestNames=@($status.plan.roles|Where-Object role -eq 'Guest'|ForEach-Object username);$targetEntries=@($entries|Where-Object{$_.Role -eq 'Client' -and [string]$_.Username -in $guestNames})}
        else{$processRole=if($Role -eq 'Guest'){'Client'}else{$Role};$targetEntries=@($entries|Where-Object{[string]$_.Role -ceq $processRole})}
    }
    $managed=$targetEntries.Count -gt 0
    if($Action -eq 'STOP_ROLE' -and -not $managed){throw 'SCENARIO_ACTION_TARGET_NOT_MANAGED'}
    $permission=$PermissionGranted.IsPresent
    $validated=Assert-MmtlScenarioAction -Action $Action -Role $Role -Command $Command -Seconds $Seconds -TargetManaged:$managed -PermissionGranted:$permission
    Add-MmtlScenarioEvent -SessionPath $session -EventCode ACTION_STARTED -Role $(if($Role){$Role}else{'Launcher'}) -Summary "$Action started"|Out-Null
    try{
        $result=switch($Action){
            'WAIT' {Start-Sleep -Seconds $Seconds;[pscustomobject]@{completed=$true;seconds=$Seconds}}
            'STOP_ROLE' {if(-not $StopProcess){throw 'SCENARIO_STOP_PROVIDER_UNAVAILABLE'};foreach($entry in $targetEntries){& $StopProcess $session ([int]$entry.PID)|Out-Null;Add-MmtlScenarioEvent -SessionPath $session -EventCode ROLE_STOPPED -Role $Role -Summary 'Managed role stopped'|Out-Null};[pscustomobject]@{completed=$true;stoppedCount=$targetEntries.Count}}
            'STOP_ALL' {if(-not $StopProcess){throw 'SCENARIO_STOP_PROVIDER_UNAVAILABLE'};$current=Get-MmtlScenarioStatus -SessionPath $session;if([string]$current.state -ne 'Stopping'){Set-MmtlScenarioState -SessionPath $session -NextState Stopping -EventCode SCENARIO_SAFE_STOP_STARTED -Summary 'Action Controller 正在回收当前 Session 的进程。'|Out-Null};$stopped=0;foreach($entry in @($targetEntries|Sort-Object {switch([string]$_.Role){'Client'{0}'Host'{1}'Server'{2}default{3}}})) {& $StopProcess $session ([int]$entry.PID)|Out-Null;$stopped++;$eventRole=[string]$entry.Role;if($eventRole -eq 'Client' -and [string]$status.plan.mode -eq 'IntegratedLAN' -and [string]$entry.Username -in @($status.plan.roles|Where-Object role -eq 'Guest'|ForEach-Object username)){$eventRole='Guest'};Add-MmtlScenarioEvent -SessionPath $session -EventCode ROLE_STOPPED -Role $eventRole -Summary 'Managed role stopped'|Out-Null};$current=Get-MmtlScenarioStatus -SessionPath $session;if([string]$current.state -eq 'Stopping'){Set-MmtlScenarioState -SessionPath $session -NextState Stopped -EventCode SCENARIO_SAFE_STOP_COMPLETED -Summary '当前 Session 登记的进程已停止。'|Out-Null};[pscustomobject]@{completed=$true;stoppedCount=$stopped}}
            {$_ -in @('SEND_COMMAND','SCREENSHOT')} {if(-not $AgentDispatcher){throw 'SCENARIO_AGENT_ACTION_UNAVAILABLE'};& $AgentDispatcher $Action $Role $Command $session $permission}
        }
        Add-MmtlScenarioEvent -SessionPath $session -EventCode ACTION_COMPLETED -Role $(if($Role){$Role}else{'Launcher'}) -Summary "$Action completed"|Out-Null
        return [pscustomobject]@{sessionId=[string]$status.sessionId;action=$Action;role=$Role;result=$result}
    }catch{Add-MmtlScenarioEvent -SessionPath $session -EventCode ACTION_FAILED -Role $(if($Role){$Role}else{'Launcher'}) -Summary "$Action failed"|Out-Null;throw}
}

Export-ModuleMember -Function New-MmtlScenarioPlan,Assert-MmtlScenarioAction,Test-MmtlScenarioTransition,Initialize-MmtlScenarioState,Set-MmtlScenarioState,Get-MmtlScenarioStatus,Add-MmtlScenarioEvent,Invoke-MmtlScenarioAction
