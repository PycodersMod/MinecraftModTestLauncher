BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/Platform/Platform.psm1') -Force
    Set-MmtlPlatformProvider ([pscustomobject]@{OS='Windows';Arch='x64';PathComparison='OrdinalIgnoreCase';DefaultRuntimeRoot='';JavaExecutable='java.exe';JavacExecutable='javac.exe';GradleWrapper='gradlew.bat';WindowManagement='Native';ProcessManagement='Native';FabricRuntimeLink='Native';IsWSL=$false})
    Import-Module (Join-Path $script:root 'src/SessionLock.psm1') -Force
    Import-Module (Join-Path $script:root 'src/SessionRecovery.psm1') -Force
    function New-RecoveryFixture {
        $runtime=Join-Path $TestDrive ('runtime-'+[guid]::NewGuid().ToString('N'));$sessions=Join-Path $runtime 'sessions';$sessionId='fixture-'+[guid]::NewGuid().ToString('N').Substring(0,8);$session=Join-Path $sessions $sessionId
        New-Item -ItemType Directory -Path $session -Force|Out-Null
        [pscustomobject]@{runtime=$runtime;sessions=$sessions;session=$session;sessionId=$sessionId;lock=(Join-Path $session '.session.lock')}
    }
    function Write-StaleSessionLock($Path,[int]$OwnerProcessId=2147483647,[string]$Identity='0') {
        @{schemaVersion=1;ownerPid=$OwnerProcessId;processStartIdentity=$Identity;createdUtc='2000-01-01T00:00:00Z';nonce='fixture'}|ConvertTo-Json -Compress|Set-Content -LiteralPath $Path
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

    It '损坏 manifest 只报告且保持原字节' {
        $fixture=New-RecoveryFixture;Write-StaleSessionLock $fixture.lock
        $manifest=Join-Path $fixture.session 'session.v2.json';Set-Content $manifest '{broken';$before=(Get-FileHash $manifest -Algorithm SHA256).Hash

        $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $fixture.runtime
        $result=Invoke-MmtlSessionRecovery -RuntimeRoot $fixture.runtime -Plan $plan

        $plan.actions.code | Should -Contain 'SESSION_MANIFEST_CORRUPT'
        $result.recovered | Should -Be 0
        (Get-FileHash $manifest -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It '确认 owner 已崩溃后将非终态 manifest 标记为 Abandoned' {
        $fixture=New-RecoveryFixture;Write-StaleSessionLock $fixture.lock
        @{schemaVersion=2;sessionId=$fixture.sessionId;state='Running';createdUtc='2000-01-01T00:00:00Z';updatedUtc='2000-01-01T00:00:00Z';planFile='execution-plan.json';planDigest=('sha256:'+('a'*64));planSha256=('sha256:'+('b'*64));artifacts=@()}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $fixture.session 'session.v2.json')

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
