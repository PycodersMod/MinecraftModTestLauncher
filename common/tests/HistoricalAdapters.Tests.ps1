BeforeAll { $root=Split-Path -Parent $PSScriptRoot;Import-Module (Join-Path $root 'src/Architecture/HistoricalContracts.psm1') -Force;$script:adapterModule=Import-Module (Join-Path $root 'src/Adapters/ContractV2.psm1') -Force -PassThru;Import-Module (Join-Path $root 'src/ProjectDetector.psm1') -Force;Import-Module (Join-Path $root 'src/Catalog/Providers/HistoricalProviders.psm1') -Force }
Describe 'Historical adapters, detection, overlay, and manual mode' {
    It 'keeps Legacy Fabric and Ornithe as distinct loader identities and toolchains' {
        (Get-MmtlHistoricalAdapterProbe -LoaderId LegacyFabric -Evidence @([pscustomobject]@{loaderId='LegacyFabric';confidence='High'})).adapterId | Should -BeExactly 'LegacyFabric'
        (Get-MmtlHistoricalAdapterProbe -LoaderId OrnitheLoader -Evidence @([pscustomobject]@{loaderId='OrnitheLoader';confidence='High'})).adapterId | Should -BeExactly 'OrnitheLoader'
    }
    It 'returns a non-matching probe instead of throwing when no loader evidence matches' {
        $probe=Get-MmtlHistoricalAdapterProbe -LoaderId Rift -Evidence @([pscustomobject]@{loaderId='Fabric';confidence='High'})
        $probe.matched | Should -BeFalse
        $probe.confidence | Should -BeExactly 'Unknown'
        @($probe.evidence).Count | Should -Be 0
    }
    It 'resolves Forge plus LiteLoader as a primary and overlay' {
        $e=@([pscustomobject]@{loaderId='Forge';confidence='High'},[pscustomobject]@{loaderId='LiteLoader';confidence='High';role='Overlay';version='1.12.2'})
        $r=Resolve-MmtlProjectStack -Evidence $e
        $r.status | Should -Be 'Resolved';$r.loaderStack.primaryLoader.id | Should -BeExactly 'Forge';$r.loaderStack.overlayLoaders[0].id | Should -BeExactly 'LiteLoader'
    }
    It 'detects an actual Forge plus LiteLoader build marker as an overlay' {
        $project=Join-Path $TestDrive 'overlay';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources/META-INF') -Force|Out-Null
        "plugins { id 'net.minecraftforge.gradle' version '2.3-SNAPSHOT' }`ndependencies { compile 'com.mumfrey:liteloader:1.12.2' }"|Set-Content (Join-Path $project 'build.gradle')
        'modLoader="javafml"'|Set-Content (Join-Path $project 'src/main/resources/META-INF/mods.toml')
        $result=Get-MmtlProject -Path $project
        $result.DetectionStatus | Should -BeExactly 'Resolved';$result.LoaderStack.primaryLoader.id | Should -BeExactly 'Forge';$result.LoaderStack.overlayLoaders[0].id | Should -BeExactly 'LiteLoader'
    }
    It 'detects a standalone LiteLoader project without promoting its ForgeGradle toolchain to Forge runtime' {
        $project=Join-Path $TestDrive 'lite-standalone';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources') -Force|Out-Null
        "plugins { id 'net.minecraftforge.gradle.liteloader' version '2.3-SNAPSHOT' }"|Set-Content (Join-Path $project 'build.gradle')
        '{"name":"Fixture","mcversion":"1.12.2"}'|Set-Content (Join-Path $project 'src/main/resources/litemod.json')
        $result=Get-MmtlProject -Path $project
        $result.DetectionStatus | Should -BeExactly 'Resolved';$result.Loader | Should -BeExactly 'LiteLoader';$result.LoaderStack.primaryLoader.id | Should -BeExactly 'LiteLoader';$result.LoaderStack.overlayLoaders.Count | Should -Be 0;$result.Toolchain.id | Should -BeExactly 'ForgeGradle'
    }
    It 'uses Legacy Looming evidence instead of the compatible Fabric metadata marker' {
        $project=Join-Path $TestDrive 'legacy';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources') -Force|Out-Null
        "plugins { id 'fabric-loom' version '1.16-SNAPSHOT'; id 'legacy-looming' version '1.16-SNAPSHOT' }"|Set-Content (Join-Path $project 'build.gradle')
        "minecraft_version=1.8.9`nloader_version=0.18.3"|Set-Content (Join-Path $project 'gradle.properties')
        '{}'|Set-Content (Join-Path $project 'src/main/resources/fabric.mod.json')
        $result=Get-MmtlProject -Path $project
        $result.Loader | Should -BeExactly 'LegacyFabric';$result.Toolchain.id | Should -BeExactly 'LegacyLooming';$result.MinecraftVersion | Should -BeExactly '1.8.9';$result.LoaderVersion | Should -BeExactly '0.18.3'
    }
    It 'keeps the loader identity from the declared Fabric Loader dependency while retaining Ornithe toolchain context' {
        $project=Join-Path $TestDrive 'ornithe';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources') -Force|Out-Null
        "plugins { id 'fabric-loom' version '1.18-SNAPSHOT'; id 'ploceus' version '1.18-SNAPSHOT' }`ndependencies { modImplementation 'net.fabricmc:fabric-loader:0.19.5' }"|Set-Content (Join-Path $project 'build.gradle')
        "minecraft_version=1.7.2`nloader_version=0.19.5"|Set-Content (Join-Path $project 'gradle.properties')
        '{"depends":{"fabricloader":">=0.17.3","minecraft":"1.7.2"}}'|Set-Content (Join-Path $project 'src/main/resources/fabric.mod.json')
        $result=Get-MmtlProject -Path $project
        $result.Loader | Should -BeExactly 'Fabric';$result.Toolchain.id | Should -BeExactly 'Ploceus';$result.Toolchain.ecosystem | Should -BeExactly 'Ornithe';$result.MinecraftVersion | Should -BeExactly '1.7.2';$result.LoaderVersion | Should -BeExactly '0.19.5'
    }
    It 'detects Ornithe Loader only when its distinct runtime artifact is declared' {
        $project=Join-Path $TestDrive 'ornithe-runtime';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources') -Force|Out-Null
        "plugins { id 'ploceus' version '1.18-SNAPSHOT' }`ndependencies { modImplementation 'net.ornithemc:ornithe-loader:0.19.5' }"|Set-Content (Join-Path $project 'build.gradle')
        "minecraft_version=1.7.2`nloader_version=0.19.5"|Set-Content (Join-Path $project 'gradle.properties')
        '{"depends":{"fabricloader":">=0.17.3","minecraft":"1.7.2"}}'|Set-Content (Join-Path $project 'src/main/resources/fabric.mod.json')
        $result=Get-MmtlProject -Path $project
        $result.Loader | Should -BeExactly 'OrnitheLoader';$result.Toolchain.id | Should -BeExactly 'Ploceus';$result.Toolchain.ecosystem | Should -BeExactly 'Ornithe'
    }
    It 'recognizes original Rift ForgeGradle tweaker projects as Rift' {
        $project=Join-Path $TestDrive 'rift';New-Item -ItemType Directory -Path $project -Force|Out-Null
        "buildscript { dependencies { classpath 'org.dimdev:ForgeGradle:2.3-SNAPSHOT' } }`napply plugin: 'net.minecraftforge.gradle.tweaker-client'`nsourceCompatibility = 1.8`nminecraft { version = '1.13' }"|Set-Content (Join-Path $project 'build.gradle')
        $result=Get-MmtlProject -Path $project
        $result.Loader | Should -BeExactly 'Rift';$result.DetectionStatus | Should -BeExactly 'Resolved';$result.MinecraftVersion | Should -BeExactly '1.13';$result.BuildJavaMajor | Should -Be 8
    }
    It 'creates non-executable historical BuildPlans with independent build/runtime Java requirements' {
        $project=Join-Path $TestDrive 'build-plan';New-Item -ItemType Directory -Path $project -Force|Out-Null
        "plugins { id 'legacy-looming' version '1.16-SNAPSHOT' }"|Set-Content (Join-Path $project 'build.gradle')
        "minecraft_version=1.8.9`nloader_version=0.18.3`njava_version=17"|Set-Content (Join-Path $project 'gradle.properties')
        $result=Get-MmtlProject -Path $project
        $plan=& $script:adapterModule { param($inputProject) New-MmtlHistoricalAdapterBuildPlan -Project $inputProject } $result
        $plan.isExecutablePlan | Should -BeFalse;$plan.buildJavaRequirement.major | Should -Be 17;$plan.historical.automaticArtifactExecution | Should -Be 'Denied';$result.RuntimeJavaRequirement.major | Should -BeNullOrEmpty
    }
    It 'uses the Gradle wrapper daemon minimum separately from legacy Minecraft Java target' {
        $project=Join-Path $TestDrive 'wrapper-java';New-Item -ItemType Directory -Path (Join-Path $project 'gradle/wrapper') -Force|Out-Null
        "plugins { id 'ploceus' version '1.18-SNAPSHOT' }`nsourceCompatibility = JavaVersion.VERSION_1_8`ntargetCompatibility = JavaVersion.VERSION_1_8"|Set-Content (Join-Path $project 'build.gradle')
        "minecraft_version=1.7.2`nloader_version=0.19.5"|Set-Content (Join-Path $project 'gradle.properties')
        'distributionUrl=https\://services.gradle.org/distributions/gradle-9.4.0-bin.zip'|Set-Content (Join-Path $project 'gradle/wrapper/gradle-wrapper.properties')
        $result=Get-MmtlProject -Path $project
        $result.BuildJavaMajor | Should -Be 17;$result.CompilerTargetJavaMajor | Should -Be 8;$result.RuntimeJavaRequirement.major | Should -BeNullOrEmpty;$result.GradleRuntimeJavaRequirement.gradleVersion | Should -Be '9.4'
    }
    It 'does not auto-patch or execute a user supplied JarMod artifact' {
        $artifact=Join-Path $TestDrive 'legacy-mod.jar';[IO.File]::WriteAllBytes($artifact,[byte[]](1,2,3,4))
        $candidate=New-MmtlJarModManualCandidate -MinecraftId '1.2.5' -ArtifactPath $artifact -PatchStrategy 'ManualPlanOnly'
        $candidate.availability | Should -Be 'Manual';$candidate.sourceClass | Should -Be 'ManualArtifact';$candidate.executePermission | Should -Be 'Denied';$candidate.patchPermission | Should -Be 'RequiresConfirmation';$candidate.sha256.Length | Should -Be 64
        $record=@{schemaVersion=1;sourceClass=$candidate.sourceClass;trustClass=$candidate.trustClass;transportSecurity=$candidate.transportSecurity;maintenanceState=$candidate.maintenanceState;integrity=@{algorithm=$candidate.integrity.algorithm;hash=$candidate.integrity.hash;strength=$candidate.integrity.strength};downloadPermission=$candidate.downloadPermission;executePermission=$candidate.executePermission;retrievedAt=$candidate.retrievedAt;lastReviewed=$candidate.lastReviewed;provenance=$candidate.provenance}
        (Test-Json -Json ($record|ConvertTo-Json -Depth 10 -Compress) -SchemaFile (Join-Path $root 'schemas/historical-provenance.schema.json')) | Should -BeTrue
    }
    It 'keeps the historical availability index opt-in' {
        $launcher=Get-Content (Join-Path $root 'src/Launcher.ps1') -Raw
        $launcher | Should -Match 'if\(\$includeHistorical\).*Get-MmtlHistoricalLoaderAvailability'
    }
}
