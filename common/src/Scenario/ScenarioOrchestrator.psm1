Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\SessionLock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Compatibility\HistoricalDedicatedServerCatalog.psm1') -Force

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

function Get-MmtlScenarioProperty {
    param([AllowNull()]$InputObject,[Parameter(Mandatory)][string]$Name,$Default=$null)
    if($null -eq $InputObject){return $Default}
    $property=$InputObject.PSObject.Properties[$Name]
    if($null -eq $property){return $Default}
    return $property.Value
}

function Resolve-MmtlScenarioMode {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$EffectiveConfig,[Parameter(Mandatory)]$TargetCapabilities)
    $mode=[string]$EffectiveConfig.mode;$transport=[string]$EffectiveConfig.transport;$count=0
    if(-not [int]::TryParse([string]$EffectiveConfig.clientCount,[ref]$count) -or $count -lt 1){throw 'SCENARIO_CLIENT_COUNT_INVALID'}
    $minecraftId=[string]$(if($null -ne $EffectiveConfig.PSObject.Properties['minecraftId']){$EffectiveConfig.minecraftId}else{Get-MmtlScenarioProperty $TargetCapabilities 'minecraftId' ''})
    $minecraftType=[string]$(if($null -ne $EffectiveConfig.PSObject.Properties['minecraftType']){$EffectiveConfig.minecraftType}else{Get-MmtlScenarioProperty $TargetCapabilities 'minecraftType' ''})
    $targetId=[string]$(if($null -ne $EffectiveConfig.PSObject.Properties['targetId']){$EffectiveConfig.targetId}else{Get-MmtlScenarioProperty $TargetCapabilities 'targetId' ''})
    $oldRelease=$false
    if($minecraftType -ceq 'release' -and $minecraftId -match '^\d+\.\d+(?:\.\d+)?$'){
        try{$oldRelease=[version]($minecraftId+'.0') -lt [version]'1.3.1'}catch{$oldRelease=$false}
    }
    if($mode -eq 'Single' -and $transport -eq 'None' -and $count -eq 1){return [pscustomobject]@{status='Supported';mode='Single';transport='None';clientCount=1;multiplayer='NotRequested';dimensionStatus=[pscustomobject]@{Multiplayer='NotRequested'};reason=$null}}
    if($mode -eq 'IntegratedLAN' -and $transport -eq 'IntegratedLAN' -and $count -ge 2){
        if($oldRelease){return [pscustomobject]@{status='Unsupported';mode='Unsupported';transport=$transport;clientCount=$count;multiplayer='UnsupportedByMinecraftVersion';dimensionStatus=[pscustomobject]@{NativeIntegratedLAN='UnsupportedByMinecraftVersion';HistoricalDedicatedEquivalent='NotRequested'};reason='NATIVE_INTEGRATED_LAN_UNSUPPORTED'}}
        if(-not [bool](Get-MmtlScenarioProperty $TargetCapabilities 'nativeIntegratedLAN' $false)){return [pscustomobject]@{status='Unsupported';mode='Unsupported';transport=$transport;clientCount=$count;multiplayer='Unsupported';dimensionStatus=[pscustomobject]@{NativeIntegratedLAN='Unsupported';HistoricalDedicatedEquivalent='NotRequested'};reason='NATIVE_INTEGRATED_LAN_UNSUPPORTED'}}
        if(-not [bool](Get-MmtlScenarioProperty $TargetCapabilities 'agentIntegratedLAN' $false)){return [pscustomobject]@{status='Unsupported';mode='Unsupported';transport=$transport;clientCount=$count;multiplayer='Unsupported';dimensionStatus=[pscustomobject]@{NativeIntegratedLAN='Blocked';HistoricalDedicatedEquivalent='NotRequested'};reason='AGENT_INTEGRATED_LAN_UNSUPPORTED'}}
        return [pscustomobject]@{status='Supported';mode='IntegratedLAN';transport=$transport;clientCount=$count;multiplayer='Requested';dimensionStatus=[pscustomobject]@{NativeIntegratedLAN='Requested';HistoricalDedicatedEquivalent='NotRequested'};reason=$null}
    }
    if($mode -eq 'Dedicated' -and $transport -eq 'Dedicated' -and $count -ge 1){
        if(-not [bool](Get-MmtlScenarioProperty $TargetCapabilities 'dedicatedServer' $false)){return [pscustomobject]@{status='Unsupported';mode='Unsupported';transport=$transport;clientCount=$count;multiplayer='Unsupported';reason='DEDICATED_SERVER_UNSUPPORTED'}}
        return [pscustomobject]@{status='Supported';mode=$mode;transport=$transport;clientCount=$count;multiplayer='Requested';reason=$null}
    }
    if($mode -eq 'HistoricalDedicatedEquivalent' -and $transport -eq 'HistoricalDedicatedEquivalent' -and $count -ge 1){
        if(-not $oldRelease){return [pscustomobject]@{status='Unsupported';mode='Unsupported';transport=$transport;clientCount=$count;multiplayer='Unsupported';dimensionStatus=[pscustomobject]@{NativeIntegratedLAN=if($minecraftId){'NotHistoricalTarget'}else{'Unknown'};HistoricalDedicatedEquivalent='Unsupported'};reason=if($minecraftId){'HISTORICAL_EQUIVALENT_NOT_APPLICABLE_TO_MODERN_VERSION'}else{'HISTORICAL_TARGET_VERSION_REQUIRED'}}}
        if(-not [bool](Get-MmtlScenarioProperty $TargetCapabilities 'historicalDedicatedEquivalent' $false)){return [pscustomobject]@{status='Unsupported';mode='Unsupported';transport=$transport;clientCount=$count;multiplayer='Unsupported';dimensionStatus=[pscustomobject]@{NativeIntegratedLAN='UnsupportedByMinecraftVersion';HistoricalDedicatedEquivalent='Unsupported'};reason='HISTORICAL_DEDICATED_UNSUPPORTED'}}
        $artifactPath=[string](Get-MmtlScenarioProperty $TargetCapabilities 'historicalServerArtifactPath' '')
        $artifact=if($artifactPath){Resolve-MmtlHistoricalDedicatedServerArtifact -TargetId $targetId -MinecraftId $minecraftId -ArtifactPath $artifactPath}else{$null}
        $artifactTrusted=$null -ne $artifact -and [string]$artifact.status -ceq 'VerifiedHistorical' -and [string]$artifact.targetId -ceq $targetId -and
            [string]$artifact.minecraftId -ceq $minecraftId -and [bool]$artifact.exactLoaderServerReady -and
            [string]$artifact.artifactRole -ceq 'LoaderReadyServer' -and [string]$artifact.catalogSha256 -match '^(?i:[a-f0-9]{64})$' -and
            [string]$artifact.sourceEvidenceSha256 -match '^(?i:[a-f0-9]{64})$' -and [string]$artifact.sourceType -ceq 'OfficialManifest'
        if(-not $artifactTrusted){return [pscustomobject]@{status='Unsupported';mode='Unsupported';transport=$transport;clientCount=$count;multiplayer='Unsupported';dimensionStatus=[pscustomobject]@{NativeIntegratedLAN='UnsupportedByMinecraftVersion';HistoricalDedicatedEquivalent='Blocked'};reason='HISTORICAL_SERVER_ARTIFACT_NOT_TRUSTED'}}
        return [pscustomobject]@{status='Supported';mode=$mode;transport=$transport;clientCount=$count;multiplayer='HistoricalDedicatedEquivalent';dimensionStatus=[pscustomobject]@{NativeIntegratedLAN='UnsupportedByMinecraftVersion';HistoricalDedicatedEquivalent='Requested'};historicalServerArtifact=$artifact;reason=$null}
    }
    throw 'SCENARIO_MODE_CONFIGURATION_CONFLICT'
}

function New-MmtlScenarioPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Single','IntegratedLAN','Dedicated','HistoricalDedicatedEquivalent')][string]$Mode,
        [ValidateRange(0,100000)][int]$Players=0,
        [ValidateRange(0,100000)][int]$ClientCount=0,
        [string]$HostUsername='MMTL_Host',
        [string]$GuestPrefix='MMTL_C',
        [string]$GuestNamePattern,
        [switch]$AutoCreateWorld,
        [ValidateRange(1,8)][int]$MaximumConcurrentInstances=8,
        [ValidateRange(1,600)][int]$ReadyTimeoutSeconds=180,
        [ValidateRange(1,600)][int]$JoinTimeoutSeconds=120,
        [ValidateRange(1,600)][int]$DurationSeconds=60
    )
    if($ClientCount -gt 0 -and $Players -gt 0 -and $ClientCount -ne $Players){throw 'SCENARIO_CLIENT_COUNT_CONFLICT'}
    $clientCount=if($ClientCount -gt 0){$ClientCount}else{$Players}
    if($clientCount -lt 1){throw 'SCENARIO_CLIENT_COUNT_REQUIRED'}
    if($Mode -eq 'Single' -and $clientCount -ne 1){throw 'SCENARIO_SINGLE_REQUIRES_ONE_PLAYER'}
    if($Mode -eq 'IntegratedLAN' -and $clientCount -lt 2){throw 'SCENARIO_INTEGRATED_LAN_REQUIRES_HOST_AND_GUEST'}
    if($Mode -in @('Dedicated','HistoricalDedicatedEquivalent') -and $clientCount -lt 1){throw 'SCENARIO_DEDICATED_REQUIRES_CLIENT'}
    foreach($name in @($HostUsername,$GuestPrefix)){if($name -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'SCENARIO_IDENTITY_INVALID'}}
    if($GuestNamePattern){if(([regex]::Matches($GuestNamePattern,'\{index\}')).Count -ne 1 -or $GuestNamePattern -replace '\{index\}','' -match '[{}]'){throw 'SCENARIO_GUEST_PATTERN_INVALID'}}
    elseif($Mode -eq 'IntegratedLAN' -and $GuestPrefix.Length -ge 16){throw 'SCENARIO_GUEST_PREFIX_TOO_LONG'}
    $roles=[Collections.Generic.List[object]]::new()
    if($Mode -eq 'Single'){$roles.Add([pscustomobject]@{role='Client';username=$HostUsername;ordinal=0})}
    elseif($Mode -eq 'IntegratedLAN'){
        $roles.Add([pscustomobject]@{role='Host';username=$HostUsername;ordinal=0})
        for($i=1;$i -lt $clientCount;$i++){$username=if($GuestNamePattern){$GuestNamePattern.Replace('{index}',[string]$i)}else{"$GuestPrefix$i"};if($username -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'SCENARIO_USERNAME_TOO_LONG'};$roles.Add([pscustomobject]@{role='Guest';username=$username;ordinal=$i})}
    }else{
        $roles.Add([pscustomobject]@{role='Server';username='';ordinal=0})
        for($i=0;$i -lt $clientCount;$i++){$username=if($i -eq 0){$HostUsername}elseif($GuestNamePattern){$GuestNamePattern.Replace('{index}',[string]$i)}else{"$GuestPrefix$i"};if($username -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'SCENARIO_USERNAME_TOO_LONG'};$roles.Add([pscustomobject]@{role='Client';username=$username;ordinal=$i+1})}
    }
    $names=@($roles|Where-Object username|ForEach-Object username)
    if(@($names|Select-Object -Unique).Count -ne $names.Count){throw 'SCENARIO_IDENTITY_COLLISION'}
    if($roles.Count -gt $MaximumConcurrentInstances){throw 'SCENARIO_CONCURRENCY_LIMIT_EXCEEDED'}
    $steps=switch($Mode){
        'Single' {@('Build','CreateSession','StartClient','Observe','Analyze','SafeStop')}
        'IntegratedLAN' {@('Build','CreateSession','StartHost','CreateOrLoadWorld','WaitHostWorld','WaitAgentLanReady','StartGuests','WaitGuestWorlds','Observe','Analyze','SafeStop')}
        {$_ -in @('Dedicated','HistoricalDedicatedEquivalent')} {@('Build','CreateSession','StartServer','WaitServerReady','StartClients','Observe','Analyze','SafeStop')}
    }
    $lifecycleStages=if($Mode -eq 'IntegratedLAN'){@('HostStarting','HostReady','WorldReady','LanPublishing','LanReady','GuestsStarting','GuestsReady','Asserting','Stopping')}elseif($Mode -eq 'Single'){@('ClientStarting','ClientReady','Asserting','Stopping')}else{@('ServerStarting','ServerReady','ClientsStarting','ClientsReady','Asserting','Stopping')}
    [pscustomobject][ordered]@{schemaVersion=1;mode=$Mode;players=$clientCount;clientCount=$clientCount;maximumConcurrentInstances=$MaximumConcurrentInstances;readyTimeoutSeconds=$ReadyTimeoutSeconds;joinTimeoutSeconds=$JoinTimeoutSeconds;durationSeconds=$DurationSeconds;stopPolicy='Always';roles=@($roles);steps=@($steps);lifecycleStages=@($lifecycleStages);autoCreateWorld=[bool]$AutoCreateWorld.IsPresent;nonInteractive=$true;loopbackOnly=($Mode -eq 'IntegratedLAN');historicalDedicatedEquivalent=($Mode -eq 'HistoricalDedicatedEquivalent');requiresAcceptedEula=($Mode -in @('Dedicated','HistoricalDedicatedEquivalent'))}
}

function Initialize-MmtlScenarioSessionMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Metadata)
    $defaults=[ordered]@{analysisStatus=$null;analysisFindingCount=$null;analysisErrorCode=$null;scenarioState=$null;sessionState=$null;runtimeProcessInventory=$null;singleWorldEvidence=$null}
    foreach($entry in $defaults.GetEnumerator()){
        if($null -eq $Metadata.PSObject.Properties[$entry.Key]){$Metadata|Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value}
    }
    return $Metadata
}

function Assert-MmtlScenarioProcessInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][int[]]$StartedProcessIds)
    $session=Assert-MmtlScenarioSessionPath -SessionPath $SessionPath
    $registry=Join-Path $session 'pids.json'
    if(-not(Test-Path -LiteralPath $registry -PathType Leaf)){throw 'SCENARIO_RUNTIME_PROCESS_INVENTORY_MISSING'}
    $item=Get-Item -LiteralPath $registry -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'SCENARIO_RUNTIME_PROCESS_INVENTORY_INVALID'}
    try{$entries=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json -ErrorAction Stop)}catch{throw 'SCENARIO_RUNTIME_PROCESS_INVENTORY_INVALID'}
    $expected=@($Plan.roles|ForEach-Object{[pscustomobject]@{Role=[string]$_.role;Username=[string]$_.username}})
    $runtimeRoles=@('Client','Host','Guest','Server')
    $actual=@($entries|Where-Object{[string]$_.Role -cin $runtimeRoles})
    $validIds=@($actual|Where-Object{[int]$_.PID -gt 0}|ForEach-Object{[int]$_.PID}|Select-Object -Unique)
    $startedIds=@($StartedProcessIds|Where-Object{$_ -gt 0}|Select-Object -Unique)
    if($actual.Count -ne $expected.Count -or $validIds.Count -ne $actual.Count -or $startedIds.Count -ne $expected.Count -or @($startedIds|Where-Object{$_ -notin $validIds}).Count -gt 0){throw 'SCENARIO_RUNTIME_PROCESS_INVENTORY_MISMATCH'}
    foreach($role in $expected){
        $matches=@($actual|Where-Object{[string]$_.Role -ceq $role.Role -and [string]$_.Username -ceq $role.Username})
        if($matches.Count -ne 1){throw 'SCENARIO_RUNTIME_PROCESS_INVENTORY_MISMATCH'}
    }
    return [pscustomobject]@{expectedRoleCount=$expected.Count;actualRoleCount=$actual.Count;processes=$actual}
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
        HostStarting=@('HostReady','Stopping','Failed');HostReady=@('WorldReady','Observing','Stopping','Failed')
        WorldReady=@('LanPublishing','Stopping','Failed');LanPublishing=@('LanReady','Stopping','Failed');LanReady=@('GuestsStarting','Stopping','Failed')
        GuestsStarting=@('GuestsReady','Stopping','Failed');GuestsReady=@('Asserting','Observing','Stopping','Failed');Asserting=@('Observing','Stopping','Failed')
        ServerStarting=@('ServerReady','Stopping','Failed');ServerReady=@('ClientsStarting','Stopping','Failed');ClientsStarting=@('ClientsReady','Stopping','Failed');ClientsReady=@('Asserting','Observing','Stopping','Failed')
        ClientStarting=@('ClientReady','Observing','Stopping','Failed');ClientReady=@('Asserting','Observing','Stopping','Failed');Observing=@('Analyzing','Stopping','Failed');Analyzing=@('Stopping','Failed');Stopping=@('Completed','Failed','Stopped')
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
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidateSet('Planned','Building','SessionReady','HostStarting','HostReady','WorldReady','LanPublishing','LanReady','GuestsStarting','GuestsReady','Asserting','ServerStarting','ServerReady','ClientsStarting','ClientsReady','ClientStarting','ClientReady','Observing','Analyzing','Stopping','Completed','Failed','Stopped')][string]$NextState,[Parameter(Mandatory)][ValidatePattern('^[A-Z][A-Z0-9_]{1,63}$')][string]$EventCode,[ValidateSet('Launcher','Host','Guest','Client','Server')][string]$Role='Launcher',[string]$Summary='')
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

Export-ModuleMember -Function Resolve-MmtlScenarioMode,New-MmtlScenarioPlan,Initialize-MmtlScenarioSessionMetadata,Assert-MmtlScenarioProcessInventory,Assert-MmtlScenarioAction,Test-MmtlScenarioTransition,Initialize-MmtlScenarioState,Set-MmtlScenarioState,Get-MmtlScenarioStatus,Add-MmtlScenarioEvent,Invoke-MmtlScenarioAction
