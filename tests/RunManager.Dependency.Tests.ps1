BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/RunManager.psm1') -Force
    $script:supportsNativeFabricLink = (Get-MmtlPlatformProvider).FabricRuntimeLink -eq 'Native'
}

Describe 'RunManager 模块依赖' {
    It '独立导入后可安全创建 Fabric Runtime junction' -Skip:(-not $script:supportsNativeFabricLink) {
        $root = Join-Path $TestDrive 'fabric-project'
        $session = Join-Path $TestDrive 'runtime\sessions\one'
        $runtime = Join-Path $session 'Dev'
        New-Item -ItemType Directory -Path $root, $runtime -Force | Out-Null

        $link = New-MmtlFabricRuntimeLink -ProjectRoot $root -SessionPath $session -TargetPath $runtime -Name 'client'
        try {
            (Get-Item -LiteralPath $link).LinkType | Should -Be 'Junction'
            [IO.Path]::GetFullPath((Get-Item -LiteralPath $link).Target) | Should -Be ([IO.Path]::GetFullPath($runtime))
        }
        finally {
            if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
        }
    }
}
