BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/ProcessManager.psm1') -Force
    $script:supportsProcessManagement = (Get-MmtlPlatformProvider).OS -in @('Windows', 'Linux')
}

Describe 'ProcessManager 模块依赖' {
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
}
