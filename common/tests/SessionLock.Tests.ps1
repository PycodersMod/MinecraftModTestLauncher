BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/SessionLock.psm1') -Force
    Import-Module (Join-Path $script:root 'src/AtomicFile.psm1') -Force
    function New-TestLockArea { $root=Join-Path $TestDrive 'runtime/sessions';$session=Join-Path $root 'fixture-session';New-Item -ItemType Directory -Path $session -Force|Out-Null;[pscustomobject]@{root=$root;session=$session;lock=(Join-Path $session '.session.lock')} }
}

Describe 'Session 互斥锁与原子文件' {
    It '记录 PID、进程启动身份、UTC 时间与 nonce，并拒绝第二 writer' {
        $area=New-TestLockArea;$owner=New-MmtlSessionLock -LockPath $area.lock -AllowedRoot $area.root
        try {
            $owner.ownerPid | Should -Be $PID
            $owner.processStartIdentity | Should -Not -BeNullOrEmpty
            $owner.createdUtc | Should -Match 'Z$|\+00:00$'
            $owner.nonce | Should -Not -BeNullOrEmpty
            {New-MmtlSessionLock -LockPath $area.lock -AllowedRoot $area.root -TimeoutSeconds 0} | Should -Throw '*SESSION_LOCKED*'
        } finally {Remove-MmtlSessionLock -Lock $owner}
    }

    It 'owner identity 不匹配时拒绝释放且过期 owner 可被诊断为 Stale' {
        $area=New-TestLockArea;$owner=New-MmtlSessionLock -LockPath $area.lock -AllowedRoot $area.root
        {Remove-MmtlSessionLock -Lock $owner -Nonce 'wrong'} | Should -Throw '*SESSION_LOCK_OWNER_MISMATCH*'
        Remove-MmtlSessionLock -Lock $owner
        @{ownerPid=2147483647;processStartIdentity='2000-01-01T00:00:00.0000000Z';createdUtc=[DateTimeOffset]::UtcNow.ToString('o');nonce='fixture';schemaVersion=1}|ConvertTo-Json|Set-Content $area.lock
        (Get-MmtlSessionLockStatus -LockPath $area.lock -AllowedRoot $area.root).status | Should -BeExactly 'Stale'
    }

    It '拒绝锁路径穿越与链接目录' {
        $area=New-TestLockArea
        {New-MmtlSessionLock -LockPath (Join-Path $TestDrive 'outside.lock') -AllowedRoot $area.root -TimeoutSeconds 0} | Should -Throw '*SESSION_LOCK_PATH_OUTSIDE_ROOT*'
        $outside=Join-Path $TestDrive 'outside';New-Item -ItemType Directory -Path $outside -Force|Out-Null
        $link=Join-Path $area.root 'linked';New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop|Out-Null
        {New-MmtlSessionLock -LockPath (Join-Path $link 'lock') -AllowedRoot $area.root -TimeoutSeconds 0} | Should -Throw '*SESSION_LOCK_PATH_REPARSE_POINT*'
    }

    It '原子替换目标文件且不遗留临时文件' {
        $area=New-TestLockArea;$target=Join-Path $area.session 'state.json';Set-Content $target 'old'

        Write-MmtlAtomicTextFile -Path $target -Content 'new'

        (Get-Content $target -Raw).Trim() | Should -BeExactly 'new'
        @(Get-ChildItem $area.session -Filter '.state.json.*.tmp' -File).Count | Should -Be 0
    }
}
