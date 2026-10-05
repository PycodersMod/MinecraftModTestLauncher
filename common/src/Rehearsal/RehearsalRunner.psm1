Set-StrictMode -Version Latest

foreach ($module in @('../AtomicFile.psm1','../Execution/ExecutionPlan.psm1','../SessionManager.psm1','../SessionLifecycle.psm1','../ProcessManager.psm1','../PortManager.psm1','../Observation/RuntimeEvents.psm1','../Observation/RuntimeEventStore.psm1','../Observation/ProcessObserver.psm1','../Observation/ClientObserver.psm1','../Observation/JavaRuntimeObserver.psm1','../Observation/DedicatedServerObserver.psm1','../Observation/LanObserver.psm1','../Observation/CrashObserver.psm1')) {
    Import-Module (Join-Path $PSScriptRoot $module)
}

function ConvertTo-MmtlRehearsalProcessArgument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        $builder=[Text.StringBuilder]::new();[void]$builder.Append('"');$slashes=0
        foreach($character in $Value.ToCharArray()){
            if($character -eq '\'){$slashes++;continue}
            if($character -eq '"'){[void]$builder.Append(('\' * (2*$slashes+1)));[void]$builder.Append('"');$slashes=0;continue}
            if($slashes){[void]$builder.Append(('\' * $slashes));$slashes=0};[void]$builder.Append($character)
        }
        if($slashes){[void]$builder.Append(('\' * (2*$slashes)))};[void]$builder.Append('"');return $builder.ToString()
    }
    return '"'+$Value.Replace('\','\\').Replace('"','\"')+'"'
}

function Get-MmtlRehearsalJavaSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ExecutionPlan)
    $binding=[string]$ExecutionPlan.runtimeJava.bindingMode
    $javaPath=if($binding -eq 'SameAsBuildJvm'){[string]$ExecutionPlan.buildJava.resolution.javaPath}else{[string]$ExecutionPlan.runtimeJava.resolution.javaPath}
    if(-not $javaPath){throw 'REHEARSAL_JAVA_UNRESOLVED: Plan 未解析出可执行 Runtime Java。'}
    $buildJava=[string]$ExecutionPlan.buildJava.resolution.javaPath
    if(-not $buildJava){throw 'REHEARSAL_COMPILER_UNRESOLVED: Plan 未解析出 Build Java。'}
    $suffix=[string]$global:MmtlPlatformProvider.ExecutableSuffix
    $javaBin=Split-Path -Parent $buildJava
    $javacPath=Join-Path $javaBin ('javac'+$suffix)
    if(-not(Test-Path -LiteralPath $javaPath -PathType Leaf)){throw 'REHEARSAL_JAVA_MISSING: Plan 指定的 Runtime Java 不存在。'}
    if(-not(Test-Path -LiteralPath $javacPath -PathType Leaf)){throw 'REHEARSAL_JAVAC_MISSING: Plan 指定 Build Java 的 javac 不存在。'}
    return [pscustomobject]@{runtimeJavaPath=[IO.Path]::GetFullPath($javaPath);buildJavaPath=[IO.Path]::GetFullPath($buildJava);javacPath=[IO.Path]::GetFullPath($javacPath);bindingMode=$binding;runtimeMajor=$ExecutionPlan.runtimeJava.resolution.actualMajor;buildMajor=$ExecutionPlan.buildJava.resolution.actualMajor}
}

function Write-MmtlRehearsalMetadata {
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$ExecutionPlan)
    $path=Join-Path $SessionPath 'session.json';$state=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -ErrorAction Stop
    $state.metadata|Add-Member -NotePropertyName rehearsal -NotePropertyValue $true -Force
    $state.metadata|Add-Member -NotePropertyName validationEligible -NotePropertyValue $false -Force
    $state.metadata|Add-Member -NotePropertyName executionPlanDigest -NotePropertyValue ([string]$ExecutionPlan.semanticDigest) -Force
    Write-MmtlAtomicTextFile -Path $path -Content (($state|ConvertTo-Json -Depth 40)+"`n")
}

function Invoke-MmtlSingleLaunchRehearsal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ExecutionPlan,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [ValidateSet('normal','early-exit','crash-after-init','timeout','pid-mismatch')][string]$Scenario='normal',
        [ValidateRange(1,120)][int]$TimeoutSeconds=10
    )
    if([string]$ExecutionPlan.profile.mode -cne 'Single'){throw 'REHEARSAL_MODE_MISMATCH: Single 演练只接受 Single Execution Plan。'}
    $planCheck=Test-MmtlExecutionPlan -Plan $ExecutionPlan
    if(-not $planCheck.valid){throw "REHEARSAL_PLAN_INVALID: $($planCheck.errors -join ',')"}
    if([string]$global:MmtlPlatformProvider.ProcessManagement -ne 'Native'){throw 'REHEARSAL_PROCESS_MANAGEMENT_UNSUPPORTED: 当前平台没有 Native process identity/stop contract。'}
    $java=Get-MmtlRehearsalJavaSelection -ExecutionPlan $ExecutionPlan
    $fixtureSource=Join-Path $RepositoryRoot 'common/tests/fixtures/rehearsal/src/net/minecraft/client/main/Main.java'
    if(-not(Test-Path -LiteralPath $fixtureSource -PathType Leaf)){throw 'REHEARSAL_FIXTURE_MISSING: 未找到合成客户端 fixture。'}

    $metadata=@{project=[string]$ExecutionPlan.repository.identity;loader=[string]$ExecutionPlan.project.loader.id;minecraft=[string]$ExecutionPlan.project.minecraftId;buildJavaMajor=$java.buildMajor;runtimeJavaMajor=$java.runtimeMajor;players=1;mode='Single';rehearsal=$true;validationEligible=$false;executionPlanDigest=[string]$ExecutionPlan.semanticDigest}
    $session=New-MmtlSession -RuntimeRoot $RuntimeRoot -Name 'rehearsal_single' -Metadata $metadata
    $sessionId=Split-Path -Leaf $session;$tracked=$null;$compiled=$false;$stopResult='NotStarted';$finalState='Failed';$timeoutObserved=$false
    try {
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $ExecutionPlan|Out-Null
        Write-MmtlRehearsalMetadata -SessionPath $session -ExecutionPlan $ExecutionPlan
        Set-MmtlSessionV2State -SessionPath $session -State Launching|Out-Null
        $runner=Get-MmtlProcessRecord -ProcessId $PID
        $runnerIdentity=if($runner){[string]$runner.StartIdentity}else{'runner-'+[guid]::NewGuid().ToString('N')}
        $startedEvent=New-MmtlRuntimeEvent -SessionId $sessionId -Role Launcher -ProcessId $PID -ProcessIdentity $runnerIdentity -SourceType Rehearsal -EventCode REHEARSAL_STARTED -Summary '开始使用当前 Execution Plan 执行合成客户端演练。' -Metadata @{mode='Single';scenario=$Scenario;rehearsal=$true;validationEligible=$false}
        Write-MmtlRuntimeEvent -SessionPath $session -Event $startedEvent|Out-Null

        $classes=Join-Path $session '.rehearsal/classes';New-Item -ItemType Directory -Path $classes -Force|Out-Null
        $compileOutput=@(& $java.javacPath -encoding UTF-8 -d $classes $fixtureSource 2>&1);$compileExit=$LASTEXITCODE
        if($compileExit -ne 0){throw "REHEARSAL_FIXTURE_COMPILE_FAILED: $($compileOutput -join ' ')"};$compiled=$true

        $runtimeDirectory=Join-Path $session 'Client-MMTL_Rehearsal';$logs=Join-Path $runtimeDirectory 'logs'
        New-Item -ItemType Directory -Path $logs -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $runtimeDirectory 'mmtl-session.id'),$sessionId,[Text.UTF8Encoding]::new($false))
        $runtimeLog=Join-Path $logs 'latest.log';$processLog=Join-Path (Join-Path $session 'logs') 'client-process.log';$argumentList=[Collections.Generic.List[string]]::new()
        foreach($argument in @($ExecutionPlan.runtime.jvmArgs)){if([string]$argument){$argumentList.Add([string]$argument)}}
        foreach($argument in @('-cp',$classes,'net.minecraft.client.main.Main',$Scenario,$runtimeDirectory)+@($ExecutionPlan.runtime.gameArgs)){ $argumentList.Add((ConvertTo-MmtlRehearsalProcessArgument ([string]$argument))) }
        $tracked=Start-MmtlTrackedProcess -SessionPath $session -FilePath $java.runtimeJavaPath -ArgumentList @($argumentList.ToArray()) -WorkingDirectory $session -LogPath $processLog -Role Client -Username 'MMTL_Rehearsal' -RuntimeDirectory $runtimeDirectory -Rehearsal -PassThru

        $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);$controlPort=0
        do{
            $portFile=Join-Path $runtimeDirectory 'control.port'
            if(Test-Path -LiteralPath $portFile){$controlPort=[int](Get-Content -LiteralPath $portFile -Raw);break}
            if($tracked.Process.HasExited){break};Start-Sleep -Milliseconds 100
        }while([DateTime]::UtcNow -lt $deadline)
        if($Scenario -in @('early-exit','crash-after-init')){
            if(-not $tracked.Process.HasExited){$tracked.Process.WaitForExit([Math]::Max(1000,$TimeoutSeconds*1000))|Out-Null}
            if(-not $tracked.Process.HasExited){throw 'REHEARSAL_EXIT_SCENARIO_TIMEOUT: 合成异常场景没有按预期退出。'}
            Complete-MmtlTrackedProcess -SessionPath $session -Process $tracked.Process -StartIdentity $tracked.StartIdentity|Out-Null
        } elseif($Scenario -eq 'timeout' -or -not $controlPort){
            $observation=Invoke-MmtlProcessObserver -SessionPath $session -TimeoutSeconds ([Math]::Min(2,$TimeoutSeconds)) -PollIntervalMilliseconds 100
            $timeoutObserved=[bool]$observation.timedOut
            if(-not $tracked.Process.HasExited){$null=Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $tracked.ProcessId;$tracked.Process.WaitForExit(5000)|Out-Null}
            $stopResult=if($tracked.Process.HasExited){'StoppedAfterTimeout'}else{'StopFailed'}
        } else {
            $markerHints=@(@{eventCode='CLIENT_INIT_DETECTED';pattern='Setting user:';description='演练客户端初始化标记。'},@{eventCode='CLIENT_MAIN_MENU_DETECTED';pattern='Main menu initialized';description='演练主菜单标记。'})
            $identityMismatchObserved=$false
            if($Scenario -eq 'pid-mismatch'){
                $registryPath=Join-Path $session 'pids.json';$registered=@(Get-Content -LiteralPath $registryPath -Raw|ConvertFrom-Json);$originalIdentity=if($registered[0].StartIdentity -is [DateTime]){$registered[0].StartIdentity.ToUniversalTime().ToString('o')}else{[string]$registered[0].StartIdentity}
                try{
                    $registered[0].StartIdentity='2000-01-01T00:00:00.0000000Z'
                    Write-MmtlAtomicTextFile -Path $registryPath -Content (($registered|ConvertTo-Json -Depth 12)+"`n")
                    $identityObservation=Invoke-MmtlProcessObserver -SessionPath $session -Role Client
                    $mismatchEvent=Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines|Where-Object{$_.eventCode -eq 'PROCESS_IDENTITY_LOST' -and [int]$_.pid -eq $tracked.ProcessId}|Select-Object -First 1
                    $mismatchClient=Invoke-MmtlClientObserver -SessionPath $session -MarkerHints $markerHints
                    if($identityObservation.processes[0].status -ne 'IdentityLost' -or -not $mismatchEvent -or $mismatchClient.clients[0].validationEligible){throw 'REHEARSAL_PID_MISMATCH_NOT_REJECTED'}
                    $identityMismatchObserved=$true
                }finally{
                    $registered[0].StartIdentity=$originalIdentity
                    Write-MmtlAtomicTextFile -Path $registryPath -Content (($registered|ConvertTo-Json -Depth 12)+"`n")
                }
            }
            $observed=Invoke-MmtlClientObserver -SessionPath $session -MarkerHints $markerHints
            $javaObservation=Invoke-MmtlJavaRuntimeObserver -SessionPath $session
            $client=$observed.clients|Select-Object -First 1
            $tcp=[Net.Sockets.TcpClient]::new()
            try{$tcp.Connect([Net.IPAddress]::Loopback,$controlPort);$writer=[IO.StreamWriter]::new($tcp.GetStream(),[Text.UTF8Encoding]::new($false));$reader=[IO.StreamReader]::new($tcp.GetStream(),[Text.UTF8Encoding]::new($false));$writer.AutoFlush=$true;$writer.WriteLine('STOP');$response=$reader.ReadLine();if($response -cne 'STOPPED'){throw 'REHEARSAL_SAFE_STOP_REJECTED'};$stopResult='Graceful'}finally{$tcp.Dispose()}
            if(-not $tracked.Process.WaitForExit(5000)){throw 'REHEARSAL_PROCESS_DID_NOT_EXIT: 安全停止命令后进程仍存活。'}
            Complete-MmtlTrackedProcess -SessionPath $session -Process $tracked.Process -StartIdentity $tracked.StartIdentity -StopRequested|Out-Null
            $processObservation=Invoke-MmtlProcessObserver -SessionPath $session
            $crashObservation=Invoke-MmtlCrashObserver -SessionPath $session
            if(-not $client.initDetected -or $client.validationEligible -or $client.javaBindingMatch -ne ($javaObservation.runtimes[0].bindingMatch) -or ($Scenario -eq 'pid-mismatch' -and -not $identityMismatchObserved)){throw 'REHEARSAL_OBSERVATION_MISMATCH'}
            if(@($crashObservation.classifications).Count){throw 'REHEARSAL_NORMAL_RUN_CLASSIFIED_AS_FAILURE'}
        }

        if($Scenario -in @('early-exit','crash-after-init')){Invoke-MmtlClientObserver -SessionPath $session -MarkerHints @(@{eventCode='CLIENT_INIT_DETECTED';pattern='Setting user:';description='合成初始化标记。'})|Out-Null;Invoke-MmtlCrashObserver -SessionPath $session|Out-Null;Set-MmtlSessionV2State -SessionPath $session -State Failed|Out-Null;$finalState='Failed'}
        elseif($timeoutObserved){Set-MmtlSessionV2State -SessionPath $session -State Failed|Out-Null;$finalState='Failed'}
        else{Set-MmtlSessionV2State -SessionPath $session -State Running|Out-Null;Set-MmtlSessionV2State -SessionPath $session -State Stopped|Out-Null;$finalState='Stopped'}

        $eventCode=if($finalState -eq 'Stopped'){'REHEARSAL_COMPLETED'}else{'REHEARSAL_FAILED'}
        $finalEvent=New-MmtlRuntimeEvent -SessionId $sessionId -Role Launcher -ProcessId $PID -ProcessIdentity $runnerIdentity -SourceType Rehearsal -EventCode $eventCode -Summary "合成客户端演练结束：$finalState。" -Metadata @{mode='Single';scenario=$Scenario;rehearsal=$true;validationEligible=$false;timeoutObserved=$timeoutObserved}
        Write-MmtlRuntimeEvent -SessionPath $session -Event $finalEvent|Out-Null
        $events=@(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines)
        return [pscustomobject][ordered]@{sessionId=$sessionId;mode='Single';scenario=$Scenario;roles=@('Client');runtimeJavaMajor=$java.runtimeMajor;buildJavaMajor=$java.buildMajor;memoryMb=[long]$ExecutionPlan.runtime.memory.requestedMb;port=$null;processes=@(Get-Content -LiteralPath (Join-Path $session 'pids.json') -Raw|ConvertFrom-Json);events=$events;stopResult=$stopResult;finalSessionState=$finalState;rehearsal=$true;validationEligible=$false;compiled=$compiled;sessionPath=$session}
    }catch{
        if($tracked -and $tracked.Process -and -not $tracked.Process.HasExited){try{$null=Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $tracked.ProcessId;$tracked.Process.WaitForExit(5000)|Out-Null}catch{}}
        try{$validation=Test-MmtlSessionV2 -SessionPath $session;if($validation.valid -and $validation.state -notin @('Completed','Failed','Stopped','Abandoned')){Set-MmtlSessionV2State -SessionPath $session -State Failed|Out-Null}}catch{}
        throw
    }finally{if($tracked -and $tracked.Process){$tracked.Process.Dispose()}}
}

function Send-MmtlRehearsalStop {
    param([Parameter(Mandatory)][int]$Port)
    $tcp=[Net.Sockets.TcpClient]::new()
    try{$tcp.Connect([Net.IPAddress]::Loopback,$Port);$writer=[IO.StreamWriter]::new($tcp.GetStream(),[Text.UTF8Encoding]::new($false));$reader=[IO.StreamReader]::new($tcp.GetStream(),[Text.UTF8Encoding]::new($false));$writer.AutoFlush=$true;$writer.WriteLine('STOP');if($reader.ReadLine() -cne 'STOPPED'){throw 'REHEARSAL_SAFE_STOP_REJECTED'};return $true}finally{$tcp.Dispose()}
}

function Complete-MmtlRehearsalFailureCleanup {
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$TrackedProcess,[int]$ControlPort=0)
    $process=$TrackedProcess.Process
    if(-not $process){return}
    $process.Refresh()
    if(-not $process.HasExited -and $ControlPort){try{Send-MmtlRehearsalStop -Port $ControlPort|Out-Null;$null=$process.WaitForExit(2000)}catch{}}
    $process.Refresh()
    if(-not $process.HasExited){try{$null=Stop-MmtlTrackedProcess -SessionPath $SessionPath -ProcessId ([int]$TrackedProcess.ProcessId)}catch{}}
    $process.Refresh()
    if($process.HasExited){
        $entry=Get-Content -LiteralPath (Join-Path $SessionPath 'pids.json') -Raw|ConvertFrom-Json|Where-Object{[int]$_.PID -eq [int]$TrackedProcess.ProcessId}|Select-Object -First 1
        if($entry -and $entry.StatePath -and -not(Test-Path -LiteralPath ([string]$entry.StatePath))){try{Complete-MmtlTrackedProcess -SessionPath $SessionPath -Process $process -StartIdentity ([string]$TrackedProcess.StartIdentity)|Out-Null}catch{}}
    }
}

function Invoke-MmtlDedicatedLaunchRehearsal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ExecutionPlan,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [ValidateRange(1,120)][int]$TimeoutSeconds=15,
        [scriptblock]$PortSelector,
        [ValidateRange(0,8)][int]$FailClientAt=0
    )
    if([string]$ExecutionPlan.profile.mode -cne 'Dedicated'){throw 'REHEARSAL_MODE_MISMATCH: Dedicated 演练只接受 Dedicated Execution Plan。'}
    $planCheck=Test-MmtlExecutionPlan -Plan $ExecutionPlan
    if(-not $planCheck.valid){throw "REHEARSAL_PLAN_INVALID: $($planCheck.errors -join ',')"}
    if([string]$global:MmtlPlatformProvider.ProcessManagement -ne 'Native'){throw 'REHEARSAL_PROCESS_MANAGEMENT_UNSUPPORTED: 当前平台没有 Native process identity/stop contract。'}
    $java=Get-MmtlRehearsalJavaSelection -ExecutionPlan $ExecutionPlan
    $serverSource=Join-Path $RepositoryRoot 'common/tests/fixtures/rehearsal/src/net/minecraft/server/Main.java'
    $clientSource=Join-Path $RepositoryRoot 'common/tests/fixtures/rehearsal/src/net/minecraft/client/main/Main.java'
    foreach($source in @($serverSource,$clientSource)){if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'REHEARSAL_FIXTURE_MISSING: 未找到 Dedicated 演练所需的合成 fixture。'}}

    $clientRoles=@($ExecutionPlan.runtime.roles|Where-Object{[string]$_.role -eq 'Client'})
    if(-not $clientRoles.Count){throw 'REHEARSAL_PLAN_INVALID: Dedicated 演练至少需要一个 Client 角色。'}
    $metadata=@{project=[string]$ExecutionPlan.repository.identity;loader=[string]$ExecutionPlan.project.loader.id;minecraft=[string]$ExecutionPlan.project.minecraftId;buildJavaMajor=$java.buildMajor;runtimeJavaMajor=$java.runtimeMajor;players=$clientRoles.Count;mode='Dedicated';rehearsal=$true;validationEligible=$false;executionPlanDigest=[string]$ExecutionPlan.semanticDigest}
    $session=New-MmtlSession -RuntimeRoot $RuntimeRoot -Name 'rehearsal_dedicated' -Metadata $metadata
    $sessionId=Split-Path -Leaf $session;$server=$null;$clients=[Collections.Generic.List[object]]::new();$clientResults=[Collections.Generic.List[object]]::new();$compiled=$false;$port=0;$finalState='Failed';$portReleased=$false;$readyBeforeClients=$false
    try{
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $ExecutionPlan|Out-Null
        Write-MmtlRehearsalMetadata -SessionPath $session -ExecutionPlan $ExecutionPlan
        Set-MmtlSessionV2State -SessionPath $session -State Launching|Out-Null
        $runner=Get-MmtlProcessRecord -ProcessId $PID;$runnerIdentity=if($runner){[string]$runner.StartIdentity}else{'runner-'+[guid]::NewGuid().ToString('N')}
        $event=New-MmtlRuntimeEvent -SessionId $sessionId -Role Launcher -ProcessId $PID -ProcessIdentity $runnerIdentity -SourceType Rehearsal -EventCode REHEARSAL_STARTED -Summary '开始使用当前 Execution Plan 执行 Dedicated 合成演练。' -Metadata @{mode='Dedicated';rehearsal=$true;validationEligible=$false}
        Write-MmtlRuntimeEvent -SessionPath $session -Event $event|Out-Null
        $classes=Join-Path $session '.rehearsal/classes';New-Item -ItemType Directory -Path $classes -Force|Out-Null
        $compileOutput=@(& $java.javacPath -encoding UTF-8 -d $classes $serverSource $clientSource 2>&1);$compileExit=$LASTEXITCODE
        if($compileExit -ne 0){throw "REHEARSAL_FIXTURE_COMPILE_FAILED: $($compileOutput -join ' ')"};$compiled=$true

        $portProbe={param($probePort)$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,[int]$probePort);try{$probe.Start()}finally{$probe.Stop()}}.GetNewClosure()
        $startServerAction={param($candidate,$attempt)
            try{& $portProbe $candidate}catch{$retryEvent=New-MmtlRuntimeEvent -SessionId $sessionId -Role Launcher -ProcessId $PID -ProcessIdentity $runnerIdentity -SourceType Rehearsal -EventCode REHEARSAL_PORT_RETRY -Summary '候选端口在启动前已被占用，正在安全重试自动端口。' -Metadata @{attempt=$attempt;port=$candidate};Write-MmtlRuntimeEvent -SessionPath $session -Event $retryEvent|Out-Null;throw 'PORT_BIND_CONFLICT: 候选端口在启动前已被占用。'}
            $attemptRuntime=Join-Path $session ("Server-Attempt-$attempt");$attemptLogs=Join-Path $attemptRuntime 'logs';New-Item -ItemType Directory -Path $attemptLogs -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $attemptRuntime 'mmtl-session.id'),$sessionId,[Text.UTF8Encoding]::new($false))
            $serverArgs=@('-cp',$classes,'net.minecraft.server.Main',$attemptRuntime,[string]$candidate)|ForEach-Object{ConvertTo-MmtlRehearsalProcessArgument ([string]$_)}
            $processLog=Join-Path $session ("logs/server-attempt-$attempt.log")
            $trackedProcess=Start-MmtlTrackedProcess -SessionPath $session -FilePath $java.runtimeJavaPath -ArgumentList @($serverArgs) -WorkingDirectory $session -LogPath $processLog -Role Server -Username "attempt-$attempt" -RuntimeDirectory $attemptRuntime -Rehearsal -PassThru
            $serverPortPath=Join-Path $attemptRuntime 'server.port';$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            do{
                if(Test-Path -LiteralPath $serverPortPath){$actualPort=[int](Get-Content -LiteralPath $serverPortPath -Raw);if($actualPort -ne $candidate){$null=Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $trackedProcess.ProcessId;$trackedProcess.Process.WaitForExit(3000)|Out-Null;throw 'REHEARSAL_SERVER_PORT_MISMATCH'};return [pscustomobject]@{tracked=$trackedProcess;runtime=$attemptRuntime;port=$actualPort;attempt=$attempt}}
                if($trackedProcess.Process.HasExited){$trackedProcess.Process.WaitForExit(1000)|Out-Null;$output='';foreach($outputPath in @($processLog,$processLog+'.err')){if(Test-Path -LiteralPath $outputPath){$output+=[IO.File]::ReadAllText($outputPath)}};$completedState=Complete-MmtlTrackedProcess -SessionPath $session -Process $trackedProcess.Process -StartIdentity $trackedProcess.StartIdentity;$trackedProcess.Process.Dispose();$bindConflict=[string]$output -match '(?i)(BindException|Address already in use|EADDRINUSE|failed to bind)';if(-not $bindConflict){try{& $portProbe $candidate}catch{$bindConflict=$true}};if($bindConflict){$retryEvent=New-MmtlRuntimeEvent -SessionId $sessionId -Role Launcher -ProcessId $PID -ProcessIdentity $runnerIdentity -SourceType Rehearsal -EventCode REHEARSAL_PORT_RETRY -Summary '候选端口在 Java Server 绑定期间被占用，正在安全重试自动端口。' -Metadata @{attempt=$attempt;port=$candidate};Write-MmtlRuntimeEvent -SessionPath $session -Event $retryEvent|Out-Null;throw 'PORT_BIND_CONFLICT: Java dummy Server 端口绑定失败。'};throw 'REHEARSAL_SERVER_EXITED_BEFORE_READY'}
                Start-Sleep -Milliseconds 100
            }while([DateTime]::UtcNow -lt $deadline)
            if(-not $trackedProcess.Process.HasExited){$null=Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $trackedProcess.ProcessId;$trackedProcess.Process.WaitForExit(3000)|Out-Null}
            throw 'REHEARSAL_SERVER_READY_TIMEOUT'
        }
        $portAllocation=Invoke-MmtlPortAllocation -OnAllocated $startServerAction -MaximumAttempts 3 -PortSelector $PortSelector
        $port=[int]$portAllocation.Port;$server=$portAllocation.Value.tracked;$serverRuntime=[string]$portAllocation.Value.runtime;$portAttempts=[int]$portAllocation.Attempts
        $serverObservation=$null;$observedServer=$null;$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do{$serverObservation=Invoke-MmtlDedicatedServerObserver -SessionPath $session -Port $port;$observedServer=$serverObservation.servers|Where-Object{$_.pid -eq $server.ProcessId}|Select-Object -First 1;if($observedServer -and $observedServer.ready -and $observedServer.listening){break};if($server.Process.HasExited){throw 'REHEARSAL_SERVER_EXITED_DURING_READY_OBSERVATION'};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
        if(-not $observedServer -or -not $observedServer.ready -or -not $observedServer.listening){throw 'REHEARSAL_SERVER_OBSERVATION_TIMEOUT'}
        $readyBeforeClients=$true
        $statePath=Join-Path $session 'session.json';$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
        $state.metadata|Add-Member -NotePropertyName port -NotePropertyValue $port -Force
        Write-MmtlAtomicTextFile -Path $statePath -Content (($state|ConvertTo-Json -Depth 40)+"`n")
        Set-MmtlSessionV2State -SessionPath $session -State Running|Out-Null

        $clientAttempt=0
        foreach($roleInfo in $clientRoles){
            $clientAttempt++
            if($FailClientAt -eq $clientAttempt){throw "REHEARSAL_INJECTED_CLIENT_FAILURE: Dedicated Client attempt $clientAttempt."}
            if(-not $server.Process -or $server.Process.HasExited){throw 'REHEARSAL_SERVER_STOPPED_BEFORE_CLIENT'}
            $username=if([string]$roleInfo.username){[string]$roleInfo.username}else{'MMTL_Rehearsal'}
            $runtimeDirectory=Join-Path $session ("Client-"+($username -replace '[^A-Za-z0-9_-]','_'));$logs=Join-Path $runtimeDirectory 'logs';New-Item -ItemType Directory -Path $logs -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $runtimeDirectory 'mmtl-session.id'),$sessionId,[Text.UTF8Encoding]::new($false))
            $clientArgs=[Collections.Generic.List[string]]::new();foreach($argument in @($ExecutionPlan.runtime.jvmArgs)){if([string]$argument){$clientArgs.Add([string]$argument)}}
            foreach($argument in @('-cp',$classes,'net.minecraft.client.main.Main','guest',$runtimeDirectory,[string]$port)+@($ExecutionPlan.runtime.gameArgs)){$clientArgs.Add((ConvertTo-MmtlRehearsalProcessArgument ([string]$argument)))}
            $tracked=Start-MmtlTrackedProcess -SessionPath $session -FilePath $java.runtimeJavaPath -ArgumentList @($clientArgs.ToArray()) -WorkingDirectory $session -LogPath (Join-Path $session ("logs/client-$($username -replace '[^A-Za-z0-9_-]','_')-process.log")) -Role Client -Username $username -RuntimeDirectory $runtimeDirectory -Rehearsal -PassThru
            $clients.Add([pscustomobject]@{tracked=$tracked;username=$username;runtime=$runtimeDirectory})
            $connectedPath=Join-Path $runtimeDirectory 'guest.connected';$controlPortPath=Join-Path $runtimeDirectory 'control.port';$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            do{if((Test-Path -LiteralPath $connectedPath -PathType Leaf) -and (Test-Path -LiteralPath $controlPortPath -PathType Leaf)){break};if($tracked.Process.HasExited){throw "REHEARSAL_CLIENT_EXITED: $username"};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
            if(-not(Test-Path -LiteralPath $connectedPath -PathType Leaf)){throw "REHEARSAL_CLIENT_CONNECT_TIMEOUT: $username"}
            $controlPort=[int](Get-Content -LiteralPath $controlPortPath -Raw)
            $clientObserved=Invoke-MmtlClientObserver -SessionPath $session -MarkerHints @(@{eventCode='CLIENT_INIT_DETECTED';pattern='Setting user:';description='演练客户端初始化标记。'},@{eventCode='CLIENT_MAIN_MENU_DETECTED';pattern='Main menu initialized';description='演练主菜单标记。'})
            if(-not @($clientObserved.clients|Where-Object{$_.pid -eq $tracked.ProcessId -and $_.initDetected}).Count){throw "REHEARSAL_CLIENT_OBSERVATION_FAILED: $username"}
            $guestEvent=New-MmtlRuntimeEvent -SessionId $sessionId -Role Client -ProcessId $tracked.ProcessId -ProcessIdentity $tracked.StartIdentity -SourceType Rehearsal -EventCode REHEARSAL_GUEST_CONNECTED -Summary '合成客户端已通过 loopback 连接当前 Dedicated dummy Server。' -Metadata @{port=$port;username=$username;rehearsal=$true;validationEligible=$false}
            Write-MmtlRuntimeEvent -SessionPath $session -Event $guestEvent|Out-Null
            $clientResults.Add([pscustomobject]@{pid=$tracked.ProcessId;username=$username;role='Client';connected=$true;controlPort=$controlPort;validationEligible=$false})
        }

        $stopResults=[Collections.Generic.List[string]]::new()
        foreach($client in @($clients.ToArray())){$tracked=$client.tracked;$control=[int](Get-Content -LiteralPath (Join-Path $client.runtime 'control.port') -Raw);Send-MmtlRehearsalStop -Port $control|Out-Null;if(-not $tracked.Process.WaitForExit(5000)){throw "REHEARSAL_CLIENT_DID_NOT_EXIT: $($client.username)"};Complete-MmtlTrackedProcess -SessionPath $session -Process $tracked.Process -StartIdentity $tracked.StartIdentity -StopRequested|Out-Null;$stopResults.Add('Client:'+ $client.username+':Graceful')}
        Send-MmtlRehearsalStop -Port $port|Out-Null
        if(-not $server.Process.WaitForExit(5000)){throw 'REHEARSAL_SERVER_DID_NOT_EXIT'}
        Complete-MmtlTrackedProcess -SessionPath $session -Process $server.Process -StartIdentity $server.StartIdentity -StopRequested|Out-Null
        $serverObservation=Invoke-MmtlDedicatedServerObserver -SessionPath $session -Port $port
        $portReleased=-not(Test-MmtlServerLoopbackListener -Port $port)
        if(-not $portReleased){throw 'REHEARSAL_SERVER_PORT_NOT_RELEASED'}
        $stopResults.Add('Server:Graceful')
        $processObservation=Invoke-MmtlProcessObserver -SessionPath $session
        Set-MmtlSessionV2State -SessionPath $session -State Stopped|Out-Null;$finalState='Stopped'
        $finalEvent=New-MmtlRuntimeEvent -SessionId $sessionId -Role Launcher -ProcessId $PID -ProcessIdentity $runnerIdentity -SourceType Rehearsal -EventCode REHEARSAL_COMPLETED -Summary 'Dedicated 合成演练已停止，loopback 端口已释放。' -Metadata @{mode='Dedicated';port=$port;rehearsal=$true;validationEligible=$false}
        Write-MmtlRuntimeEvent -SessionPath $session -Event $finalEvent|Out-Null
        $events=@(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines)
        return [pscustomobject][ordered]@{sessionId=$sessionId;mode='Dedicated';roles=@('Server')+@($clientRoles|ForEach-Object{'Client'});runtimeJavaMajor=$java.runtimeMajor;buildJavaMajor=$java.buildMajor;memoryMb=[long]$ExecutionPlan.runtime.memory.requestedMb;port=$port;portAttempts=$portAttempts;server=[pscustomobject]@{pid=$server.ProcessId;ready=[bool]$observedServer.ready;listening=[bool]$observedServer.listening;readyBeforeClients=$readyBeforeClients};clients=@($clientResults.ToArray());processes=@(Get-Content -LiteralPath (Join-Path $session 'pids.json') -Raw|ConvertFrom-Json);events=$events;stopResult=@($stopResults.ToArray());portReleased=$portReleased;finalSessionState=$finalState;rehearsal=$true;validationEligible=$false;compiled=$compiled;sessionPath=$session}
    }catch{
        foreach($client in @($clients.ToArray())){$control=Join-Path $client.runtime 'control.port';$controlPort=if(Test-Path -LiteralPath $control){[int](Get-Content -LiteralPath $control -Raw)}else{0};Complete-MmtlRehearsalFailureCleanup -SessionPath $session -TrackedProcess $client.tracked -ControlPort $controlPort}
        if($server){Complete-MmtlRehearsalFailureCleanup -SessionPath $session -TrackedProcess $server -ControlPort $port}
        try{$validation=Test-MmtlSessionV2 -SessionPath $session;if($validation.valid -and $validation.state -notin @('Completed','Failed','Stopped','Abandoned')){Set-MmtlSessionV2State -SessionPath $session -State Failed|Out-Null}}catch{}
        throw
    }finally{foreach($client in @($clients.ToArray())){if($client.tracked.Process){$client.tracked.Process.Dispose()}};if($server -and $server.Process){$server.Process.Dispose()}}
}

function Invoke-MmtlIntegratedLanLaunchRehearsal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ExecutionPlan,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$RepositoryRoot,[ValidateRange(1,120)][int]$TimeoutSeconds=15,[ValidateRange(0,8)][int]$FailGuestAt=0)
    if([string]$ExecutionPlan.profile.mode -cne 'IntegratedLAN'){throw 'REHEARSAL_MODE_MISMATCH: IntegratedLAN 演练只接受 IntegratedLAN Execution Plan。'}
    $planCheck=Test-MmtlExecutionPlan -Plan $ExecutionPlan
    if(-not $planCheck.valid){throw "REHEARSAL_PLAN_INVALID: $($planCheck.errors -join ',')"}
    if([string]$global:MmtlPlatformProvider.ProcessManagement -ne 'Native'){throw 'REHEARSAL_PROCESS_MANAGEMENT_UNSUPPORTED: 当前平台没有 Native process identity/stop contract。'}
    $java=Get-MmtlRehearsalJavaSelection -ExecutionPlan $ExecutionPlan
    $fixtureSource=Join-Path $RepositoryRoot 'common/tests/fixtures/rehearsal/src/net/minecraft/client/main/Main.java'
    if(-not(Test-Path -LiteralPath $fixtureSource -PathType Leaf)){throw 'REHEARSAL_FIXTURE_MISSING: 未找到合成客户端 fixture。'}
    $hostRole=$ExecutionPlan.runtime.roles|Where-Object{[string]$_.role -eq 'Host'}|Select-Object -First 1
    $guestRoles=@($ExecutionPlan.runtime.roles|Where-Object{[string]$_.role -eq 'Guest'})
    if(-not $hostRole -or -not $guestRoles.Count){throw 'REHEARSAL_PLAN_INVALID: IntegratedLAN 必须包含 Host 和至少一个 Guest。'}
    $metadata=@{project=[string]$ExecutionPlan.repository.identity;loader=[string]$ExecutionPlan.project.loader.id;minecraft=[string]$ExecutionPlan.project.minecraftId;buildJavaMajor=$java.buildMajor;runtimeJavaMajor=$java.runtimeMajor;players=($guestRoles.Count+1);mode='IntegratedLAN';rehearsal=$true;validationEligible=$false;executionPlanDigest=[string]$ExecutionPlan.semanticDigest}
    $session=New-MmtlSession -RuntimeRoot $RuntimeRoot -Name 'rehearsal_integrated_lan' -Metadata $metadata
    $sessionId=Split-Path -Leaf $session;$hostTracked=$null;$guests=[Collections.Generic.List[object]]::new();$guestResults=[Collections.Generic.List[object]]::new();$compiled=$false;$port=0;$finalState='Failed';$portReleased=$false;$publishedBeforeGuests=$false
    try{
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $ExecutionPlan|Out-Null
        Write-MmtlRehearsalMetadata -SessionPath $session -ExecutionPlan $ExecutionPlan
        Set-MmtlSessionV2State -SessionPath $session -State Launching|Out-Null
        $runner=Get-MmtlProcessRecord -ProcessId $PID;$runnerIdentity=if($runner){[string]$runner.StartIdentity}else{'runner-'+[guid]::NewGuid().ToString('N')}
        $event=New-MmtlRuntimeEvent -SessionId $sessionId -Role Launcher -ProcessId $PID -ProcessIdentity $runnerIdentity -SourceType Rehearsal -EventCode REHEARSAL_STARTED -Summary '开始使用当前 Execution Plan 执行 IntegratedLAN 合成演练。' -Metadata @{mode='IntegratedLAN';rehearsal=$true;validationEligible=$false}
        Write-MmtlRuntimeEvent -SessionPath $session -Event $event|Out-Null
        $classes=Join-Path $session '.rehearsal/classes';New-Item -ItemType Directory -Path $classes -Force|Out-Null
        $compileOutput=@(& $java.javacPath -encoding UTF-8 -d $classes $fixtureSource 2>&1);$compileExit=$LASTEXITCODE
        if($compileExit -ne 0){throw "REHEARSAL_FIXTURE_COMPILE_FAILED: $($compileOutput -join ' ')"};$compiled=$true
        $hostName=if([string]$hostRole.username){[string]$hostRole.username}else{'MMTL_Rehearsal_Host'}
        $hostRuntime=Join-Path $session ("Host-"+($hostName -replace '[^A-Za-z0-9_-]','_'));$hostLogs=Join-Path $hostRuntime 'logs';New-Item -ItemType Directory -Path $hostLogs -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $hostRuntime 'mmtl-session.id'),$sessionId,[Text.UTF8Encoding]::new($false))
        $hostArgs=[Collections.Generic.List[string]]::new();foreach($argument in @($ExecutionPlan.runtime.jvmArgs)){if([string]$argument){$hostArgs.Add([string]$argument)}}
        foreach($argument in @('-cp',$classes,'net.minecraft.client.main.Main','host',$hostRuntime)+@($ExecutionPlan.runtime.gameArgs)){$hostArgs.Add((ConvertTo-MmtlRehearsalProcessArgument ([string]$argument)))}
        $hostTracked=Start-MmtlTrackedProcess -SessionPath $session -FilePath $java.runtimeJavaPath -ArgumentList @($hostArgs.ToArray()) -WorkingDirectory $session -LogPath (Join-Path $session 'logs/host-process.log') -Role Host -Username $hostName -RuntimeDirectory $hostRuntime -Rehearsal -PassThru
        $controlPath=Join-Path $hostRuntime 'control.port';$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do{if(Test-Path -LiteralPath $controlPath){break};if($hostTracked.Process.HasExited){throw 'REHEARSAL_HOST_EXITED_BEFORE_READY'};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
        if(-not(Test-Path -LiteralPath $controlPath)){throw 'REHEARSAL_HOST_CONTROL_TIMEOUT'}
        $controlPort=[int](Get-Content -LiteralPath $controlPath -Raw)
        $hostObserved=Invoke-MmtlClientObserver -SessionPath $session -MarkerHints @(@{eventCode='CLIENT_INIT_DETECTED';pattern='Setting user:';description='演练 Host 初始化标记。'},@{eventCode='CLIENT_MAIN_MENU_DETECTED';pattern='Main menu initialized';description='演练 Host 主菜单标记。'})
        if(-not @($hostObserved.clients|Where-Object{$_.pid -eq $hostTracked.ProcessId -and $_.initDetected}).Count){throw 'REHEARSAL_HOST_OBSERVATION_FAILED'}
        $lanObservation=$null;$hostPublished=$null;$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do{$lanObservation=Invoke-MmtlLanObserver -SessionPath $session;$hostPublished=$lanObservation.hosts|Where-Object{$_.pid -eq $hostTracked.ProcessId -and $_.port}|Select-Object -First 1;if($hostPublished){break};if($hostTracked.Process.HasExited){throw 'REHEARSAL_HOST_EXITED_DURING_LAN_OBSERVATION'};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
        if(-not $hostPublished){throw 'REHEARSAL_LAN_PORT_OBSERVATION_TIMEOUT'}
        $port=[int]$hostPublished.port
        if(-not(Test-MmtlServerLoopbackListener -Port $port)){throw 'REHEARSAL_LAN_PORT_NOT_LISTENING'}
        $publishedBeforeGuests=$true
        $statePath=Join-Path $session 'session.json';$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
        $state.metadata|Add-Member -NotePropertyName port -NotePropertyValue $port -Force
        Write-MmtlAtomicTextFile -Path $statePath -Content (($state|ConvertTo-Json -Depth 40)+"`n")
        Set-MmtlSessionV2State -SessionPath $session -State Running|Out-Null

        $guestAttempt=0
        foreach($roleInfo in $guestRoles){
            $guestAttempt++
            if($FailGuestAt -eq $guestAttempt){throw "REHEARSAL_INJECTED_GUEST_FAILURE: IntegratedLAN Guest attempt $guestAttempt."}
            if($hostTracked.Process.HasExited){throw 'REHEARSAL_HOST_STOPPED_BEFORE_GUEST'}
            $username=if([string]$roleInfo.username){[string]$roleInfo.username}else{'MMTL_Rehearsal_Guest'}
            $runtimeDirectory=Join-Path $session ("Guest-"+($username -replace '[^A-Za-z0-9_-]','_'));$logs=Join-Path $runtimeDirectory 'logs';New-Item -ItemType Directory -Path $logs -Force|Out-Null
            [IO.File]::WriteAllText((Join-Path $runtimeDirectory 'mmtl-session.id'),$sessionId,[Text.UTF8Encoding]::new($false))
            $guestArgs=[Collections.Generic.List[string]]::new();foreach($argument in @($ExecutionPlan.runtime.jvmArgs)){if([string]$argument){$guestArgs.Add([string]$argument)}}
            foreach($argument in @('-cp',$classes,'net.minecraft.client.main.Main','guest',$runtimeDirectory,[string]$port)+@($ExecutionPlan.runtime.gameArgs)){$guestArgs.Add((ConvertTo-MmtlRehearsalProcessArgument ([string]$argument)))}
            $tracked=Start-MmtlTrackedProcess -SessionPath $session -FilePath $java.runtimeJavaPath -ArgumentList @($guestArgs.ToArray()) -WorkingDirectory $session -LogPath (Join-Path $session ("logs/guest-$($username -replace '[^A-Za-z0-9_-]','_')-process.log")) -Role Guest -Username $username -RuntimeDirectory $runtimeDirectory -Rehearsal -PassThru
            $guests.Add([pscustomobject]@{tracked=$tracked;username=$username;runtime=$runtimeDirectory})
            $connectedPath=Join-Path $runtimeDirectory 'guest.connected';$guestControl=Join-Path $runtimeDirectory 'control.port';$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            do{if((Test-Path -LiteralPath $connectedPath -PathType Leaf) -and (Test-Path -LiteralPath $guestControl -PathType Leaf)){break};if($tracked.Process.HasExited){throw "REHEARSAL_GUEST_EXITED: $username"};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $deadline)
            if(-not(Test-Path -LiteralPath $connectedPath -PathType Leaf)){throw "REHEARSAL_GUEST_CONNECT_TIMEOUT: $username"}
            $observed=Invoke-MmtlClientObserver -SessionPath $session -MarkerHints @(@{eventCode='CLIENT_INIT_DETECTED';pattern='Setting user:';description='演练 Guest 初始化标记。'},@{eventCode='CLIENT_MAIN_MENU_DETECTED';pattern='Main menu initialized';description='演练 Guest 主菜单标记。'})
            if(-not @($observed.clients|Where-Object{$_.pid -eq $tracked.ProcessId -and $_.initDetected}).Count){throw "REHEARSAL_GUEST_OBSERVATION_FAILED: $username"}
            $guestEvent=New-MmtlRuntimeEvent -SessionId $sessionId -Role Guest -ProcessId $tracked.ProcessId -ProcessIdentity $tracked.StartIdentity -SourceType Rehearsal -EventCode REHEARSAL_GUEST_CONNECTED -Summary '合成 Guest 已连接当前 Session 的 IntegratedLAN loopback Host。' -Metadata @{port=$port;rehearsal=$true;validationEligible=$false}
            Write-MmtlRuntimeEvent -SessionPath $session -Event $guestEvent|Out-Null
            $guestResults.Add([pscustomobject]@{pid=$tracked.ProcessId;username=$username;role='Guest';connected=$true;validationEligible=$false})
        }
        $stopResults=[Collections.Generic.List[string]]::new()
        foreach($guest in @($guests.ToArray())){$tracked=$guest.tracked;$control=[int](Get-Content -LiteralPath (Join-Path $guest.runtime 'control.port') -Raw);Send-MmtlRehearsalStop -Port $control|Out-Null;if(-not $tracked.Process.WaitForExit(5000)){throw "REHEARSAL_GUEST_DID_NOT_EXIT: $($guest.username)"};Complete-MmtlTrackedProcess -SessionPath $session -Process $tracked.Process -StartIdentity $tracked.StartIdentity -StopRequested|Out-Null;$stopResults.Add('Guest:'+ $guest.username+':Graceful')}
        Send-MmtlRehearsalStop -Port $controlPort|Out-Null
        if(-not $hostTracked.Process.WaitForExit(5000)){throw 'REHEARSAL_HOST_DID_NOT_EXIT'}
        Complete-MmtlTrackedProcess -SessionPath $session -Process $hostTracked.Process -StartIdentity $hostTracked.StartIdentity -StopRequested|Out-Null
        $portReleased=-not(Test-MmtlServerLoopbackListener -Port $port)
        if(-not $portReleased){throw 'REHEARSAL_LAN_PORT_NOT_RELEASED'}
        $stopResults.Add('Host:Graceful');Invoke-MmtlProcessObserver -SessionPath $session|Out-Null
        Set-MmtlSessionV2State -SessionPath $session -State Stopped|Out-Null;$finalState='Stopped'
        $finalEvent=New-MmtlRuntimeEvent -SessionId $sessionId -Role Launcher -ProcessId $PID -ProcessIdentity $runnerIdentity -SourceType Rehearsal -EventCode REHEARSAL_COMPLETED -Summary 'IntegratedLAN 合成演练已停止，loopback 端口已释放。' -Metadata @{mode='IntegratedLAN';port=$port;rehearsal=$true;validationEligible=$false}
        Write-MmtlRuntimeEvent -SessionPath $session -Event $finalEvent|Out-Null
        return [pscustomobject][ordered]@{sessionId=$sessionId;mode='IntegratedLAN';roles=@('Host')+@($guestRoles|ForEach-Object{'Guest'});runtimeJavaMajor=$java.runtimeMajor;buildJavaMajor=$java.buildMajor;memoryMb=[long]$ExecutionPlan.runtime.memory.requestedMb;host=[pscustomobject]@{pid=$hostTracked.ProcessId;port=$port;published=$true;publishedBeforeGuests=$publishedBeforeGuests};guests=@($guestResults.ToArray());processes=@(Get-Content -LiteralPath (Join-Path $session 'pids.json') -Raw|ConvertFrom-Json);events=@(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines);stopResult=@($stopResults.ToArray());portReleased=$portReleased;finalSessionState=$finalState;rehearsal=$true;validationEligible=$false;compiled=$compiled;sessionPath=$session}
    }catch{
        foreach($guest in @($guests.ToArray())){$control=Join-Path $guest.runtime 'control.port';$controlPort=if(Test-Path -LiteralPath $control){[int](Get-Content -LiteralPath $control -Raw)}else{0};Complete-MmtlRehearsalFailureCleanup -SessionPath $session -TrackedProcess $guest.tracked -ControlPort $controlPort}
        if($hostTracked){$control=Join-Path $hostRuntime 'control.port';$controlPort=if(Test-Path -LiteralPath $control){[int](Get-Content -LiteralPath $control -Raw)}else{0};Complete-MmtlRehearsalFailureCleanup -SessionPath $session -TrackedProcess $hostTracked -ControlPort $controlPort}
        try{$validation=Test-MmtlSessionV2 -SessionPath $session;if($validation.valid -and $validation.state -notin @('Completed','Failed','Stopped','Abandoned')){Set-MmtlSessionV2State -SessionPath $session -State Failed|Out-Null}}catch{}
        throw
    }finally{foreach($guest in @($guests.ToArray())){if($guest.tracked.Process){$guest.tracked.Process.Dispose()}};if($hostTracked -and $hostTracked.Process){$hostTracked.Process.Dispose()}}
}

Export-ModuleMember -Function Get-MmtlRehearsalJavaSelection,Invoke-MmtlSingleLaunchRehearsal,Invoke-MmtlDedicatedLaunchRehearsal,Invoke-MmtlIntegratedLanLaunchRehearsal
