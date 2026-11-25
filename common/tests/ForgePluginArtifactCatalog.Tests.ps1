BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:catalogPath = Join-Path $script:repoRoot 'compatibility/forge-plugin-artifacts.json'
    $script:schemaPath = Join-Path $script:repoRoot 'common/schemas/forge-plugin-artifacts.schema.json'
}

Describe 'Pinned ForgeGradle Plugins DSL artifact closure' {
    It 'locks the complete Forge 1.8 plugin dependency closure without claiming Runner validation' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $catalog.schemaVersion | Should -Be 1
        $catalog.targetId | Should -BeExactly 'Forge@1.8'
        $catalog.pluginId | Should -BeExactly 'net.minecraftforge.gradle.forge'
        $catalog.pluginVersion | Should -BeExactly '2.0.2'
        $catalog.implementationCoordinate | Should -BeExactly 'gradle.plugin.net.minecraftforge.gradle:ForgeGradle:2.0.2'
        $catalog.sourceRepository | Should -BeExactly 'https://plugins.gradle.org/m2'
        $catalog.artifactStatus | Should -BeExactly 'HashesVerified'
        $catalog.targetBuildStatus | Should -BeExactly 'PendingRunnerValidation'
        $catalog.mcpVersions.url | Should -BeExactly 'https://maven.minecraftforge.net/de/oceanlabs/mcp/versions.json'
        $catalog.mcpVersions.bytes | Should -Be 26705
        $catalog.mcpVersions.sha256 | Should -BeExactly 'df5875099a4191293a4d36df5cc95086eb95eed4d4549a7a976e847ee3ae5156'
        $catalog.mcpMapping | Should -BeExactly 'snapshot_20141130'
        $catalog.forgeVersionMetadataFallback | Should -BeExactly 'ExactPinnedTargetOnly'
        @($catalog.artifacts).Count | Should -Be 54
        @($catalog.artifacts | Where-Object extension -CEQ 'jar').Count | Should -Be 19
        @($catalog.artifacts | Where-Object extension -CEQ 'pom').Count | Should -Be 35

        foreach ($artifact in $catalog.artifacts) {
            $artifact.bytes | Should -BeGreaterThan 0
            $artifact.sha256 | Should -Match '^[a-f0-9]{64}$'
            $artifact.url | Should -Match '^https://plugins\.gradle\.org/m2/'
            $artifact.file | Should -Match ('\.' + [regex]::Escape([string]$artifact.extension) + '$')
        }

        $core = [pscustomobject][ordered]@{
            schemaVersion = [int]$catalog.schemaVersion
            targetId = [string]$catalog.targetId
            pluginId = [string]$catalog.pluginId
            pluginVersion = [string]$catalog.pluginVersion
            implementationCoordinate = [string]$catalog.implementationCoordinate
            sourceRepository = [string]$catalog.sourceRepository
            resolver = [string]$catalog.resolver
            javaMajor = [int]$catalog.javaMajor
            artifactStatus = [string]$catalog.artifactStatus
            targetBuildStatus = [string]$catalog.targetBuildStatus
            mcpVersions = [pscustomobject][ordered]@{url=[string]$catalog.mcpVersions.url;bytes=[long]$catalog.mcpVersions.bytes;sha256=[string]$catalog.mcpVersions.sha256}
            mcpMapping = [string]$catalog.mcpMapping
            forgeVersionMetadataFallback = [string]$catalog.forgeVersionMetadataFallback
            artifacts = @($catalog.artifacts)
        }
        $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 20 -Compress)))).ToLowerInvariant()
        $catalog.catalogHash | Should -BeExactly $actualHash
    }
}
