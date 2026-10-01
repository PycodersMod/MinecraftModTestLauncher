BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/RuntimeManager.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/ProcessManager.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Linux.Process.psm1') -Force
}

Import-Module (Join-Path $PSScriptRoot '../src/Platform/Platform.psm1') -Force
if((Get-MmtlPlatformProvider).OS -eq 'Linux') {
    Describe 'Linux process identity and stop safety' {
        It 'parses comm containing spaces and parentheses without shifting stat fields' {
            $tail=@('S','42')+@('0')*17+@('987654')
            $text="123 (worker (test) process) $($tail -join ' ')"
            $stat=ConvertFrom-MmtlLinuxProcStat -Text $text
            $stat.PID | Should -Be 123
            $stat.Comm | Should -Be 'worker (test) process'
            $stat.ParentPID | Should -Be 42
            $stat.SessionID | Should -Be 0
            $stat.StartTimeToken | Should -Be '987654'
        }

        It 'rejects a mismatched PID or starttime identity token' {
            $actual=Get-MmtlLinuxProcessRecord -ProcessId $PID
            $wrongPid=[pscustomobject]@{PID=($actual.PID+1);StartIdentity=$actual.StartIdentity;Executable=$actual.Executable;CommandLine=$actual.CommandLine}
            $wrongStart=[pscustomobject]@{PID=$actual.PID;StartIdentity='not-the-start-token';Executable=$actual.Executable;CommandLine=$actual.CommandLine}
            (Test-MmtlLinuxProcessIdentity -Process $actual -Record $wrongPid) | Should -BeFalse
            (Test-MmtlLinuxProcessIdentity -Process $actual -Record $wrongStart) | Should -BeFalse
        }

        It 'registers, snapshots, and stops only its own tracked child process' {
            $runtime=Join-Path $TestDrive 'runtime';$sessions=Join-Path $runtime 'sessions';$session=Join-Path $sessions 'unit';$logs=Join-Path $session 'logs'
            New-Item -ItemType Directory -Path $logs -Force|Out-Null
            '[]'|Set-Content (Join-Path $session 'pids.json')
            $log=Join-Path $logs 'parent.log';$pidValue=$null
            try {
                $childScript=Join-Path $TestDrive 'parent.sh'
                [IO.File]::WriteAllText($childScript,"#!/bin/sh`n/bin/sleep 30 &`nwait`n",[Text.UTF8Encoding]::new($false))
                $mode=[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute
                [IO.File]::SetUnixFileMode($childScript,$mode)
                $pidValue=Start-MmtlTrackedProcess -SessionPath $session -FilePath $childScript -WorkingDirectory $TestDrive -LogPath $log
                $entry=@(Get-Content (Join-Path $session 'pids.json') -Raw|ConvertFrom-Json)[0]
                $originalEntry=($entry|ConvertTo-Json -Depth 10|ConvertFrom-Json)
                $entry.PID | Should -Be $pidValue
                $entry.StartIdentity | Should -Not -BeNullOrEmpty
                $deadline=[DateTime]::UtcNow.AddSeconds(5);$snapshot=@()
                do{$snapshot=@(Get-MmtlProcessSnapshot -RootProcessId $pidValue);if($snapshot.Count -lt 2){Start-Sleep -Milliseconds 100}}while($snapshot.Count -lt 2 -and [DateTime]::UtcNow -lt $deadline)
                $snapshot.Count | Should -BeGreaterOrEqual 2
                $snapshot[0].PID | Should -Be $pidValue
                @($snapshot|Where-Object Depth -eq 1).Count | Should -BeGreaterOrEqual 1
                (Test-MmtlProcessIdentity -Process (Get-MmtlLinuxProcessRecord -ProcessId $pidValue) -Record $entry) | Should -BeTrue
                $entry.StartIdentity='incorrect-token';Write-MmtlPidRegistry -Path (Join-Path $session 'pids.json') -Entries @($entry)
                { Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $pidValue -Confirm:$false } | Should -Throw
                (Get-MmtlLinuxProcessRecord -ProcessId $pidValue) | Should -Not -BeNullOrEmpty
                $entry.StartIdentity=$originalEntry.StartIdentity;$entry.StartTimeToken=$originalEntry.StartTimeToken;Write-MmtlPidRegistry -Path (Join-Path $session 'pids.json') -Entries @($entry)
                Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $pidValue -Confirm:$false | Should -BeTrue
                (Get-MmtlLinuxProcessRecord -ProcessId $pidValue) | Should -BeNullOrEmpty
            } finally {
                if($pidValue){$registered=@(Get-Content (Join-Path $session 'pids.json') -Raw|ConvertFrom-Json);$current=Get-MmtlLinuxProcessRecord -ProcessId $pidValue;if($registered.Count -and $originalEntry -and $current -and (Test-MmtlLinuxProcessIdentity -Process $current -Record $originalEntry)){Write-MmtlPidRegistry -Path (Join-Path $session 'pids.json') -Entries @($originalEntry);Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $pidValue -Confirm:$false|Out-Null}}
            }
        }
    }
}
