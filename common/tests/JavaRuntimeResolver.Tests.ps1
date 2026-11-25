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

    It 'resolves Java from a frozen Mojang snapshot when the live catalog is unavailable' {
        $snapshotRoot=Join-Path $TestDrive 'frozen-runtime-java'
        $snapshotDirectory=Join-Path $snapshotRoot 'MojangVersions'
        New-Item -ItemType Directory -Path $snapshotDirectory -Force|Out-Null
        $bytes=[Text.Encoding]::UTF8.GetBytes('{"id":"1.7.10","javaVersion":{"component":"jre-legacy","majorVersion":8}}')
        $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        [IO.File]::WriteAllBytes((Join-Path $snapshotDirectory "$sha256.bin"),$bytes)
        $source=[pscustomobject]@{url="https://piston-meta.mojang.com/v1/packages/$sha1/1.7.10.json";manifestSha1=$sha1;sourceSha1=$sha1;snapshotSha256=$sha256;retrievedAt='2026-10-07T14:05:25Z'}
        $catalog=[pscustomobject]@{schemaVersion=1;universeHash='universe-fixture';entries=@([pscustomobject]@{minecraftId='1.7.10';metadataSource=$source})}

        $result=Resolve-MmtlFrozenRuntimeJavaCatalogRequirement -MinecraftId '1.7.10' -Catalog $catalog -UniverseHash 'universe-fixture' -SnapshotRoot $snapshotRoot

        $result.major|Should -Be 8
        $result.source|Should -BeExactly 'MojangVersionMetadata'
        $result.component|Should -BeExactly 'jre-legacy'
    }

    It 'rejects frozen runtime Java snapshots whose bytes do not match their catalog hash' {
        $snapshotRoot=Join-Path $TestDrive 'tampered-runtime-java'
        $snapshotDirectory=Join-Path $snapshotRoot 'MojangVersions'
        New-Item -ItemType Directory -Path $snapshotDirectory -Force|Out-Null
        $bytes=[Text.Encoding]::UTF8.GetBytes('{"id":"1.7.10","javaVersion":{"component":"jre-legacy","majorVersion":8}}')
        $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $sha256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        [IO.File]::WriteAllBytes((Join-Path $snapshotDirectory "$sha256.bin"),$bytes)
        $source=[pscustomobject]@{url="https://piston-meta.mojang.com/v1/packages/$sha1/1.7.10.json";manifestSha1=$sha1;sourceSha1=$sha1;snapshotSha256=$sha256;retrievedAt='2026-10-07T14:05:25Z'}
        $catalog=[pscustomobject]@{schemaVersion=1;universeHash='universe-fixture';entries=@([pscustomobject]@{minecraftId='1.7.10';metadataSource=$source})}

        { Resolve-MmtlFrozenRuntimeJavaCatalogRequirement -MinecraftId '1.7.10' -Catalog $catalog -UniverseHash 'universe-fixture' -SnapshotRoot $snapshotRoot } | Should -Throw '*MOJANG_VERSION_CATALOG_SNAPSHOT_HASH_MISMATCH*'
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

Describe 'Frozen Mojang client artifact resolver' {
    It 'resolves only content-addressed client metadata from the hash-verified snapshot' {
        $snapshotRoot=Join-Path $TestDrive 'client-snapshots'
        $directory=Join-Path $snapshotRoot 'MojangVersions';New-Item -ItemType Directory -Path $directory -Force|Out-Null
        $metadata=[ordered]@{id='1.7.10';assetIndex=[ordered]@{id='1.7.10';sha1='1863782e33ce7b584fc45b037325a1964e095d3e';size=72996;url='https://launchermeta.mojang.com/v1/packages/1863782e33ce7b584fc45b037325a1964e095d3e/1.7.10.json'};downloads=[ordered]@{client=[ordered]@{sha1='e80d9b3bf5085002218d4be59e668bac718abbc6';size=5256245;url='https://launcher.mojang.com/v1/objects/e80d9b3bf5085002218d4be59e668bac718abbc6/client.jar'}}}
        $bytes=[Text.Encoding]::UTF8.GetBytes(($metadata|ConvertTo-Json -Depth 8 -Compress))
        $snapshotSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $snapshotSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        [IO.File]::WriteAllBytes((Join-Path $directory "$snapshotSha256.bin"),$bytes)
        $catalog=[pscustomobject]@{schemaVersion=1;universeHash='fixture';entries=@([pscustomobject]@{minecraftId='1.7.10';metadataSource=[pscustomobject]@{url="https://piston-meta.mojang.com/v1/packages/$snapshotSha1/1.7.10.json";manifestSha1=$snapshotSha1;sourceSha1=$snapshotSha1;snapshotSha256=$snapshotSha256}})}

        $artifact=Resolve-MmtlFrozenMojangClientArtifact -MinecraftId '1.7.10' -Catalog $catalog -UniverseHash 'fixture' -SnapshotRoot $snapshotRoot

        $artifact.url | Should -BeExactly 'https://launcher.mojang.com/v1/objects/e80d9b3bf5085002218d4be59e668bac718abbc6/client.jar'
        $artifact.sha1 | Should -BeExactly 'e80d9b3bf5085002218d4be59e668bac718abbc6'
        $artifact.bytes | Should -Be 5256245
        $artifact.metadataSnapshotSha256 | Should -BeExactly $snapshotSha256
        $artifact.versionMetadata.sha1 | Should -BeExactly $snapshotSha1
        $artifact.assetIndex.sha1 | Should -BeExactly '1863782e33ce7b584fc45b037325a1964e095d3e'
    }

    It 'resolves a separately pinned official server artifact from the same verified version snapshot' {
        $snapshotRoot=Join-Path $TestDrive 'server-snapshots';$directory=Join-Path $snapshotRoot 'MojangVersions';New-Item -ItemType Directory -Path $directory -Force|Out-Null
        $metadata=[ordered]@{id='1.7.10';assetIndex=[ordered]@{id='1.7.10';sha1='1863782e33ce7b584fc45b037325a1964e095d3e';size=72996;url='https://launchermeta.mojang.com/v1/packages/1863782e33ce7b584fc45b037325a1964e095d3e/1.7.10.json'};downloads=[ordered]@{server=[ordered]@{sha1='952438ac4e01b4d115c5fc38f891710c4941df29';size=9605030;url='https://launcher.mojang.com/v1/objects/952438ac4e01b4d115c5fc38f891710c4941df29/server.jar'}}}
        $bytes=[Text.Encoding]::UTF8.GetBytes(($metadata|ConvertTo-Json -Depth 8 -Compress));$snapshotSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant();$snapshotSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();[IO.File]::WriteAllBytes((Join-Path $directory "$snapshotSha256.bin"),$bytes)
        $catalog=[pscustomobject]@{schemaVersion=1;universeHash='fixture';entries=@([pscustomobject]@{minecraftId='1.7.10';metadataSource=[pscustomobject]@{url="https://piston-meta.mojang.com/v1/packages/$snapshotSha1/1.7.10.json";manifestSha1=$snapshotSha1;sourceSha1=$snapshotSha1;snapshotSha256=$snapshotSha256}})}

        $artifact=Resolve-MmtlFrozenMojangClientArtifact -MinecraftId '1.7.10' -Catalog $catalog -UniverseHash 'fixture' -SnapshotRoot $snapshotRoot -ArtifactName server

        $artifact.url | Should -BeExactly 'https://launcher.mojang.com/v1/objects/952438ac4e01b4d115c5fc38f891710c4941df29/server.jar'
        $artifact.sha1 | Should -BeExactly '952438ac4e01b4d115c5fc38f891710c4941df29'
        $artifact.bytes | Should -Be 9605030
    }

    It 'rejects a client URL that does not bind to the official SHA-1 object path' {
        $snapshotRoot=Join-Path $TestDrive 'client-bad-url'
        $directory=Join-Path $snapshotRoot 'MojangVersions';New-Item -ItemType Directory -Path $directory -Force|Out-Null
        $metadata=[ordered]@{id='1.7.10';assetIndex=[ordered]@{id='1.7.10';sha1='1863782e33ce7b584fc45b037325a1964e095d3e';size=72996;url='https://launchermeta.mojang.com/v1/packages/1863782e33ce7b584fc45b037325a1964e095d3e/1.7.10.json'};downloads=[ordered]@{client=[ordered]@{sha1=('a'*40);size=10;url='https://example.invalid/client.jar'}}}
        $bytes=[Text.Encoding]::UTF8.GetBytes(($metadata|ConvertTo-Json -Depth 8 -Compress));$sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant();$sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        [IO.File]::WriteAllBytes((Join-Path $directory "$sha256.bin"),$bytes)
        $catalog=[pscustomobject]@{schemaVersion=1;universeHash='fixture';entries=@([pscustomobject]@{minecraftId='1.7.10';metadataSource=[pscustomobject]@{url="https://piston-meta.mojang.com/v1/packages/$sha1/1.7.10.json";manifestSha1=$sha1;sourceSha1=$sha1;snapshotSha256=$sha256}})}
        { Resolve-MmtlFrozenMojangClientArtifact -MinecraftId '1.7.10' -Catalog $catalog -UniverseHash 'fixture' -SnapshotRoot $snapshotRoot } | Should -Throw '*MOJANG_CLIENT_ARTIFACT_URL_INVALID*'
    }
}
