BeforeAll { $script:root=Split-Path -Parent $PSScriptRoot;$script:launcher=$env:MMTL_PLATFORM_ENTRYPOINT;$script:pwsh=(Get-Command pwsh -ErrorAction Stop).Source }
Describe 'Loader CLI options' {
    It 'requires a Minecraft ID for --list-loaders before configuration/network access' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --list-loaders 2>&1|Out-String
        $LASTEXITCODE | Should -Not -Be 0;$output | Should -Match '--list-loaders 缺少 Minecraft 版本 ID'
    }
    It 'requires both Minecraft ID and loader ID for --loader-info' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --loader-info 1.20.1 2>&1|Out-String
        $LASTEXITCODE | Should -Not -Be 0;$output | Should -Match '--loader-info 需要 Minecraft 版本 ID 和 Loader ID'
    }
    It 'rejects loader IDs outside the declared loader identities before network access' {
        $unknown=& $script:pwsh -NoProfile -File $script:launcher --loader-info 1.20.1 UnknownLoader 2>&1|Out-String
        $LASTEXITCODE | Should -Not -Be 0;$unknown | Should -Match '不支持的 Loader'
    }
}
