BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:platformRoot = Split-Path -Parent $script:repoRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        Import-Module (Join-Path $script:platformRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
        Register-MmtlWindowsPlatform -RepositoryRoot $script:platformRoot
    } elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) {
        Import-Module (Join-Path $script:platformRoot 'linux/src/LinuxPlatformProvider.psm1') -Force
        Register-MmtlLinuxPlatform -RepositoryRoot $script:platformRoot
    } else {
        Import-Module (Join-Path $script:platformRoot 'macos/src/MacOSPlatformProvider.psm1') -Force
        Register-MmtlMacOSPlatform -RepositoryRoot $script:platformRoot
    }
    Import-Module (Join-Path $script:repoRoot 'src/ProcessManager.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/SessionLifecycle.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/SessionManager.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/RuntimeManager.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Execution/ExecutionPlan.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Rehearsal/RehearsalRunner.psm1') -Force
    $script:canTrackProcesses = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)
}

BeforeAll {
function New-RehearsalExecutionPlan {
    param([Parameter(Mandatory)][string]$JavaPath,[Parameter(Mandatory)][int]$Major,[Parameter(Mandatory)][string]$RuntimeRoot)
    $plan=[pscustomobject][ordered]@{
        schemaVersion=1;status='Ready';planId='pending';semanticDigest='';createdAt=[DateTimeOffset]::UtcNow.ToString('o')
        platform=[pscustomobject][ordered]@{os=$global:MmtlPlatformProvider.OS;arch=$global:MmtlPlatformProvider.Arch;isWSL=[bool]$global:MmtlPlatformProvider.IsWSL;capabilities=[pscustomobject][ordered]@{Build='Native';Launch='Native'}}
        repository=[pscustomobject][ordered]@{identity='fixture-mod';root=$RuntimeRoot}
        project=[pscustomobject][ordered]@{projectRoot=$RuntimeRoot;locator='fixture';minecraftId='1.20.1';loader=[pscustomobject][ordered]@{id='Forge';version='47.2.0'};loaderStack=@();toolchain=[pscustomobject][ordered]@{id='ForgeGradle';version='6.0'};buildSystem=[pscustomobject][ordered]@{id='GradleWrapper';version='8.8'};modId='fixturemod'}
        buildJava=[pscustomobject][ordered]@{requirement=[pscustomobject][ordered]@{purpose='BuildJava';major=17;minimumMajor=17;requirementKind='Minimum';source='fixture';confidence='High'};resolution=[pscustomobject][ordered]@{status='Resolved';javaPath=$JavaPath;home=(Split-Path (Split-Path $JavaPath -Parent) -Parent);actualMajor=$Major;exactVersion="$Major.0.1";vendor='Fixture JDK';os=$global:MmtlPlatformProvider.OS;arch=$global:MmtlPlatformProvider.Arch;reasonCode=$null}}
        runtimeJava=[pscustomobject][ordered]@{requirement=[pscustomobject][ordered]@{purpose='RuntimeJava';major=$Major;requirementKind='Exact';source='fixture';confidence='High'};resolution=[pscustomobject][ordered]@{status='Resolved';javaPath=$JavaPath;home=(Split-Path (Split-Path $JavaPath -Parent) -Parent);actualMajor=$Major;exactVersion="$Major.0.1";vendor='Fixture JDK';os=$global:MmtlPlatformProvider.OS;arch=$global:MmtlPlatformProvider.Arch;reasonCode=$null};bindingMode='Direct';bindingEvidence=$null}
        profile=[pscustomobject][ordered]@{name='fixture';mode='Single';players=1;hostUsername='Dev';clientPrefix='Dev_';memoryMb=512;jvmArgs=@('-Dmmtl.rehearsal.test=fixture');gameArgs=@('--dummy-arg','fixture-value');acceptEula=$false}
        build=[pscustomobject][ordered]@{required=$false;clean=$false;task='build';wrapper='gradlew';artifactExpectation='one-mod-jar'}
        runtime=[pscustomobject][ordered]@{roles=@([pscustomobject]@{role='Client';username='Dev';launchReady=$true;blockingReasons=@()});runtimeDirectories=@([pscustomobject]@{role='Client';username='Dev';path=(Join-Path $RuntimeRoot 'sessions/planned/Dev');relativePath='sessions/planned/Dev'});memory=[pscustomobject][ordered]@{requestedMb=512;limitMb=4096;exceedsLimit=$false};jvmArgs=@('-Dmmtl.rehearsal.test=fixture');gameArgs=@('--dummy-arg','fixture-value')}
        network=[pscustomobject][ordered]@{portPolicy='None';fixedPort=$null;bindPolicy='Loopback'}
        session=[pscustomobject][ordered]@{intendedMode='Single'}
        capabilityGates=[pscustomobject][ordered]@{buildReady=$true;launchReady=$true;buildReasons=@();launchReasons=@()}
        blockingReasons=@();warnings=@();launchBlockingReasons=@();launchWarnings=@();provenance=[pscustomobject][ordered]@{runtimeJavaSource='fixture';metadataStatus='VERIFIED'}
    }
    $plan.semanticDigest=Get-MmtlExecutionPlanSemanticDigest -Plan $plan
    $plan.planId='plan-'+$plan.semanticDigest.Substring(7,16)
    return $plan
}
function Set-RehearsalPlanMode {
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][ValidateSet('Single','Dedicated','IntegratedLAN')][string]$Mode,[ValidateRange(1,8)][int]$Players=1)
    $Plan.profile.mode=$Mode;$Plan.profile.players=$Players;$Plan.session.intendedMode=$Mode
    $names=for($i=0;$i -lt $Players;$i++){if($i -eq 0){'Dev'}else{"Dev_$i"}}
    $roles=if($Mode -eq 'Dedicated'){@([pscustomobject]@{role='Server';username=''};for($i=0;$i -lt $Players;$i++){[pscustomobject]@{role='Client';username=$names[$i]}})}elseif($Mode -eq 'IntegratedLAN'){@([pscustomobject]@{role='Host';username=$names[0]};for($i=1;$i -lt $Players;$i++){[pscustomobject]@{role='Guest';username=$names[$i]}})}else{@([pscustomobject]@{role='Client';username='Dev'})}
    $Plan.runtime.roles=@($roles)
    $Plan.runtime.runtimeDirectories=@($roles|ForEach-Object{$safe=if($_.role -eq 'Server'){'Server'}else{$_.username};[pscustomobject]@{role=$_.role;username=$_.username;path=(Join-Path $Plan.repository.root "sessions/planned/$safe");relativePath="sessions/planned/$safe"}})
    $Plan.runtime.memory.requestedMb=512*$roles.Count
    $Plan.network.portPolicy=if($Mode -eq 'Single'){'None'}else{'Auto'}
    $Plan.semanticDigest=Get-MmtlExecutionPlanSemanticDigest -Plan $Plan;$Plan.planId='plan-'+$Plan.semanticDigest.Substring(7,16)
    return $Plan
}
}

Describe '演练进程登记' {
    It 'PassThru 返回实际进程句柄，并在登记记录上标记 rehearsal' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $runtime = Join-Path $TestDrive 'rehearsal-runtime'
        $session = Join-Path $runtime 'sessions/rehearsal'
        $logs = Join-Path $session 'logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        '[]' | Set-Content -LiteralPath (Join-Path $session 'pids.json')
        $shell = (Get-Process -Id $PID).Path
        $tracked = Start-MmtlTrackedProcess -SessionPath $session -FilePath $shell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WorkingDirectory $TestDrive -LogPath (Join-Path $logs 'dummy.log') -Role Client -RuntimeDirectory (Join-Path $session 'Client') -Rehearsal -PassThru
        try {
            $tracked.ProcessId | Should -BeGreaterThan 0
            $tracked.Process.Id | Should -Be $tracked.ProcessId
            $entry = Get-Content -LiteralPath (Join-Path $session 'pids.json') -Raw | ConvertFrom-Json
            $entry[0].Rehearsal | Should -BeTrue
            $storedIdentity=if($entry[0].StartIdentity -is [DateTime]){$entry[0].StartIdentity.ToUniversalTime().ToString('o')}else{[string]$entry[0].StartIdentity}
            $tracked.StartIdentity | Should -BeExactly $storedIdentity
        } finally {
            Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $tracked.ProcessId | Out-Null
            $tracked.Process.Dispose()
        }
    }

    It '自然退出状态只按原进程句柄与已登记启动身份写入 Session' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $runtime = Join-Path $TestDrive 'rehearsal-exit-runtime'
        $session = Join-Path $runtime 'sessions/rehearsal-exit'
        $logs = Join-Path $session 'logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        '[]' | Set-Content -LiteralPath (Join-Path $session 'pids.json')
        $shell = (Get-Process -Id $PID).Path
        $tracked = Start-MmtlTrackedProcess -SessionPath $session -FilePath $shell -ArgumentList @('-NoProfile','-Command','exit 7') -WorkingDirectory $TestDrive -LogPath (Join-Path $logs 'exit.log') -Role Client -Rehearsal -PassThru
        try {
            $tracked.Process.WaitForExit()
            $state = Complete-MmtlTrackedProcess -SessionPath $session -Process $tracked.Process -StartIdentity $tracked.StartIdentity
            $state.ExitCode | Should -Be 7
            $state.StopRequested | Should -BeFalse
            (Get-Content -LiteralPath $tracked.StatePath -Raw | ConvertFrom-Json).ExitCode | Should -Be 7
        } finally {
            $tracked.Process.Dispose()
        }
    }

    It 'Single 演练复用 Plan、Session、Java 解析、Observer 与安全停止且不晋级验证' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop
        $javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $versionText=(& $javaPath -version 2>&1 | Out-String)
        $majorMatch=[regex]::Match($versionText,'(?:version\s+"|openjdk\s+)(?<major>\d+)')
        if(-not $majorMatch.Success){Set-ItResult -Skipped -Because '当前 runner 无法确认 Java major version。';return}
        $major=[int]$majorMatch.Groups['major'].Value
        $runtime=Join-Path $TestDrive 'single-rehearsal-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime
        $check=Test-MmtlExecutionPlan -Plan $plan
        $check.valid | Should -BeTrue -Because ($check.errors -join ',')

        $result=Invoke-MmtlSingleLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -TimeoutSeconds 15

        $result.finalSessionState | Should -Be 'Stopped'
        $result.rehearsal | Should -BeTrue
        $result.validationEligible | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $result.sessionPath 'Client-MMTL_Rehearsal/eula.txt')) | Should -BeFalse
        $result.stopResult | Should -Be 'Graceful'
        $result.compiled | Should -BeTrue
        @($result.events.eventCode) | Should -Contain 'CLIENT_INIT_DETECTED'
        @($result.events.eventCode) | Should -Contain 'JAVA_RUNTIME_OBSERVED'
        @($result.events.eventCode) | Should -Not -Contain 'CLIENT_LAUNCH_VERIFIED'
        $javaEvent=$result.events|Where-Object eventCode -eq 'JAVA_RUNTIME_OBSERVED'|Select-Object -First 1
        $javaEvent.metadata.bindingMatch | Should -BeTrue
        $processLog=[string]$result.processes[0].LogPath
        $processOutput=Get-Content -LiteralPath $processLog -Raw
        $processOutput | Should -Match 'MMTL_FIXTURE_JVM_ARG=fixture'
        $processOutput | Should -Match 'MMTL_FIXTURE_GAME_ARGS=--dummy-arg fixture-value'
        (Get-Content -LiteralPath (Join-Path $result.sessionPath 'execution-plan.json') -Raw | ConvertFrom-Json).semanticDigest | Should -Be $plan.semanticDigest
        (Test-MmtlSessionV2 -SessionPath $result.sessionPath).state | Should -Be 'Stopped'
    }

    It '初始化前退出分类为早退并保留退出码' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'early-exit-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime
        $result=Invoke-MmtlSingleLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -Scenario early-exit -TimeoutSeconds 10
        @($result.events.eventCode) | Should -Contain 'CLIENT_EXITED_BEFORE_INITIALIZATION'
        $result.finalSessionState | Should -Be 'Failed'
        $result.processes[0].Rehearsal | Should -BeTrue
        (Get-Content -LiteralPath $result.processes[0].StatePath -Raw|ConvertFrom-Json).ExitCode | Should -Be 23
        @($result.events.eventCode) | Should -Not -Contain 'CLIENT_LAUNCH_VERIFIED'
    }

    It '初始化后异常退出分类为客户端崩溃但不晋级验证' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'crash-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime
        $result=Invoke-MmtlSingleLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -Scenario crash-after-init -TimeoutSeconds 10
        @($result.events.eventCode) | Should -Contain 'CLIENT_CRASH' -Because (@($result.events|ForEach-Object{"$($_.pid):$($_.role):$($_.eventCode)"}) -join ';')
        $result.finalSessionState | Should -Be 'Failed'
        @($result.events.eventCode) | Should -Not -Contain 'CLIENT_LAUNCH_VERIFIED'
    }

    It '超时事件有结构化证据且只停止当前已登记演练进程' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'timeout-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime
        $result=Invoke-MmtlSingleLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -Scenario timeout -TimeoutSeconds 1
        @($result.events.eventCode) | Should -Contain 'TIMED_OUT'
        $result.finalSessionState | Should -Be 'Failed'
        $result.processes[0].Rehearsal | Should -BeTrue
    }

    It 'PID identity mismatch 产生 IdentityLost 且绝不进入正式验证候选' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'pid-mismatch-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime
        $result=Invoke-MmtlSingleLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -Scenario pid-mismatch -TimeoutSeconds 15
        @($result.events.eventCode) | Should -Contain 'PROCESS_IDENTITY_LOST'
        @($result.events.eventCode) | Should -Not -Contain 'CLIENT_LAUNCH_VERIFIED'
        $result.validationEligible | Should -BeFalse
        $result.finalSessionState | Should -Be 'Stopped'
        (Test-MmtlSessionV2 -SessionPath $result.sessionPath).state | Should -Be 'Stopped'
    }

    It 'Dedicated 等待 loopback dummy Server ready 后启动客户端并安全释放端口' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'dedicated-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=Set-RehearsalPlanMode -Plan (New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime) -Mode Dedicated -Players 1
        $result=Invoke-MmtlDedicatedLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -TimeoutSeconds 15
        $result.finalSessionState | Should -Be 'Stopped'
        $result.mode | Should -Be 'Dedicated'
        $result.port | Should -BeGreaterThan 0
        $result.server.ready | Should -BeTrue
        $result.server.listening | Should -BeTrue
        $result.server.readyBeforeClients | Should -BeTrue
        $result.clients.Count | Should -Be 1
        $result.clients[0].connected | Should -BeTrue
        $result.clients[0].role | Should -Be 'Client'
        @($result.processes.RuntimeDirectory | Sort-Object -Unique).Count | Should -Be 2
        @($result.processes | Where-Object { -not $_.Rehearsal }).Count | Should -Be 0
        $result.portReleased | Should -BeTrue
        @($result.events.eventCode) | Should -Contain 'SERVER_READY'
        @($result.events.eventCode) | Should -Contain 'SERVER_LISTENING'
        @($result.events.eventCode) | Should -Contain 'SERVER_STOPPED'
        @($result.events.eventCode) | Should -Contain 'REHEARSAL_GUEST_CONNECTED'
        @($result.events.eventCode) | Should -Not -Contain 'SERVER_VERIFIED'
        $result.rehearsal | Should -BeTrue
        $result.validationEligible | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $result.sessionPath 'Server/eula.txt')) | Should -BeFalse
    }

    It 'Dedicated 端口在选择后被抢占时安全重选并继续完成演练' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'dedicated-retry-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=Set-RehearsalPlanMode -Plan (New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime) -Mode Dedicated -Players 1
        $blocker=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$blocker.Start()
        $state=[hashtable]::Synchronized(@{blocker=$blocker;blockedPort=[int]$blocker.LocalEndpoint.Port})
        $selectEphemeral={ $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);try{$listener.Start();return [int]$listener.LocalEndpoint.Port}finally{$listener.Stop()} }.GetNewClosure()
        $selector={param($attempt)if($attempt -eq 1){return [int]$state.blockedPort};if($attempt -eq 2){$state.blocker.Stop()};return (& $selectEphemeral)}.GetNewClosure()
        try {
            $result=Invoke-MmtlDedicatedLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -TimeoutSeconds 15 -PortSelector $selector
            $result.finalSessionState | Should -Be 'Stopped'
            $result.portAttempts | Should -Be 2
            @($result.events.eventCode) | Should -Contain 'REHEARSAL_PORT_RETRY'
            $result.portReleased | Should -BeTrue
        } finally {try{$state.blocker.Stop()}catch{}}
    }

    It 'Dedicated 第二个 Client 启动失败时保留已登记进程并将 Session 标记 Failed' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'dedicated-partial-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=Set-RehearsalPlanMode -Plan (New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime) -Mode Dedicated -Players 2
        { Invoke-MmtlDedicatedLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -TimeoutSeconds 15 -FailClientAt 2 } | Should -Throw '*REHEARSAL_INJECTED_CLIENT_FAILURE*'
        $session=Get-ChildItem (Join-Path $runtime 'sessions') -Directory|Sort-Object LastWriteTime -Descending|Select-Object -First 1
        (Test-MmtlSessionV2 -SessionPath $session.FullName).state | Should -Be 'Failed'
        $processes=@(Get-Content (Join-Path $session.FullName 'pids.json') -Raw|ConvertFrom-Json)
        @($processes.Role) | Should -Contain 'Server'
        @($processes.Role) | Should -Contain 'Client'
        @($processes|Where-Object{$_.Role -eq 'Client'}).Count | Should -Be 1
        foreach($process in $processes){Test-Path -LiteralPath $process.StatePath | Should -BeTrue}
    }

    It 'IntegratedLAN 第二个 Guest 启动失败时保留 Host 与首个 Guest 并将 Session 标记 Failed' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'lan-partial-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=Set-RehearsalPlanMode -Plan (New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime) -Mode IntegratedLAN -Players 3
        { Invoke-MmtlIntegratedLanLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -TimeoutSeconds 15 -FailGuestAt 2 } | Should -Throw '*REHEARSAL_INJECTED_GUEST_FAILURE*'
        $session=Get-ChildItem (Join-Path $runtime 'sessions') -Directory|Sort-Object LastWriteTime -Descending|Select-Object -First 1
        (Test-MmtlSessionV2 -SessionPath $session.FullName).state | Should -Be 'Failed'
        $processes=@(Get-Content (Join-Path $session.FullName 'pids.json') -Raw|ConvertFrom-Json)
        @($processes.Role) | Should -Contain 'Host'
        @($processes.Role) | Should -Contain 'Guest'
        @($processes|Where-Object{$_.Role -eq 'Guest'}).Count | Should -Be 1
        foreach($process in $processes){Test-Path -LiteralPath $process.StatePath | Should -BeTrue}
    }

    It 'IntegratedLAN 只在 Host 发布 loopback 端口后启动 Guest 并安全释放端口' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'lan-runtime';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=Set-RehearsalPlanMode -Plan (New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime) -Mode IntegratedLAN -Players 2
        $result=Invoke-MmtlIntegratedLanLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -TimeoutSeconds 15
        $result.finalSessionState | Should -Be 'Stopped'
        $result.mode | Should -Be 'IntegratedLAN'
        $result.host.port | Should -BeGreaterThan 0
        $result.host.published | Should -BeTrue
        $result.host.publishedBeforeGuests | Should -BeTrue
        $result.guests.Count | Should -Be 1
        $result.guests[0].connected | Should -BeTrue
        @($result.processes.RuntimeDirectory | Sort-Object -Unique).Count | Should -Be 2
        @($result.processes | Where-Object { -not $_.Rehearsal }).Count | Should -Be 0
        $result.portReleased | Should -BeTrue
        @($result.events.eventCode) | Should -Contain 'LAN_PORT_PUBLISHED'
        @($result.events.eventCode) | Should -Contain 'REHEARSAL_GUEST_CONNECTED'
        @($result.events.eventCode) | Should -Not -Contain 'LAN_OPENED'
        $result.rehearsal | Should -BeTrue
        $result.validationEligible | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $result.sessionPath 'Host-Dev/eula.txt')) | Should -BeFalse
    }

    It '连续二十次短 Single rehearsal 均安全停止且 Session 身份互不重复' -Skip:([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        $javaCommand=Get-Command java -ErrorAction Stop;$javaFile=[IO.FileInfo]::new($javaCommand.Source);$link=$javaFile.ResolveLinkTarget($true);$javaPath=if($link){$link.FullName}else{$javaFile.FullName}
        $major=[int][regex]::Match((& $javaPath -version 2>&1|Out-String),'(?:version\s+"|openjdk\s+)(?<major>\d+)').Groups['major'].Value
        $runtime=Join-Path $TestDrive 'twenty-short-rehearsals';New-Item -ItemType Directory -Path $runtime -Force|Out-Null
        $plan=New-RehearsalExecutionPlan -JavaPath $javaPath -Major $major -RuntimeRoot $runtime
        $results=[Collections.Generic.List[object]]::new()
        for($iteration=1;$iteration -le 20;$iteration++){
            $results.Add((Invoke-MmtlSingleLaunchRehearsal -ExecutionPlan $plan -RuntimeRoot $runtime -RepositoryRoot $script:platformRoot -TimeoutSeconds 10))
        }
        $results.Count | Should -Be 20
        $invalidResults=@($results|Where-Object{$_.finalSessionState -ne 'Stopped' -or -not $_.rehearsal -or $_.validationEligible}|ForEach-Object{[ordered]@{sessionId=$_.sessionId;scenario=$_.scenario;finalSessionState=$_.finalSessionState;rehearsal=$_.rehearsal;validationEligible=$_.validationEligible;stopResult=$_.stopResult;eventCodes=@($_.events|ForEach-Object eventCode)}})
        $invalidResults.Count | Should -Be 0 -Because (ConvertTo-Json -InputObject $invalidResults -Depth 10 -Compress)
        @($results.sessionId|Sort-Object -Unique).Count | Should -Be 20
        foreach($result in $results){
            $session=Join-Path (Join-Path $runtime 'sessions') $result.sessionId
            (Test-MmtlSessionV2 -SessionPath $session).state | Should -Be 'Stopped'
            (Update-MmtlSessionReport -SessionPath $session).Status | Should -Be 'Stopped'
        }
    }
}
