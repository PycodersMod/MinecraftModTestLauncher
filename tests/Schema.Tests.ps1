BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Config.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/MinecraftVersionCatalog.psm1') -Force
    $script:matrixSchema = Join-Path $script:repoRoot 'schemas/compatibility-matrix.schema.json'
    $script:exceptionSchema = Join-Path $script:repoRoot 'schemas/exception-registry.schema.json'
    $script:configSchema = Join-Path $script:repoRoot 'schemas/launcher-config.schema.json'
    $script:catalogSchema = Join-Path $script:repoRoot 'schemas/minecraft-version-catalog.schema.json'
    $script:availabilitySchema = Join-Path $script:repoRoot 'schemas/loader-availability.schema.json'
    $script:historicalAvailabilitySchema = Join-Path $script:repoRoot 'schemas/historical-availability.schema.json'
    $script:provenance = @{
        sourceType = 'archivedOfficial'
        url = 'https://example.invalid/archive'
        fetchedAt = '2026-10-01T00:00:00Z'
        hash = ('a' * 64)
        archiveStatus = 'archived'
        notes = @('fixture provenance')
    }
    $script:matrixRecord = @{
        schemaVersion = 1
        minecraft = @{ id = '1.20.1'; channel = 'release'; releaseTime = '2023-06-12T00:00:00Z'; provenance = @($script:provenance) }
        loaderStack = @{
            primaryLoader = @{ id = 'Forge'; version = '47.2.0'; role = 'Primary'; provenance = @($script:provenance) }
            overlayLoaders = @(@{ id = 'LiteLoader'; version = '1.12.2'; role = 'Overlay'; provenance = @($script:provenance) })
        }
        toolchain = @{ id = 'ForgeGradle'; version = '6.0.16' }
        buildSystem = @{ id = 'GradleWrapper'; version = '8.1.1' }
        java = @{
            build = @{ major = 17; source = 'ToolchainMetadata'; confidence = 'High'; vendor = 'Eclipse Adoptium'; arch = 'x64' }
            runtime = @{ major = 17; source = 'MinecraftMetadata'; confidence = 'High' }
        }
        target = @{ os = 'Windows'; arch = 'x64'; capability = 'Native' }
        validation = @{ level = 'BUILD_VERIFIED'; result = 'PASSED'; lastVerified = '2026-10-01T00:00:00Z'; evidence = @('https://example.invalid/ci/1') }
        provenance = @($script:provenance)
        notes = @()
    }
    $script:exceptionRecord = @{
        schemaVersion = 1
        exceptions = @(@{
            id = 'legacy-jar-native'
            matcher = @{ minecraftVersion = '^1\.6\.4$'; loader = 'JarMod'; os = 'macOS'; arch = 'ARM64' }
            rule = @{ capability = 'Unsupported' }
            reason = 'Historical native dependency has no verified arm64 runtime.'
            provenance = @($script:provenance)
            appliesTo = @{ minecraftVersions = @('1.6.4'); loaders = @('JarMod') }
            lastReviewed = '2026-10-01'
            reviewPolicy = 'Review when upstream artifact provenance changes.'
            owner = 'MMTL'
        })
    }
}

Describe 'MMTL v2 JSON Schemas' {
    It '所有 Schema 文件自身是合法 JSON 并使用 JSON Schema Draft 7' {
        foreach ($path in @($script:matrixSchema, $script:exceptionSchema, $script:configSchema,$script:availabilitySchema)) {
            $schema = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            $schema.'$schema' | Should -Be 'http://json-schema.org/draft-07/schema#'
        }
        (Get-Content $script:catalogSchema -Raw|ConvertFrom-Json -ErrorAction Stop).'$schema' | Should -Be 'http://json-schema.org/draft-07/schema#'
    }

    It 'Compatibility Matrix 接受来源、LoaderStack、任意 Java major 与验证证据' {
        $json = $script:matrixRecord | ConvertTo-Json -Depth 20 -Compress
        Test-Json -Json $json -SchemaFile $script:matrixSchema | Should -BeTrue
    }

    It 'Compatibility Matrix 拒绝把 capability 当 validation level 或省略来源' {
        $badLevel = $script:matrixRecord.Clone()
        $badLevel.validation = @{ level = 'Native'; result = 'PASSED'; lastVerified = '2026-10-01T00:00:00Z'; evidence = @() }
        (Test-Json -Json ($badLevel | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:matrixSchema -ErrorAction SilentlyContinue) | Should -BeFalse
        $missingSource = $script:matrixRecord.Clone()
        $missingSource.minecraft = @{ id = '1.20.1'; channel = 'release'; releaseTime = '2023-06-12T00:00:00Z'; provenance = @() }
        (Test-Json -Json ($missingSource | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:matrixSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It '允许 schema 表达 Java 6 与 26，拒绝 major 0' {
        $valid = $script:matrixRecord.Clone()
        $valid.java = @{ build = @{ major = 6; source = 'ProjectConfig'; confidence = 'High' }; runtime = @{ major = 26; source = 'MinecraftMetadata'; confidence = 'Medium' } }
        (Test-Json -Json ($valid | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:matrixSchema) | Should -BeTrue
        $valid.java.build.major = 0
        (Test-Json -Json ($valid | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:matrixSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'Exception Registry 要求 matcher、reason、provenance 和复核策略' {
        (Test-Json -Json ($script:exceptionRecord | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:exceptionSchema) | Should -BeTrue
        $invalid = $script:exceptionRecord | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $invalid.exceptions[0].reason = ''
        (Test-Json -Json ($invalid | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:exceptionSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'Config Schema 兼容旧 v1、v2 任意 Java major、平台映射和未知字段' {
        $old = @{ defaultProfile = 'test'; javaHomes = @{ '17' = 'C:/jdk-17'; '26' = 'C:/jdk-26' }; profiles = @{ test = @{ project = 'demo'; mode = 'Single'; players = 1 } } }
        (Test-Json -Json ($old | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $script:configSchema) | Should -BeTrue
        $v2 = @{
            configVersion = 2; defaultProfile = 'test'; javaHomes = @{ '6' = '/jdk-6'; '11' = '/jdk-11' }
            javaHomesByPlatform = @{ Windows = @{ '8' = 'D:/jdk-8' }; Linux = @{ '21' = '/opt/jdk-21' }; MacOS = @{} }
            profiles = @{ test = @{ project = 'demo'; mode = 'Single'; players = 1 } }; futureExtension = @{ keep = $true }
        }
        (Test-Json -Json ($v2 | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $script:configSchema) | Should -BeTrue
        $v2.javaHomes['0'] = '/jdk-0'
        (Test-Json -Json ($v2 | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $script:configSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'Config Reader 原样读取 v1 与 v2 字段且不丢弃未知字段' {
        $legacyPath = Join-Path $TestDrive 'legacy-config.json'
        $legacy = @{ defaultProfile = 'test'; javaHomes = @{ '25' = '/jdk-25' }; profiles = @{ test = @{ project = 'demo'; mode = 'Single'; players = 1 } } }
        $legacy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $legacyPath
        $legacyRead = Read-MmtlConfig -Path $legacyPath
        $legacyRead.javaHomes.'25' | Should -Be '/jdk-25'
        $legacyRead.configVersion | Should -BeNullOrEmpty

        $v2Path = Join-Path $TestDrive 'v2-config.json'
        $v2 = @{ configVersion = 2; defaultProfile = 'test'; javaHomes = @{ '11' = '/jdk-11' }; javaHomesByPlatform = @{ Linux = @{ '11' = '/linux/jdk-11' } }; futureExtension = 'preserved'; profiles = @{ test = @{ project = 'demo'; mode = 'Single'; players = 1 } } }
        $v2 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $v2Path
        $v2Read = Read-MmtlConfig -Path $v2Path
        $v2Read.configVersion | Should -Be 2
        $v2Read.javaHomesByPlatform.Linux.'11' | Should -Be '/linux/jdk-11'
        $v2Read.futureExtension | Should -Be 'preserved'
    }

    It 'Config Reader 拒绝未知 schema 版本和非正整数 Java major' {
        $path = Join-Path $TestDrive 'invalid-config.json'
        $config = @{ configVersion = 3; defaultProfile = 'test'; javaHomes = @{ '17' = '/jdk-17' }; profiles = @{ test = @{ project = 'demo'; mode = 'Single'; players = 1 } } }
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        { Read-MmtlConfig -Path $path } | Should -Throw '*Config Schema 版本*'
        $config.configVersion = 2
        $config.javaHomes = @{ '0' = '/jdk-0' }
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
        { Read-MmtlConfig -Path $path } | Should -Throw '*正整数 major*'
    }

    It 'normalized Mojang Catalog schema accepts canonical release metadata and provenance' {
        $catalog=[ordered]@{
            schemaVersion=1;source='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';fetchedAt='2026-10-01T00:00:00Z';manifestHash=('a'*64);latestRelease='26.3';latestSnapshot='26.4-snapshot-2';minimumReleaseId='1.0'
            entries=@(@{
                id='26.3';type='release';time='2026-09-15T10:00:00Z';releaseTime='2026-09-15T10:00:00Z';metadataUrl='https://piston-meta.mojang.com/v1/26.3.json';metadataSha1=('b'*40);complianceLevel=1
                catalogStatus='CATALOGUED';metadataStatus='NOT_FETCHED';runtimeJava=@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown'}
                provenance=@(@{sourceType='official';url='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';fetchedAt='2026-10-01T00:00:00Z';hash=('a'*64);archiveStatus='active';cacheStatus='Fresh'})
            })
        }
        (Test-Json -Json ($catalog|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:catalogSchema) | Should -BeTrue
        $catalog.entries[0].type='snapshot'
        (Test-Json -Json ($catalog|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:catalogSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'Loader Availability Index schema accepts three-valued upstream results and cache provenance' {
        $index=@{schemaVersion=1;generatedAt='2026-10-02T00:00:00Z';minecraftCatalogHash=('a'*64);cacheStatus='OfflineCache';providerStatuses=@{};entries=@()}
        foreach($loader in @('Forge','Fabric','NeoForge','Quilt')){$index.providerStatuses[$loader]=@{status='Available';cacheStatus='OfflineCache';source='https://example.invalid/metadata';lastChecked='2026-10-02T00:00:00Z';error=$null}}
        $index.entries=@(@{minecraftId='1.20.1';loaders=@{}})
        foreach($loader in @('Forge','Fabric','NeoForge','Quilt')){$index.entries[0].loaders[$loader]=@{availability='Unknown';source=$null;lastChecked=$null;cacheStatus='Unavailable';notes=@('offline fixture')}}
        (Test-Json -Json ($index|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:availabilitySchema) | Should -BeTrue
        $index.entries[0].loaders.Forge.availability='BUILD_VERIFIED'
        (Test-Json -Json ($index|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:availabilitySchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'Historical Availability schema keeps manual artifacts separate from remote availability' {
        $index=@{schemaVersion=1;minecraftId='1.2.5';scope='Historical';generatedAt='2026-10-02T00:00:00Z';entries=@(@{loaderId='JarMod';availability='Manual';providerStatus='ManualOnly';sourceClass='ManualArtifact';trustClass='UnverifiedHistorical';transportSecurity='LocalManual';maintenanceState='Unknown';cacheStatus='NotApplicable';source=$null;candidateCount=0;notes=@('Requires user supplied artifact.')})}
        (Test-Json -Json ($index|ConvertTo-Json -Depth 10 -Compress) -SchemaFile $script:historicalAvailabilitySchema) | Should -BeTrue
        $index.entries[0].availability='Available'
        (Test-Json -Json ($index|ConvertTo-Json -Depth 10 -Compress) -SchemaFile $script:historicalAvailabilitySchema) | Should -BeTrue
        $index.entries[0].sourceClass='TrustedOfficial'
        (Test-Json -Json ($index|ConvertTo-Json -Depth 10 -Compress) -SchemaFile $script:historicalAvailabilitySchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }
}
