BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/JavaRuntimeResolver.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/ProjectDetector.psm1') -Force
    $script:catalogEntry=[pscustomobject]@{id='1.20.5';metadataStatus='VERIFIED'}
    $script:fallbackPath=Join-Path $script:repoRoot 'src/Catalog/data/java-runtime-fallback.json'
}

Describe 'Runtime Java metadata resolver v2' {
    It 'uses verified Mojang javaVersion as authoritative metadata' {
        $metadata=[pscustomobject]@{metadataStatus='VERIFIED';metadata=[pscustomobject]@{javaVersion=[pscustomobject]@{majorVersion=21;component='java-runtime-delta'}};provenance=@('official')}
        $result=Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId '1.20.5' -CatalogEntry $script:catalogEntry -VersionMetadata $metadata
        $result.major | Should -Be 21
        $result.component | Should -Be 'java-runtime-delta'
        $result.source | Should -Be 'MojangVersionMetadata'
        $result.requirementKind | Should -Be 'AuthoritativeMetadata'
    }

    It 'uses an explicit project override ahead of metadata' {
        $metadata=[pscustomobject]@{metadataStatus='VERIFIED';metadata=[pscustomobject]@{javaVersion=[pscustomobject]@{majorVersion=21;component='java-runtime-delta'}};provenance=@('official')}
        $override=[pscustomobject]@{major=25;component='custom';provenance=@('project config')}
        $result=Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId '1.20.5' -CatalogEntry $script:catalogEntry -VersionMetadata $metadata -RuntimeOverride $override
        $result.major | Should -Be 25
        $result.source | Should -Be 'ProjectOverride'
        $result.requirementKind | Should -Be 'ProjectOverride'
    }

    It 'labels audited fallback separately from authoritative requirements' {
        $metadata=[pscustomobject]@{metadataStatus='VERIFIED';metadata=[pscustomobject]@{id='1.18.2'};provenance=@('official')}
        $result=Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId '1.18.2' -CatalogEntry $script:catalogEntry -VersionMetadata $metadata
        $result.major | Should -Be 17
        $result.source | Should -Be 'MMTLCompatibilityFallback'
        $result.requirementKind | Should -Be 'CompatibilityFallback'
        $result.provenance.url | Should -Match 'minecraft.net|minecraft-feedback'
    }

    It 'returns Unknown when verified metadata has no javaVersion and no fallback applies' {
        $metadata=[pscustomobject]@{metadataStatus='VERIFIED';metadata=[pscustomobject]@{id='1.12.2'};provenance=@('official')}
        $result=Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId '1.12.2' -CatalogEntry $script:catalogEntry -VersionMetadata $metadata
        $result.major | Should -BeNullOrEmpty
        $result.requirementKind | Should -Be 'Unknown'
        $result.metadataStatus | Should -Be 'VERIFIED_NO_JAVA_VERSION'
    }

    It 'supports arbitrary positive Java majors and rejects zero overrides' {
        foreach($major in @(6,7,8,11,16,17,21,25,26)){
            $metadata=[pscustomobject]@{metadataStatus='VERIFIED';metadata=[pscustomobject]@{javaVersion=[pscustomobject]@{majorVersion=$major}};provenance=@()}
            (Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId '26.3' -CatalogEntry $script:catalogEntry -VersionMetadata $metadata).major | Should -Be $major
        }
        { Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId '26.3' -CatalogEntry $script:catalogEntry -RuntimeOverride @{major=0} } | Should -Throw '*RUNTIME_JAVA_OVERRIDE_INVALID*'
        $missingMajor=[pscustomobject]@{metadataStatus='VERIFIED';metadata=[pscustomobject]@{javaVersion=[pscustomobject]@{component='java-runtime-delta'}};provenance=@()}
        { Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId '26.3' -CatalogEntry $script:catalogEntry -VersionMetadata $missingMajor } | Should -Throw '*METADATA_JAVA_VERSION_INVALID*'
    }

    It 'keeps the legacy JavaMajor as Build Java and leaves Runtime Java independent' {
        $project=Join-Path $TestDrive 'project'
        New-Item -ItemType Directory -Path $project -Force|Out-Null
        Set-Content (Join-Path $project 'build.gradle') '// fixture'
        Set-Content (Join-Path $project 'gradle.properties') ('minecraft_version=1.20.5'+[Environment]::NewLine+'java_version=17')
        $detected=Get-MmtlProject -Path $project
        $detected.JavaMajor | Should -Be 17
        $detected.BuildJavaMajor | Should -Be 17
        $detected.BuildJavaRequirement.major | Should -Be 17
        $detected.RuntimeJavaMajor | Should -BeNullOrEmpty
        $detected.RuntimeJavaRequirement.requirementKind | Should -Be 'Unknown'
    }
}
