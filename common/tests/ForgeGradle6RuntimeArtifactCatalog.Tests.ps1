BeforeAll {
    $script:repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:catalogPath=Join-Path $script:repoRoot 'compatibility/forge-gradle6-runtime-artifacts/Forge-1.16.5-Windows-x64.json'
    $script:schemaPath=Join-Path $script:repoRoot 'common/schemas/forge-gradle6-runtime-artifacts.schema.json'
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/ForgeSecureBuild.psm1') -Force
}

Describe 'ForgeGradle 6 runtime artifact catalog' {
    It 'validates the pinned Windows x64 resolved artifact snapshot and Maven POM pins' {
        $resolved=Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $script:catalogPath
        $resolved.catalogHash | Should -BeExactly '8829d0392640c83cc2139d91d53039ee0e32c6a496e462d04721d2fdeeabcebe'
        $resolved.catalog.resolvedConfigurationCount | Should -Be 12
        $resolved.catalog.resolvedArtifactObservations | Should -Be 434
        $resolved.mavenArtifacts | Should -HaveCount 43
        $resolved.catalog.mojangArtifacts | Should -HaveCount 37
        $resolved.catalog.generatedArtifacts | Should -HaveCount 4
        $resolved.supportPoms | Should -HaveCount 17
        $resolved.moduleMetadata | Should -HaveCount 7
        $resolved.dynamicMetadata | Should -HaveCount 6
        $resolved.dynamicCandidates | Should -HaveCount 7
        @($resolved.mavenArtifacts | ForEach-Object {$_.pom.sha256} | Select-Object -Unique) | Should -HaveCount 40
        (Test-Json -LiteralPath $script:catalogPath -SchemaFile $script:schemaPath) | Should -BeTrue
    }

    It 'validates an exact target-specific runtime closure without relying on the 1.16.5 catalog identity' {
        $raw=[IO.File]::ReadAllText($script:catalogPath).Replace('Forge@1.16.5','Forge@1.18.2').Replace('1.16.5','1.18.2').Replace('36.2.42','40.3.11').Replace('Gradle 8.4','Gradle 8.8')
        $catalog=$raw|ConvertFrom-Json
        $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 40 -Compress)))).ToLowerInvariant()
        $path=Join-Path $TestDrive 'Forge-1.18.2-Windows-x64-runtime.json'
        ConvertTo-Json -InputObject $catalog -Depth 40|Set-Content -LiteralPath $path -Encoding utf8

        $resolved=Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.18.2'
        $resolved.catalog.forgeVersion | Should -BeExactly '1.18.2-40.3.11'
        $resolved.catalog.platform.os | Should -BeExactly 'Windows'
        $resolved.catalog.generatedArtifacts | Should -HaveCount 4
        (Test-Json -LiteralPath $path -SchemaFile $script:schemaPath) | Should -BeTrue
    }

    It 'rejects catalog tampering when the trusted catalog hash is unchanged' {
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $catalog.mavenArtifacts[0].pom.bytes++
        $path=Join-Path $TestDrive 'tampered-forge-gradle6-runtime.json'
        ConvertTo-Json -InputObject $catalog -Depth 40 | Set-Content -LiteralPath $path -Encoding utf8
        { Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $path } | Should -Throw '*FORGE_GRADLE6_RUNTIME_CATALOG_HASH_MISMATCH*'
    }

    It 'rejects artifacts that reference a configuration absent from their resolved snapshot' {
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw|ConvertFrom-Json
        $catalog.mavenArtifacts[0].configurations=@('attackerConfiguration')
        $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 40 -Compress)))).ToLowerInvariant()
        $path=Join-Path $TestDrive 'unknown-runtime-configuration.json'
        ConvertTo-Json -InputObject $catalog -Depth 40|Set-Content -LiteralPath $path -Encoding utf8

        { Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $path } | Should -Throw '*FORGE_GRADLE6_RUNTIME_CONFIGURATION_REFERENCE_INVALID*'
    }

    It 'rejects a Maven Central URL without the canonical repository path' {
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $catalog.mavenArtifacts[0].url=$catalog.mavenArtifacts[0].url.Replace('/maven2/','/')
        $core=[ordered]@{}
        foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 40 -Compress)))).ToLowerInvariant()
        $path=Join-Path $TestDrive 'bad-url-forge-gradle6-runtime.json'
        ConvertTo-Json -InputObject $catalog -Depth 40 | Set-Content -LiteralPath $path -Encoding utf8
        { Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $path } | Should -Throw '*FORGE_GRADLE6_RUNTIME_ARTIFACT_URL_INVALID*'
    }

    It 'rejects a corrupt cached runtime artifact before mirroring any file' {
        $resolved=Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $script:catalogPath
        $cacheRoot=Join-Path $TestDrive 'forge-gradle6-runtime-cache'
        $artifactCache=Join-Path $cacheRoot 'artifact-cache'
        $null=New-Item -ItemType Directory -Path $artifactCache -Force
        $artifact=$resolved.mavenArtifacts[0]
        [IO.File]::WriteAllText((Join-Path $artifactCache ([string]$artifact.sha256)),'corrupt')
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild { throw 'unexpected network request' }

        { Get-MmtlForgeGradle6RuntimeArtifactMirror -CatalogPath $script:catalogPath -CacheRoot $cacheRoot } | Should -Throw '*FORGE_GRADLE6_RUNTIME_CACHE_INVALID*'
        Should -Invoke Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -Times 0
        @(Get-ChildItem -LiteralPath (Join-Path $cacheRoot 'maven-mirror') -Recurse -File -ErrorAction SilentlyContinue) | Should -HaveCount 0
    }
}
