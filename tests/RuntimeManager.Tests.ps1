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
        $provider=Get-MmtlPlatformProvider;$root=Join-Path $TestDrive 'CaseRoot';$variant=Join-Path $TestDrive 'caseroot'
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
