Set-StrictMode -Version Latest
$script:ForgeControlRepoRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $script:ForgeControlRepoRoot 'common/src/Platform/Platform.psm1') -Force
Import-Module (Join-Path $script:ForgeControlRepoRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
Import-Module (Join-Path $script:ForgeControlRepoRoot 'common/src/SessionManager.psm1') -Force
Import-Module (Join-Path $script:ForgeControlRepoRoot 'common/src/ProcessManager.psm1') -Force
Import-Module (Join-Path $script:ForgeControlRepoRoot 'common/src/Agent/AgentProvider.psm1') -Force
Import-Module (Join-Path $script:ForgeControlRepoRoot 'common/src/Agent/AgentEvents.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ForgeClientLaunch.psm1') -Force

function Write-MmtlForgeControlJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    $parent=Split-Path -Parent $Path;New-Item -ItemType Directory -Path $parent -Force|Out-Null
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temporary,(($Value|ConvertTo-Json -Depth 24)+"`n"),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $Path -Force}
    finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}

function Invoke-MmtlForgeProcessCapture {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Arguments,
        [ValidateRange(1,120000)][int]$TimeoutMilliseconds=15000
    )
    $startInfo=[Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName=$ExecutablePath
    $startInfo.Arguments=$Arguments
    $startInfo.UseShellExecute=$false
    $startInfo.CreateNoWindow=$true
    $startInfo.RedirectStandardOutput=$true
    $startInfo.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$startInfo
    try{
        if(-not $process.Start()){throw 'FORGE_PROCESS_START_FAILED'}
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutMilliseconds)){
            try{$process.Kill()}catch{}
            throw 'FORGE_PROCESS_CAPTURE_TIMEOUT'
        }
        $process.WaitForExit()
        return [pscustomobject]@{standardOutput=[string]$stdout.Result;standardError=[string]$stderr.Result;exitCode=[int]$process.ExitCode}
    }finally{$process.Dispose()}
}

function Save-MmtlForgeReportArtifacts {
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$ReportRoot,
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$MarkdownLines
    )
    $sessionReport=Join-Path $SessionPath 'report.json'
    $sessionMarkdown=Join-Path $SessionPath 'report.md'
    $root=[IO.Path]::GetFullPath($ReportRoot)
    New-Item -ItemType Directory -Path $root -Force|Out-Null
    $Report|Add-Member -NotePropertyName reportPath -NotePropertyValue (Join-Path $root "$($Report.sessionId).json") -Force
    $Report|Add-Member -NotePropertyName markdownReportPath -NotePropertyValue (Join-Path $root "$($Report.sessionId).md") -Force
    Write-MmtlForgeControlJson -Path $sessionReport -Value $Report
    [IO.File]::WriteAllLines($sessionMarkdown,$MarkdownLines,[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $sessionReport -Destination $Report.reportPath -Force
    Copy-Item -LiteralPath $sessionMarkdown -Destination $Report.markdownReportPath -Force
    return [pscustomobject]@{reportPath=$Report.reportPath;markdownReportPath=$Report.markdownReportPath}
}

function Get-MmtlForgeSessionRecord {
    param([Parameter(Mandatory)][string]$SessionId)
    $runtimeSetting=[string]$env:MMTL_FORGE_CONTROL_RUNTIME
    if(-not $runtimeSetting){$runtimeSetting=Join-Path $script:ForgeControlRepoRoot 'runtime'}
    $runtimeRoot=[IO.Path]::GetFullPath($runtimeSetting)
    if(-not $runtimeRoot){throw 'FORGE_RUNTIME_ROOT_NOT_SET'}
    $sessionPath=Join-Path (Join-Path $runtimeRoot 'sessions') $SessionId
    if(-not(Test-Path -LiteralPath $sessionPath -PathType Container)){throw 'FORGE_SESSION_NOT_FOUND'}
    $recordPath=Join-Path $sessionPath 'session.json'
    $record=Get-Content -LiteralPath $recordPath -Raw|ConvertFrom-Json -ErrorAction Stop
    if([string]$record.sessionId -cne $SessionId){throw 'FORGE_SESSION_ID_MISMATCH'}
    return [pscustomobject]@{path=$sessionPath;record=$record}
}

function Get-MmtlForgeAvailableMemoryMb {
    try{return [int][math]::Floor((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory/1024)}catch{throw 'FORGE_MEMORY_QUERY_FAILED'}
}

function Get-MmtlForgeLoopbackPort {
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    try{$listener.Start();$port=[int]$listener.LocalEndpoint.Port}finally{$listener.Stop()}
    if($port -lt 1){throw 'FORGE_LOOPBACK_PORT_RESERVATION_FAILED'}
    return $port
}

function ConvertTo-MmtlWindowsArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    if($Argument -notmatch '[\s"]'){return $Argument}
    $builder=[Text.StringBuilder]::new();[void]$builder.Append('"');$slashes=0
    foreach($character in $Argument.ToCharArray()){
        if($character -eq '\'){ $slashes++;continue }
        if($character -eq '"'){[void]$builder.Append(('\' * (2*$slashes+1)));[void]$builder.Append('"');$slashes=0;continue}
        if($slashes){[void]$builder.Append(('\' * $slashes));$slashes=0};[void]$builder.Append($character)
    }
    if($slashes){[void]$builder.Append(('\' * (2*$slashes)))};[void]$builder.Append('"')
    return $builder.ToString()
}

function Start-MmtlForgeControlClient {
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$SessionId,[Parameter(Mandatory)][string]$SessionToken,[Parameter(Mandatory)][string]$ProviderRoot,[Parameter(Mandatory)][ValidateSet('Client','Host','Guest')][string]$Role,[Parameter(Mandatory)][string]$PlayerName,[int]$LanPort=0,[int]$GuestPort=0)
    $availableMemory=Get-MmtlForgeAvailableMemoryMb;$minimumMemory=[int]$Config.memoryMb+1024
    if($availableMemory -lt $minimumMemory){throw "FORGE_RESOURCE_MEMORY_LIMIT: available=${availableMemory}MB required=${minimumMemory}MB before starting $Role/$PlayerName"}
    $plan=New-MmtlForgeClientLaunchPlan -Config $Config -SessionPath $SessionPath -Role $Role -PlayerName $PlayerName -ProviderRoot $ProviderRoot -SessionToken $SessionToken -IntegratedLanPort $LanPort -ExpectedLoopbackPort $GuestPort
    $javaw=[IO.Path]::Combine((Split-Path -Parent $plan.javaPath),'javaw.exe');$executable=if(Test-Path -LiteralPath $javaw -PathType Leaf){$javaw}else{$plan.javaPath}
    $quoted=@($plan.arguments|ForEach-Object{ConvertTo-MmtlWindowsArgument -Argument ([string]$_)})
    $logPath=Join-Path $SessionPath ("logs/{0}-{1}.stdout.log" -f $Role,$PlayerName)
    $tracked=Start-MmtlTrackedProcess -SessionPath $SessionPath -FilePath $executable -ArgumentList $quoted -WorkingDirectory $plan.workingDirectory -LogPath $logPath -Role $Role -Username $PlayerName -PassThru
    $identity=Get-MmtlProcessRecord -ProcessId $tracked.ProcessId
    if(-not $identity){throw 'FORGE_PROCESS_IDENTITY_UNAVAILABLE'}
    $eventPath=[string]$plan.eventSink
    return [pscustomobject][ordered]@{instanceId=$plan.instanceId;playerName=$PlayerName;role=$Role;processId=[int]$tracked.ProcessId;processIdentity=[string]$identity.StartIdentity;executable=$executable;gameDirectory=$plan.gameDirectory;javaPath=$plan.javaPath;versionId=$plan.versionId;forgeVersion=$plan.forgeVersion;eventPath=$eventPath;logPath=$logPath;memoryAvailableBeforeStartMb=$availableMemory;startedUtc=[DateTimeOffset]::UtcNow.ToString('o');state='Starting';launchPlan=$plan}
}

function Wait-MmtlForgeAgentClient {
    param([Parameter(Mandatory)]$Client,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$SessionId,[Parameter(Mandatory)][string]$NonceHash,[ValidateSet('Client','Host','Guest')][string]$Role)
    $null=Wait-MmtlAgentClientReady -SessionPath $SessionPath -EventPath $Client.eventPath -SessionId $SessionId -Role $Role -ExpectedNonceHash $NonceHash -ProcessId $Client.processId -ProcessIdentity $Client.processIdentity -TimeoutSeconds 240
    $Client.state='ClientReady';$Client|Add-Member -NotePropertyName readyUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    try{$world=Wait-MmtlAgentWorldJoined -SessionPath $SessionPath -EventPath $Client.eventPath -SessionId $SessionId -Role $Role -ExpectedNonceHash $NonceHash -ProcessId $Client.processId -ProcessIdentity $Client.processIdentity -TimeoutSeconds 240}
    catch{
        if($_.Exception.Message -like 'GUEST_LOGIN_DISCONNECTED:*'){$_.Exception.Data['mmtlFailureStage']="waiting-guest-world:$($Client.playerName)"}
        elseif($Role -eq 'Guest'){$_.Exception.Data['mmtlFailureStage']="waiting-guest-world:$($Client.playerName)"}
        elseif($Role -eq 'Host'){$_.Exception.Data['mmtlFailureStage']='waiting-host-world'}
        else{$_.Exception.Data['mmtlFailureStage']="waiting-client-world:$($Client.playerName)"}
        throw
    }
    $Client.state='WorldJoined';$Client|Add-Member -NotePropertyName worldJoinedUtc -NotePropertyValue ([string]$world.detectedAtUtc) -Force
    $window=Get-Process -Id ([int]$Client.processId) -ErrorAction Stop
    $Client|Add-Member -NotePropertyName windowHandle -NotePropertyValue $(if($window.MainWindowHandle -ne [IntPtr]::Zero){'0x'+$window.MainWindowHandle.ToInt64().ToString('X')}else{$null}) -Force
    $Client|Add-Member -NotePropertyName windowTitle -NotePropertyValue ([string]$window.MainWindowTitle) -Force
}

function Update-MmtlForgeWindowIdentities {
    param([Parameter(Mandatory)][object[]]$Clients,[ValidateRange(1,60)][int]$TimeoutSeconds=12)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do{
        $missing=0
        foreach($client in $Clients){
            $window=Get-Process -Id ([int]$client.processId) -ErrorAction Stop;$window.Refresh()
            if($window.MainWindowHandle -eq [IntPtr]::Zero){$missing++;continue}
            $client|Add-Member -NotePropertyName windowHandle -NotePropertyValue ('0x'+$window.MainWindowHandle.ToInt64().ToString('X')) -Force
            $client|Add-Member -NotePropertyName windowTitle -NotePropertyValue ([string]$window.MainWindowTitle) -Force
        }
        if(-not $missing){return}
        Start-Sleep -Milliseconds 250
    }while([DateTime]::UtcNow -lt $deadline)
    $unobserved=@($Clients|Where-Object{-not $_.windowHandle}|ForEach-Object{$_.role+'/'+$_.playerName+' PID '+$_.processId})
    if($unobserved.Count){throw ('FORGE_WINDOW_NOT_OBSERVED: '+($unobserved -join ', '))}
}

function Start-MmtlForgeControlSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'FORGE_CONTROL_WINDOWS_ONLY'}
    $java=[IO.Path]::GetFullPath([string]$Config.javaPath)
    if(-not(Test-Path -LiteralPath $java -PathType Leaf) -or [IO.Path]::GetFileName($java) -ine 'java.exe'){throw 'FORGE_JAVA_EXE_INVALID'}
    $versionResult=Invoke-MmtlForgeProcessCapture -ExecutablePath $java -Arguments '-version'
    $versionInfo=[string]$versionResult.standardOutput+"`n"+[string]$versionResult.standardError
    if($versionResult.exitCode -ne 0 -or $versionInfo -notmatch 'version "17(?:\.|"|\+)'){throw 'FORGE_JAVA_MAJOR_MISMATCH'}
    $available=Get-MmtlForgeAvailableMemoryMb;$required=([int]$Config.memoryMb*[int]$Config.clientCount)+1536
    if($available -lt $required){throw "FORGE_RESOURCE_MEMORY_LIMIT: available=${available}MB required=${required}MB; no client was started"}
    $mode=if($Config.clientCount -eq 1){'Single'}else{'IntegratedLAN'}
    $metadata=[pscustomobject]@{mode=$mode;players=[int]$Config.clientCount;hostUsername=[string]$Config.players[0];playerNames=@($Config.players);runtimeJavaMajor=17;runtimeJavaPath=$java;target=$Config.target;loaderVersion=$Config.target.loaderVersion;worldName=$Config.worldName;lanEnabled=[bool]$Config.lanEnabled;configPath=[string]$Config.configPath;config=$Config}
    Register-MmtlWindowsPlatform -RepositoryRoot $script:ForgeControlRepoRoot
    $env:MMTL_FORGE_CONTROL_RUNTIME=[IO.Path]::GetFullPath([string]$Config.runtimeRoot)
    $sessionPath=New-MmtlSession -RuntimeRoot $Config.runtimeRoot -Name 'forge-control' -Metadata $metadata
    $sessionId=Split-Path -Leaf $sessionPath;$started=[DateTimeOffset]::UtcNow
    $token=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $nonceHash=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($token)))).ToLowerInvariant()
    $agentRoot=Join-Path $script:ForgeControlRepoRoot 'common/agent'
    $agent=Get-MmtlAgentProviderStatus -AgentRoot $agentRoot -LoaderId Forge -MinecraftVersion '1.20.1'
    if($agent.status -cne 'Supported'){throw "FORGE_AGENT_PROVIDER_UNAVAILABLE: $($agent.reason)"}
    $sessionRecord=Get-Content -LiteralPath (Join-Path $sessionPath 'session.json') -Raw|ConvertFrom-Json
    $clients=[Collections.Generic.List[object]]::new();$port=0
    if($Config.clientCount -gt 1){$port=Get-MmtlForgeLoopbackPort}
    $failureStage='client-start'
    try{
        if($Config.clientCount -eq 1){
            $failureStage="starting-client:$($Config.players[0])"
            $client=Start-MmtlForgeControlClient -Config $Config -SessionPath $sessionPath -SessionId $sessionId -SessionToken $token -ProviderRoot $agentRoot -Role Client -PlayerName $Config.players[0]
            $clients.Add($client);$sessionRecord.testIdentities|Where-Object username -eq $client.playerName|ForEach-Object{$_.processIdentity=$client.processIdentity}
            $failureStage="waiting-client-ready:$($client.playerName)"
            Wait-MmtlForgeAgentClient -Client $client -SessionPath $sessionPath -SessionId $sessionId -NonceHash $nonceHash -Role Client
        }else{
            $failureStage="starting-host:$($Config.players[0])"
            $hostClient=Start-MmtlForgeControlClient -Config $Config -SessionPath $sessionPath -SessionId $sessionId -SessionToken $token -ProviderRoot $agentRoot -Role Host -PlayerName $Config.players[0] -LanPort $port
            $clients.Add($hostClient);$sessionRecord.testIdentities|Where-Object username -eq $hostClient.playerName|ForEach-Object{$_.processIdentity=$hostClient.processIdentity}
            $failureStage='waiting-host-ready'
            Wait-MmtlForgeAgentClient -Client $hostClient -SessionPath $sessionPath -SessionId $sessionId -NonceHash $nonceHash -Role Host
            $hostClient.state='PublishingLAN'
            $failureStage='waiting-host-lan-publish'
            $lan=Wait-MmtlAgentIntegratedLanReady -SessionPath $sessionPath -EventPath $hostClient.eventPath -SessionId $sessionId -ExpectedNonceHash $nonceHash -Port $port -ProcessId $hostClient.processId -ProcessIdentity $hostClient.processIdentity -TimeoutSeconds 60
            $hostClient|Add-Member -NotePropertyName lan -NotePropertyValue $lan -Force;$hostClient.state='LANReady'
            foreach($name in @($Config.players|Select-Object -Skip 1)){
                $failureStage="starting-guest:$name"
                $client=Start-MmtlForgeControlClient -Config $Config -SessionPath $sessionPath -SessionId $sessionId -SessionToken $token -ProviderRoot $agentRoot -Role Guest -PlayerName $name -GuestPort $port
                $clients.Add($client);$sessionRecord.testIdentities|Where-Object username -eq $client.playerName|ForEach-Object{$_.processIdentity=$client.processIdentity}
                $failureStage="waiting-guest-ready:$name"
                Wait-MmtlForgeAgentClient -Client $client -SessionPath $sessionPath -SessionId $sessionId -NonceHash $nonceHash -Role Guest
                $failureStage="waiting-guest-join:$name"
                $guest=Wait-MmtlAgentGuestJoined -SessionPath $sessionPath -EventPath $client.eventPath -SessionId $sessionId -ExpectedNonceHash $nonceHash -Port $port -ProcessId $client.processId -ProcessIdentity $client.processIdentity -TimeoutSeconds 120
                $client|Add-Member -NotePropertyName guestJoin -NotePropertyValue $guest -Force;$client.state='GuestJoined'
            }
            $failureStage='asserting-host-player-list'
            $players=Wait-MmtlAgentHostPlayersJoined -SessionPath $sessionPath -EventPath $hostClient.eventPath -SessionId $sessionId -ExpectedNonceHash $nonceHash -PlayerNames @($Config.players) -ProcessId $hostClient.processId -ProcessIdentity $hostClient.processIdentity -TimeoutSeconds 60
            $hostClient|Add-Member -NotePropertyName observedPlayers -NotePropertyValue $players -Force
        }
        $failureStage='observing-game-windows'
        Update-MmtlForgeWindowIdentities -Clients @($clients.ToArray())
        $sessionRecord.processes=@($clients|ForEach-Object{[pscustomobject]@{pid=$_.processId;role=$_.role;playerName=$_.playerName;processIdentity=$_.processIdentity;windowHandle=$_.windowHandle;windowTitle=$_.windowTitle;gameDirectory=$_.gameDirectory;eventPath=$_.eventPath;logPath=$_.logPath;startedUtc=$_.startedUtc;state=$_.state}})
        $sessionRecord.ports=if($port){@([pscustomobject]@{port=$port;bindAddress='127.0.0.1';purpose='IntegratedLAN'})}else{@()}
        $joinedRoles=@($clients|Where-Object{$_.worldJoinedUtc}|ForEach-Object{$_.role+':'+$_.playerName})
        $observedPlayers=if($port -gt 0){@($hostClient.observedPlayers.joinedPlayers)}else{@()}
        $sessionRecord|Add-Member -NotePropertyName gameAssertions -NotePropertyValue ([pscustomobject]@{worldJoinedRoles=$joinedRoles;hostObservedPlayers=$observedPlayers;integratedLan=$port -gt 0}) -Force
        $finalStatus=if($port){'RunningLAN'}else{'RunningSingle'}
        $sessionRecord|Add-Member -NotePropertyName status -NotePropertyValue $finalStatus -Force
        $sessionRecord|Add-Member -NotePropertyName startedUtc -NotePropertyValue $started.ToString('o') -Force
        $sessionRecord|Add-Member -NotePropertyName config -NotePropertyValue $Config -Force
        Write-MmtlForgeControlJson -Path (Join-Path $sessionPath 'session.json') -Value $sessionRecord
        $clientSummary=@($clients|ForEach-Object{[pscustomobject]@{instanceId=$_.instanceId;playerName=$_.playerName;role=$_.role;processId=$_.processId;processIdentity=$_.processIdentity;windowHandle=$_.windowHandle;windowTitle=$_.windowTitle;executable=$_.executable;gameDirectory=$_.gameDirectory;javaPath=$_.javaPath;versionId=$_.versionId;forgeVersion=$_.forgeVersion;eventPath=$_.eventPath;logPath=$_.logPath;memoryAvailableBeforeStartMb=$_.memoryAvailableBeforeStartMb;startedUtc=$_.startedUtc;readyUtc=$_.readyUtc;worldJoinedUtc=$_.worldJoinedUtc;state=$_.state}})
        $result=[pscustomobject][ordered]@{sessionId=$sessionId;sessionPath=$sessionPath;status=[string]$sessionRecord.status;config=$Config;clients=$clientSummary;lanPort=$port;gameAssertions=$sessionRecord.gameAssertions;startedUtc=$started.ToString('o');memoryAtStartMb=$available;reportPath=(Join-Path $sessionPath 'report.json')}
        Write-MmtlForgeControlJson -Path $result.reportPath -Value $result
        return $result
    }catch{
        $originalError=$_
        if($originalError.Exception.Data.Contains('mmtlFailureStage')){$failureStage=[string]$originalError.Exception.Data['mmtlFailureStage']}
        $failureTime=[DateTimeOffset]::UtcNow
        $processEntries=@(Get-Content -LiteralPath (Join-Path $sessionPath 'pids.json') -Raw|ConvertFrom-Json -ErrorAction SilentlyContinue)
        $knownByPid=@{}
        foreach($client in $clients){$knownByPid[[string]$client.processId]=$client}
        foreach($entry in $processEntries){
            $key=[string][int]$entry.PID
            if(-not $knownByPid.ContainsKey($key)){
                $knownByPid[$key]=[pscustomobject]@{instanceId=$null;processId=[int]$entry.PID;processIdentity=[string]$entry.StartIdentity;role=[string]$entry.Role;playerName=[string]$entry.Username;gameDirectory=[string]$entry.WorkingDirectory;eventPath=$null;logPath=[string]$entry.LogPath;state='StartedButNotReturned'}
                $commandLine=[string]$entry.CommandLine
                if($commandLine -match '(?i)-Dmmtl\.agent\.eventSink=([^\s]+)'){$knownByPid[$key].eventPath=$Matches[1]}
            }
        }
        $sessionRecord|Add-Member -NotePropertyName status -NotePropertyValue 'Failed' -Force
        $sessionRecord|Add-Member -NotePropertyName failure -NotePropertyValue ([string]$originalError.Exception.Message) -Force
        $sessionRecord|Add-Member -NotePropertyName failureStage -NotePropertyValue $failureStage -Force
        $sessionRecord|Add-Member -NotePropertyName failedUtc -NotePropertyValue $failureTime.ToString('o') -Force
        $sessionRecord|Add-Member -NotePropertyName startedUtc -NotePropertyValue $started.ToString('o') -Force
        $sessionRecord|Add-Member -NotePropertyName config -NotePropertyValue $Config -Force
        $sessionRecord|Add-Member -NotePropertyName processes -NotePropertyValue @($knownByPid.Values|Sort-Object processId|ForEach-Object{[pscustomobject]@{pid=$_.processId;role=$_.role;playerName=$_.playerName;processIdentity=$_.processIdentity;eventPath=$_.eventPath;logPath=$_.logPath;gameDirectory=$_.gameDirectory;state=$_.state}}) -Force
        $sessionRecord|Add-Member -NotePropertyName ports -NotePropertyValue $(if($port){@([pscustomobject]@{port=$port;bindAddress='127.0.0.1';purpose='IntegratedLAN'})}else{@()}) -Force
        Write-MmtlForgeControlJson -Path (Join-Path $sessionPath 'session.json') -Value $sessionRecord

        $stopResults=[Collections.Generic.List[object]]::new()
        foreach($client in @($knownByPid.Values|Sort-Object @{Expression={if($_.role -eq 'Host'){0}else{1}}},processId)){
            try{$stopResults.Add((Stop-MmtlForgeClient -SessionPath $sessionPath -Client ([pscustomobject]@{processId=$client.processId;processIdentity=$client.processIdentity;role=$client.role;playerName=$client.playerName}) -TimeoutSeconds 10))}
            catch{$stopResults.Add([pscustomobject]@{processId=[int]$client.processId;stopped=$false;graceful=$false;method='StopFailed';error=$_.Exception.Message})}
        }

        $joinedRoles=[Collections.Generic.List[string]]::new();$hostObserved=[Collections.Generic.List[string]]::new();$lanPublished=$false;$validEvents=[Collections.Generic.List[object]]::new()
        foreach($client in $knownByPid.Values){
            if(-not $client.eventPath -or -not(Test-Path -LiteralPath $client.eventPath -PathType Leaf)){continue}
            $snapshot=Get-MmtlAgentEventSnapshot -Path $client.eventPath
            if(-not $snapshot.success){continue}
            foreach($line in $snapshot.lines){
                try{$observation=ConvertFrom-MmtlAgentEventLine -Line $line -ExpectedSessionId $sessionId -ExpectedRole $client.role -ExpectedNonceHash $nonceHash -ProcessId $client.processId -ProcessIdentity $client.processIdentity;$agentRecord=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue}
                $validEvents.Add($observation)
                if([string]$agentRecord.eventType -ceq 'WORLD_JOINED'){$joinedRoles.Add(([string]$client.role+':'+[string]$client.playerName))}
                if([string]$client.role -ceq 'Host' -and [string]$agentRecord.eventType -ceq 'PLAYER_JOINED' -and $agentRecord.playerName){$hostObserved.Add([string]$agentRecord.playerName)}
                if([string]$client.role -ceq 'Host' -and [string]$agentRecord.eventType -ceq 'LAN_PUBLISHED' -and [string]$agentRecord.bindAddress -ceq '127.0.0.1' -and [int]$agentRecord.port -gt 0){$lanPublished=$true}
            }
        }
        $gameAssertions=[pscustomobject]@{worldJoinedRoles=@($joinedRoles.ToArray()|Select-Object -Unique);hostObservedPlayers=@($hostObserved.ToArray()|Select-Object -Unique);integratedLan=$lanPublished}
        $sessionRecord|Add-Member -NotePropertyName gameAssertions -NotePropertyValue $gameAssertions -Force
        $sessionRecord|Add-Member -NotePropertyName stopResults -NotePropertyValue @($stopResults.ToArray()) -Force
        $sessionRecord|Add-Member -NotePropertyName stoppedUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
        Write-MmtlForgeControlJson -Path (Join-Path $sessionPath 'session.json') -Value $sessionRecord

        $reportProcesses=@($knownByPid.Values|ForEach-Object{
            $client=$_;$exitPath=Join-Path $sessionPath "process-$($client.processId).exit.json";$exitRecord=$null
            if(Test-Path -LiteralPath $exitPath){try{$exitRecord=Get-Content -LiteralPath $exitPath -Raw|ConvertFrom-Json}catch{}}
            [pscustomobject]@{instanceId=$client.instanceId;pid=[int]$client.processId;processIdentity=$client.processIdentity;role=$client.role;playerName=$client.playerName;state=$client.state;gameDirectory=$client.gameDirectory;eventPath=$client.eventPath;stdoutLogPath=$client.logPath;minecraftLogPath=$(if($client.gameDirectory){Join-Path $client.gameDirectory 'logs/latest.log'}else{$null});debugLogPath=$(if($client.gameDirectory){Join-Path $client.gameDirectory 'logs/debug.log'}else{$null});exitCode=$(if($exitRecord){$exitRecord.ExitCode}else{$null});stopRequested=[bool]($exitRecord -and $exitRecord.StopRequested)}
        })
        $report=[pscustomobject]@{schemaVersion=1;sessionId=$sessionId;target=$Config.target;status='Failed';testStatus='FAIL';failureStage=$failureStage;error=[string]$originalError.Exception.Message;originalError=[pscustomobject]@{exceptionType=$originalError.Exception.GetType().FullName;message=$originalError.Exception.Message;stackTrace=$originalError.ScriptStackTrace;fullyQualifiedErrorId=$originalError.FullyQualifiedErrorId};config=$Config;processes=$reportProcesses;ports=@($sessionRecord.ports);gameAssertions=$gameAssertions;completedAssertions=[pscustomobject]@{hostLanPublished=$lanPublished;worldJoinedInstances=$gameAssertions.worldJoinedRoles;hostObservedPlayers=$gameAssertions.hostObservedPlayers;expectedPlayers=@($Config.players);allExpectedPlayersObserved=(@($gameAssertions.hostObservedPlayers|Select-Object -Unique).Count -eq @($Config.players).Count)};stopResults=@($stopResults.ToArray());validatedAgentEventCount=$validEvents.Count;startedUtc=$started.ToString('o');failedUtc=$failureTime.ToString('o');stoppedUtc=$sessionRecord.stoppedUtc}
        $markdown=@('# MMTL Forge 1.20.1 启动失败报告',"",'- Session：'+$sessionId,'- 状态：FAIL','- 失败阶段：'+$failureStage,'- 原始错误：'+$originalError.Exception.Message,'- 异常类型：'+$originalError.Exception.GetType().FullName,'- 开始时间：'+$started.ToString('o'),'- 失败时间：'+$failureTime.ToString('o'),'- 停止时间：'+$sessionRecord.stoppedUtc,'', '## 已启动客户端')
        foreach($process in $reportProcesses){$markdown+=('- '+$process.role+' / '+$process.playerName+' / PID '+$process.pid+' / state='+$process.state+' / exit='+$process.exitCode+' / stopRequested='+$process.stopRequested);$markdown+=('  - stdout: '+$process.stdoutLogPath);$markdown+=('  - latest.log: '+$process.minecraftLogPath);$markdown+=('  - Agent JSONL: '+$process.eventPath)}
        $markdown+=@('', '## 已完成断言',('- LAN 已发布：'+$lanPublished),('- 已进入世界：'+(@($gameAssertions.worldJoinedRoles) -join ', ')),('- Host 已观察玩家：'+(@($gameAssertions.hostObservedPlayers) -join ', ')),('- 已验证 Agent 事件数：'+$validEvents.Count),'','## 安全停止结果')
        foreach($result in $stopResults){$stopError=if($result.PSObject.Properties['error']){[string]$result.error}else{''};$markdown+=('- PID '+$result.processId+'：stopped='+$result.stopped+'；graceful='+$result.graceful+'；method='+$result.method+'；error='+$stopError)}
        $markdown+=@('', '## 原始堆栈',([string]$originalError.ScriptStackTrace))
        Save-MmtlForgeReportArtifacts -SessionPath $sessionPath -ReportRoot ([string]$Config.reportRoot) -Report $report -MarkdownLines $markdown|Out-Null
        throw $originalError
    }
}

function Get-MmtlForgeControlSessionStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionId)
    $session=Get-MmtlForgeSessionRecord -SessionId $SessionId;$entries=@(Get-Content -LiteralPath (Join-Path $session.path 'pids.json') -Raw|ConvertFrom-Json);$processes=[Collections.Generic.List[object]]::new()
    foreach($entry in $entries){$current=Get-MmtlProcessRecord -ProcessId ([int]$entry.PID);$alive=[bool]($current -and (Test-MmtlProcessIdentity -Process $current -Record $entry));$processes.Add([pscustomobject]@{processId=[int]$entry.PID;role=[string]$entry.Role;playerName=[string]$entry.Username;running=$alive;processIdentity=[string]$entry.StartIdentity;logPath=[string]$entry.LogPath})}
    $status=if($session.record.PSObject.Properties['status']){[string]$session.record.status}else{'Created'}
    $ports=[Collections.Generic.List[int]]::new();foreach($portRecord in @($session.record.ports)){if($null -ne $portRecord -and $portRecord.PSObject.Properties['port']){$ports.Add([int]$portRecord.port)}}
    return [pscustomobject]@{sessionId=$SessionId;status=$status;processes=@($processes.ToArray());lanPort=@($ports.ToArray());reportPath=(Join-Path $session.path 'report.json')}
}

function Stop-MmtlForgeClient {
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$Client,[ValidateRange(1,120)][int]$TimeoutSeconds=45)
    $process=Get-Process -Id ([int]$Client.processId) -ErrorAction SilentlyContinue
    if(-not $process){$entries=@(Get-Content -LiteralPath (Join-Path $SessionPath 'pids.json') -Raw|ConvertFrom-Json);$entry=$entries|Where-Object{[int]$_.PID -eq [int]$Client.processId}|Select-Object -First 1;$exitPath=if($entry.StatePath){[string]$entry.StatePath}else{Join-Path $SessionPath "process-$([int]$Client.processId).exit.json"};$exitRecord=if(Test-Path -LiteralPath $exitPath){Get-Content -LiteralPath $exitPath -Raw|ConvertFrom-Json}else{$null};$sessionRecord=Get-Content -LiteralPath (Join-Path $SessionPath 'session.json') -Raw|ConvertFrom-Json;$priorResult=@($sessionRecord.stopResults|Where-Object{[int]$_.processId -eq [int]$Client.processId -and $_.stopped -and $_.graceful})|Select-Object -First 1;$wasRequested=[bool](($exitRecord -and $exitRecord.StopRequested) -or $priorResult);return [pscustomobject]@{processId=[int]$Client.processId;stopped=$true;graceful=$wasRequested;method=$(if($wasRequested){'AlreadyStoppedByController'}else{'UnexpectedlyExited'})}}
    $current=Get-MmtlProcessRecord -ProcessId ([int]$Client.processId)
    $registry=Join-Path $SessionPath 'pids.json';$entries=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json);$registered=$entries|Where-Object{[int]$_.PID -eq [int]$Client.processId}|Select-Object -First 1
    if(-not $current -or -not $registered -or -not(Test-MmtlProcessIdentity -Process $current -Record $registered)){throw 'FORGE_PROCESS_IDENTITY_MISMATCH_REFUSE_STOP'}
    $requested=$false;try{$requested=[bool]$process.CloseMainWindow()}catch{}
    if($requested -and $process.WaitForExit($TimeoutSeconds*1000)){
        $completeIdentity=if($registered.StartIdentity -is [DateTime]){$registered.StartIdentity.ToUniversalTime().ToString('o')}else{[string]$registered.StartIdentity}
        Complete-MmtlTrackedProcess -SessionPath $SessionPath -Process $process -StartIdentity $completeIdentity -StopRequested|Out-Null
        return [pscustomobject]@{processId=[int]$Client.processId;stopped=$true;graceful=$true;method='CloseMainWindow'}
    }
    $result=Stop-MmtlTrackedProcess -SessionPath $SessionPath -ProcessId ([int]$Client.processId) -Confirm:$false
    return [pscustomobject]@{processId=[int]$Client.processId;stopped=[bool]$result;graceful=$false;method='TrackedProcessTreeFallback'}
}

function Stop-MmtlForgeControlSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionId,[ValidateRange(1,120)][int]$TimeoutSeconds=45)
    $session=Get-MmtlForgeSessionRecord -SessionId $SessionId;$manifest=$session.record;$entries=@(Get-Content -LiteralPath (Join-Path $session.path 'pids.json') -Raw|ConvertFrom-Json);$results=[Collections.Generic.List[object]]::new()
    foreach($processInfo in @($manifest.processes)){$window=Get-Process -Id ([int]$processInfo.pid) -ErrorAction SilentlyContinue;if($window){$window.Refresh();if($window.MainWindowHandle -ne [IntPtr]::Zero){$processInfo|Add-Member -NotePropertyName windowHandle -NotePropertyValue ('0x'+$window.MainWindowHandle.ToInt64().ToString('X')) -Force;$processInfo|Add-Member -NotePropertyName windowTitle -NotePropertyValue ([string]$window.MainWindowTitle) -Force}};if(-not $processInfo.PSObject.Properties['windowHandle']){$processInfo|Add-Member -NotePropertyName windowHandle -NotePropertyValue $null};if(-not $processInfo.PSObject.Properties['windowTitle']){$processInfo|Add-Member -NotePropertyName windowTitle -NotePropertyValue $null}}
    foreach($entry in @($entries|Sort-Object @{Expression={if($_.Role -eq 'Host'){1}else{0}}})){
        $client=[pscustomobject]@{processId=[int]$entry.PID;processIdentity=[string]$entry.StartIdentity;role=[string]$entry.Role;playerName=[string]$entry.Username}
        $results.Add((Stop-MmtlForgeClient -SessionPath $session.path -Client $client -TimeoutSeconds $TimeoutSeconds))
    }
    $manifest.status='Stopped';$manifest|Add-Member -NotePropertyName stoppedUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force;$manifest|Add-Member -NotePropertyName stopResults -NotePropertyValue @($results.ToArray()) -Force
    Write-MmtlForgeControlJson -Path (Join-Path $session.path 'session.json') -Value $manifest
    $joinedRoles=[Collections.Generic.List[string]]::new();$hostObserved=[Collections.Generic.List[string]]::new();$publishedLan=$false
    foreach($processInfo in @($manifest.processes)){
        $eventFile=[string]$processInfo.eventPath
        if(-not(Test-Path -LiteralPath $eventFile -PathType Leaf)){continue}
        foreach($line in Get-Content -LiteralPath $eventFile){try{$event=$line|ConvertFrom-Json -ErrorAction Stop}catch{continue};if([string]$event.sessionId -cne $SessionId){continue};if([string]$event.role -cne [string]$processInfo.role){continue};if([string]$event.eventType -ceq 'WORLD_JOINED'){$joinedRoles.Add(([string]$processInfo.role+':'+[string]$processInfo.playerName))};if([string]$processInfo.role -ceq 'Host' -and [string]$event.eventType -ceq 'PLAYER_JOINED' -and $event.playerName){$hostObserved.Add([string]$event.playerName)};if([string]$event.eventType -ceq 'LAN_PUBLISHED' -and [string]$event.bindAddress -ceq '127.0.0.1' -and [int]$event.port -gt 0){$publishedLan=$true}}
    }
    $gameAssertions=[pscustomobject]@{worldJoinedRoles=@($joinedRoles.ToArray()|Select-Object -Unique);hostObservedPlayers=@($hostObserved.ToArray()|Select-Object -Unique);integratedLan=$publishedLan}
    $manifest|Add-Member -NotePropertyName gameAssertions -NotePropertyValue $gameAssertions -Force
    $expectedCount=[int]$manifest.metadata.players;$joinedCount=if($gameAssertions){@($gameAssertions.worldJoinedRoles).Count}else{0}
    $gamePass=($joinedCount -eq $expectedCount)
    if([bool]$manifest.metadata.lanEnabled){$gamePass=$gamePass -and $null -ne $gameAssertions -and [bool]$gameAssertions.integratedLan -and @($gameAssertions.hostObservedPlayers).Count -eq $expectedCount}
    $integratedLan=if($gameAssertions){[bool]$gameAssertions.integratedLan}else{$false};$worldJoinedSummary=if($gameAssertions){@($gameAssertions.worldJoinedRoles)}else{@()};$hostPlayersSummary=if($gameAssertions){@($gameAssertions.hostObservedPlayers)}else{@()}
    $listenerReleased=$true;$portChecks=[Collections.Generic.List[object]]::new()
    foreach($portRecord in @($manifest.ports)){
        if($null -eq $portRecord -or -not $portRecord.PSObject.Properties['port']){continue}
                    $released=$false;$releaseDeadline=[DateTime]::UtcNow.AddSeconds(15)
                    do{try{$listeners=@(Get-NetTCPConnection -State Listen -LocalPort ([int]$portRecord.port) -ErrorAction Stop);if($listeners.Count -eq 0){$released=$true;break}}catch{if($_.Exception.Message -match '未找到匹配的 MSFT_NetTCPConnection 对象|No MSFT_NetTCPConnection objects found'){$released=$true;break}};if(-not $released){Start-Sleep -Milliseconds 250}}while([DateTime]::UtcNow -lt $releaseDeadline)
        if(-not $released){$listenerReleased=$false};$portChecks.Add([pscustomobject]@{port=[int]$portRecord.port;released=$released})
    }
    $stopPass=(@($results|Where-Object{-not $_.stopped -or -not $_.graceful}).Count -eq 0 -and $listenerReleased)
    $testStatus=if($gamePass -and $stopPass){'PASS'}elseif(-not $gamePass){'FAIL'}else{'PARTIAL'}
    $report=[pscustomobject]@{schemaVersion=1;sessionId=$SessionId;target=$manifest.metadata.target;status=$manifest.status;testStatus=$testStatus;error=$(if($manifest.PSObject.Properties['failure']){[string]$manifest.failure}else{$null});config=$manifest.config;processes=@($manifest.processes);ports=@($manifest.ports);gameAssertions=$gameAssertions;portReleaseChecks=@($portChecks.ToArray());stopResults=@($results.ToArray());startedUtc=$manifest.startedUtc;stoppedUtc=$manifest.stoppedUtc}
    $md=@("# MMTL Forge 控制 Session $SessionId",'','## 结果',"- 测试结果：$testStatus", "- Session 状态：$($manifest.status)","- 错误：$(if($manifest.PSObject.Properties['failure']){$manifest.failure}else{'无'})", "- 开始：$($manifest.startedUtc)","- 停止：$($manifest.stoppedUtc)","- 客户端数：$(@($manifest.processes).Count)",'','## 客户端')
    foreach($item in @($manifest.processes)){$md+="- $($item.role) / $($item.playerName) / PID $($item.pid) / 窗口 $($item.windowHandle) $($item.windowTitle) / $($item.state) / $($item.gameDirectory)"}
    $md+=@('','## 游戏断言',"- Integrated LAN：$integratedLan","- 进入世界的实例：$($worldJoinedSummary -join ', ')","- Host 观察到的玩家：$($hostPlayersSummary -join ', ')",'','## 监听端口')
    foreach($item in $portChecks){$md+="- 127.0.0.1:$($item.port) 已释放：$($item.released)"}
    $md+=@('','## 停止结果');foreach($item in $results){$md+="- PID $($item.processId)：$($item.method)；graceful=$($item.graceful)"}
    $artifacts=Save-MmtlForgeReportArtifacts -SessionPath $session.path -ReportRoot ([string]$manifest.config.reportRoot) -Report $report -MarkdownLines $md
    return [pscustomobject]@{sessionId=$SessionId;status=$manifest.status;stopResults=@($results.ToArray());reportPath=$artifacts.reportPath;markdownReportPath=$artifacts.markdownReportPath}
}

Export-ModuleMember -Function Start-MmtlForgeControlSession,Get-MmtlForgeControlSessionStatus,Stop-MmtlForgeControlSession
