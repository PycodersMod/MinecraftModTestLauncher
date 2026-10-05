BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'AtomicFile.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
}

Describe 'Session Runtime Event JSONL 存储' {
    BeforeEach {
        $script:session = Join-Path $TestDrive 'session_01'
        New-Item -ItemType Directory -Path $script:session -Force | Out-Null
        $script:event = New-MmtlRuntimeEvent -SessionId session_01 -Role Client -ProcessId 7 -ProcessIdentity identity-7 -SourceType Observer -EventCode PROCESS_STARTED
    }

    It '按 UTF-8 JSONL 追加并读取事件' {
        $path = Write-MmtlRuntimeEvent -SessionPath $session -Event $event
        $path | Should -Be (Join-Path $session 'runtime-events.jsonl')
        Write-MmtlRuntimeEvent -SessionPath $session -Event (New-MmtlRuntimeEvent -SessionId session_01 -Role Client -ProcessId 7 -ProcessIdentity identity-7 -SourceType Observer -EventCode PROCESS_EXITED)
        $lines = @(Get-Content -LiteralPath $path)
        $lines.Count | Should -Be 2
        $lines | ForEach-Object { { $_ | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw }
        @(Get-MmtlRuntimeEvents -SessionPath $session).Count | Should -Be 2
    }

    It '拒绝写入其他 Session 与越界目标' {
        $other = New-MmtlRuntimeEvent -SessionId another_session -Role Client -ProcessId 7 -ProcessIdentity identity-7 -SourceType Observer -EventCode PROCESS_STARTED
        { Write-MmtlRuntimeEvent -SessionPath $session -Event $other } | Should -Throw
        { Get-MmtlRuntimeEvents -SessionPath (Join-Path $session '..\outside') } | Should -Throw
    }
}
