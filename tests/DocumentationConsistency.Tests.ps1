BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
}

Describe 'Public documentation consistency' {
    It 'keeps Phase A through F implementation boundaries aligned in README and architecture docs' {
        $readme=Get-Content (Join-Path $script:repoRoot 'README.md') -Raw
        $architecture=Get-Content (Join-Path $script:repoRoot 'docs/architecture-v2.md') -Raw
        foreach($phase in 'A','B','C','D','E','F'){$readme | Should -Match "(?i)Phase $phase";$architecture | Should -Match "(?i)Phase $phase"}
        $readme | Should -Match 'Phase F 已完成'
        $architecture | Should -Match 'Phase F 完成'
        $architecture | Should -Not -Match 'Linux/macOS Runtime、路径 provider、进程树实现、launcher\.sh。'
    }

    It 'documents the exact coverage queries and does not start Phase G' {
        $readme=Get-Content (Join-Path $script:repoRoot 'README.md') -Raw
        foreach($option in @('--coverage-report','--json','--coverage-gaps','--coverage-version','--catalog-offline','--loader-offline')){$readme | Should -Match ([regex]::Escape($option))}
        $architecture=Get-Content (Join-Path $script:repoRoot 'docs/architecture-v2.md') -Raw
        $architecture | Should -Match '## Phase F'
        $architecture | Should -Match 'Phase G 或后续阶段'
        $architecture | Should -Match 'Ornithe 官方 game-support 记录不会单独推导 Ornithe Loader 候选'
    }

    It 'keeps provider outages and explicit unmapped versions separate from audit invariant failures' {
        $workflow=Get-Content (Join-Path $script:repoRoot '.github/workflows/live-coverage.yml') -Raw
        $workflow | Should -Match 'Provider health warnings'
        $workflow | Should -Match 'Coverage errors \(explicit provider/data gaps\)'
        $workflow | Should -Match 'Invariant errors/blockers'
        $workflow | Should -Match 'if \(\$invariantErrors.Count -gt 0\)'
        $workflow | Should -Not -Match 'Where-Object severity -in @\(''Error'', ''Blocker''\)'
        $workflow | Should -Not -Match 'UNMAPPED_UPSTREAM_VERSION'
    }
}
