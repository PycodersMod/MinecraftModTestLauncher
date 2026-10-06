BeforeAll {
    $module=Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Scenario/ScenarioOrchestrator.psm1'
    Import-Module $module -Force
}

Describe 'MMTL 通用 Scenario plan 与 Action contract' {
    It '为场景生命周期预留可写的分析与终态元数据字段' {
        $metadata=[pscustomobject]@{mode='Single'}
        $initialized=Initialize-MmtlScenarioSessionMetadata -Metadata $metadata
        $initialized.analysisStatus | Should -BeNullOrEmpty
        $initialized.analysisFindingCount | Should -BeNullOrEmpty
        $initialized.analysisErrorCode | Should -BeNullOrEmpty
        $initialized.scenarioState | Should -BeNullOrEmpty
        $initialized.sessionState | Should -BeNullOrEmpty
        $initialized.analysisStatus='Complete'
        $initialized.scenarioState='Completed'
        $initialized.analysisStatus | Should -Be 'Complete'
        $initialized.scenarioState | Should -Be 'Completed'
    }

    It '按 players 总数生成 loopback IntegratedLAN Host 和 Guest 顺序' {
        $plan=New-MmtlScenarioPlan -Mode IntegratedLAN -Players 3
        $plan.roles.role | Should -Be @('Host','Guest','Guest')
        $plan.roles.username | Should -Be @('MMTL_Host','MMTL_C1','MMTL_C2')
        $plan.steps.IndexOf('WaitAgentLanReady') | Should -BeLessThan $plan.steps.IndexOf('StartGuests')
        $plan.loopbackOnly | Should -BeTrue
        $plan.nonInteractive | Should -BeTrue
    }

    It '限制单人/联机人数、并发数、用户名长度和身份冲突' {
        {New-MmtlScenarioPlan -Mode Single -Players 2} | Should -Throw '*SCENARIO_SINGLE_REQUIRES_ONE_PLAYER*'
        {New-MmtlScenarioPlan -Mode IntegratedLAN -Players 1} | Should -Throw '*SCENARIO_INTEGRATED_LAN_REQUIRES_HOST_AND_GUEST*'
        {New-MmtlScenarioPlan -Mode IntegratedLAN -Players 3 -MaximumConcurrentInstances 2} | Should -Throw '*SCENARIO_CONCURRENCY_LIMIT_EXCEEDED*'
        {New-MmtlScenarioPlan -Mode IntegratedLAN -Players 2 -GuestPrefix '1234567890123456'} | Should -Throw '*SCENARIO_GUEST_PREFIX_TOO_LONG*'
        {New-MmtlScenarioPlan -Mode Dedicated -Players 2 -HostUsername 'Guest1' -GuestPrefix 'Guest'} | Should -Throw '*SCENARIO_IDENTITY_COLLISION*'
        {New-MmtlScenarioPlan -Mode Single -Players 1 -DurationSeconds 0} | Should -Throw
        (New-MmtlScenarioPlan -Mode Single -Players 1 -DurationSeconds 45 -MaximumConcurrentInstances 1).durationSeconds | Should -Be 45
    }

    It '按明确状态机拒绝跳过 Host readiness 或从终态重启' {
        (Test-MmtlScenarioTransition -Current HostStarting -Next HostReady) | Should -BeTrue
        (Test-MmtlScenarioTransition -Current HostStarting -Next GuestsStarting) | Should -BeFalse
        (Test-MmtlScenarioTransition -Current Completed -Next Building) | Should -BeFalse
        (Test-MmtlScenarioTransition -Current Failed -Next Stopping) | Should -BeTrue
    }

    It '验证动作权限、目标和本机高危管理命令' {
        (Assert-MmtlScenarioAction -Action WAIT -Seconds 2).seconds | Should -Be 2
        {Assert-MmtlScenarioAction -Action WAIT -Seconds 0} | Should -Throw '*SCENARIO_WAIT_DURATION_INVALID*'
        {Assert-MmtlScenarioAction -Action SEND_COMMAND -Command 'say hello'} | Should -Throw '*SCENARIO_ACTION_TARGET_NOT_MANAGED*'
        {Assert-MmtlScenarioAction -Action SEND_COMMAND -Command 'say hello' -TargetManaged -PermissionGranted:$false} | Should -Throw '*SCENARIO_COMMAND_PERMISSION_REQUIRED*'
        {Assert-MmtlScenarioAction -Action SEND_COMMAND -Command 'stop' -TargetManaged -PermissionGranted} | Should -Throw '*SCENARIO_COMMAND_FORBIDDEN*'
        {Assert-MmtlScenarioAction -Action SEND_COMMAND -Command "say hello`nstop" -TargetManaged -PermissionGranted} | Should -Throw '*SCENARIO_COMMAND_INVALID*'
        {Assert-MmtlScenarioAction -Action SCREENSHOT} | Should -Throw '*SCENARIO_ACTION_TARGET_NOT_MANAGED*'
        {Assert-MmtlScenarioAction -Action STOP_ROLE} | Should -Throw '*SCENARIO_ROLE_REQUIRED*'
    }

    It '将场景状态转换和事件追加限制在当前 Session 并拒绝非法跳步' {
        $session=Join-Path $TestDrive 'scenario-session';New-Item -ItemType Directory -Path $session|Out-Null
        $plan=New-MmtlScenarioPlan -Mode IntegratedLAN -Players 2
        $state=Initialize-MmtlScenarioState -SessionPath $session -SessionId 'session_1' -Plan $plan
        $state.state | Should -Be 'Planned'
        $state=Set-MmtlScenarioState -SessionPath $session -NextState Building -EventCode SCENARIO_STARTED
        $state.state | Should -Be 'Building'
        {Set-MmtlScenarioState -SessionPath $session -NextState GuestsStarting -EventCode ROLE_START_REQUESTED} | Should -Throw '*SCENARIO_TRANSITION_INVALID*'
        $events=Get-Content -LiteralPath (Join-Path $session 'scenario-events.jsonl')
        $events.Count | Should -Be 2
        ($events|ForEach-Object{($($_|ConvertFrom-Json)).sequence}) | Should -Be @(1,2)
        {Initialize-MmtlScenarioState -SessionPath $session -SessionId 'session_1' -Plan $plan} | Should -Throw '*SCENARIO_STATE_ALREADY_EXISTS*'
    }
}

Describe 'Scenario plan CLI' {
    It '在陌生空项目字段下仍输出纯净 JSON 且不触发项目导入或启动' {
        $repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $config=Get-Content -LiteralPath (Join-Path $repoRoot 'common/config/launcher.config.example.json') -Raw|ConvertFrom-Json
        $profile=$config.profiles.'single-test';$profile.mode='IntegratedLAN';$profile.players=3;$profile.project=''
        $config.profiles.'single-test'=$profile
        $configPath=Join-Path $TestDrive 'scenario-cli.json';$config|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $configPath -Encoding utf8
        $output=& (Get-Command pwsh).Source -NoProfile -File (Join-Path $repoRoot 'windows/launcher.ps1') --config-file $configPath --scenario-plan --json 2>$null
        $LASTEXITCODE | Should -Be 0
        $result=($output -join "`n")|ConvertFrom-Json
        $result.status | Should -Be 'PlanOnly'
        $result.plan.roles.role | Should -Be @('Host','Guest','Guest')
        [Array]::IndexOf([string[]]$result.plan.steps,'WaitAgentLanReady') | Should -BeLessThan ([Array]::IndexOf([string[]]$result.plan.steps,'StartGuests'))
    }

    It '读取 Session 范围内已持久化的场景状态' {
        $repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $runtime=Join-Path $TestDrive 'status-runtime';$id=([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_scenario')
        $session=Join-Path (Join-Path $runtime 'sessions') $id;New-Item -ItemType Directory -Path $session -Force|Out-Null
        $scenario=New-MmtlScenarioPlan -Mode Single -Players 1
        Initialize-MmtlScenarioState -SessionPath $session -SessionId $id -Plan $scenario|Out-Null
        $config=Get-Content -LiteralPath (Join-Path $repoRoot 'common/config/launcher.config.example.json') -Raw|ConvertFrom-Json
        $config|Add-Member -NotePropertyName runtimeRoot -NotePropertyValue $runtime -Force
        $configPath=Join-Path $TestDrive 'scenario-status-cli.json';$config|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $configPath -Encoding utf8
        $output=& (Get-Command pwsh).Source -NoProfile -File (Join-Path $repoRoot 'windows/launcher.ps1') --config-file $configPath --scenario-status $id --json 2>$null
        $LASTEXITCODE | Should -Be 0
        $result=($output -join "`n")|ConvertFrom-Json
        $result.sessionId | Should -Be $id
        $result.state | Should -Be 'Planned'
        $result.plan.mode | Should -Be 'Single'
    }

    It '通过 CLI 执行带上限的 WAIT 并输出 JSON 结果' {
        $repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $runtime=Join-Path $TestDrive 'action-cli-runtime';$id=([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_action')
        $session=Join-Path (Join-Path $runtime 'sessions') $id;New-Item -ItemType Directory -Path $session -Force|Out-Null
        Initialize-MmtlScenarioState -SessionPath $session -SessionId $id -Plan (New-MmtlScenarioPlan -Mode Single -Players 1)|Out-Null
        Set-MmtlScenarioState $session -NextState Building -EventCode TEST_STEP|Out-Null
        Set-MmtlScenarioState $session -NextState SessionReady -EventCode TEST_STEP|Out-Null
        Set-MmtlScenarioState $session -NextState ClientStarting -EventCode TEST_STEP|Out-Null
        Set-MmtlScenarioState $session -NextState Observing -EventCode TEST_STEP|Out-Null
        [IO.File]::WriteAllText((Join-Path $session 'pids.json'),'[]',[Text.UTF8Encoding]::new($false))
        $config=Get-Content -LiteralPath (Join-Path $repoRoot 'common/config/launcher.config.example.json') -Raw|ConvertFrom-Json
        $config|Add-Member -NotePropertyName runtimeRoot -NotePropertyValue $runtime -Force
        $configPath=Join-Path $TestDrive 'scenario-action-cli.json';$config|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $configPath -Encoding utf8
        $output=& (Get-Command pwsh).Source -NoProfile -File (Join-Path $repoRoot 'windows/launcher.ps1') --config-file $configPath --scenario-action $id WAIT --seconds 1 --json
        $LASTEXITCODE | Should -Be 0
        $result=($output -join "`n")|ConvertFrom-Json
        $result.action | Should -Be 'WAIT'
        $result.result.completed | Should -BeTrue
    }

    It '执行有界 WAIT 并只通过注入的受管进程停止回调执行 STOP_ROLE' {
        $session=Join-Path $TestDrive 'action-session';New-Item -ItemType Directory -Path $session|Out-Null
        $plan=New-MmtlScenarioPlan -Mode Single -Players 1
        Initialize-MmtlScenarioState -SessionPath $session -SessionId 'action_session' -Plan $plan|Out-Null
        Set-MmtlScenarioState $session -NextState Building -EventCode TEST_STEP|Out-Null
        Set-MmtlScenarioState $session -NextState SessionReady -EventCode TEST_STEP|Out-Null
        Set-MmtlScenarioState $session -NextState ClientStarting -EventCode TEST_STEP|Out-Null
        Set-MmtlScenarioState $session -NextState Observing -EventCode TEST_STEP|Out-Null
        [IO.File]::WriteAllText((Join-Path $session 'pids.json'),(@([pscustomobject]@{PID=43210;Role='Client';Username='MMTL_Host'})|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $wait=Invoke-MmtlScenarioAction -SessionPath $session -Action WAIT -Seconds 1
        $wait.result.completed | Should -BeTrue
        $script:stoppedPid=0
        $stop=Invoke-MmtlScenarioAction -SessionPath $session -Action STOP_ROLE -Role Client -StopProcess {param($path,$pidValue)$script:stoppedPid=$pidValue;$true}
        $stop.result.stoppedCount | Should -Be 1
        $script:stoppedPid | Should -Be 43210
        $events=@(Get-Content (Join-Path $session 'scenario-events.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
        $events[-1].eventCode | Should -Be 'ACTION_COMPLETED'
        $events.eventCode | Should -Contain 'ROLE_STOPPED'
    }
    It 'STOP_ALL 按 Session 登记回收进程并把 Scenario 转到 Stopped' {
        $session=Join-Path $TestDrive 'stop-all-session';New-Item -ItemType Directory -Path $session -Force|Out-Null
        $plan=New-MmtlScenarioPlan -Mode IntegratedLAN -Players 2;Initialize-MmtlScenarioState -SessionPath $session -SessionId 'stop_all_session' -Plan $plan|Out-Null
        Set-MmtlScenarioState $session -NextState Building -EventCode TEST_STEP|Out-Null;Set-MmtlScenarioState $session -NextState SessionReady -EventCode TEST_STEP|Out-Null;Set-MmtlScenarioState $session -NextState HostStarting -EventCode TEST_STEP|Out-Null;Set-MmtlScenarioState $session -NextState HostReady -EventCode TEST_STEP|Out-Null;Set-MmtlScenarioState $session -NextState GuestsStarting -EventCode TEST_STEP|Out-Null;Set-MmtlScenarioState $session -NextState GuestsReady -EventCode TEST_STEP|Out-Null;Set-MmtlScenarioState $session -NextState Observing -EventCode TEST_STEP|Out-Null
        [IO.File]::WriteAllText((Join-Path $session 'pids.json'),(@([pscustomobject]@{PID=1;Role='Client';Username='MMTL_C1'},[pscustomobject]@{PID=2;Role='Host';Username='MMTL_Host'})|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        $script:stoppedRoles=@();$result=Invoke-MmtlScenarioAction -SessionPath $session -Action STOP_ALL -StopProcess {param($path,$pidValue)$script:stoppedRoles+= $pidValue;$true}
        $result.result.stoppedCount | Should -Be 2;(Get-MmtlScenarioStatus $session).state | Should -Be 'Stopped';$script:stoppedRoles | Should -Be @(1,2)
        $events=@(Get-Content (Join-Path $session 'scenario-events.jsonl')|ForEach-Object{$_|ConvertFrom-Json});$events.eventCode | Should -Contain 'SCENARIO_SAFE_STOP_COMPLETED'
    }

}

Describe 'Session-local signed Agent actions' {
    BeforeAll { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Agent/AgentActions.psm1') -Force }
    It '创建角色绑定且签名的 Session 请求，不写出 token 或命令原文' {
        $session=Join-Path $TestDrive 'signed-action-session';New-Item -ItemType Directory -Path $session|Out-Null
        $id='20261006T120000Z_action';$state=[ordered]@{schemaVersion=1;sessionId=$id;state='Observing';plan=[ordered]@{mode='IntegratedLAN';roles=@(@{role='Host';username='MMTL_Host'},@{role='Guest';username='MMTL_C1'})}}
        [IO.File]::WriteAllText((Join-Path $session 'scenario.json'),($state|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $session 'pids.json'),(@([pscustomobject]@{PID=77;Role='Client';Username='MMTL_C1'})|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        New-Item -ItemType Directory -Path (Join-Path $session 'agent')|Out-Null
        $token='unit-token-0123456789abcdef0123456789';[IO.File]::WriteAllText((Join-Path $session 'agent/session-token.txt'),$token,[Text.UTF8Encoding]::new($false))
        $request=New-MmtlAgentActionRequest -SessionPath $session -Role Guest -Action SEND_COMMAND -Command 'say hello' -PermissionGranted
        $line=Get-Content -LiteralPath $request.requestPath -Raw
        $line | Should -Not -Match 'say hello|unit-token'
        $record=$line|ConvertFrom-Json
        $record.role | Should -Be 'Guest';$record.actionId | Should -Match '^[a-f0-9]{32}$';$record.signature | Should -Match '^[a-f0-9]{64}$'
        {New-MmtlAgentActionRequest -SessionPath $session -Role Guest -Action SEND_COMMAND -Command 'say hello'} | Should -Throw '*SCENARIO_COMMAND_PERMISSION_REQUIRED*'
        $eventDirectory=Join-Path $session 'agent-events';New-Item -ItemType Directory -Path $eventDirectory -Force|Out-Null;$eventPath=Join-Path $eventDirectory 'guest.jsonl'
        $fake=[ordered]@{schemaVersion=1;sessionId=$id;eventId='event-1';eventType='ACTION_COMPLETED';timestampUtc=[DateTimeOffset]::UtcNow.ToString('o');role='Guest';sessionNonceHash=('a'*64);summary='completed';actionId=$record.actionId}
        [IO.File]::WriteAllText($eventPath,(($fake|ConvertTo-Json -Compress)+"`n"),[Text.UTF8Encoding]::new($false))
        (Wait-MmtlAgentAction -Request $request -TimeoutSeconds 1).completed | Should -BeTrue
    }
    It '拒绝链接 token 和越界 Agent 队列' {
        $session=Join-Path $TestDrive 'linked-action-session';New-Item -ItemType Directory -Path $session|Out-Null
        $id='20261006T120001Z_action';$state=[ordered]@{schemaVersion=1;sessionId=$id;state='Observing';plan=[ordered]@{mode='Single';roles=@(@{role='Client';username='MMTL_Host'})}}
        [IO.File]::WriteAllText((Join-Path $session 'scenario.json'),($state|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $session 'pids.json'),(@([pscustomobject]@{PID=78;Role='Client';Username='MMTL_Host'})|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));New-Item -ItemType Directory -Path (Join-Path $session 'agent')|Out-Null
        $outside=Join-Path $TestDrive 'outside-token.txt';[IO.File]::WriteAllText($outside,'unit-token-0123456789abcdef0123456789',[Text.UTF8Encoding]::new($false))
        New-Item -ItemType SymbolicLink -Path (Join-Path $session 'agent/session-token.txt') -Target $outside|Out-Null
        {New-MmtlAgentActionRequest -SessionPath $session -Role Client -Action SCREENSHOT} | Should -Throw '*SCENARIO_AGENT_ACTION_REPARSE_POINT*'
    }
}
