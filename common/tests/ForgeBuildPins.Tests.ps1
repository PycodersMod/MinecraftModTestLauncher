BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:manifestPath = Join-Path $script:repoRoot 'compatibility/forge-build-pins.json'
    $script:schemaPath = Join-Path $script:repoRoot 'common/schemas/forge-build-pins.schema.json'
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/ForgeSecureBuild.psm1') -Force
}

Describe 'Pinned Forge historical build inputs' {
    It 'resolves exact ForgeGradle 6 catalog filenames for the supported family targets' {
        $paths=Get-MmtlForgeGradle6CatalogFileNames -TargetId 'Forge@1.18.2' -OperatingSystem Windows -Architecture x64

        $paths.buildClasspath | Should -BeExactly 'Forge-1.18.2.json'
        $paths.targetInputs | Should -BeExactly 'Forge-1.18.2.json'
        $paths.runtimeArtifacts | Should -BeExactly 'Forge-1.18.2-Windows-x64.json'
        (Get-MmtlForgeGradle6CatalogFileNames -TargetId 'Forge@1.16.5' -OperatingSystem Windows -Architecture x64).runtimeArtifacts | Should -BeExactly 'Forge-1.16.5-Windows-x64.json'
        (Get-MmtlForgeGradle6CatalogFileNames -TargetId 'Forge@1.18.2' -OperatingSystem Linux -Architecture arm64).runtimeArtifacts | Should -BeExactly 'Forge-1.18.2-Linux-arm64.json'
        (Get-MmtlForgeGradle6CatalogFileNames -TargetId 'Forge@1.20.1' -OperatingSystem macOS -Architecture x64).runtimeArtifacts | Should -BeExactly 'Forge-1.20.1-macOS-x64.json'
        { Get-MmtlForgeGradle6CatalogFileNames -TargetId 'Forge@1.18.2/../../escape' -OperatingSystem Windows -Architecture x64 } | Should -Throw '*FORGE_GRADLE6_CATALOG_TARGET_INVALID*'
    }

    It 'routes another exact FG6 pin to its target-specific catalog path' {
        $sourceHash='06dc30e30b148d33e36e1c24f47c985e46ae669556f2060d750a141264bcdc26'
        $pin=[pscustomobject]@{
            targetId='Forge@1.18.2';minecraftId='1.18.2';forgeVersion='1.18.2-40.3.11'
            sourceArchiveUrl='https://maven.minecraftforge.net/net/minecraftforge/forge/1.18.2-40.3.11/forge-1.18.2-40.3.11-mdk.zip';sourceArchiveSha256=$sourceHash
            forgeGradleSpec='[6.0,6.2)';forgeGradleResolvedVersion='6.0.54';buildClasspathCatalogHash='f13500f38a41c5c4a7c9e877c39d7ae22ad1f612b667753b4346766ef5c1633d';targetInputCatalogHash='47ca7d6499e7c7a2675d17041b4f3e168d12ced9aca45161011115ae4af09a53';runtimeArtifactCatalogHash=('d'*64)
            forgeGradleJarUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/6.0.54/ForgeGradle-6.0.54.jar';forgeGradleJarSha256='1d54a97a225ed5180300e8070a1c818597d98ec45a11fedecb425254b7982da2'
            forgeGradlePomUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/6.0.54/ForgeGradle-6.0.54.pom';forgeGradlePomSha256='4bba725a86422bef59342db927cd5ab53baea7ffab9d74d23b6cdd1cb462d4c1'
            buildGradleSha256='7e62af868e3859bf02282f63cc6015bff09232f66de3e4af7a6bc0487bdbdcec';gradleDistributionUrl='https://services.gradle.org/distributions/gradle-8.8-bin.zip';gradleDistributionSha256='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612';buildJavaMajor=17
            mojangMetadataSnapshot='3df8f7b5e0ae5ccfd73adc9e00daf407a7274b138daab5793e58d14f2ab74144'
            client=[pscustomobject]@{url='https://piston-data.mojang.com/v1/objects/2e9a3e3107cca00d6bc9c97bf7d149cae163ef21/client.jar';sha1='2e9a3e3107cca00d6bc9c97bf7d149cae163ef21';sizeBytes=20259661}
            server=[pscustomobject]@{url='https://piston-data.mojang.com/v1/objects/c8f83c5655308435b3dcf03c06d9fe8740a77469/server.jar';sha1='c8f83c5655308435b3dcf03c06d9fe8740a77469';sizeBytes=46592587}
            status='PinnedInputsVerified'
        }
        $manifestPath=Join-Path $TestDrive 'forge-gradle6-family-pin.json'
        $manifest=[pscustomobject]@{schemaVersion=1;status='PARTIAL';targets=@($pin)}
        ConvertTo-Json -InputObject $manifest -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $target=[pscustomobject]@{targetId='Forge@1.18.2';minecraftId='1.18.2';loaderVersion='1.18.2-40.3.11'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.18.2';LoaderVersion='1.18.2-40.3.11'}
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source=$pin.sourceArchiveUrl;commit=$sourceHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$sourceHash}

        { Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture } | Should -Throw '*FORGE_GRADLE6_RUNTIME_CATALOG_PIN_MISMATCH*'

        $pin.runtimeArtifactCatalogHash='be4c190691ef8fb40a9ab43fd1ed6da1569e0a39f1af2ee683497790414fb2c5'
        $manifest.targets=@($pin)
        ConvertTo-Json -InputObject $manifest -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $resolved=Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture
        $resolved.buildMode | Should -BeExactly 'ForgeGradle6PluginsDsl'
        $resolved.policy.forgeVersion | Should -BeExactly '1.18.2-40.3.11'
        $resolved.policy.runtimeArtifactCatalogHash | Should -BeExactly 'be4c190691ef8fb40a9ab43fd1ed6da1569e0a39f1af2ee683497790414fb2c5'
    }

    It 'pins Forge 1.18.2 to official FG6 catalogs and Mojang artifacts' {
        $manifest=Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        $pin=@($manifest.targets | Where-Object targetId -CEQ 'Forge@1.18.2')
        $pin | Should -HaveCount 1
        $pin[0].forgeVersion | Should -BeExactly '1.18.2-40.3.11'
        $pin[0].forgeGradleResolvedVersion | Should -BeExactly '6.0.54'
        $pin[0].buildClasspathCatalogHash | Should -BeExactly 'f13500f38a41c5c4a7c9e877c39d7ae22ad1f612b667753b4346766ef5c1633d'
        $pin[0].targetInputCatalogHash | Should -BeExactly '47ca7d6499e7c7a2675d17041b4f3e168d12ced9aca45161011115ae4af09a53'
        $pin[0].runtimeArtifactCatalogHash | Should -BeExactly 'be4c190691ef8fb40a9ab43fd1ed6da1569e0a39f1af2ee683497790414fb2c5'
        $target=[pscustomobject]@{targetId='Forge@1.18.2';minecraftId='1.18.2';loaderVersion='1.18.2-40.3.11'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.18.2';LoaderVersion='1.18.2-40.3.11'}
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source=$pin[0].sourceArchiveUrl;commit=$pin[0].sourceArchiveSha256;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$pin[0].sourceArchiveSha256}
        $resolved=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture
        $resolved.buildMode | Should -BeExactly 'ForgeGradle6PluginsDsl'
        $resolved.policy.buildJavaMajor | Should -Be 17
    }

    It 'routes a ForgeGradle 6 Plugins DSL range to its exact resolved generation' {
        $sourceHash='a'*64
        $pin=[pscustomobject]@{
            targetId='Forge@1.16.5';minecraftId='1.16.5';forgeVersion='1.16.5-36.2.42'
            sourceArchiveUrl='https://maven.minecraftforge.net/net/minecraftforge/forge/1.16.5-36.2.42/forge-1.16.5-36.2.42-mdk.zip';sourceArchiveSha256=$sourceHash
            forgeGradleSpec='[6.0,6.2)';forgeGradleResolvedVersion='6.0.54';buildClasspathCatalogHash='ade87d84a2d6710442caa962ade4b65a353621a5a3ec581aa9c71ebe7f6ca193';targetInputCatalogHash='a32ecc9b98e434ee0ea5eda4d641e4a15dfd5fe9a544651dbe12c4f67a820b3e';runtimeArtifactCatalogHash='8829d0392640c83cc2139d91d53039ee0e32c6a496e462d04721d2fdeeabcebe'
            forgeGradleJarUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/6.0.54/ForgeGradle-6.0.54.jar';forgeGradleJarSha256=('b'*64)
            forgeGradlePomUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/6.0.54/ForgeGradle-6.0.54.pom';forgeGradlePomSha256=('c'*64)
            buildGradleSha256=('d'*64);gradleDistributionUrl='https://services.gradle.org/distributions/gradle-8.4-all.zip';gradleDistributionSha256=('e'*64);buildJavaMajor=17
            client=[pscustomobject]@{url='https://piston-data.mojang.com/v1/objects/'+('1'*40)+'/client.jar';sha1=('1'*40);sizeBytes=1}
            server=[pscustomobject]@{url='https://piston-data.mojang.com/v1/objects/'+('2'*40)+'/server.jar';sha1=('2'*40);sizeBytes=1}
            status='PinnedInputsVerified'
        }
        $manifest=[pscustomobject]@{schemaVersion=1;status='PARTIAL';targets=@($pin)}
        $manifestPath=Join-Path $TestDrive 'forge-gradle6-build-pins.json'
        ConvertTo-Json -InputObject $manifest -Depth 20|Set-Content -LiteralPath $manifestPath -Encoding utf8
        $target=[pscustomobject]@{targetId='Forge@1.16.5';minecraftId='1.16.5';loaderVersion='1.16.5-36.2.42'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.16.5';LoaderVersion='1.16.5-36.2.42'}
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source=$pin.sourceArchiveUrl;commit=$sourceHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$sourceHash}

        $resolved=Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture

        $resolved.buildMode | Should -BeExactly 'ForgeGradle6PluginsDsl'
        $resolved.policy.forgeGradleResolvedVersion | Should -BeExactly '6.0.54'
        $pin.buildClasspathCatalogHash='0'*64
        $manifest.targets=@($pin)
        ConvertTo-Json -InputObject $manifest -Depth 20|Set-Content -LiteralPath $manifestPath -Encoding utf8
        { Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture } | Should -Throw '*FORGE_GRADLE6_BUILD_CATALOG_PIN_MISMATCH*'
        $pin.buildClasspathCatalogHash='ade87d84a2d6710442caa962ade4b65a353621a5a3ec581aa9c71ebe7f6ca193';$pin.targetInputCatalogHash='0'*64;$manifest.targets=@($pin)
        ConvertTo-Json -InputObject $manifest -Depth 20|Set-Content -LiteralPath $manifestPath -Encoding utf8
        { Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture } | Should -Throw '*FORGE_GRADLE6_TARGET_INPUT_CATALOG_PIN_MISMATCH*'
        $pin.targetInputCatalogHash='a32ecc9b98e434ee0ea5eda4d641e4a15dfd5fe9a544651dbe12c4f67a820b3e';$pin.runtimeArtifactCatalogHash='0'*64;$manifest.targets=@($pin)
        ConvertTo-Json -InputObject $manifest -Depth 20|Set-Content -LiteralPath $manifestPath -Encoding utf8
        { Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture } | Should -Throw '*FORGE_GRADLE6_RUNTIME_CATALOG_PIN_MISMATCH*'
    }

    It 'pins Forge 1.16.5 to official FG6 inputs and validated Mojang artifacts' {
        $manifest=Get-Content -LiteralPath $script:manifestPath -Raw|ConvertFrom-Json
        $pin=@($manifest.targets|Where-Object targetId -CEQ 'Forge@1.16.5')
        $pin | Should -HaveCount 1
        $pin[0].forgeVersion | Should -BeExactly '1.16.5-36.2.42'
        $pin[0].forgeGradleSpec | Should -BeExactly '[6.0,6.2)'
        $pin[0].forgeGradleResolvedVersion | Should -BeExactly '6.0.54'
        $pin[0].buildClasspathCatalogHash | Should -BeExactly 'ade87d84a2d6710442caa962ade4b65a353621a5a3ec581aa9c71ebe7f6ca193'
        $pin[0].targetInputCatalogHash | Should -BeExactly 'a32ecc9b98e434ee0ea5eda4d641e4a15dfd5fe9a544651dbe12c4f67a820b3e'
        $pin[0].runtimeArtifactCatalogHash | Should -BeExactly '8829d0392640c83cc2139d91d53039ee0e32c6a496e462d04721d2fdeeabcebe'
        $pin[0].gradleDistributionUrl | Should -BeExactly 'https://services.gradle.org/distributions/gradle-8.4-all.zip'
        $pin[0].sourceArchiveSha256 | Should -BeExactly '02774cc07855111ee58936319bc39416c31df899b649748f089afd7ec51d5568'
        $target=[pscustomobject]@{targetId='Forge@1.16.5';minecraftId='1.16.5';loaderVersion='1.16.5-36.2.42'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.16.5';LoaderVersion='1.16.5-36.2.42'}
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source=$pin[0].sourceArchiveUrl;commit=$pin[0].sourceArchiveSha256;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$pin[0].sourceArchiveSha256}
        (Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture).buildMode | Should -BeExactly 'ForgeGradle6PluginsDsl'
    }

    It 'labels a pinned classpath build so the validation runner selects the correct preparation path' {
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.8.9';LoaderVersion='1.8.9-11.15.1.2318-1.8.9'}
        $target=[pscustomobject]@{targetId='Forge@1.8.9';minecraftId='1.8.9';loaderVersion='1.8.9-11.15.1.2318-1.8.9'}
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.8.9-11.15.1.2318-1.8.9/forge-1.8.9-11.15.1.2318-1.8.9-mdk.zip';commit='5a9a798b14676f9f8a5782aced4bbbca30f6ab5bca545fd2d320c356c1a9afae';trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum='5a9a798b14676f9f8a5782aced4bbbca30f6ab5bca545fd2d320c356c1a9afae'}
        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture
        $pin.buildMode | Should -BeExactly 'ForgeGradleClasspath'
    }

    It 'pins Forge 1.8.9 to its exact ForgeGradle 2.1 snapshot and Gradle 2.7' {
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        $pin = @($manifest.targets | Where-Object targetId -CEQ 'Forge@1.8.9')
        $pin.Count | Should -Be 1
        $pin[0].minecraftId | Should -BeExactly '1.8.9'
        $pin[0].forgeVersion | Should -BeExactly '1.8.9-11.15.1.2318-1.8.9'
        $pin[0].forgeGradleSpec | Should -BeExactly '2.1-SNAPSHOT'
        $pin[0].forgeGradleTimestamp | Should -BeExactly '2.1-20211118.174922-42'
        $pin[0].forgeGradleJarSha256 | Should -BeExactly '29f4f9a4b7ad917937d6ca761404ed4c56ee2a716cbfdd190b9aa99f25eb4695'
        $pin[0].forgeGradlePomSha256 | Should -BeExactly '9715509dfa5cb66ffae953149ea705ef9ad2bacede46f1847b395eebfed742c8'
        $pin[0].gradleDistributionUrl | Should -BeExactly 'https://services.gradle.org/distributions/gradle-2.7-bin.zip'
        $pin[0].gradleDistributionSha256 | Should -BeExactly 'cde43b90945b5304c43ee36e58aab4cc6fb3a3d5f9bd9449bb1709a68371cb06'
    }

    It 'selects the exact Forge 1.8.8 classpath pin for its official MDK fixture' {
        $target=[pscustomobject]@{targetId='Forge@1.8.8';minecraftId='1.8.8';loaderVersion='1.8.8-11.15.0.1655'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.8.8';LoaderVersion='1.8.8-11.15.0.1655'}
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.8.8-11.15.0.1655/forge-1.8.8-11.15.0.1655-mdk.zip';commit='17515602a2bd628cf328c9587178262908f49804b6ee9325d31c39fd342c42f5';trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum='17515602a2bd628cf328c9587178262908f49804b6ee9325d31c39fd342c42f5'}
        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture
        $pin.policy.targetId | Should -BeExactly 'Forge@1.8.8'
        $pin.policy.status | Should -BeExactly 'PinnedInputsVerified'
        $pin.buildMode | Should -BeExactly 'ForgeGradleClasspath'
    }

    It 'selects the exact verified Forge 1.9 MDK pin' {
        $target=[pscustomobject]@{targetId='Forge@1.9';minecraftId='1.9';loaderVersion='1.9-12.16.1.1938-1.9.0'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.9';LoaderVersion='1.9-12.16.1.1938-1.9.0'}
        $archiveHash='46edffa6b28b79ce99eee0b40665701b78fd5c882a331fd0255c18b9164f23cd'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.9-12.16.1.1938-1.9.0/forge-1.9-12.16.1.1938-1.9.0-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}
        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture
        $pin.policy.targetId | Should -BeExactly 'Forge@1.9'
        $pin.policy.sourceArchiveSha256 | Should -BeExactly $archiveHash
        $pin.policy.mojangMetadataSnapshot | Should -BeExactly '8d6f1e7f3a99f1236914b61e64eeade955ba21e8150563457142d3981aeee688'
        $pin.policy.buildJavaMajor | Should -Be 8
    }

    It 'pins Forge 1.10.2 to its ForgeGradle 2.2 snapshot and Gradle 2.14' {
        $manifest=Get-Content -LiteralPath $script:manifestPath -Raw|ConvertFrom-Json
        $pin=@($manifest.targets|Where-Object targetId -CEQ 'Forge@1.10.2')
        $pin.Count | Should -Be 1
        $pin[0].minecraftId | Should -BeExactly '1.10.2'
        $pin[0].forgeVersion | Should -BeExactly '1.10.2-12.18.3.2511'
        $pin[0].forgeGradleSpec | Should -BeExactly '2.2-SNAPSHOT'
        $pin[0].forgeGradleTimestamp | Should -BeExactly '2.2-20210802.021822-44'
        $pin[0].buildJavaMajor | Should -Be 8
        $pin[0].gradleDistributionUrl | Should -BeExactly 'https://services.gradle.org/distributions/gradle-2.14-bin.zip'
        $pin[0].mojangMetadataSnapshot | Should -BeExactly 'd0624badea6367233d47c830341952126cdb0f99b1e11fb60428dd530a0d4db5'
    }
    It 'pins Forge 1.12 to its exact ForgeGradle 2.3 snapshot and Gradle 2.14' {
        $manifest=Get-Content -LiteralPath $script:manifestPath -Raw|ConvertFrom-Json
        $pin=@($manifest.targets|Where-Object targetId -CEQ 'Forge@1.12')
        $pin.Count | Should -Be 1
        $pin[0].minecraftId | Should -BeExactly '1.12'
        $pin[0].forgeVersion | Should -BeExactly '1.12-14.21.1.2443'
        $pin[0].forgeGradleSpec | Should -BeExactly '2.3-SNAPSHOT'
        $pin[0].forgeGradleTimestamp | Should -BeExactly '2.3-20210802.170449-48'
        $pin[0].buildJavaMajor | Should -Be 8
        $pin[0].gradleDistributionUrl | Should -BeExactly 'https://services.gradle.org/distributions/gradle-2.14-bin.zip'
        $pin[0].mojangMetadataSnapshot | Should -BeExactly '33cc40a05466b4e34e04e65def732094388e9149eb6bd37e5daa227c06cbde4b'
    }
    It 'pins Forge 1.12.1 to its exact ForgeGradle 2.3 snapshot and Gradle 2.14' {
        $manifest=Get-Content -LiteralPath $script:manifestPath -Raw|ConvertFrom-Json
        $pin=@($manifest.targets|Where-Object targetId -CEQ 'Forge@1.12.1')
        $pin.Count | Should -Be 1
        $pin[0].minecraftId | Should -BeExactly '1.12.1'
        $pin[0].forgeVersion | Should -BeExactly '1.12.1-14.22.1.2485'
        $pin[0].sourceArchiveSha256 | Should -BeExactly 'efaf4baff6b7b26907dd222ec21c234e775efd07cbd01ebc338e007e73897233'
        $pin[0].forgeGradleSpec | Should -BeExactly '2.3-SNAPSHOT'
        $pin[0].forgeGradleTimestamp | Should -BeExactly '2.3-20210802.170449-48'
        $pin[0].buildJavaMajor | Should -Be 8
        $pin[0].gradleDistributionUrl | Should -BeExactly 'https://services.gradle.org/distributions/gradle-2.14-bin.zip'
        $pin[0].mojangMetadataSnapshot | Should -BeExactly 'a83e8ab7e3e78fd8dfa8fdbd0216b090ef7298fb44637b79093fe663bf2d6814'
    }
    It 'pins the ForgeGradle 3 selector and its resolved release independently for Forge 1.12.2' {
        $target=[pscustomobject]@{targetId='Forge@1.12.2';minecraftId='1.12.2';loaderVersion='1.12.2-14.23.5.2860'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.12.2';LoaderVersion='1.12.2-14.23.5.2860'}
        $archiveHash='d0de63c4109becaacff68308720ff99edb2534877853d3e34165c04341826461'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.12.2-14.23.5.2860/forge-1.12.2-14.23.5.2860-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin.policy.forgeGradleSpec | Should -BeExactly '3.+'
        $pin.policy.forgeGradleResolvedVersion | Should -BeExactly '3.0.197'
        $pin.policy.forgeGradleTimestamp | Should -BeNullOrEmpty
        $pin.policy.gradleDistributionUrl | Should -BeExactly 'https://services.gradle.org/distributions/gradle-4.9-bin.zip'
        $pin.policy.buildJavaMajor | Should -Be 8
    }
    It 'pins the exact ForgeGradle 3 release and official source for Forge 1.13.2' {
        $target=[pscustomobject]@{targetId='Forge@1.13.2';minecraftId='1.13.2';loaderVersion='1.13.2-25.0.223'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.13.2';LoaderVersion='1.13.2-25.0.223'}
        $archiveHash='d13ab7a7a3fad9a64dc9a58a2dde4e57fdeab028feadfd25b210e5a8076abfbe'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.13.2-25.0.223/forge-1.13.2-25.0.223-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin.policy.status | Should -BeExactly 'PinnedInputsVerified'
        $pin.policy.forgeGradleSpec | Should -BeExactly '3.+'
        $pin.policy.forgeGradleResolvedVersion | Should -BeExactly '3.0.197'
        $pin.policy.buildJavaMajor | Should -Be 8
        $pin.policy.mojangMetadataSnapshot | Should -BeExactly '26ddcd28289a44d4ae4179307b7193ce0227d2da57350e717ff1d8c6e27e8c95'
    }
    It 'pins Forge 1.14.2 to its exact official ForgeGradle 3 target inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.14.2';minecraftId='1.14.2';loaderVersion='1.14.2-26.0.63'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.14.2';LoaderVersion='1.14.2-26.0.63'}
        $archiveHash='fcd167ff0c959b518941c06afb349700ec120c3308578d46c608fe86868e93e2'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.14.2-26.0.63/forge-1.14.2-26.0.63-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin | Should -Not -BeNullOrEmpty
        $pin.policy.status | Should -BeExactly 'PinnedInputsVerified'
        $pin.policy.buildGradleSha256 | Should -BeExactly '6bd53205a06829185ec76a08c340fab84a897c4afcbd9de399da75539643f23c'
        $pin.policy.forgeGradleSpec | Should -BeExactly '3.+'
        $pin.policy.forgeGradleResolvedVersion | Should -BeExactly '3.0.197'
        $pin.policy.mojangMetadataSnapshot | Should -BeExactly '237aa8d499b71bb17122cbee40b8748efcd5ac9d8362c68c89e99ab0703e66b8'
        $pin.policy.client.sha1 | Should -BeExactly 'ca6c5a139045967229975c0c0b7f93e78b4314c2'
        $pin.policy.server.sha1 | Should -BeExactly '808be3869e2ca6b62378f9f4b33c946621620019'
    }
    It 'pins Forge 1.14.3 to its exact official ForgeGradle 3 target inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.14.3';minecraftId='1.14.3';loaderVersion='1.14.3-27.0.60'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.14.3';LoaderVersion='1.14.3-27.0.60'}
        $archiveHash='868d2fe31d14807e6e53e7c83c304ea4c07f18a5ea9b9186e86c15ffb59b7a2e'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.14.3-27.0.60/forge-1.14.3-27.0.60-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}
        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture
        $pin | Should -Not -BeNullOrEmpty
        $pin.policy.status | Should -BeExactly 'PinnedInputsVerified'
        $pin.policy.sourceArchiveSha256 | Should -BeExactly $archiveHash
        $pin.policy.buildGradleSha256 | Should -BeExactly 'cbfb3df0cd83b5415ba05dc41a90fe61bafa4f9ca023eea647af1e3a1e44795a'
        $pin.policy.forgeGradleSpec | Should -BeExactly '3.+'
        $pin.policy.forgeGradleResolvedVersion | Should -BeExactly '3.0.197'
        $pin.policy.buildJavaMajor | Should -Be 8
        $pin.policy.mojangMetadataSnapshot | Should -BeExactly 'ebf2df95d9bd83c6687f287d5a6f5f41f74bc1b39159fcbb74ff6d1d19d8464c'
    }

    It 'pins Forge 1.14.4 to its exact official ForgeGradle 3 target inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.14.4';minecraftId='1.14.4';loaderVersion='1.14.4-28.2.26'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.14.4';LoaderVersion='1.14.4-28.2.26'}
        $archiveHash='0fd8553d9fd72a37949708cdc6c208ffea955a0b4854e0725e7416d09a001948'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.14.4-28.2.26/forge-1.14.4-28.2.26-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}
        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture
        $pin | Should -Not -BeNullOrEmpty
        $pin.policy.status | Should -BeExactly 'PinnedInputsVerified'
        $pin.policy.sourceArchiveSha256 | Should -BeExactly $archiveHash
        $pin.policy.buildGradleSha256 | Should -BeExactly 'beb661aee58bcb6fadac4869e5a3e34b3b18496a15a37a098d075178f55a3dc8'
        $pin.policy.forgeGradleSpec | Should -BeExactly '3.+'
        $pin.policy.forgeGradleResolvedVersion | Should -BeExactly '3.0.197'
        $pin.policy.buildJavaMajor | Should -Be 8
        $pin.policy.mojangMetadataSnapshot | Should -BeExactly '615f466a39d2c19ae9b6e2401aa7bd07dbda337f976bcce383326b8d6ba4e532'
        $pin.policy.client.sha1 | Should -BeExactly '8c325a0c5bd674dd747d6ebaa4c791fd363ad8a9'
        $pin.policy.server.sha1 | Should -BeExactly '3dc3d84a581f14691199cf6831b71ed1296a9fdf'
    }

    It 'pins Forge 1.15.2 to its exact official Gradle 4.10.3 and ForgeGradle 3 inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.15.2';minecraftId='1.15.2';loaderVersion='1.15.2-31.2.57'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.15.2';LoaderVersion='1.15.2-31.2.57'}
        $archiveHash='383b1ce2a8512591ec292549b1cb620f00e2a2dd97b3b4b44e195c9b8ab73be2'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.15.2-31.2.57/forge-1.15.2-31.2.57-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin.buildMode | Should -BeExactly 'ForgeGradleClasspath'
        $pin.policy.gradleDistributionUrl | Should -BeExactly 'https://services.gradle.org/distributions/gradle-4.10.3-bin.zip'
        $pin.policy.gradleDistributionSha256 | Should -BeExactly '8626cbf206b4e201ade7b87779090690447054bc93f052954c78480fa6ed186e'
        $pin.policy.forgeGradleResolvedVersion | Should -BeExactly '3.0.197'
        $pin.policy.buildJavaMajor | Should -Be 8
        $pin.policy.mojangMetadataSnapshot | Should -BeExactly 'e974511243e845b2427ab635eba5612481cb420a70c0630aa041eab3eeb590c5'
        $pin.policy.client.sha1 | Should -BeExactly 'e3f78cd16f9eb9a52307ed96ebec64241cc5b32d'
        $pin.policy.server.sha1 | Should -BeExactly 'bb2b6b1aefcd70dfd1892149ac3a215f6c636b07'
    }

    It 'pins Forge 1.15.1 to its exact official Gradle 4.9 and ForgeGradle 3 inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.15.1';minecraftId='1.15.1';loaderVersion='1.15.1-30.0.51'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.15.1';LoaderVersion='1.15.1-30.0.51'}
        $archiveHash='4008c52d7e99d902138f8d187ce53c4858995cb02959992a0d376a3fa9a4b436'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.15.1-30.0.51/forge-1.15.1-30.0.51-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin.buildMode | Should -BeExactly 'ForgeGradleClasspath'
        $pin.policy.forgeGradleSpec | Should -BeExactly '3.+'
        $pin.policy.gradleDistributionUrl | Should -BeExactly 'https://services.gradle.org/distributions/gradle-4.9-bin.zip'
        $pin.policy.buildJavaMajor | Should -Be 8
        $pin.policy.sourceArchiveSha256 | Should -BeExactly $archiveHash
        $pin.policy.buildGradleSha256 | Should -BeExactly '14b15519201cf87f08652d1aa424eba6b37998b4d548f606818619217e35f2be'
    }

    It 'pins Forge 1.16.1 to its official Gradle 4.10.3 and ForgeGradle 3 inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.16.1';minecraftId='1.16.1';loaderVersion='1.16.1-32.0.108'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.16.1';LoaderVersion='1.16.1-32.0.108'}
        $archiveHash='8201ae624f6efe8b21b80cf64a526bcea1a9a98091ea65987fcafbc9180cb81e'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.16.1-32.0.108/forge-1.16.1-32.0.108-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin.buildMode|Should -BeExactly 'ForgeGradleClasspath'
        $pin.policy.gradleDistributionUrl|Should -BeExactly 'https://services.gradle.org/distributions/gradle-4.10.3-bin.zip'
        $pin.policy.gradleDistributionSha256|Should -BeExactly '8626cbf206b4e201ade7b87779090690447054bc93f052954c78480fa6ed186e'
        $pin.policy.buildGradleSha256|Should -BeExactly '02e38c4d52b55621c67718a4f1080680c4e699cd484b556d4df5d03b9be37a0f'
        $pin.policy.mojangMetadataSnapshot|Should -BeExactly '9688ec094a807c45513733388f7c8426d80a58cee96ed86be5380cb6a45f4a73'
        $pin.policy.client.sha1|Should -BeExactly 'c9abbe8ee4fa490751ca70635340b7cf00db83ff'
        $pin.policy.server.sha1|Should -BeExactly 'a412fd69db1f81db3f511c1463fd304675244077'
    }

    It 'pins Forge 1.16.2 to its official Gradle 4.10.3, ForgeGradle 3, and Mojang inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.16.2';minecraftId='1.16.2';loaderVersion='1.16.2-33.0.61'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.16.2';LoaderVersion='1.16.2-33.0.61'}
        $archiveHash='05db470f79304f6aecc705407cfdc1b6c41d37eed4679a0cd6acf88f470c08ca'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.16.2-33.0.61/forge-1.16.2-33.0.61-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin.buildMode|Should -BeExactly 'ForgeGradleClasspath'
        $pin.policy.forgeVersion|Should -BeExactly '1.16.2-33.0.61'
        $pin.policy.gradleDistributionUrl|Should -BeExactly 'https://services.gradle.org/distributions/gradle-4.10.3-bin.zip'
        $pin.policy.gradleDistributionSha256|Should -BeExactly '8626cbf206b4e201ade7b87779090690447054bc93f052954c78480fa6ed186e'
        $pin.policy.buildGradleSha256|Should -BeExactly '38c0f5b4c4d97ae39297b6a1c17099d9b5a0686cc61388da705738f0833c7e13'
        $pin.policy.mojangMetadataSnapshot|Should -BeExactly 'f696986f4c07cd12dede183c86266d5cd34def6846eb0f014e1a84c2a76688d4'
        $pin.policy.client.sha1|Should -BeExactly '653e97a2d1d76f87653f02242d243cdee48a5144'
        $pin.policy.server.sha1|Should -BeExactly 'c5f6fb23c3876461d46ec380421e42b289789530'
    }

    It 'pins Forge 1.16.3 to its official Gradle 4.10.3, ForgeGradle 3, and Mojang inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.16.3';minecraftId='1.16.3';loaderVersion='1.16.3-34.1.42'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.16.3';LoaderVersion='1.16.3-34.1.42'}
        $archiveHash='48e0bfe7360a51c28850d04d7be76275eca9b28abeca9bcfca9c7f6574815a9b'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.16.3-34.1.42/forge-1.16.3-34.1.42-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin.buildMode|Should -BeExactly 'ForgeGradleClasspath'
        $pin.policy.forgeVersion|Should -BeExactly '1.16.3-34.1.42'
        $pin.policy.gradleDistributionUrl|Should -BeExactly 'https://services.gradle.org/distributions/gradle-4.10.3-bin.zip'
        $pin.policy.gradleDistributionSha256|Should -BeExactly '8626cbf206b4e201ade7b87779090690447054bc93f052954c78480fa6ed186e'
        $pin.policy.buildGradleSha256|Should -BeExactly 'cefd57214cf840ee4f67f3f4fc4779afd6cfea10d38a216591570b24cbebcb3a'
        $pin.policy.mojangMetadataSnapshot|Should -BeExactly '193c5226095ce9e8a317f1e35ddbe4d976f176f6df7ac649ecfa669e17160ead'
        $pin.policy.client.sha1|Should -BeExactly '1321521b2caf934f7fc9665aab7e059a7b2bfcdf'
        $pin.policy.server.sha1|Should -BeExactly 'f02f4473dbf152c23d7d484952121db0b36698cb'
    }

    It 'pins Forge 1.16.4 to its official Gradle 4.10.3, ForgeGradle 3, and Mojang inputs' {
        $target=[pscustomobject]@{targetId='Forge@1.16.4';minecraftId='1.16.4';loaderVersion='1.16.4-35.1.37'}
        $project=[pscustomobject]@{Root='unused';Loader='Forge';MinecraftVersion='1.16.4';LoaderVersion='1.16.4-35.1.37'}
        $archiveHash='af49356944240ccab58f942a5cba9211153f8f04e3643718b3a3d6abada92b5a'
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/1.16.4-35.1.37/forge-1.16.4-35.1.37-mdk.zip';commit=$archiveHash;trust='TrustedOfficial';officialChecksumAlgorithm='SHA256';officialChecksum=$archiveHash}

        $pin=Get-MmtlForgeBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture

        $pin.buildMode|Should -BeExactly 'ForgeGradleClasspath'
        $pin.policy.forgeVersion|Should -BeExactly '1.16.4-35.1.37'
        $pin.policy.gradleDistributionUrl|Should -BeExactly 'https://services.gradle.org/distributions/gradle-4.10.3-bin.zip'
        $pin.policy.gradleDistributionSha256|Should -BeExactly '8626cbf206b4e201ade7b87779090690447054bc93f052954c78480fa6ed186e'
        $pin.policy.buildGradleSha256|Should -BeExactly '2ec97238ae147881b6dec058c9eb1994c16182beb7676ed19f225b140b20f5bd'
        $pin.policy.mojangMetadataSnapshot|Should -BeExactly '667fff4ca7fd0f56ab78b757224515e8e64375868e8d1ce6040091d7b63a0cb5'
        $pin.policy.client.sha1|Should -BeExactly '1952d94a0784e7abda230aae6a1e8fc0522dba99'
        $pin.policy.client.sizeBytes|Should -Be 17546582
        $pin.policy.server.sha1|Should -BeExactly '35139deedbd5182953cf1caa23835da59ca3d7cd'
        $pin.policy.server.sizeBytes|Should -Be 37961464
    }

    It 'has schema-valid pins bound to the frozen Forge archive and Mojang metadata' {
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        $json = ConvertTo-Json -InputObject $manifest -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath | Should -BeTrue
        $universe = Get-Content (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
        $forgeCatalog = Get-Content (Join-Path $script:repoRoot 'compatibility/forge-mdk-generations.json') -Raw | ConvertFrom-Json
        foreach($pin in $manifest.targets){
            $target = @($universe.targets | Where-Object targetId -CEQ $pin.targetId)
            $generation = @($forgeCatalog.targets | Where-Object targetId -CEQ $pin.targetId)
            $target.Count | Should -Be 1
            $generation.Count | Should -Be 1
            $pin.minecraftId | Should -BeExactly $target[0].minecraftId
            if($generation[0].httpStatus -eq 200){
                $pin.sourceArchiveSha256 | Should -BeExactly $generation[0].archiveSha256
                $pin.sourceArchiveUrl | Should -BeExactly $generation[0].mdkUrl
                $pin.buildGradleSha256 | Should -BeExactly $generation[0].buildGradleSha256
                $pin.forgeGradleSpec | Should -BeExactly $generation[0].forgeGradleSpec
            }else{
                $pin.sourceArchiveSha256 | Should -BeExactly $generation[0].alternateArchiveSha256
                $pin.sourceArchiveUrl | Should -BeExactly $generation[0].alternateSourceUrl
                $pin.buildGradleSha256 | Should -BeExactly $generation[0].alternateBuildGradleSha256
                $pin.forgeGradleSpec | Should -BeExactly $generation[0].alternateForgeGradleSpec
            }
            $mojangSnapshots = Get-ChildItem (Join-Path $script:repoRoot 'compatibility/snapshots/MojangVersions') -File
            $snapshot = @($mojangSnapshots | Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -CEQ $pin.minecraftId })
            $snapshot.Count | Should -Be 1
            (Get-FileHash $snapshot[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $pin.mojangMetadataSnapshot
            $metadata = Get-Content $snapshot[0].FullName -Raw | ConvertFrom-Json
            $pin.client.sha1 | Should -BeExactly $metadata.downloads.client.sha1
            $pin.client.url | Should -BeExactly $metadata.downloads.client.url
            $pin.server.sha1 | Should -BeExactly $metadata.downloads.server.sha1
            $pin.server.url | Should -BeExactly $metadata.downloads.server.url
        }
    }

    It 'refuses non-HTTPS or unpinned plugin artifacts' {
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        $manifest.targets[0].forgeGradleJarUrl = $manifest.targets[0].forgeGradleJarUrl -replace '^https:', 'http:'
        $valid=$false;$schemaError=$null
        try{$valid=Test-Json -Json (ConvertTo-Json -InputObject $manifest -Depth 20) -SchemaFile $script:schemaPath -ErrorAction Stop}catch{$schemaError=$_.Exception.Message}
        if($schemaError){$schemaError | Should -Match 'not valid with the schema'}else{$valid | Should -BeFalse}
    }

    It 'accepts an official Forge MDK archive as the pinned source project' {
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        $manifest.targets[0].sourceArchiveUrl = 'https://maven.minecraftforge.net/net/minecraftforge/forge/1.8-11.14.4.1577/forge-1.8-11.14.4.1577-mdk.zip'
        $json = ConvertTo-Json -InputObject $manifest -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath | Should -BeTrue
    }
}
