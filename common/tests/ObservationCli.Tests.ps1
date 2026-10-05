BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
    Import-Module (Join-Path $source 'Observation/ProcessObserver.psm1') -Force
    Import-Module (Join-Path $source 'Observation/ClientObserver.psm1') -Force
    Import-Module (Join-Path $source 'Observation/JavaRuntimeObserver.psm1') -Force
    Import-Module (Join-Path $source 'Observation/LanObserver.psm1') -Force
    Import-Module (Join-Path $source 'Observation/DedicatedServerObserver.psm1') -Force
    Import-Module (Join-Path $source 'Observation/CrashObserver.psm1') -Force
    Import-Module (Join-Path $source 'Observation/ObservationCli.psm1') -Force
}

Describe 'Observation CLI 参数与 JSON 输出' {
    BeforeEach {
        $script:runtime = Join-Path $TestDrive 'runtime'
        $script:session = Join-Path $runtime 'sessions/session_01'
        New-Item -ItemType Directory -Path $session -Force | Out-Null
        @([pscustomobject]@{PID=42;Role='Client';StartIdentity='identity-42';StatePath=(Join-Path $session 'process-42.exit.json')}) | ConvertTo-Json | Set-Content (Join-Path $session 'pids.json')
    }

    It '拒绝同时请求事件读取与进程观察' {
        { Invoke-MmtlObservationCommand -Arguments @('--observe-session','session_01','--session-events','session_01') -RuntimeRoot $runtime } | Should -Throw '*OBSERVATION_OPTION_CONFLICT*'
    }

    It 'session-events 只读取事件且保持 JSON 数组形状' {
        $event = New-MmtlRuntimeEvent -SessionId session_01 -Role Client -ProcessId 42 -ProcessIdentity identity-42 -SourceType Observer -EventCode CLIENT_INIT_DETECTED
        Write-MmtlRuntimeEvent -SessionPath $session -Event $event | Out-Null
        $result = Invoke-MmtlObservationCommand -Arguments @('--session-events','session_01','--json') -RuntimeRoot $runtime
        @($result.events).Count | Should -Be 1
        $result.sessionId | Should -Be 'session_01'
    }

    It 'observe-session 只调用当前登记进程并返回非晋级候选' {
        $lookup = { param($processId) [pscustomobject]@{ProcessId=$processId;StartIdentity='identity-42'} }
        $result = Invoke-MmtlObservationCommand -Arguments @('--observe-session','session_01') -RuntimeRoot $runtime -ProcessLookup $lookup -IdentityCheck {param($proc,$entry) $proc.StartIdentity -ceq $entry.StartIdentity}
        $result.processes[0].status | Should -Be 'Running'
        $result.validationCandidate | Should -BeFalse
    }

    It 'Launcher 实际入口输出纯 JSON 且 session-events 不启动进程观察' {
        $runtimeRoot = Join-Path $TestDrive 'cli-runtime'
        $eventSession = Join-Path $runtimeRoot 'sessions/cli_events'
        New-Item -ItemType Directory -Path $eventSession -Force | Out-Null
        $event = New-MmtlRuntimeEvent -SessionId cli_events -Role Client -ProcessId 42 -ProcessIdentity identity-42 -SourceType Observer -EventCode CLIENT_INIT_DETECTED
        Write-MmtlRuntimeEvent -SessionPath $eventSession -Event $event | Out-Null
        $config = Join-Path $TestDrive 'cli-config.json'
        [pscustomobject]@{configVersion=2;defaultProfile='test';profiles=[pscustomobject]@{test=[pscustomobject]@{project='fixture';mode='Single';players=1}};javaHomes=[pscustomobject]@{};runtimeRoot=$runtimeRoot} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config
        $launcher = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'windows/launcher.ps1'
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $output = @(& $pwsh -NoLogo -NoProfile -File $launcher --config-file $config --session-events cli_events --json 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $jsonText = $output -join "`n"
        $jsonText | Should -Not -Match '运行时观察|Minecraft 模组测试启动器'
        $actual = $jsonText | ConvertFrom-Json
        $actual.sessionId | Should -Be 'cli_events'
        $actual.eventCount | Should -Be 1
    }
}

