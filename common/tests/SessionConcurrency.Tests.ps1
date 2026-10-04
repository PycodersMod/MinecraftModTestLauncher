BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/Platform/Platform.psm1') -Force
    $repoRoot=Split-Path -Parent $script:root
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){$platformDir='windows';$provider='WindowsPlatformProvider.psm1';$register='Register-MmtlWindowsPlatform'}elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$platformDir='linux';$provider='LinuxPlatformProvider.psm1';$register='Register-MmtlLinuxPlatform'}else{$platformDir='macos';$provider='MacOSPlatformProvider.psm1';$register='Register-MmtlMacOSPlatform'}
    Import-Module (Join-Path $repoRoot "$platformDir/src/$provider") -Force
    & $register -RepositoryRoot $repoRoot
    Import-Module (Join-Path $script:root 'src/SessionManager.psm1') -Force
}

Describe 'Session 并发创建与排序' {
    It '竞争创建的多个独立 PowerShell 进程产生不同 Session 且都完整' {
        $runtime=Join-Path $TestDrive 'runtime';$module=Join-Path $script:root 'src/SessionManager.psm1'
        $jobs=1..4|ForEach-Object { Start-Job -ArgumentList $runtime,$module -ScriptBlock { param($root,$path);$source=Join-Path (Split-Path -Parent $path) 'Platform/Platform.psm1';Import-Module $source -Force;Set-MmtlPlatformProvider ([pscustomobject]@{OS='Windows';Arch='x64';PathComparison='OrdinalIgnoreCase';DefaultRuntimeRoot='';JavaExecutable='java.exe';JavacExecutable='javac.exe';GradleWrapper='gradlew.bat';WindowManagement='Native';ProcessManagement='Native';FabricRuntimeLink='Native';IsWSL=$false});Import-Module $path -Force;New-MmtlSession -RuntimeRoot $root -Name 'parallel' -Metadata ([pscustomobject]@{players=1}) } }
        try {
            $paths=@(Receive-Job -Job $jobs -Wait -AutoRemoveJob -ErrorAction Stop)
            $paths.Count | Should -Be 4
            @($paths|Select-Object -Unique).Count | Should -Be 4
            foreach($path in $paths){Test-Path (Join-Path $path 'session.json')|Should -BeTrue;Test-Path (Join-Path $path 'pids.json')|Should -BeTrue}
        } finally {$jobs|Remove-Job -Force -ErrorAction SilentlyContinue}
    }

    It '第二 writer 无法同时获得同一 Session 锁' {
        $runtime=Join-Path $TestDrive 'writer-runtime';$session=Join-Path $runtime 'sessions/one';New-Item -ItemType Directory -Path $session -Force|Out-Null
        Import-Module (Join-Path $script:root 'src/SessionLock.psm1') -Force
        $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
        try { {New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session -TimeoutSeconds 0} | Should -Throw '*SESSION_LOCKED*' }
        finally {Remove-MmtlSessionLock $lock}
    }
}
