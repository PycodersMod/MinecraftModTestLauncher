BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
    Import-Module (Join-Path $source 'Observation/CrashObserver.psm1') -Force
}

Describe 'Failure classification stays distinct' {
    It '将当前登记 client crash report 分类为 CLIENT_CRASH' {
        $session=Join-Path $TestDrive ('session_crash_'+[guid]::NewGuid().ToString('N'));$runtime=Join-Path $session 'Client'
        New-Item -ItemType Directory -Path (Join-Path $runtime 'crash-reports') -Force|Out-Null
        Set-Content (Join-Path $runtime 'crash-reports/crash-test.txt') 'Synthetic crash fixture'
        $id=[IO.Path]::GetFileName($session)
        @([pscustomobject]@{PID=7;Role='Client';StartIdentity='id7';RuntimeDirectory=$runtime})|ConvertTo-Json|Set-Content (Join-Path $session 'pids.json')
        $result=Invoke-MmtlCrashObserver -SessionPath $session
        $result.classifications[0].code | Should -Be 'CLIENT_CRASH'
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'CRASH_DETECTED'
    }

    It '将 build 退出失败与 client crash 分开' {
        $session=Join-Path $TestDrive ('session_build_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $session -Force|Out-Null
        @([pscustomobject]@{PID=8;Role='Build';StartIdentity='id8';StatePath=(Join-Path $session 'process-8.exit.json')})|ConvertTo-Json|Set-Content (Join-Path $session 'pids.json')
        [pscustomobject]@{PID=8;ExitCode=1;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');StopRequested=$false} | ConvertTo-Json | Set-Content (Join-Path $session 'process-8.exit.json')
        $result=Invoke-MmtlCrashObserver -SessionPath $session
        $result.classifications[0].code | Should -Be 'BUILD_FAILED'
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'BUILD_FAILED'
    }
}
