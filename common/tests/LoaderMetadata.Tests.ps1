BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/LoaderMetadata.psm1') -Force
}

Describe 'Loader metadata transport and cache' {
    It 'validates HTTPS and each provider host before accepting a response' {
        { Invoke-MmtlMetadataHttpGet -Uri 'http://meta.fabricmc.net/v2/versions/game' -AllowedHosts @('meta.fabricmc.net') } | Should -Throw '*METADATA_INVALID_URL*'
        $fake={param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes('redirected');ResponseUri='https://evil.invalid/payload'}}
        { Invoke-MmtlMetadataHttpGet -Uri 'https://meta.fabricmc.net/v2/versions/game' -AllowedHosts @('meta.fabricmc.net') -HttpGet $fake } | Should -Throw '*METADATA_UNTRUSTED_REDIRECT*'
    }

    It 'caches independent provider documents atomically and reuses fresh data' {
        $root=Join-Path $TestDrive 'runtime'
        $state=[pscustomobject]@{calls=0}
        $fake={param($Uri,$Headers,$TimeoutSeconds)$state.calls++;[pscustomobject]@{StatusCode=200;Headers=@{ETag='"fixture"';'Last-Modified'='Wed, 30 Sep 2026 00:00:00 GMT'};Bytes=[Text.Encoding]::UTF8.GetBytes('fabric-fixture');ResponseUri=$Uri}}.GetNewClosure()
        $first=Get-MmtlLoaderMetadataDocument -ProviderId Fabric -CacheKey 'game-versions' -Uri 'https://meta.fabricmc.net/v2/versions/game' -AllowedHosts @('meta.fabricmc.net') -RuntimeRoot $root -HttpGet $fake
        $first.cacheStatus | Should -Be 'Fresh'
        $first.content | Should -Be 'fabric-fixture'
        $second=Get-MmtlLoaderMetadataDocument -ProviderId Fabric -CacheKey 'game-versions' -Uri 'https://meta.fabricmc.net/v2/versions/game' -AllowedHosts @('meta.fabricmc.net') -RuntimeRoot $root -HttpGet {throw 'fresh cache should not request'}
        $second.cacheStatus | Should -Be 'Fresh'
        $state.calls | Should -Be 1
        $second.etag | Should -Be '"fixture"'
        $paths=Get-ChildItem (Join-Path $root 'metadata/loaders') -Recurse -File
        @($paths).Count | Should -Be 1
        $paths[0].FullName | Should -Match 'fabric'
    }

    It 'returns OfflineCache and Unavailable without crossing provider caches' {
        $root=Join-Path $TestDrive 'offline-root'
        $fake={param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes('forge');ResponseUri=$Uri}}
        $null=Get-MmtlLoaderMetadataDocument -ProviderId Forge -CacheKey 'promotions' -Uri 'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json' -AllowedHosts @('files.minecraftforge.net') -RuntimeRoot $root -HttpGet $fake
        $offline=Get-MmtlLoaderMetadataDocument -ProviderId Forge -CacheKey 'promotions' -Uri 'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json' -AllowedHosts @('files.minecraftforge.net') -RuntimeRoot $root -Offline
        $offline.cacheStatus | Should -Be 'OfflineCache'
        $offline.content | Should -Be 'forge'
        $missing=Get-MmtlLoaderMetadataDocument -ProviderId Quilt -CacheKey 'game-versions' -Uri 'https://meta.quiltmc.org/v3/versions/game' -AllowedHosts @('meta.quiltmc.org') -RuntimeRoot $root -Offline
        $missing.providerStatus | Should -Be 'Unavailable'
        $missing.cacheStatus | Should -Be 'Unavailable'
    }

    It 'serves stale cache after provider failure and honors conditional 304' {
        $root=Join-Path $TestDrive 'stale-root'
        $first=Get-MmtlLoaderMetadataDocument -ProviderId Quilt -CacheKey 'game-versions' -Uri 'https://meta.quiltmc.org/v3/versions/game' -AllowedHosts @('meta.quiltmc.org') -RuntimeRoot $root -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{ETag='"q1"'};Bytes=[Text.Encoding]::UTF8.GetBytes('quilt');ResponseUri=$Uri}}
        $stale=Get-MmtlLoaderMetadataDocument -ProviderId Quilt -CacheKey 'game-versions' -Uri 'https://meta.quiltmc.org/v3/versions/game' -AllowedHosts @('meta.quiltmc.org') -RuntimeRoot $root -MaxAge ([TimeSpan]::Zero) -HttpGet {throw 'offline'}
        $stale.cacheStatus | Should -Be 'Stale'
        $stale.content | Should -Be 'quilt'
        $seen=[pscustomobject]@{etag=$null}
        $refreshed=Get-MmtlLoaderMetadataDocument -ProviderId Quilt -CacheKey 'game-versions' -Uri 'https://meta.quiltmc.org/v3/versions/game' -AllowedHosts @('meta.quiltmc.org') -RuntimeRoot $root -MaxAge ([TimeSpan]::Zero) -HttpGet {param($Uri,$Headers,$TimeoutSeconds)$seen.etag=$Headers['If-None-Match'];[pscustomobject]@{StatusCode=304;Headers=@{};Bytes=[byte[]]@();ResponseUri=$Uri}}.GetNewClosure()
        $seen.etag | Should -Be '"q1"'
        $refreshed.cacheStatus | Should -Be 'Fresh'
        $refreshed.validatedAt | Should -Not -Be $null
        $refreshed.content | Should -Be 'quilt'
    }

    It 'parses XML with DTD and external entities disabled' {
        $safe=ConvertFrom-MmtlSafeXml -Xml '<metadata><versioning><versions><version>1.20.1-47.2.0</version></versions></versioning></metadata>'
        $safe.metadata.versioning.versions.version | Should -Be '1.20.1-47.2.0'
        $malicious='<!DOCTYPE x [<!ENTITY secret SYSTEM "file:///etc/passwd">]><metadata>&secret;</metadata>'
        { ConvertFrom-MmtlSafeXml -Xml $malicious } | Should -Throw '*XML_INVALID*'
    }
}
