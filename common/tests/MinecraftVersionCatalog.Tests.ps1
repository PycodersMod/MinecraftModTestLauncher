BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/MinecraftVersionCatalog.psm1') -Force
    $script:now=[DateTimeOffset]::UtcNow
    $script:manifest=[pscustomobject]@{
        latest=[pscustomobject]@{release='26.3';snapshot='26.4-snapshot-2'}
        versions=@(
            [pscustomobject]@{id='26.3';type='release';url='https://piston-meta.mojang.com/v1/26.3.json';time='2026-09-15T10:00:00Z';releaseTime='2026-09-15T10:00:00Z';sha1=('a'*40);complianceLevel=1},
            [pscustomobject]@{id='26.4-snapshot-2';type='snapshot';url='https://piston-meta.mojang.com/v1/snap.json';time='2026-09-16T10:00:00Z';releaseTime='2026-09-16T10:00:00Z';sha1=('b'*40)},
            [pscustomobject]@{id='1.20.5';type='release';url='https://piston-meta.mojang.com/v1/1.20.5.json';time='2024-04-23T10:00:00Z';releaseTime='2024-04-23T10:00:00Z';sha1=('c'*40)},
            [pscustomobject]@{id='1.0';type='release';url='https://piston-meta.mojang.com/v1/1.0.json';time='2022-03-10T10:00:00Z';releaseTime='2011-11-18T06:00:00Z';sha1=('d'*40)},
            [pscustomobject]@{id='rd-132211';type='old_alpha';url='https://piston-meta.mojang.com/v1/old.json';time='2010-01-01T00:00:00Z';releaseTime='2010-01-01T00:00:00Z';sha1=('e'*40)}
        )
    }
}

Describe 'Mojang Minecraft Version Catalog' {
    It 'uses canonical string IDs and filters the 1.0-to-CurrentStable release window in source order' {
        $catalog=ConvertTo-MmtlMinecraftVersionCatalog -Manifest $script:manifest -FetchedAt $script:now
        $catalog.latestRelease | Should -Be '26.3'
        $catalog.latestSnapshot | Should -Be '26.4-snapshot-2'
        $catalog.minimumReleaseId | Should -Be '1.0'
        @($catalog.entries.id) | Should -Be @('26.3','1.20.5','1.0')
        @($catalog.entries | Where-Object type -ne 'release').Count | Should -Be 0
        $catalog.entries[0].id | Should -BeOfType ([string])
        $catalog.entries[0].catalogStatus | Should -Be 'CATALOGUED'
    }

    It 'rejects duplicate IDs, invalid dates, untrusted hosts, malformed hash and absent 1.0 anchor' {
        $duplicate=$script:manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $duplicate.versions=@($duplicate.versions)+@($duplicate.versions[0])
        { ConvertTo-MmtlMinecraftVersionCatalog -Manifest $duplicate } | Should -Throw '*MANIFEST_SCHEMA_ERROR*'
        $badDate=$script:manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $badDate.versions[0].releaseTime='not-a-date'
        { ConvertTo-MmtlMinecraftVersionCatalog -Manifest $badDate } | Should -Throw '*MANIFEST_SCHEMA_ERROR*'
        $badUrl=$script:manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $badUrl.versions[0].url='http://evil.invalid/metadata.json'
        { ConvertTo-MmtlMinecraftVersionCatalog -Manifest $badUrl } | Should -Throw '*MANIFEST_SCHEMA_ERROR*'
        $badHash=$script:manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $badHash.versions[0].sha1='xyz'
        { ConvertTo-MmtlMinecraftVersionCatalog -Manifest $badHash } | Should -Throw '*MANIFEST_SCHEMA_ERROR*'
        $noAnchor=$script:manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $noAnchor.versions=@($noAnchor.versions | Where-Object id -ne '1.0')
        { ConvertTo-MmtlMinecraftVersionCatalog -Manifest $noAnchor } | Should -Throw '*MINIMUM_RELEASE_NOT_FOUND*'
    }

    It 'reports explicit schema errors for missing root and entry fields' {
        $missingLatest=$script:manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $missingLatest.PSObject.Properties.Remove('latest')
        { ConvertTo-MmtlMinecraftVersionCatalog -Manifest $missingLatest } | Should -Throw '*MANIFEST_SCHEMA_ERROR*'
        $missingEntryField=$script:manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $missingEntryField.versions[0].PSObject.Properties.Remove('releaseTime')
        { ConvertTo-MmtlMinecraftVersionCatalog -Manifest $missingEntryField } | Should -Throw '*MANIFEST_SCHEMA_ERROR*'
    }

    It 'fetches online on cache miss, writes atomically, and reuses fresh cache' {
        $root=Join-Path $TestDrive 'runtime'
        $state=[pscustomobject]@{calls=0}
        $json=$script:manifest|ConvertTo-Json -Depth 20 -Compress
        $fake={param($Uri,$Headers,$TimeoutSeconds)$state.calls++;[pscustomobject]@{StatusCode=200;Headers=@{'Last-Modified'='Wed, 30 Sep 2026 00:00:00 GMT';ETag='"fixture"'};Bytes=[Text.Encoding]::UTF8.GetBytes($json)}}.GetNewClosure()
        $first=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet $fake
        $first.cacheStatus | Should -Be 'Fresh'
        $first.entries[0].provenance[0].cacheStatus | Should -Be 'Fresh'
        $state.calls | Should -Be 1
        $second=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet {throw 'fresh cache should not fetch'}
        $second.cacheStatus | Should -Be 'Fresh'
        $second.entries[0].provenance[0].cacheStatus | Should -Be 'Cached'
        (Join-Path $root 'metadata/mojang/normalized/version-catalog.json') | Should -Exist
        @(Get-ChildItem (Join-Path $root 'metadata/mojang') -Recurse -Filter '*.tmp').Count | Should -Be 0
    }

    It 'uses conditional headers for stale cache and falls back as Stale if refresh fails' {
        $root=Join-Path $TestDrive 'stale-runtime'
        $json=$script:manifest|ConvertTo-Json -Depth 20 -Compress
        $first=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{ETag='"v1"';'Last-Modified'='Wed, 30 Sep 2026 00:00:00 GMT'};Bytes=[Text.Encoding]::UTF8.GetBytes($json)}} -MaxAge ([TimeSpan]::Zero)
        $state=[pscustomobject]@{headers=$null}
        $stale=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -MaxAge ([TimeSpan]::Zero) -HttpGet {param($Uri,$Headers,$TimeoutSeconds)$state.headers=$Headers;throw 'network down'}.GetNewClosure()
        $stale.cacheStatus | Should -Be 'Stale'
        $stale.entries[0].provenance[0].cacheStatus | Should -Be 'Stale'
        $state.headers['If-None-Match'] | Should -Be '"v1"'
        $state.headers['If-Modified-Since'] | Should -Be 'Wed, 30 Sep 2026 00:00:00 GMT'
    }

    It 'accepts HTTP 304 and preserves the cached official metadata' {
        $root=Join-Path $TestDrive 'not-modified-runtime'
        $json=$script:manifest|ConvertTo-Json -Depth 20 -Compress
        Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{ETag='"stable"';'Last-Modified'='Wed, 30 Sep 2026 00:00:00 GMT'};Bytes=[Text.Encoding]::UTF8.GetBytes($json)}}.GetNewClosure() | Out-Null
        $state=[pscustomobject]@{headers=$null}
        $result=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -MaxAge ([TimeSpan]::Zero) -HttpGet {param($Uri,$Headers,$TimeoutSeconds)$state.headers=$Headers;[pscustomobject]@{StatusCode=304;Headers=@{};Bytes=[byte[]]@()}}.GetNewClosure()
        $result.latestRelease | Should -Be '26.3'
        $state.headers['If-None-Match'] | Should -Be '"stable"'
        $state.headers['If-Modified-Since'] | Should -Be 'Wed, 30 Sep 2026 00:00:00 GMT'
        Get-Content -LiteralPath (Join-Path $root 'metadata/mojang/normalized/version-catalog.json') -Raw | ConvertFrom-Json | Should -Not -BeNullOrEmpty
    }

    It 'does not silently fall back after forced refresh fails' {
        $root=Join-Path $TestDrive 'forced-refresh-runtime'
        $json=$script:manifest|ConvertTo-Json -Depth 20 -Compress
        Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($json)}}.GetNewClosure() | Out-Null
        { Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -ForceRefresh -HttpGet {throw 'upstream is unavailable'} } | Should -Throw '*MANIFEST_NETWORK_ERROR*'
    }

    It 'offline reads cache without calling HTTP and clearly fails when cache is absent' {
        $root=Join-Path $TestDrive 'offline-runtime'
        $json=$script:manifest|ConvertTo-Json -Depth 20 -Compress
        Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($json)}} | Out-Null
        $offline=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -Offline -HttpGet {throw 'must not call'}
        $offline.cacheStatus | Should -Be 'OfflineCache'
        $offline.entries[0].provenance[0].cacheStatus | Should -Be 'OfflineCache'
        { Get-MmtlMinecraftVersionCatalog -RuntimeRoot (Join-Path $TestDrive 'empty') -Offline -HttpGet {throw 'must not call'} } | Should -Throw '*CACHE_UNAVAILABLE*'
    }

    It 'rejects corrupt cache instead of trusting it' {
        $root=Join-Path $TestDrive 'corrupt-runtime'
        $json=$script:manifest|ConvertTo-Json -Depth 20 -Compress
        Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($json)}} | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'metadata/mojang/normalized/version-catalog.json') -Value '{broken'
        { Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -Offline } | Should -Throw '*CACHE_CORRUPT*'
    }

    It 'replaces a corrupt online cache only after successfully fetching and verifying a new manifest' {
        $root=Join-Path $TestDrive 'repair-cache-runtime'
        $json=$script:manifest|ConvertTo-Json -Depth 20 -Compress
        $fake={param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($json)}}.GetNewClosure()
        Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet $fake | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'metadata/mojang/normalized/version-catalog.json') -Value '{broken'
        $repaired=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -HttpGet $fake
        $repaired.cacheStatus | Should -Be 'Fresh'
        $repaired.latestRelease | Should -Be '26.3'
        Get-MmtlMinecraftVersionCatalog -RuntimeRoot $root -Offline | Should -Not -BeNullOrEmpty
    }

    It 'verifies lazy version metadata SHA-1 before caching and re-verifies cache reads' {
        $metadata=[ordered]@{id='1.20.5';javaVersion=@{component='java-runtime-delta';majorVersion=21}}
        $raw=$metadata|ConvertTo-Json -Compress
        $bytes=[Text.Encoding]::UTF8.GetBytes($raw)
        $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $entry=[pscustomobject]@{id='1.20.5';metadataUrl='https://piston-meta.mojang.com/v1/1.20.5.json';metadataSha1=$sha1}
        $root=Join-Path $TestDrive 'metadata-runtime'
        $fake={param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=$bytes;ResponseUri=$Uri}}.GetNewClosure()
        $result=Get-MmtlMinecraftVersionMetadata -CatalogEntry $entry -RuntimeRoot $root -HttpGet $fake
        $result.hashStatus | Should -Be 'SHA1_VERIFIED'
        $result.metadata.javaVersion.majorVersion | Should -Be 21
        $cached=Get-MmtlMinecraftVersionMetadata -CatalogEntry $entry -RuntimeRoot $root -Offline
        $cached.actualSha1 | Should -Be $sha1
        $wrong=[pscustomobject]@{id='1.20.5';metadataUrl='https://piston-meta.mojang.com/v1/1.20.5.json';metadataSha1=('f'*40)}
        { Get-MmtlMinecraftVersionMetadata -CatalogEntry $wrong -RuntimeRoot (Join-Path $TestDrive 'bad-hash') -HttpGet $fake } | Should -Throw '*METADATA_HASH_MISMATCH*'
    }

    It 'rejects malformed metadata JSON, a mismatched version ID, and an unsafe URL' {
        $badUrl=[pscustomobject]@{id='1.20.5';metadataUrl='https://evil.invalid/version.json';metadataSha1=('a'*40)}
        { Get-MmtlMinecraftVersionMetadata -CatalogEntry $badUrl -RuntimeRoot (Join-Path $TestDrive 'unsafe') -HttpGet {throw 'must reject before request'} } | Should -Throw '*METADATA_INVALID_URL*'
        $malformed=[Convert]::FromBase64String('e2Jyb2tlbg==')
        $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($malformed)).ToLowerInvariant()
        $entry=[pscustomobject]@{id='1.20.5';metadataUrl='https://piston-meta.mojang.com/v1/1.20.5.json';metadataSha1=$sha1}
        $malformedFake={param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Convert]::FromBase64String('e2Jyb2tlbg==');ResponseUri=$Uri}}
        { Get-MmtlMinecraftVersionMetadata -CatalogEntry $entry -RuntimeRoot (Join-Path $TestDrive 'malformed') -HttpGet $malformedFake } | Should -Throw '*METADATA_INVALID_JSON*'
        $wrongRaw='{"id":"1.20.4"}';$wrongBytes=[Text.Encoding]::UTF8.GetBytes($wrongRaw);$wrongSha=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]$wrongBytes)).ToLowerInvariant()
        $entry.metadataSha1=$wrongSha
        $wrongFake={param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes('{"id":"1.20.4"}');ResponseUri=$Uri}}
        { Get-MmtlMinecraftVersionMetadata -CatalogEntry $entry -RuntimeRoot (Join-Path $TestDrive 'wrong-id') -HttpGet $wrongFake } | Should -Throw '*METADATA_VERSION_ID_MISMATCH*'
    }
}
