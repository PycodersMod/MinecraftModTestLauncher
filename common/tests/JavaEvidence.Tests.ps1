BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Architecture/Contracts.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/BuildJavaResolver.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/ProjectDetector.psm1') -Force
    $script:buildEvidenceArgs=@{
        MinecraftId='1.8.9';LoaderId='LegacyFabric';LoaderVersion='0.18.3'
        Toolchain=(New-MmtlToolchainContext -Id LegacyLooming -Version '1.16.1' -Ecosystem LegacyFabric)
        Platform=(New-MmtlPlatformContext -OS Windows -Arch x64)
        BuildJavaRequirement=(New-MmtlJavaRequirement -Purpose BuildJava -Major 17 -RequirementKind Minimum -Source GradleWrapperRuntimeCompatibility -Confidence High)
        ObservedBuildJava=[pscustomobject]@{major=25;exactVersion='25.0.1+8-LTS';vendor='Oracle';os='Windows';arch='x64'}
        CompilerTargetMajor=8;Result='PASSED';ArtifactSha256=('a' * 64)
        VerifiedAt=[DateTimeOffset]::Parse('2026-10-02T00:00:00Z')
        FixtureProvenance=[pscustomobject]@{sourceUrl='https://github.com/Legacy-Fabric/fabric-example-mod';commit='422896c188108632da97825f801719f0015b1b32';license='MIT'}
    }
}

Describe 'Build Java requirement and observed build evidence' {
    It 'labels Gradle wrapper compatibility as a JVM minimum' {
        $project=Join-Path $TestDrive 'gradle-nine';New-Item -ItemType Directory -Path (Join-Path $project 'gradle/wrapper') -Force|Out-Null
        'distributionUrl=https\://services.gradle.org/distributions/gradle-9.4-bin.zip'|Set-Content (Join-Path $project 'gradle/wrapper/gradle-wrapper.properties')
        $requirement=Get-MmtlGradleWrapperRuntimeJavaRequirement -ProjectRoot $project
        $requirement.requirementKind | Should -BeExactly 'Minimum'
        $requirement.minimumMajor | Should -Be 17
        $requirement.major | Should -Be 17
    }

    It 'records the documented Gradle 4.9 daemon JVM support interval separately from compiler target' {
        $project=Join-Path $TestDrive 'gradle-four-nine';New-Item -ItemType Directory -Path (Join-Path $project 'gradle/wrapper') -Force|Out-Null
        'distributionUrl=https\\://services.gradle.org/distributions/gradle-4.9-all.zip'|Set-Content (Join-Path $project 'gradle/wrapper/gradle-wrapper.properties')
        $requirement=Get-MmtlGradleWrapperRuntimeJavaRequirement -ProjectRoot $project
        $requirement.minimumMajor | Should -Be 7
        $requirement.maximumMajor | Should -Be 10
    }

    It 'labels a Minecraft compatibility fallback as a low-confidence preference' {
        $requirement=Get-MmtlBuildJavaCompatibilityFallback -MinecraftId '1.12.2'
        $requirement.requirementKind | Should -BeExactly 'Preferred'
        $requirement.preferredMajor | Should -Be 8
        $requirement.minimumMajor | Should -BeNullOrEmpty
        $requirement.confidence | Should -BeExactly 'Low'
    }

    It 'keeps wrapper minimum and configured JVM preference separate from Java 8 bytecode target' {
        $project=Join-Path $TestDrive 'java-semantics';New-Item -ItemType Directory -Path (Join-Path $project 'gradle/wrapper') -Force|Out-Null
        'plugins { id "fabric-loom" version "1.10.5" }'|Set-Content (Join-Path $project 'build.gradle')
        "minecraft_version=1.20.1`njava_version=21"|Set-Content (Join-Path $project 'gradle.properties')
        'distributionUrl=https\://services.gradle.org/distributions/gradle-9.4-bin.zip'|Set-Content (Join-Path $project 'gradle/wrapper/gradle-wrapper.properties')
        'sourceCompatibility = JavaVersion.VERSION_1_8'|Add-Content (Join-Path $project 'build.gradle')
        $detected=Get-MmtlProject -Path $project
        $detected.BuildJavaRequirement.major | Should -Be 17
        $detected.BuildJavaRequirement.minimumMajor | Should -Be 17
        $detected.BuildJavaRequirement.preferredMajor | Should -Be 21
        $detected.BuildJavaRequirement.compilerTargetMajor | Should -Be 8
        $detected.CompilerTargetJavaMajor | Should -Be 8
    }

    It 'bounds Rift Gradle 4.9 Build Java to the documented JVM range without treating target 8 as the daemon version' {
        $project=Join-Path $TestDrive 'rift-build-java-range';New-Item -ItemType Directory -Path (Join-Path $project 'gradle/wrapper') -Force|Out-Null
        "buildscript { dependencies { classpath 'org.dimdev:ForgeGradle:2.3-SNAPSHOT' } }`napply plugin: 'net.minecraftforge.gradle.tweaker-client'`nsourceCompatibility = 1.8`nminecraft { version = '1.13' }"|Set-Content (Join-Path $project 'build.gradle')
        'distributionUrl=https\\://services.gradle.org/distributions/gradle-4.9-all.zip'|Set-Content (Join-Path $project 'gradle/wrapper/gradle-wrapper.properties')
        $detected=Get-MmtlProject -Path $project
        $detected.BuildJavaRequirement.minimumMajor | Should -Be 8
        $detected.BuildJavaRequirement.maximumMajor | Should -Be 10
        $detected.CompilerTargetJavaMajor | Should -Be 8
        $detected.RuntimeJavaRequirement.major | Should -BeNullOrEmpty
    }

    It 'keeps the minimum JVM, actually used JDK, compiler target, and fixture provenance distinct' {
        $requirement = $script:buildEvidenceArgs.BuildJavaRequirement
        $evidence = New-MmtlBuildEvidence @script:buildEvidenceArgs

        $requirement.requirementKind | Should -BeExactly 'Minimum'
        $requirement.minimumMajor | Should -Be 17
        $requirement.major | Should -Be 17
        $evidence.observedBuildJava.major | Should -Be 25
        $evidence.compilerTarget.major | Should -Be 8
        $evidence.buildJavaRequirement.minimumMajor | Should -Be 17
        $evidence.minecraftId | Should -BeExactly '1.8.9'
        (Test-Json -Json ($evidence | ConvertTo-Json -Depth 12 -Compress) -SchemaFile (Join-Path $script:repoRoot 'schemas/build-evidence.schema.json')) | Should -BeTrue
    }

    It 'rejects a passed build record without an artifact digest' {
        $incomplete=@{}+$script:buildEvidenceArgs
        $incomplete.Remove('ArtifactSha256')
        { New-MmtlBuildEvidence @incomplete } | Should -Throw '*必须包含产物 SHA-256*'
    }

    It 'does not mark a build passed when the observed JVM is below the declared minimum' {
        $incompatible=@{}+$script:buildEvidenceArgs
        $incompatible.ObservedBuildJava=[pscustomobject]@{major=16;exactVersion='16.0.2';vendor='Oracle';os='Windows';arch='x64'}
        { New-MmtlBuildEvidence @incompatible } | Should -Throw '*实测构建 JVM 低于要求的最低版本*'
    }

    It 'does not mark a build passed when the observed JVM exceeds the declared Gradle maximum' {
        $incompatible=@{}+$script:buildEvidenceArgs
        $incompatible.BuildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=8;minimumMajor=8;maximumMajor=10;requirementKind='Minimum';source='GradleWrapperRuntimeCompatibility';confidence='High'}
        $incompatible.ObservedBuildJava=[pscustomobject]@{major=17;exactVersion='17.0.1';vendor='Oracle';os='Windows';arch='x64'}
        { New-MmtlBuildEvidence @incompatible } | Should -Throw '*实测构建 JVM 高于要求的最高版本*'
    }

    It 'rejects build evidence whose observed Java platform differs from the build platform' {
        $mismatch=@{}+$script:buildEvidenceArgs
        $mismatch.ObservedBuildJava=[pscustomobject]@{major=25;exactVersion='25.0.1+8-LTS';vendor='Oracle';os='Linux';arch='x64'}
        { New-MmtlBuildEvidence @mismatch } | Should -Throw '*必须与构建平台一致*'
    }

    It 'rejects a schema record that claims a passed build without an artifact digest' {
        $evidence=New-MmtlBuildEvidence @script:buildEvidenceArgs
        $evidence.artifactSha256=$null
        (Test-Json -Json ($evidence | ConvertTo-Json -Depth 12 -Compress) -SchemaFile (Join-Path $script:repoRoot 'schemas/build-evidence.schema.json') -ErrorAction SilentlyContinue) | Should -BeFalse
    }
}
