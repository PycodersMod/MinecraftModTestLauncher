BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:pinPath = Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json'
    $script:fixtureRoot = Join-Path $script:repoRoot 'common/fixtures/fabric/1.21.8-marker'
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/FabricSecureBuild.psm1') -Force

    function New-TestFabricBuildContext {
        param([string]$TargetId = 'Fabric@1.21.8')
        $pin = (Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json).targets | Where-Object targetId -CEQ $TargetId
        $version = [string]$pin.minecraftVersion
        $fixtureRoot = Join-Path $script:repoRoot ('common/fixtures/fabric/' + $version + '-marker')
        $fixtureManifest = Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        [pscustomobject]@{
            Target = [pscustomobject]@{targetId=$TargetId;minecraftId=$version;loaderVersion=[string]$pin.loaderVersion}
            Project = [pscustomobject]@{Loader='Fabric';MinecraftVersion=$version;LoaderVersion=[string]$pin.loaderVersion;Root=$fixtureRoot}
            Fixture = [pscustomobject]@{
                type='GeneratedOfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=[string]$pin.sourceCommit
                archiveSha256=[string]$pin.sourceArchiveSha256;license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('clean','build')
                fixtureId=[string]$fixtureManifest.fixtureId;overlaySha256=[string]$fixtureManifest.overlaySha256;overlayFiles=@($fixtureManifest.overlayFiles)
            }
        }
    }
}

Describe 'Fabric exact-target secure build pins' {
    It 'maps exact Minecraft IDs to the correct Fabric Loom plugin generation boundary' {
        Get-MmtlFabricLoomPluginId -MinecraftVersion '1.21.11' | Should -BeExactly 'net.fabricmc.fabric-loom-remap'
        Get-MmtlFabricLoomPluginId -MinecraftVersion '26w14a' | Should -BeExactly 'net.fabricmc.fabric-loom-remap'
        Get-MmtlFabricLoomPluginId -MinecraftVersion '26.1' | Should -BeExactly 'net.fabricmc.fabric-loom'
        Get-MmtlFabricLoomPluginId -MinecraftVersion '26.3' | Should -BeExactly 'net.fabricmc.fabric-loom'
        { Get-MmtlFabricLoomPluginId -MinecraftVersion 'not-a-version' } | Should -Throw '*FABRIC_MINECRAFT_VERSION_UNPARSEABLE*'
    }

    It 'resolves the verified exact-target pin and requires strict Gradle dependency verification' {
        $context = New-TestFabricBuildContext
        $pin = Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $context.Target -Project $context.Project -Fixture $context.Fixture

        $pin.policy.targetId | Should -BeExactly 'Fabric@1.21.8'
        $pin.policy.verificationStatus | Should -BeExactly 'PinnedInputsVerified'
        $pin.buildMode | Should -BeExactly 'FabricLoomPinned'
        $pin.additionalArguments | Should -Contain '--dependency-verification=strict'
        $pin.pinHash | Should -Match '^[a-f0-9]{64}$'
    }

    It 'resolves an exact 1.21.11 remapping Loom marker pin with strict dependency verification' {
        $context = New-TestFabricBuildContext -TargetId 'Fabric@1.21.11'
        $pin = Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $context.Target -Project $context.Project -Fixture $context.Fixture

        $pin.policy.loomPluginId | Should -BeExactly 'net.fabricmc.fabric-loom-remap'
        $pin.policy.minecraftVersion | Should -BeExactly '1.21.11'
        $pin.policy.verificationStatus | Should -BeExactly 'PinnedInputsVerified'
        $pin.policy.fabricApiVersion | Should -BeExactly '0.141.6+1.21.11'
        $pin.policy.trustedArtifactFiles.Count | Should -Be 69
        $pin.policy.trustedArtifactFiles | Should -Contain 'mappings-layered+hash.2198.jar'
        $pin.policy.trustedArtifactFiles | Should -Contain 'fabric-api-4abd26ae-common-0.141.6+1.21.11.jar'
        $pin.policy.trustedArtifactFiles | Should -Contain 'fabric-rendering-v1-4abd26ae-client-16.2.10+0290ad933e.jar'
        $pin.additionalArguments | Should -Contain '--dependency-verification=strict'
    }

    It 'trusts only exact Loom-remapped 1.21.10 client artifacts under strict verification' {
        $context = New-TestFabricBuildContext -TargetId 'Fabric@1.21.10'
        $pin = Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $context.Target -Project $context.Project -Fixture $context.Fixture
        $metadataPath = Join-Path $context.Project.Root 'gradle/verification-metadata.xml'
        $metadata = [xml](Get-Content -LiteralPath $metadataPath -Raw)
        $clientArtifact = 'fabric-block-view-api-v2-e9493de5-client-1.0.34+e4fd1b926f.jar'
        $minecraftArtifact = 'minecraft-clientOnly-6227aad8ee-1.21.10-loom.mappings.1_21_10.layered+hash.2198-v2.jar'
        $trustEntries = @($metadata.SelectNodes("//*[local-name()='trusted-artifacts']/*[local-name()='trust']"))
        $trustEntry = $trustEntries | Where-Object { $_.GetAttribute('file') -CEQ $clientArtifact }
        $minecraftTrustEntry = $trustEntries | Where-Object { $_.GetAttribute('file') -CEQ $minecraftArtifact }

        $pin.additionalArguments | Should -Contain '--dependency-verification=strict'
        $pin.policy.trustedArtifactCount | Should -Be 70
        $pin.policy.trustedArtifactFiles.Count | Should -Be 70
        $pin.policy.trustedArtifactFiles | Should -Contain $clientArtifact
        $pin.policy.trustedArtifactFiles | Should -Contain $minecraftArtifact
        $trustEntries.Count | Should -Be 70
        $trustEntry.GetAttribute('reason') | Should -BeExactly 'Loom-remapped client artifact derived from checksum-verified pinned Fabric API input'
        $minecraftTrustEntry.GetAttribute('reason') | Should -BeExactly 'Loom-remapped client-only artifact derived from checksum-verified pinned Minecraft client input'
    }

    It 'resolves the 26.3 pin, marker overlay, non-obfuscated Loom and target-exact trusted artifact' {
        $pin = (Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json).targets | Where-Object targetId -CEQ 'Fabric@26.3'
        $fixtureRoot = Join-Path $script:repoRoot 'common/fixtures/fabric/26.3-marker'
        $fixtureManifest = Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $target = [pscustomobject]@{targetId='Fabric@26.3';minecraftId='26.3';loaderVersion='0.19.5'}
        $project = [pscustomobject]@{Loader='Fabric';MinecraftVersion='26.3';LoaderVersion='0.19.5';Root=$fixtureRoot}
        $fixture = [pscustomobject]@{type='GeneratedOfficialFixture';source=$pin.sourceRepository;commit=$pin.sourceCommit;archiveSha256=$pin.sourceArchiveSha256;license='CC0-1.0';trust='TrustedOfficial';fixtureId=$fixtureManifest.fixtureId;overlaySha256=$fixtureManifest.overlaySha256;overlayFiles=@($fixtureManifest.overlayFiles)}

        $resolved = Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $target -Project $project -Fixture $fixture

        $resolved.policy.targetId | Should -BeExactly 'Fabric@26.3'
        $resolved.policy.loomPluginId | Should -BeExactly 'net.fabricmc.fabric-loom'
        $resolved.policy.trustedArtifactFiles | Should -Be @('minecraft-common-7e9a32a5b8-26.3.jar','minecraft-clientOnly-7e9a32a5b8-26.3.jar')
        $resolved.additionalArguments | Should -Contain '--dependency-verification=strict'
    }

    It 'accepts the generated pinned fixture type while preserving the exact Fabric source pin' {
        $context = New-TestFabricBuildContext -TargetId 'Fabric@26.3'
        $pin = (Get-Content -LiteralPath $script:pinPath -Raw | ConvertFrom-Json).targets | Where-Object targetId -CEQ 'Fabric@26.3'
        $context.Fixture.type = 'GeneratedPinnedLoaderFixture'
        $context.Fixture | Add-Member -NotePropertyName archiveUrl -NotePropertyValue ([string]$pin.sourceArchiveUrl) -Force

        $resolved = Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $context.Target -Project $context.Project -Fixture $context.Fixture

        $resolved.policy.targetId | Should -BeExactly 'Fabric@26.3'
        $resolved.policy.sourceArchiveSha256 | Should -BeExactly $pin.sourceArchiveSha256
    }

    It 'rejects a fixture whose upstream source identity differs from the pin' {
        $context = New-TestFabricBuildContext
        $context.Fixture.commit = '0' * 40

        { Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $context.Target -Project $context.Project -Fixture $context.Fixture } | Should -Throw '*FABRIC_PIN_SOURCE_IDENTITY_MISMATCH*'
    }

    It 'rejects a changed generated overlay before allowing Gradle to run' {
        $context = New-TestFabricBuildContext
        $context.Fixture.overlaySha256 = '0' * 64

        { Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $context.Target -Project $context.Project -Fixture $context.Fixture } | Should -Throw '*FABRIC_PIN_OVERLAY_HASH_MISMATCH*'
    }

    It 'rejects a changed dependency verification metadata file' {
        $context = New-TestFabricBuildContext
        $copyRoot = Join-Path $TestDrive 'fabric-fixture-tamper'
        Copy-Item -LiteralPath $script:fixtureRoot -Destination $copyRoot -Recurse -Force
        $context.Project.Root = $copyRoot
        $path = Join-Path $copyRoot 'gradle/verification-metadata.xml'
        $backup = [IO.File]::ReadAllBytes($path)
        try {
            [IO.File]::AppendAllText($path, "`n<!-- tamper -->", [Text.UTF8Encoding]::new($false))
            { Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $context.Target -Project $context.Project -Fixture $context.Fixture } | Should -Throw '*FABRIC_PIN_VERIFICATION_METADATA_HASH_MISMATCH*'
        } finally {
            [IO.File]::WriteAllBytes($path, $backup)
        }
    }

    It 'rejects the same pin when applied to a different Minecraft exact target' {
        $context = New-TestFabricBuildContext
        $context.Target.minecraftId = '1.21.9'

        { Get-MmtlFabricBuildPin -ManifestPath $script:pinPath -Target $context.Target -Project $context.Project -Fixture $context.Fixture } | Should -Throw '*FABRIC_PIN_TARGET_IDENTITY_MISMATCH*'
    }
}
