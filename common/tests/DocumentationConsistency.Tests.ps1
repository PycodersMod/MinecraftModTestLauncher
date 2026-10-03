BeforeAll {
    $script:repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe 'Public documentation consistency' {
    It 'keeps Phase A through F implementation boundaries aligned in README and architecture docs' {
        $readme=Get-Content (Join-Path $script:repoRoot 'README.md') -Raw
        $architecture=Get-Content (Join-Path $script:repoRoot 'docs/architecture-v2.md') -Raw
        foreach($phase in 'A','B','C','D','E','F'){$readme | Should -Match "(?i)(?:Phase|阶段) $phase";$architecture | Should -Match "(?i)(?:Phase|阶段) $phase"}
        $readme | Should -Match '(?:Phase|阶段) F 已完成'
        $architecture | Should -Match 'Phase F 完成'
        $architecture | Should -Not -Match 'Linux/macOS Runtime、路径 provider、进程树实现、launcher\.sh。'
    }

    It 'documents coverage queries and identifies Phase G as completed deep validation' {
        $readme=Get-Content (Join-Path $script:repoRoot 'README.md') -Raw
        foreach($option in @('--coverage-report','--json','--coverage-gaps','--coverage-version','--catalog-offline','--loader-offline')){$readme | Should -Match ([regex]::Escape($option))}
        $architecture=Get-Content (Join-Path $script:repoRoot 'docs/architecture-v2.md') -Raw
        $architecture | Should -Match '## 阶段 F — 全版本覆盖审计'
        $architecture | Should -Match '阶段 G — 深度验证矩阵（已完成）'
        $architecture | Should -Match 'Ornithe 官方 game-support 记录不会单独推导 Ornithe Loader 候选'
    }

    It 'keeps provider outages and explicit unmapped versions separate from audit invariant failures' {
        $workflow=Get-Content (Join-Path $script:repoRoot '.github/workflows/live-coverage.yml') -Raw
        $workflow | Should -Match 'Provider 健康警告'
        $workflow | Should -Match '覆盖错误（Provider/数据缺口）'
        $workflow | Should -Match '不变量错误/阻断项'
        $workflow | Should -Match 'if \(\$invariantErrors.Count -gt 0\)'
        $workflow | Should -Not -Match 'Where-Object severity -in @\(''Error'', ''Blocker''\)'
        $workflow | Should -Not -Match 'UNMAPPED_UPSTREAM_VERSION'
    }
}
