BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/RuntimeManager.psm1') -Force
}

Describe 'Cross-platform path safety' {
    It 'accepts the root and descendants but rejects adjacent prefixes and traversal' {
        $root = Join-Path $TestDrive 'foo'
        $inside = Join-Path $root 'child'
        $adjacent = Join-Path $TestDrive 'foobar'
        New-Item -ItemType Directory -Path $inside -Force | Out-Null
        New-Item -ItemType Directory -Path $adjacent -Force | Out-Null
        Test-MmtlInsideRoot -Root $root -Target $inside | Should -BeTrue
        Test-MmtlInsideRoot -Root $root -Target $root | Should -BeTrue
        Test-MmtlInsideRoot -Root $root -Target $adjacent | Should -BeFalse
        Test-MmtlInsideRoot -Root $root -Target (Join-Path $root '../escape') | Should -BeFalse
    }

    It 'follows the detected filesystem case policy' {
        Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1')
        $root=Join-Path $TestDrive 'CaseRoot';$variant=Join-Path $TestDrive 'caseroot';$provider=Get-MmtlPlatformProvider -Path $root
        $inside=Test-MmtlInsideRoot -Root $root -Target $variant
        if($provider.PathComparison -eq [StringComparison]::OrdinalIgnoreCase){$inside|Should -BeTrue}else{$inside|Should -BeFalse}
    }

    It 'rejects a path traversing a symbolic link' {
        $root = Join-Path $TestDrive 'links'
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $root,$outside -Force | Out-Null
        $link = Join-Path $root 'escape'
        try { New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop | Out-Null }
        catch { Set-ItResult -Skipped -Because 'Symlink creation is unavailable to this test identity.'; return }
        { Assert-MmtlNoReparsePath -Path (Join-Path $link 'child') } | Should -Throw
    }
}

Describe 'macOS Session process capability gate' {
    BeforeEach {
        $script:originalProvider=$global:MmtlPlatformProvider
        $global:MmtlPlatformProvider=[pscustomobject]@{OS='MacOS';PathComparison=[StringComparison]::Ordinal;ProcessManagement='Native';FabricRuntimeLink='Unsupported';ProcessApi=[pscustomobject]@{GetRecord={param($id)$null};TestIdentity={param($process,$entry)$false}}}
    }
    AfterEach {$global:MmtlPlatformProvider=$script:originalProvider}

    It '允许 Native macOS 删除没有存活登记进程的 Session' {
        $runtime=Join-Path $TestDrive 'mac-native-runtime';$session=Join-Path $runtime 'sessions/native';New-Item -ItemType Directory -Path $session -Force|Out-Null
        @([pscustomobject]@{PID=42;StartIdentity='ended-process'})|ConvertTo-Json|Set-Content (Join-Path $session 'pids.json')
        Remove-MmtlSession -RuntimeRoot $runtime -SessionPath $session
        Test-Path -LiteralPath $session | Should -BeFalse
    }

    It 'macOS ProcessManagement 仍为 Unsupported 时保留拒绝门禁' {
        $global:MmtlPlatformProvider.ProcessManagement='Unsupported'
        $runtime=Join-Path $TestDrive 'mac-unsupported-runtime';$session=Join-Path $runtime 'sessions/unsupported';New-Item -ItemType Directory -Path $session -Force|Out-Null
        @([pscustomobject]@{PID=42;StartIdentity='unknown-process'})|ConvertTo-Json|Set-Content (Join-Path $session 'pids.json')
        {Remove-MmtlSession -RuntimeRoot $runtime -SessionPath $session} | Should -Throw '*进程管理能力*'
        Test-Path -LiteralPath $session | Should -BeTrue
    }
}
