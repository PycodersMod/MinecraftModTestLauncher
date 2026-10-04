if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
    BeforeAll {
    $script:repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repoRoot 'common/src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'common/src/ProcessManager.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'macos/src/MacOSPlatformProvider.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'common/src/SessionRecovery.psm1') -Force
    Register-MmtlMacOSPlatform -RepositoryRoot $script:repoRoot
    $global:MmtlPlatformProvider.ProcessManagement='Native'
    $script:processApi=$global:MmtlPlatformProvider.ProcessApi
    function Get-MacOSTestProcessRecord { param([int]$ProcessId) return & $script:processApi.GetRecord $ProcessId }
    function Get-MacOSTestProcessSnapshot { param([int]$RootProcessId) return @(& $script:processApi.GetSnapshot $RootProcessId) }
    function Test-MacOSTestProcessIdentity { param($Process,$Record) return [bool](& $script:processApi.TestIdentity $Process $Record) }
    function New-MacOSTestProcess {
        param([string]$SessionPath,[string]$Name)
        $scriptPath=Join-Path $TestDrive "$Name.sh"
        [IO.File]::WriteAllText($scriptPath,"#!/bin/sh`n/bin/sleep 30 &`nwait`n",[Text.UTF8Encoding]::new($false))
        $mode=[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute
        [IO.File]::SetUnixFileMode($scriptPath,$mode)
        $logs=Join-Path $SessionPath 'logs';New-Item -ItemType Directory -Path $logs -Force|Out-Null
        '[]'|Set-Content (Join-Path $SessionPath 'pids.json')
        Start-MmtlTrackedProcess -SessionPath $SessionPath -FilePath $scriptPath -WorkingDirectory $TestDrive -LogPath (Join-Path $logs "$Name.log")
    }
    }
    Describe 'macOS 进程身份与跟踪生命周期' {
        It '默认仍将 macOS 进程能力标记为 Unsupported，避免未验证前提前承诺' {
            $provider=New-MmtlMacOSPlatformProvider -RepositoryRoot $script:repoRoot
            $provider.ProcessManagement | Should -BeExactly 'Unsupported'
            $provider.WindowManagement | Should -BeExactly 'Unsupported'
            $provider.ProcessApi.GetRecord | Should -Not -BeNullOrEmpty
        }

        It '验证 PID、start-time token、可执行命令与 PID 重用隔离' {
            $record=Get-MacOSTestProcessRecord -ProcessId $PID
            $record.PID | Should -Be $PID
            $record.StartTimeToken | Should -Not -BeNullOrEmpty
            (Test-MacOSTestProcessIdentity -Process $record -Record $record) | Should -BeTrue
            $reused=$record.PSObject.Copy();$reused.StartIdentity='reused-pid-identity'
            (Test-MacOSTestProcessIdentity -Process $record -Record $reused) | Should -BeFalse
        }

        It '兼容省略可选 ParentPID 的 Session 登记记录' {
            $record=Get-MacOSTestProcessRecord -ProcessId $PID
            $entry=[pscustomobject]@{PID=$PID;StartIdentity=$record.StartIdentity;StartTimeToken=$record.StartTimeToken;Executable=$record.Executable;CommandLine=$record.CommandLine}
            (Test-MacOSTestProcessIdentity -Process $record -Record $entry) | Should -BeTrue
        }

        It '跟踪并停止 dummy 父子进程且不影响未登记子进程' {
            $session=Join-Path $TestDrive 'sessions/tracked';New-Item -ItemType Directory -Path $session -Force|Out-Null
            $untracked=Start-Process -FilePath '/bin/sleep' -ArgumentList @('30') -PassThru
            $parent=New-MacOSTestProcess -SessionPath $session -Name 'tracked-parent'
            try {
                $deadline=[DateTime]::UtcNow.AddSeconds(8);$snapshot=@()
                do{$snapshot=@(Get-MacOSTestProcessSnapshot -RootProcessId $parent);if($snapshot.Count -lt 2){Start-Sleep -Milliseconds 100}}while($snapshot.Count -lt 2 -and [DateTime]::UtcNow -lt $deadline)
                $snapshot.Count | Should -BeGreaterOrEqual 2
                @($snapshot|Where-Object Depth -gt 0).Count | Should -BeGreaterThan 0
                $entries=@(Get-Content (Join-Path $session 'pids.json') -Raw|ConvertFrom-Json);$registered=$entries[0];$actualIdentity=$registered.StartIdentity;$registered.StartIdentity='stale-process-identity';Write-MmtlPidRegistry -Path (Join-Path $session 'pids.json') -Entries @($registered)
                {Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $parent -Confirm:$false}|Should -Throw
                (Get-MacOSTestProcessRecord -ProcessId $parent)|Should -Not -BeNullOrEmpty
                $registered.StartIdentity=$actualIdentity;Write-MmtlPidRegistry -Path (Join-Path $session 'pids.json') -Entries @($registered)
                Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $parent -Confirm:$false | Should -BeTrue
                (Get-MacOSTestProcessRecord -ProcessId $parent) | Should -BeNullOrEmpty
                (Get-MacOSTestProcessRecord -ProcessId $untracked.Id) | Should -Not -BeNullOrEmpty
            } finally {
                $tracked=@(Get-Content (Join-Path $session 'pids.json') -Raw|ConvertFrom-Json)
                if($tracked.Count -and (Get-MacOSTestProcessRecord -ProcessId $parent)){Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $parent -Confirm:$false|Out-Null}
                try{$untracked.Refresh();if(-not $untracked.HasExited){$untracked.Kill();$untracked.WaitForExit(3000)}}catch{}
            }
        }

        It '存活的登记进程会阻止 Session 恢复并报告 orphan' {
            $runtime=Join-Path $TestDrive 'orphan-runtime';$session=Join-Path $runtime 'sessions/orphan';New-Item -ItemType Directory $session -Force|Out-Null
            $record=Get-MacOSTestProcessRecord -ProcessId $PID
            $entry=[pscustomobject]@{PID=$PID;StartIdentity=$record.StartIdentity;StartTimeToken=$record.StartTimeToken;Executable=$record.Executable;CommandLine=$record.CommandLine}
            (& $script:processApi.TestIdentity $record $entry) | Should -BeTrue
            @($entry)|ConvertTo-Json -Depth 5|Set-Content (Join-Path $session 'pids.json')
            @{schemaVersion=1;ownerPid=2147483647;processStartIdentity='0';createdUtc='2000-01-01T00:00:00Z';nonce='fixture'}|ConvertTo-Json -Compress|Set-Content (Join-Path $session '.session.lock')
            $before=(Get-FileHash (Join-Path $session '.session.lock') -Algorithm SHA256).Hash

            $recoveryModule=Get-Module SessionRecovery|Select-Object -Last 1
            $tracked=& $recoveryModule {param($path)Get-MmtlRecoveryTrackedProcessState -SessionPath $path} $session
            $tracked.state | Should -BeExactly 'Alive' -Because "identity records: $($tracked.live|ConvertTo-Json -Compress)"

            $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $runtime

            $plan.actions.code | Should -Contain 'OrphanedTrackedProcess'
            $result=Invoke-MmtlSessionRecovery -RuntimeRoot $runtime -Plan $plan
            $result.recovered | Should -Be 0
            (Get-FileHash (Join-Path $session '.session.lock') -Algorithm SHA256).Hash | Should -BeExactly $before
        }
    }
}
