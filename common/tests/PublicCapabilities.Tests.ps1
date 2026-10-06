Describe 'Public Alpha 能力清单' {
    BeforeAll {
        $script:repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:capabilities=Get-Content (Join-Path $script:repoRoot 'common/config/public-capabilities.json') -Raw|ConvertFrom-Json
        $script:version=(Get-Content (Join-Path $script:repoRoot 'VERSION') -Raw).Trim()
        $script:providerRoot=Join-Path $script:repoRoot 'common/agent/providers'
        $script:manifests=@(Get-ChildItem -LiteralPath $script:providerRoot -Filter agent-manifest.json -File -Recurse -ErrorAction SilentlyContinue|ForEach-Object{[pscustomobject]@{path=$_.FullName;manifest=(Get-Content $_.FullName -Raw|ConvertFrom-Json)}})
    }

    It '版本和渠道必须与 VERSION 一致' {
        $script:capabilities.version | Should -BeExactly $script:version
        $script:capabilities.releaseChannel | Should -BeExactly 'PublicAlpha'
    }

    It '每条 Supported Agent 声明必须有对应版本 manifest 和 SHA-256 正确的 artifact' {
        foreach($declaration in @($script:capabilities.agentProviders|Where-Object status -CEQ 'Supported')){
            $matches=@($script:manifests|Where-Object{$_.manifest.providerId -ceq $declaration.providerId -and $_.manifest.loaderId -ceq $declaration.loader -and @($_.manifest.minecraftVersions) -contains $declaration.minecraft})
            $matches.Count | Should -Be 1
            $artifact=Join-Path $script:repoRoot (Join-Path 'common/agent' $matches[0].manifest.artifact)
            (Test-Path -LiteralPath $artifact -PathType Leaf) | Should -BeTrue
            (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash | Should -BeExactly $matches[0].manifest.sha256.ToUpperInvariant()
        }
    }

    It '现有 Agent manifest 不得遗漏或被误标为 Unsupported' {
        foreach($entry in $script:manifests){
            $matches=@($script:capabilities.agentProviders|Where-Object{$_.providerId -ceq $entry.manifest.providerId -and $_.loader -ceq $entry.manifest.loaderId -and $_.status -CEQ 'Supported'})
            $matches.Count | Should -Be 1
        }
    }
}
