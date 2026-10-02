BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/HistoricalProviders.psm1') -Force
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

    It 'identifies original Rift and labels a community port separately when present' {
        $original = Get-MmtlRiftCandidates -MinecraftId '1.13' | Where-Object originality -eq 'Original' | Select-Object -First 1
        $original.sourceClass | Should -Be 'HistoricalOfficial'
        $original.loaderId | Should -Be 'Rift'
        $original.commit | Should -Match '^[0-9a-f]{40}$'
        $port = Get-MmtlRiftCandidates -MinecraftId '1.13.2' | Select-Object -First 1
        if ($port) { $port.originality | Should -Be 'CommunityPort';$port.displayName | Should -Be 'Rift Community Port' }
    }
}
