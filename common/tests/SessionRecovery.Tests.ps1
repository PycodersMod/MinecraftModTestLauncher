BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/Platform/Platform.psm1') -Force
    $repoRoot=Split-Path -Parent $script:root
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){$platformDir='windows';$provider='WindowsPlatformProvider.psm1';$register='Register-MmtlWindowsPlatform'}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$platformDir='linux';$provider='LinuxPlatformProvider.psm1';$register='Register-MmtlLinuxPlatform'}else{$platformDir='macos';$provider='MacOSPlatformProvider.psm1';$register='Register-MmtlMacOSPlatform'}
    Import-Module (Join-Path $repoRoot "$platformDir/src/$provider") -Force
    & $register -RepositoryRoot $repoRoot
    Import-Module (Join-Path $script:root 'src/SessionLock.psm1') -Force
    Import-Module (Join-Path $script:root 'src/SessionRecovery.psm1') -Force
    Import-Module (Join-Path $script:root 'src/Execution/ExecutionPlanner.psm1') -Force
    Import-Module (Join-Path $script:root 'src/SessionLifecycle.psm1') -Force
    function New-RecoveryFixture {
        $runtime=Join-Path $TestDrive ('runtime-'+[guid]::NewGuid().ToString('N'));$sessions=Join-Path $runtime 'sessions';$sessionId='fixture-'+[guid]::NewGuid().ToString('N').Substring(0,8);$session=Join-Path $sessions $sessionId
        New-Item -ItemType Directory -Path $session -Force|Out-Null
        [pscustomobject]@{runtime=$runtime;sessions=$sessions;session=$session;sessionId=$sessionId;lock=(Join-Path $session '.session.lock')}
    }
    function Write-StaleSessionLock($Path,[int]$OwnerProcessId=2147483647,[string]$Identity='0') {
        @{schemaVersion=1;ownerPid=$OwnerProcessId;processStartIdentity=$Identity;createdUtc='2000-01-01T00:00:00Z';nonce='fixture'}|ConvertTo-Json -Compress|Set-Content -LiteralPath $Path
    }
    function New-RecoveryTestPlan {
        $repo=Join-Path $TestDrive 'recovery-plan-repo';$projectRoot=Join-Path $repo 'mod';$jdk=Join-Path $TestDrive 'recovery-plan-jdk'
        New-Item -ItemType Directory -Path $projectRoot,(Join-Path $jdk 'bin') -Force|Out-Null
        New-Item -ItemType File -Path (Join-Path $jdk 'bin/java.exe') -Force|Out-Null
        @('JAVA_VERSION="17.0.1"','IMPLEMENTOR="Test Vendor"','OS_ARCH="amd64"')|Set-Content (Join-Path $jdk 'release')
        $platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false;capabilities=[pscustomobject]@{Build='Native';Launch='Native'}}
        $project=[pscustomobject]@{RepositoryRoot=$repo;Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';ModId='fixture';LoaderStack=[pscustomobject]@{primaryLoader=[pscustomobject]@{id='Forge';version='47.2.0'};overlayLoaders=@()};Toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'};BuildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'};BuildTask='build';Wrapper=$true;BuildJavaRequirement=[pscustomobject]@{major=17;minimumMajor=17;requirementKind='Minimum';source='Fixture';confidence='High'}}
        $profile=[pscustomobject]@{project=$projectRoot;mode='Single';players=1;hostUsername='Dev';autoBuild=$true;cleanBuild=$false;acceptEula=$false;port='Auto';memoryMb=1024;jvmArgs=@();gameArgs=@()}
        $config=[pscustomobject]@{defaultProfile='fixture';javaHomes=[pscustomobject]@{'17'=$jdk};javaHomesByPlatform=[pscustomobject]@{Windows=[pscustomobject]@{};Linux=[pscustomobject]@{};MacOS=[pscustomobject]@{}}}
        New-MmtlExecutionPlan -Project $project -Profile $profile -Config $config -Platform $platform -RuntimeRoot (Join-Path $TestDrive 'recovery-plan-runtime') -ProfileName fixture -PhysicalMemoryMb 8192
    }
}

Describe 'Session 崩溃恢复计划' {
    It 'dry-run 只读列出可恢复锁与原子写入残留，不修改文件' {
        $fixture=New-RecoveryFixture;Write-StaleSessionLock $fixture.lock
        $temp=Join-Path $fixture.session ('.session.v2.json.'+('a'*32)+'.tmp');Set-Content $temp 'partial'
        $before=(Get-FileHash $fixture.lock -Algorithm SHA256).Hash

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime

        $plan.actions | Where-Object sessionId -eq $fixture.sessionId | Where-Object code -eq 'STALE_LOCK_METADATA' | Should -Not -BeNullOrEmpty
        $plan.actions | Where-Object code -eq 'PARTIAL_ATOMIC_TEMP' | Should -Not -BeNullOrEmpty
        (Get-FileHash $fixture.lock -Algorithm SHA256).Hash | Should -BeExactly $before
        (Test-Path $temp) | Should -BeTrue
    }

    It '显式恢复只清理 stale lock 元数据与临时文件，保留 Session 内容' {
        $fixture=New-RecoveryFixture;Write-StaleSessionLock $fixture.lock
        Set-Content (Join-Path $fixture.session 'session.json') ("`{""sessionId"":""$($fixture.sessionId)""`}")
        $temp=Join-Path $fixture.session ('.session.v2.json.'+('a'*32)+'.tmp');Set-Content $temp 'partial'
        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime

        $result=Invoke-MmtlSessionRecovery -RuntimeRoot $fixture.runtime -Plan $plan

        $result.recovered | Should -Be 1
        (Get-Content $fixture.lock -Raw|ConvertFrom-Json).recoveryState | Should -BeExactly 'Recovered'
        (Test-Path $temp) | Should -BeFalse
        (Test-Path (Join-Path $fixture.session 'session.json')) | Should -BeTrue
    }

    It 'PID 复用时按启动身份判断旧锁失效' {
        $fixture=New-RecoveryFixture
        Write-StaleSessionLock $fixture.lock -OwnerProcessId $PID -Identity '0'

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime
        $action=$plan.actions|Where-Object code -eq 'STALE_LOCK_METADATA'

        $action.reasonCode | Should -BeExactly 'SESSION_LOCK_OWNER_GONE_OR_PID_REUSED'
    }

    It '缺少 owner nonce 或启动身份时不清理锁文件' {
        $fixture=New-RecoveryFixture
        @{schemaVersion=1;ownerPid=2147483647;processStartIdentity='not-an-identity';createdUtc='2000-01-01T00:00:00Z'}|ConvertTo-Json -Compress|Set-Content $fixture.lock
        $before=(Get-FileHash $fixture.lock -Algorithm SHA256).Hash

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime
        $plan.actions.code | Should -Contain 'SESSION_LOCK_OWNER_IDENTITY_UNPROVEN'
        $result=Invoke-MmtlSessionRecovery -RuntimeRoot $fixture.runtime -Plan $plan

        $result.recovered | Should -Be 0
        (Get-FileHash $fixture.lock -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It '跟踪进程仍存活时报告 OrphanedTrackedProcess 且不修改元数据' {
        $fixture=New-RecoveryFixture;Write-StaleSessionLock $fixture.lock
        $identity=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)
        @{PID=$PID;ProcessStartIdentity=$identity;Role='fixture'}|ConvertTo-Json -AsArray|Set-Content (Join-Path $fixture.session 'pids.json')
        $before=(Get-FileHash $fixture.lock -Algorithm SHA256).Hash

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime
        $result=Invoke-MmtlSessionRecovery -RuntimeRoot $fixture.runtime -Plan $plan

        $plan.actions.code | Should -Contain 'OrphanedTrackedProcess'
        $result.recovered | Should -Be 0
        (Get-FileHash $fixture.lock -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It '接受 ProcessManager 正式写入的 StartIdentity PID 登记格式' {
        Import-Module (Join-Path $script:root 'src/ProcessManager.psm1') -Force
        $fixture=New-RecoveryFixture;Write-StaleSessionLock $fixture.lock
        $record=Get-MmtlProcessRecord -ProcessId $PID
        $entry=[pscustomobject]@{PID=$PID;StartIdentity=$record.StartIdentity;StartTimeUtc=$record.StartTimeUtc;StartTimeToken=$record.StartTimeToken;Executable=$record.Executable;CommandLine=$record.CommandLine;ParentPID=$record.ParentPID;Role='fixture'}
        $api=$global:MmtlPlatformProvider.ProcessApi;$actual=& $api.GetRecord $PID
        (& $api.TestIdentity $actual $entry) | Should -BeTrue
        @($entry)|ConvertTo-Json -Depth 5|Set-Content (Join-Path $fixture.session 'pids.json')

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime

        $plan.actions.code | Should -Contain 'OrphanedTrackedProcess'
    }

    It '损坏 manifest 只报告且保持原字节' {
        $fixture=New-RecoveryFixture;Write-StaleSessionLock $fixture.lock
        $manifest=Join-Path $fixture.session 'session.v2.json';Set-Content $manifest '{broken';$before=(Get-FileHash $manifest -Algorithm SHA256).Hash

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime
        $result=Invoke-MmtlSessionRecovery -RuntimeRoot $fixture.runtime -Plan $plan

        $plan.actions.code | Should -Contain 'SESSION_MANIFEST_CORRUPT'
        $result.recovered | Should -Be 0
        (Get-FileHash $manifest -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It '有效 JSON 但缺少 schema 与 Plan 绑定的 manifest 也保持原字节' {
        $fixture=New-RecoveryFixture;Write-StaleSessionLock $fixture.lock
        $manifest=Join-Path $fixture.session 'session.v2.json';@{schemaVersion=2;sessionId=$fixture.sessionId;state='Running';updatedUtc='2000-01-01T00:00:00Z'}|ConvertTo-Json|Set-Content $manifest
        $before=(Get-FileHash $manifest -Algorithm SHA256).Hash

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime
        $result=Invoke-MmtlSessionRecovery -RuntimeRoot $fixture.runtime -Plan $plan

        $plan.actions.code | Should -Contain 'SESSION_MANIFEST_CORRUPT'
        $result.recovered | Should -Be 0
        (Get-FileHash $manifest -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It '确认 owner 已崩溃后将非终态 manifest 标记为 Abandoned' {
        Import-Module (Join-Path $script:root 'src/SessionLifecycle.psm1') -Force
        $fixture=New-RecoveryFixture;$sessionPlan=New-RecoveryTestPlan
        Initialize-MmtlSessionV2 -SessionPath $fixture.session -ExecutionPlan $sessionPlan|Out-Null
        Set-MmtlSessionV2State -SessionPath $fixture.session -State Building|Out-Null
        Write-StaleSessionLock $fixture.lock

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime
        Invoke-MmtlSessionRecovery -RuntimeRoot $fixture.runtime -Plan $plan|Out-Null

        (Get-Content (Join-Path $fixture.session 'session.v2.json') -Raw|ConvertFrom-Json).state | Should -BeExactly 'Abandoned'
    }

    It '恢复已崩溃的运行目录创建锁但保留未完成 Session 目录' {
        $fixture=New-RecoveryFixture;$creationLock=Join-Path $fixture.sessions '.creation.lock'
        Write-StaleSessionLock $creationLock

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime
        $plan.actions.code | Should -Contain 'STALE_CREATION_LOCK_METADATA'
        $result=Invoke-MmtlSessionRecovery -RuntimeRoot $fixture.runtime -Plan $plan

        $result.recovered | Should -Be 1
        (Get-Content $creationLock -Raw|ConvertFrom-Json).recoveryState | Should -BeExactly 'Recovered'
        (Test-Path $fixture.session) | Should -BeTrue
    }
}
