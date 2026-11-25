BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = Join-Path $script:repoRoot 'compatibility/forge-plugin-build-pins.json'
    $script:schemaPath = Join-Path $script:repoRoot 'common/schemas/forge-plugin-build-pins.schema.json'
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/ForgeSecureBuild.psm1') -Force
}

Describe 'Pinned Forge 1.8 Plugins DSL build inputs' {
    It 'binds the Plugins DSL pin to the frozen MDK, artifact catalogs, and Mojang snapshot' {
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        Test-Json -Json (ConvertTo-Json -InputObject $manifest -Depth 20) -SchemaFile $script:schemaPath | Should -BeTrue
        $pin = @($manifest.targets | Where-Object targetId -CEQ 'Forge@1.8')
        $pin.Count | Should -Be 1
        $generation = Get-Content (Join-Path $script:repoRoot 'compatibility/forge-mdk-generations.json') -Raw | ConvertFrom-Json
        $generationPin = @($generation.targets | Where-Object targetId -CEQ 'Forge@1.8')
        $generationPin.Count | Should -Be 1
        $pin[0].sourceArchiveSha256 | Should -BeExactly $generationPin[0].archiveSha256
        $pin[0].buildGradleSha256 | Should -BeExactly $generationPin[0].buildGradleSha256
        $pin[0].pluginArtifactCatalogHash | Should -BeExactly ((Get-Content (Join-Path $script:repoRoot 'compatibility/forge-plugin-artifacts.json') -Raw | ConvertFrom-Json).catalogHash)
        $pin[0].buildArtifactCatalogHash | Should -BeExactly ((Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-artifacts.json') -Raw | ConvertFrom-Json).catalogHash)
        $pin[0].mcpVersions.sha256 | Should -BeExactly ((Get-Content (Join-Path $script:repoRoot 'compatibility/forge-plugin-artifacts.json') -Raw | ConvertFrom-Json).mcpVersions.sha256)
        $pin[0].mojangMetadataSnapshot | Should -BeExactly '8be392d3e8b3e61500b60eb141de56519299069c9169081483ea5aae9fa9d593'
        $pin[0].versionJson.sha256 | Should -BeExactly $pin[0].mojangMetadataSnapshot
        $pin[0].fernflowerArchive.url | Should -BeExactly 'https://files.minecraftforge.net/fernflower-fix-1.0.zip'
        $pin[0].fernflowerArchive.sha256 | Should -BeExactly '7b18843dec340463a7e00c49325d7a6a8621a1de6ae64a4a282d629b0263d0ac'
        $pin[0].fernflowerJar.sha256 | Should -BeExactly 'f857d0a5dc440e9576a099ffe2dcf0f57f62ec6a9a90cdd7e8a27d4573e0504b'
    }

    It 'resolves only the exact trusted Forge 1.8 source fixture and known catalog identities' {
        $target = [pscustomobject]@{targetId='Forge@1.8';minecraftId='1.8';loaderVersion='1.8-11.14.4.1577'}
        $project = [pscustomobject]@{Loader='Forge';MinecraftVersion='1.8';LoaderVersion='1.8-11.14.4.1577'}
        $pin = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json | ForEach-Object { $_.targets[0] }
        $fixture = [pscustomobject]@{type='OfficialArtifactFixture';trust='TrustedOfficial';source=$pin.sourceArchiveUrl;commit=$pin.sourceArchiveSha256;officialChecksumAlgorithm='SHA256';officialChecksum=$pin.sourceArchiveSha256}

        $resolved = Get-MmtlForgePluginBuildPin -ManifestPath $script:manifestPath -PluginCatalogPath (Join-Path $script:repoRoot 'compatibility/forge-plugin-artifacts.json') -BuildArtifactCatalogPath (Join-Path $script:repoRoot 'compatibility/forge-build-artifacts.json') -MojangSnapshotsPath (Join-Path $script:repoRoot 'compatibility/snapshots/MojangVersions') -Target $target -Project $project -Fixture $fixture
        $resolved.policy.targetId | Should -BeExactly 'Forge@1.8'
        $resolved.pinHash | Should -Match '^[a-f0-9]{64}$'
        $resolved.policy.buildJavaMajor | Should -Be 8
    }

    It 'rejects a plugin or artifact catalog hash that differs from the pinned identities' {
        $target = [pscustomobject]@{targetId='Forge@1.8';minecraftId='1.8';loaderVersion='1.8-11.14.4.1577'}
        $project = [pscustomobject]@{Loader='Forge';MinecraftVersion='1.8';LoaderVersion='1.8-11.14.4.1577'}
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        $manifest.targets[0].buildArtifactCatalogHash = '0' * 64
        $temporary = Join-Path $TestDrive 'forge-plugin-build-pins-tampered.json'
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary
        $pin = $manifest.targets[0]
        $fixture = [pscustomobject]@{type='OfficialArtifactFixture';trust='TrustedOfficial';source=$pin.sourceArchiveUrl;commit=$pin.sourceArchiveSha256;officialChecksumAlgorithm='SHA256';officialChecksum=$pin.sourceArchiveSha256}

        { Get-MmtlForgePluginBuildPin -ManifestPath $temporary -PluginCatalogPath (Join-Path $script:repoRoot 'compatibility/forge-plugin-artifacts.json') -BuildArtifactCatalogPath (Join-Path $script:repoRoot 'compatibility/forge-build-artifacts.json') -MojangSnapshotsPath (Join-Path $script:repoRoot 'compatibility/snapshots/MojangVersions') -Target $target -Project $project -Fixture $fixture } | Should -Throw '*FORGE_PLUGIN_BUILD_PIN_CATALOG_MISMATCH*'
    }
}
