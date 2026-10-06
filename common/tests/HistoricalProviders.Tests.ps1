BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/HistoricalAvailability.psm1') -Force
    $script:providerModule=Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/HistoricalProviders.psm1') -Force -PassThru
    $script:catalog = [pscustomobject]@{entries=@(@{id='1.7.2';type='release'},@{id='1.8.9';type='release'},@{id='1.14.4';type='release'},@{id='1.13';type='release'})}
    $script:legacyGame = '[{"version":"1.7.2","stable":true},{"version":"1.8.9","stable":true},{"version":"1.14.4","stable":false},{"version":"b1.7.3","stable":true}]'
    $script:ornitheGame = '[{"version":"b1.9-pre6","stable":false},{"version":"1.7.2","stable":false},{"version":"1.8.9","stable":true},{"version":"1.8.8","stable":false},{"version":"1.14.4","stable":false}]'
    $script:ornitheLoader = '[{"separator":".","build":1,"version":"0.1.1","stable":true}]'
    $script:ornitheDetail = '[{"loader":{"version":"0.1.1","stable":true},"calamus":{"version":"1.7.2","stable":true},"launcherMeta":{"mainClass":{"client":"net.ornithemc.loader.launch.knot.KnotClient"}}}]'
    $script:legacyDetail = '[{"loader":{"version":"0.14.0","maven":"net.fabricmc:fabric-loader:0.14.0","stable":true},"intermediary":{"version":"1.7.2","maven":"net.legacyfabric:intermediary:1.7.2","stable":true},"launcherMeta":{"version":1}}]'
    $script:liteManifest = '{"meta":{"updated":"2017-11-29T16:31:41+00:00"},"versions":{"1.10.2":{"repo":{"url":"http://dl.liteloader.com/repo/"},"artefacts":{"com.mumfrey:liteloader":{"1.10.2":{"file":"liteloader-1.10.2.jar","version":"1.10.2","md5":"8a7c21f32d77ee08b393dd3921ced8eb"}}},"dev":{"fgVersion":"2.2","mappings":"snapshot_custom"}}}}'
    $script:http = {
        param($uri,$headers,$timeout)
        $content = switch -Regex ($uri) {
            '/v2/versions/game$' { if($uri -match 'legacyfabric'){ $script:legacyGame } else { $script:ornitheGame }; break }
            '/v2/versions/loader$' { $script:ornitheLoader; break }
            '/v2/versions/loader/1\.7\.2$' { if($uri -match 'legacyfabric'){$script:legacyDetail}else{$script:ornitheDetail}; break }
            'versions/versions\.json$' { $script:liteManifest; break }
            default { '[]' }
        }
        [pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($content);ResponseUri=$uri}
    }
}

Describe 'Historical providers and provenance' {
    It 'reports unavailable providers cleanly when every official endpoint is offline' {
        $offline={throw 'fixture network failure'}
        $legacy=Get-MmtlLegacyFabricProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'legacy-down') -HttpGet $offline
        $ornithe=Get-MmtlOrnitheProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'ornithe-down') -HttpGet $offline
        $legacy.providerStatus | Should -BeExactly 'Unavailable';@($legacy.supportedVersions).Count | Should -Be 0
        $ornithe.providerStatus | Should -BeExactly 'Unavailable';@($ornithe.supportedVersions).Count | Should -Be 0
    }
    It 'maps only Ornithe 1.0+ game IDs present in the Mojang release catalog and preserves loader/mappings context' {
        $snapshot = Get-MmtlOrnitheProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'ornithe') -HttpGet $script:http
        $coverage = Get-MmtlOrnitheReleaseCoverage -Catalog $script:catalog -Snapshot $snapshot
        $coverage.releaseCount | Should -Be 3
        $coverage.earliestRelease | Should -Be '1.7.2'
        $coverage.latestRelease | Should -Be '1.14.4'
        $candidate = Get-MmtlOrnitheCandidates -MinecraftId '1.7.2' -RuntimeRoot (Join-Path $TestDrive 'ornithe-candidate') -HttpGet $script:http | Select-Object -First 1
        $candidate.loaderId | Should -Be 'OrnitheLoader'
        $candidate.toolchain.id | Should -Be 'Ploceus'
        $candidate.toolchain.ecosystem | Should -Be 'Ornithe'
        $candidate.mappingContext.calamus.version | Should -Be '1.7.2'
    }

    It 'keeps Legacy Fabric identity distinct and attaches its intermediary mapping to the candidate' {
        $coverageSnapshot = [pscustomobject]@{supportedVersions=@(@{version='1.7.2'},@{version='1.8.9'},@{version='b1.7.3'})}
        $coverage = Get-MmtlLegacyFabricReleaseCoverage -Catalog $script:catalog -Snapshot $coverageSnapshot
        $coverage.releaseCount | Should -Be 2
        $candidate = Get-MmtlLegacyFabricCandidates -MinecraftId '1.7.2' -RuntimeRoot (Join-Path $TestDrive 'legacy-candidate') -HttpGet $script:http | Select-Object -First 1
        $candidate.loaderId | Should -Be 'LegacyFabric'
        $candidate.loaderId | Should -Not -Be 'Fabric'
        $candidate.mappingContext.intermediary.maven | Should -Be 'net.legacyfabric:intermediary:1.7.2'
        $candidate.toolchain.id | Should -Be 'LegacyLooming'
    }

    It 'keeps LiteLoader official HTTPS metadata separate from HTTP-only MD5 artifacts' {
        $snapshot = Get-MmtlLiteLoaderProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'lite') -HttpGet $script:http
        $candidate = Get-MmtlLiteLoaderCandidates -MinecraftId '1.10.2' -Snapshot $snapshot | Select-Object -First 1
        $candidate.sourceClass | Should -Be 'HistoricalOfficial'
        $candidate.metadataTransport | Should -Be 'HTTPS'
        $candidate.artifactTransport | Should -Be 'HTTPOnly'
        $candidate.integrity.algorithm | Should -Be 'MD5'
        $candidate.integrity.strength | Should -Be 'CorruptionDetectionOnly'
        $candidate.executePermission | Should -Be 'Denied'
        $candidate.maintenanceState | Should -Be 'Archived'
    }
    It 'accepts LiteLoader manifest records without optional dev toolchain metadata' {
        $original=$script:liteManifest
        try {
            $script:liteManifest=$script:liteManifest.Replace(',"dev":{"fgVersion":"2.2","mappings":"snapshot_custom"}','')
            $snapshot=Get-MmtlLiteLoaderProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'lite-no-dev') -HttpGet $script:http
            $snapshot.providerStatus | Should -Be 'Available'
            $candidate=Get-MmtlLiteLoaderCandidates -MinecraftId '1.10.2' -Snapshot $snapshot|Select-Object -First 1
            $candidate.toolchain.version | Should -BeNullOrEmpty
            $candidate.mappingContext.mappings | Should -BeNullOrEmpty
        } finally {$script:liteManifest=$original}
    }

    It 'exposes ModLoader and ModLoaderMP as separate archive providers with distinct client/server artifacts' {
        $loader = Get-MmtlModLoaderArchiveCandidates -MinecraftId '1.2.5' | Select-Object -First 1
        $mp = Get-MmtlModLoaderMPArchiveCandidates -MinecraftId '1.2.5'
        $loader.loaderId | Should -Be 'ModLoader'
        $loader.hashAlgorithm | Should -Be 'SHA256'
        @($mp | Where-Object loaderId -ne 'ModLoaderMP').Count | Should -Be 0
        @($mp | ForEach-Object artifactType | Sort-Object -Unique) | Should -Be @('ClientZip','ServerZip')
        @($mp | ForEach-Object sha256 | Where-Object { $_ -match '^[0-9a-f]{64}$' }).Count | Should -Be 2
        @($mp | Where-Object executePermission -eq 'Granted').Count | Should -Be 0
    }

    It 'resolves historical ModLoader archive entries without treating source-declared hashes as local verification' {
        $modernArchive = Get-MmtlModLoaderArchiveCandidates -MinecraftId '1.6.2'
        $modernArchive.Count | Should -BeGreaterThan 0
        $modernArchive[0].loaderVersion | Should -BeExactly 'ModLoader 1.6.2'
        $modernArchive[0].versionLabelSource | Should -BeExactly 'SOURCE_FILENAME'
        $modernArchive[0].artifactFilename | Should -Be 'ModLoader 1.6.2.zip'
        $modernArchive[0].sha256 | Should -BeExactly '0b14f5e261c9862989aa74313b59188cce10bea6724bae31130ce1e8e6a1c060'
        $modernArchive[0].hashProvenance | Should -BeExactly 'SourceDeclared'
        $modernArchive[0].hashVerifiedLocally | Should -BeFalse
        $modernArchive[0].artifactTransport | Should -BeExactly 'HTTPS'
        $modernArchive[0].executePermission | Should -BeExactly 'Denied'

        $httpOnly = Get-MmtlModLoaderArchiveCandidates -MinecraftId '1.2.4'
        $httpOnly.Count | Should -BeGreaterThan 0
        $httpOnly[0].artifactTransport | Should -BeExactly 'HTTPOnly'
        $httpOnly[0].downloadPermission | Should -BeExactly 'Denied'
        $httpOnly[0].integrity.downloadPermission | Should -BeExactly 'Denied'
        $httpOnly[0].executePermission | Should -BeExactly 'Denied'

        $oldRar = Get-MmtlModLoaderArchiveCandidates -MinecraftId 'b1.2_01'
        $oldRar.Count | Should -BeGreaterThan 0
        $oldRar[0].artifactFilename | Should -BeExactly 'ModLoader B1.2_01.rar'
        $oldRar[0].artifactFormat | Should -BeExactly 'RAR'
    }

    It 'has source-backed candidate records for every historical archive target in the frozen Universe' {
        $universePath=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'compatibility/universe-preview.json'
        $sourceIndexPath=Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'compatibility/source-snapshots.json'
        $universe=Get-Content -LiteralPath $universePath -Raw|ConvertFrom-Json
        $sourceIndex=Get-Content -LiteralPath $sourceIndexPath -Raw|ConvertFrom-Json
        foreach($loaderId in @('ModLoader','ModLoaderMP')){
            $targets=@($universe.targets|Where-Object loaderId -CEQ $loaderId)
            $targets.Count | Should -BeGreaterThan 0
            $source=$sourceIndex.sources|Where-Object providerId -CEQ $loaderId|Select-Object -First 1
            $source | Should -Not -BeNullOrEmpty
            foreach($target in $targets){
                $candidates=if($loaderId -eq 'ModLoader'){@(Get-MmtlModLoaderArchiveCandidates -MinecraftId ([string]$target.minecraftId))}else{@(Get-MmtlModLoaderMPArchiveCandidates -MinecraftId ([string]$target.minecraftId))}
                $candidates.Count | Should -BeGreaterThan 0 -Because "$loaderId@$($target.minecraftId) has exact source archive records"
                $target.candidateStatus | Should -BeExactly 'Resolved' -Because "$loaderId@$($target.minecraftId) is in the frozen Universe"
                $target.loaderVersionCandidates -is [array] | Should -BeTrue
                @($target.loaderVersionCandidates).Count | Should -Be $candidates.Count
                $target.candidateSourceHash | Should -BeExactly $source.sha256
            }
        }
        $universeSchemaPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/compatibility-universe.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $universePath -Raw) -SchemaFile $universeSchemaPath) | Should -BeTrue
    }

    It 'identifies original Rift and labels a community port separately when present' {
        $original = Get-MmtlRiftCandidates -MinecraftId '1.13' | Where-Object originality -eq 'Original' | Select-Object -First 1
        $original.sourceClass | Should -Be 'HistoricalOfficial'
        $original.loaderId | Should -Be 'Rift'
        $original.commit | Should -Match '^[0-9a-f]{40}$'
        $port = Get-MmtlRiftCandidates -MinecraftId '1.13.2' | Select-Object -First 1
        if ($port) { $port.originality | Should -Be 'CommunityPort';$port.displayName | Should -Be 'Rift Community Port' }
    }

    It 'returns historical availability when static providers have no candidates for an anchor' {
        $offline={throw 'fixture network failure'}
        $index=Get-MmtlHistoricalLoaderAvailability -MinecraftId '1.14.4' -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'availability-empty') -Offline -HttpGet $offline
        @($index.entries).Count | Should -Be 7
        @($index.entries | Where-Object {$_.loaderId -in @('Rift','ModLoader','ModLoaderMP')} | Where-Object availability -ne 'Unknown').Count | Should -Be 0
        @($index.entries | Where-Object {$_.loaderId -in @('Rift','ModLoader','ModLoaderMP')} | Where-Object reasonCode -ne 'HISTORICAL_SOURCE_NO_RECORD').Count | Should -Be 0
        $json=$index|ConvertTo-Json -Depth 20 -Compress
        (Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas/historical-availability.schema.json')) | Should -BeTrue
    }

    It 'validates an online-shaped availability index with empty provider notes' {
        $index=Get-MmtlHistoricalLoaderAvailability -MinecraftId '1.14.4' -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'availability-live-shape') -HttpGet $script:http
        (Test-Json -Json ($index|ConvertTo-Json -Depth 20 -Compress) -SchemaFile (Join-Path $script:repoRoot 'schemas/historical-availability.schema.json')) | Should -BeTrue
    }

    It 'reports OfflineCache aggregate status instead of fresh Available' {
        $documents=@(@{providerStatus='Available';cacheStatus='OfflineCache'},@{providerStatus='Available';cacheStatus='OfflineCache'})
        $status=& $script:providerModule {param($items) Get-MmtlHistoricalAggregateStatus -Documents $items} $documents
        $status | Should -BeExactly 'OfflineCache'
    }

    It 'preserves failed per-version candidate metadata lookups instead of returning fresh zero candidates' {
        $query=Get-MmtlLegacyFabricCandidateQuery -MinecraftId '1.14.4' -RuntimeRoot (Join-Path $TestDrive 'candidate-down') -HttpGet {throw 'candidate endpoint offline'}
        $query.providerStatus | Should -BeExactly 'Unavailable'
        $query.cacheStatus | Should -BeExactly 'Unavailable'
        @($query.candidates).Count | Should -Be 0
        $query.error | Should -Match 'candidate endpoint offline'
    }

    It 'marks availability unknown when its game candidate endpoint is unavailable' {
        $failedCandidate={param($uri,$headers,$timeout) if($uri -match '/loader/1\.14\.4$'){throw 'candidate endpoint offline'};& $script:http $uri $headers $timeout}
        $index=Get-MmtlHistoricalLoaderAvailability -MinecraftId '1.14.4' -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'index-candidate-down') -HttpGet $failedCandidate
        $legacy=$index.entries | Where-Object loaderId -eq 'LegacyFabric'
        $legacy.availability | Should -BeExactly 'Unknown'
        $legacy.providerStatus | Should -BeExactly 'Unavailable'
        $legacy.candidateCount | Should -Be 0
        @($legacy.notes | Where-Object {$_}).Count | Should -BeGreaterThan 0
    }

    It 'does not claim an Ornithe loader candidate from game support alone' {
        $index=Get-MmtlHistoricalLoaderAvailability -MinecraftId '1.8.9' -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'ornithe-game-without-loader') -HttpGet $script:http
        $ornithe=$index.entries | Where-Object loaderId -eq 'OrnitheLoader'
        $ornithe.availability | Should -BeExactly 'Unavailable'
        $ornithe.reasonCode | Should -BeExactly 'GAME_VERSION_HAS_NO_ORNITHE_LOADER'
        $ornithe.candidateCount | Should -Be 0
    }

    It 'uses the complete LiteLoader manifest to explain a version absent from its index' {
        $index=Get-MmtlHistoricalLoaderAvailability -MinecraftId '1.14.4' -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'liteloader-complete-index') -HttpGet $script:http
        $lite=$index.entries | Where-Object loaderId -eq 'LiteLoader'
        $lite.availability | Should -BeExactly 'Unavailable'
        $lite.reasonCode | Should -BeExactly 'LITELOADER_VERSION_NOT_LISTED'
        $lite.providerStatus | Should -BeExactly 'Available'
    }

    It 'preserves community Rift provenance in the historical availability index' {
        $index=Get-MmtlHistoricalLoaderAvailability -MinecraftId '1.13.2' -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'availability-rift') -Offline -HttpGet {throw 'fixture network failure'}
        $rift=$index.entries | Where-Object loaderId -eq 'Rift'
        $rift.sourceClass | Should -BeExactly 'VerifiedCommunitySource'
        $rift.source | Should -BeExactly 'https://github.com/Chocohead/Rift'
        $rift.candidateCount | Should -Be 1
    }
}
