BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/SessionLock.psm1') -Force
    $platformRoot=Split-Path -Parent $script:repoRoot
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){Import-Module (Join-Path $platformRoot 'windows/src/WindowsPlatformProvider.psm1') -Force;Register-MmtlWindowsPlatform -RepositoryRoot $platformRoot}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){Import-Module (Join-Path $platformRoot 'linux/src/LinuxPlatformProvider.psm1') -Force;Register-MmtlLinuxPlatform -RepositoryRoot $platformRoot}else{Import-Module (Join-Path $platformRoot 'macos/src/MacOSPlatformProvider.psm1') -Force;Register-MmtlMacOSPlatform -RepositoryRoot $platformRoot}
    Import-Module (Join-Path $script:repoRoot 'src/ProcessManager.psm1') -Force
    $script:supportsProcessManagement = [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows) -or [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)
}

Describe 'ProcessManager 模块依赖' {
    It 'PID 登记写入遵守 Session 元数据锁并原子替换 registry' {
        Import-Module (Join-Path $script:repoRoot 'src/SessionLock.psm1')
        $runtime=Join-Path $TestDrive 'runtime-registry-lock';$session=Join-Path $runtime 'sessions/registry-lock';New-Item -ItemType Directory -Path $session -Force|Out-Null
        $registry=Join-Path $session 'pids.json';'[]'|Set-Content -LiteralPath $registry
        $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
        try{{Write-MmtlPidRegistry -Path $registry -Entries @([pscustomobject]@{PID=41})} | Should -Throw '*SESSION_LOCKED*'}finally{Remove-MmtlSessionLock -Lock $lock}

        Write-MmtlPidRegistry -Path $registry -Entries @([pscustomobject]@{PID=42})

        @(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json).PID | Should -Be 42
        @(Get-ChildItem -LiteralPath $session -Filter '.pids.json.*.tmp' -File).Count | Should -Be 0
    }

    It '独立导入后可登记并安全停止当前 Session 的子进程' -Skip:(-not $script:supportsProcessManagement) {
        $runtime = Join-Path $TestDrive 'runtime'
        $session = Join-Path $runtime 'sessions\tracked-process'
        $logs = Join-Path $session 'logs'
        New-Item -ItemType Directory -Path $logs -Force | Out-Null
        '[]' | Set-Content -LiteralPath (Join-Path $session 'pids.json')

        $powerShell = (Get-Process -Id $PID).Path
        $processId = Start-MmtlTrackedProcess -SessionPath $session -FilePath $powerShell -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -WorkingDirectory $TestDrive -LogPath (Join-Path $logs 'tracked.log')
        try {
            (Get-Process -Id $processId -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
            (Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $processId) | Should -BeTrue
            (Get-Process -Id $processId -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
        finally {
            if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
                Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $processId | Out-Null
            }
        }
    }

    It '登记失败且 PID 身份已变化时不会终止新进程' {
        $runtime=Join-Path $TestDrive 'runtime-identity-change'
        $session=Join-Path $runtime 'sessions/identity-change'
        $logs=Join-Path $session 'logs'
        New-Item -ItemType Directory -Path $logs -Force|Out-Null
        '{invalid'|Set-Content -LiteralPath (Join-Path $session 'pids.json')

        $originalApi=$global:MmtlPlatformProvider.ProcessApi
        $originalCapability=$global:MmtlPlatformProvider.ProcessManagement
        $global:MmtlPlatformProvider.ProcessManagement='Native'
        $calls=@{count=0;pid=0}
        $global:MmtlPlatformProvider.ProcessApi=[pscustomobject]@{
            ProcessManagement='Native'
            GetRecord=({param($id)$calls.count++;$calls.pid=$id;[pscustomobject]@{PID=$id;StartIdentity=$(if($calls.count -eq 1){'original'}else{'reused'});StartTimeUtc='';StartTimeToken='';Executable='';ParentPID=0;CommandLine='';SessionID=$null}}).GetNewClosure()
            TestIdentity=({param($process,$record)[string]$process.StartIdentity -ceq [string]$record.StartIdentity}).GetNewClosure()
        }
        $processId=0
        try {
            $powerShell=(Get-Process -Id $PID).Path
            {Start-MmtlTrackedProcess -SessionPath $session -FilePath $powerShell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WorkingDirectory $TestDrive -LogPath (Join-Path $logs 'identity.log')} | Should -Throw
            $processId=$calls.pid
            $processId|Should -BeGreaterThan 0
            (Get-Process -Id $processId -ErrorAction SilentlyContinue)|Should -Not -BeNullOrEmpty
        } finally {
            if($processId){Get-Process -Id $processId -ErrorAction SilentlyContinue|Stop-Process -Force -ErrorAction SilentlyContinue}
            $global:MmtlPlatformProvider.ProcessApi=$originalApi
            $global:MmtlPlatformProvider.ProcessManagement=$originalCapability
        }
    }
}
