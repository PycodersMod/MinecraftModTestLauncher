BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:catalogPath = Join-Path $script:repoRoot 'compatibility/forge-build-artifacts.json'
    $script:schemaPath = Join-Path $script:repoRoot 'common/schemas/forge-build-artifacts.schema.json'
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/ForgeSecureBuild.psm1') -Force
}

Describe 'Pinned Forge 1.8 project build artifact closure' {
    It 'locks every artifact observed by the official MDK build to an approved HTTPS source' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $catalog.schemaVersion | Should -Be 1
        $catalog.targetId | Should -BeExactly 'Forge@1.8'
        $catalog.resolver | Should -BeExactly 'Gradle 2.7 official MDK build cache capture'
        $catalog.artifactStatus | Should -BeExactly 'HashesVerified'
        $catalog.targetBuildStatus | Should -BeExactly 'PendingRunnerValidation'
        @($catalog.artifacts).Count | Should -Be 128
        @($catalog.artifacts | Where-Object extension -CEQ 'jar').Count | Should -Be 58
        @($catalog.artifacts | Where-Object extension -CEQ 'pom').Count | Should -Be 68
        @($catalog.artifacts | Where-Object extension -CEQ 'zip').Count | Should -Be 2

        $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($artifact in $catalog.artifacts) {
            $artifact.bytes | Should -BeGreaterThan 0
            $artifact.sha256 | Should -Match '^[a-f0-9]{64}$'
            $artifact.file | Should -Match ('\.' + [regex]::Escape([string]$artifact.extension) + '$')
            $artifact.url | Should -Match '^https://(maven\.minecraftforge\.net|libraries\.minecraft\.net)/'
            $key = "$($artifact.group):$($artifact.artifact):$($artifact.version):$($artifact.file)"
            $keys.Add($key) | Should -BeTrue
        }

        $json = ConvertTo-Json -InputObject $catalog -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath | Should -BeTrue
        $core = [pscustomobject][ordered]@{
            schemaVersion = [int]$catalog.schemaVersion
            targetId = [string]$catalog.targetId
            resolver = [string]$catalog.resolver
            artifactStatus = [string]$catalog.artifactStatus
            targetBuildStatus = [string]$catalog.targetBuildStatus
            artifacts = @($catalog.artifacts)
        }
        $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 20 -Compress)))).ToLowerInvariant()
        $catalog.catalogHash | Should -BeExactly $actualHash

        $resolved = Get-MmtlForgeBuildArtifactCatalog -CatalogPath $script:catalogPath
        $resolved.catalogHash | Should -BeExactly $catalog.catalogHash
        $resolved.artifacts.Count | Should -Be 128
    }

    It 'does not accept HTTP or unapproved artifact hosts' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $catalog.artifacts[0].url = $catalog.artifacts[0].url.Replace('https://', 'http://')
        $json = ConvertTo-Json -InputObject $catalog -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
        $catalog.artifacts[0].url = 'https://example.invalid/artifact.jar'
        $json = ConvertTo-Json -InputObject $catalog -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'rejects an altered catalog before building any artifact mirror' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $catalog.artifacts[0].sha256 = ('0' * 64)
        $tamperedPath = Join-Path $TestDrive 'forge-build-artifacts-tampered.json'
        $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tamperedPath
        { Get-MmtlForgeBuildArtifactCatalog -CatalogPath $tamperedPath } | Should -Throw '*FORGE_BUILD_ARTIFACT_CATALOG_HASH_MISMATCH*'
    }
}
