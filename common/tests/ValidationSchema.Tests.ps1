BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:matrixSchema=Join-Path $script:repoRoot 'schemas/validation-matrix.schema.json'
    $script:evidenceSchema=Join-Path $script:repoRoot 'schemas/validation-evidence.schema.json'
}

Describe 'Deep validation JSON schemas' {
    It 'accepts an auditable target with observed and required Java kept distinct' {
        $target=[pscustomobject]@{
            targetId='1.20.1-forge-windows-x64'
            tier='Tier2'
            minecraftId='1.20.1'
            loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge';version='47.4.20'};overlays=@()}
            loaderVersion='47.4.20'
            toolchain='ForgeGradle'
            toolchainVersion='6.0.24'
            buildSystem='GradleWrapper'
            platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false}
            java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};observedBuildJava=[pscustomobject]@{major=21;exactVersion='21.0.9';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=8;runtimeRequirement=[pscustomobject]@{kind='Preferred';major=21};observedRuntimeJava=$null}
            sourceFixture=[pscustomobject]@{type='UserProject';source='PycodersMod/SharecodeChest';commit=('a'*40);license='MIT';trust='UserOwned'}
            validation=[pscustomobject]@{effectiveLevel='BUILD_VERIFIED';resolved=$true;build=$true;server=$false;client=$false;integration=$false}
            evidence=[pscustomobject]@{runIds=@('run-001');timestamps=@('2026-10-03T00:00:00Z');logs=@('run-001/build.log');hashes=@(('b'*64));artifact='sharecodechest-1.0.0.jar';process=$null;result='PASSED'}
            notes=@()
        }
        $matrix=[pscustomobject]@{schemaVersion=1;generatedAt='2026-10-03T00:00:00Z';scope='P0';targets=@($target)}
        (Test-Json -Json ($matrix|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:matrixSchema) | Should -BeTrue
    }

    It 'requires explicit failure classification in non-passing immutable run evidence' {
        $evidence=[pscustomobject]@{
            schemaVersion=1;targetId='1.20.1-forge-windows-x64';runId='run-002';startedAt='2026-10-03T00:00:00Z';endedAt='2026-10-03T00:01:00Z';durationSeconds=60
            validationLevel='BUILD_VERIFIED';result='FAILED';failureCode='BUILD_FAILED_NETWORK';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false}
            java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};observedBuildJava=[pscustomobject]@{major=17;exactVersion='17.0.19';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=8;runtimeRequirement=$null;observedRuntimeJava=$null}
            toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0.24'};buildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'}
            sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/example/fixture';commit=('c'*40);license='MIT';trust='TrustedOfficial'}
            logs=@([pscustomobject]@{path='logs/build.log';sha256=('d'*64)});artifact=$null;process=$null;marker=$null;stopMethod=$null;scenario=$null;notes=@()
        }
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeTrue
        $evidence|Add-Member -NotePropertyName forgeSecurity -NotePropertyValue ([pscustomobject]@{pinId='Forge@1.8.9';pinHash=('e'*64);forgeGradleSpec='2.1-SNAPSHOT';forgeGradleTimestamp='2.1-20211118.174922-42';forgeGradleJarSha256=('f'*64);forgeGradlePomSha256=('a'*64);buildClasspathArtifactCatalogHash=('b'*64);buildClasspathArtifactCount=53;buildClasspathMcpVersionsSha256=('c'*64);buildClasspathMcpMapping='stable_22';buildClasspathMojangVersionSha256='341af5f47a6b5bc137bfe681f4f3533e081041290aabbf9d7ebeae9881de768f';sourceBuildGradleSha256=('d'*64);gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.7-bin.zip';gradleDistributionSha256=('1'*64);gradleVersion='2.7';mojangArtifacts=@();integrityFailure=$null})
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeTrue
        $evidence.targetId='Forge@1.8.8';$evidence.forgeSecurity.pinId='Forge@1.8.8';$evidence.forgeSecurity.buildClasspathMojangVersionSha256='7f002c1dca74cc51ce995e7fdb465ab4984c940e77a1b1c4f2b09bed8702e558'
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeTrue
        $evidence.forgeSecurity.buildClasspathMojangVersionSha256=('0'*64)
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeFalse
        $evidence.forgeSecurity.buildClasspathMojangVersionSha256='341af5f47a6b5bc137bfe681f4f3533e081041290aabbf9d7ebeae9881de768f'
        $evidence.forgeSecurity.buildClasspathMcpMapping='stable_30'
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeFalse
        $evidence.failureCode=$null
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'accepts Fabric build security evidence for the non-obfuscated Loom generation' {
        $evidence=[pscustomobject]@{
            schemaVersion=1;targetId='Fabric@26.3';runId='run-fabric-263';startedAt='2026-10-11T00:00:00Z';endedAt='2026-10-11T00:01:00Z';durationSeconds=60
            validationLevel='BUILD_VERIFIED';result='PASSED';failureCode='NONE';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false}
            java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Exact';major=25};observedBuildJava=[pscustomobject]@{major=25;exactVersion='25.0.1';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=$null;runtimeRequirement=$null;observedRuntimeJava=$null}
            toolchain=[pscustomobject]@{id='FabricLoom';version='1.18.4'};buildSystem=[pscustomobject]@{id='Gradle';version='9.7.1'}
            sourceFixture=[pscustomobject]@{type='GeneratedOfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit='1685ed178a113092f8aa002c4f7d78181643d75b';license='CC0-1.0';trust='TrustedOfficial'}
            logs=@([pscustomobject]@{path='stdout.log';sha256=('b'*64)});artifact=$null;process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@()
            fabricSecurity=[pscustomobject]@{pinId='Fabric@26.3';pinHash=('c'*64);sourceArchiveSha256=('d'*64);sourceBuildGradleSha256=('e'*64);sourceSettingsGradleSha256=('f'*64);sourceWrapperJarSha256=('1'*64);gradleDistributionUrl='https://services.gradle.org/distributions/gradle-9.7.1-bin.zip';gradleDistributionSha256=('2'*64);gradleVersion='9.7.1';loomPluginId='net.fabricmc.fabric-loom';loomVersion='1.18.4';loaderVersion='0.19.5';fabricApiVersion='0.162.0+26.3';verificationMetadataSha256=('3'*64);verificationComponentCount=174;verificationArtifactCount=375;trustedArtifactCount=1;overlaySha256=('4'*64);buildJavaMajor=25;runtimeJavaMajor=25;verificationMode='strict'}
        }
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeTrue
        $evidence.sourceFixture=[pscustomobject]@{
            type='GeneratedPinnedLoaderFixture';source='https://github.com/FabricMC/fabric-example-mod';commit='1685ed178a113092f8aa002c4f7d78181643d75b'
            archiveUrl='https://codeload.github.com/FabricMC/fabric-example-mod/zip/1685ed178a113092f8aa002c4f7d78181643d75b';archiveSha256=('a'*64)
            fixtureId='fabric-26.3';overlaySha256=('b'*64);overlayFiles=@([pscustomobject]@{path='build.gradle';sha256=('c'*64)})
            license='CC0-1.0';trust='TrustedOfficial'
        }
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeTrue
        $evidence.sourceFixture.PSObject.Properties.Remove('archiveUrl')
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'accepts only pin-bound ForgeGradle 6 evidence for Forge 1.16.5' {
        $evidence=[pscustomobject]@{schemaVersion=1;targetId='Forge@1.16.5';runId='run-fg6';startedAt='2026-10-10T00:00:00Z';endedAt='2026-10-10T00:01:00Z';durationSeconds=60;validationLevel='BUILD_VERIFIED';result='PASSED';failureCode='NONE';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false};java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Exact';major=17};observedBuildJava=[pscustomobject]@{major=17;exactVersion='17.0.19';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=8;runtimeRequirement=$null;observedRuntimeJava=$null};toolchain=[pscustomobject]@{id='ForgeGradle6';version='6.0.54'};buildSystem=[pscustomobject]@{id='Gradle';version='8.4'};sourceFixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/fixture.zip';commit=('a'*64);license='Minecraft Forge MDK';trust='TrustedOfficial'};logs=@([pscustomobject]@{path='stdout.log';sha256=('b'*64)});artifact=$null;process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@();forgeSecurity=[pscustomobject]@{pinId='Forge@1.16.5';pinHash=('c'*64);forgeGradleSpec='[6.0,6.2)';forgeGradleResolvedVersion='6.0.54';forgeGradleJarSha256=('d'*64);forgeGradlePomSha256=('e'*64);sourceBuildGradleSha256=('f'*64);gradleDistributionUrl='https://services.gradle.org/distributions/gradle-8.4-all.zip';gradleDistributionSha256=('1'*64);gradleVersion='8.4';buildClasspathArtifactCatalogHash='ade87d84a2d6710442caa962ade4b65a353621a5a3ec581aa9c71ebe7f6ca193';buildClasspathArtifactCount=88;targetInputCatalogHash='a32ecc9b98e434ee0ea5eda4d641e4a15dfd5fe9a544651dbe12c4f67a820b3e';targetInputArtifactCount=13;runtimeArtifactCatalogHash='8829d0392640c83cc2139d91d53039ee0e32c6a496e462d04721d2fdeeabcebe';runtimeArtifactCount=157;mojangVersionHash='3eeeab7b3165cc5263dc26ff8fe114fdb718b75a0244efead9d19635d090ba72';mojangArtifacts=@();integrityFailure=$null}}
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeTrue
        $evidence.forgeSecurity.runtimeArtifactCatalogHash='0'*64
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }
}
