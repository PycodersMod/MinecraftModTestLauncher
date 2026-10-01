BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/HistoricalMetadata.psm1') -Force
    $script:fixture = '[{"version":"fixture-1"}]'
    $script:reply = {
        param($uri, $headers, $timeout)
        [pscustomobject]@{StatusCode=200;Headers=@{ETag='"fixture"'};Bytes=[Text.Encoding]::UTF8.GetBytes($script:fixture);ResponseUri=$uri}
    }
}

Describe 'Historical metadata transport and cache' {
    It 'caches allowlisted HTTPS metadata and serves offline without a network request' {
        $runtime = Join-Path $TestDrive 'runtime'
        $first = Get-MmtlHistoricalMetadataDocument -ProviderId Ornithe -CacheKey 'v2-game' -Uri 'https://meta.ornithemc.net/v2/versions/game' -AllowedHosts @('meta.ornithemc.net') -RuntimeRoot $runtime -HttpGet $script:reply
        $first.providerStatus | Should -Be 'Available'
        $first.cacheStatus | Should -Be 'Fresh'
        $offline = Get-MmtlHistoricalMetadataDocument -ProviderId Ornithe -CacheKey 'v2-game' -Uri 'https://meta.ornithemc.net/v2/versions/game' -AllowedHosts @('meta.ornithemc.net') -RuntimeRoot $runtime -Offline -HttpGet { throw 'offline request must not run' }
        $offline.cacheStatus | Should -Be 'OfflineCache'
        $offline.content | Should -Be $script:fixture
    }

    It 'rejects insecure or non-allowlisted endpoints before network access' {
        $http = Get-MmtlHistoricalMetadataDocument -ProviderId LiteLoader -CacheKey 'manifest' -Uri 'http://dl.liteloader.com/versions/versions.json' -AllowedHosts @('dl.liteloader.com') -RuntimeRoot (Join-Path $TestDrive 'http') -HttpGet $script:reply
        $http.providerStatus | Should -Be 'Unavailable'
        $http.error | Should -Match 'METADATA_INVALID_URL'
        $unlisted = Get-MmtlHistoricalMetadataDocument -ProviderId Ornithe -CacheKey 'game' -Uri 'https://evil.example.invalid/game' -AllowedHosts @('meta.ornithemc.net') -RuntimeRoot (Join-Path $TestDrive 'host') -HttpGet $script:reply
        $unlisted.providerStatus | Should -Be 'Unavailable'
    }

    It 'does not accept redirects outside the provider allowlist' {
        $redirect = { param($uri,$headers,$timeout) [pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes('[]');ResponseUri='https://evil.example.invalid/data'} }
        $result = Get-MmtlHistoricalMetadataDocument -ProviderId Ornithe -CacheKey 'redirect' -Uri 'https://meta.ornithemc.net/v2/versions/game' -AllowedHosts @('meta.ornithemc.net') -RuntimeRoot (Join-Path $TestDrive 'redirect') -HttpGet $redirect
        $result.providerStatus | Should -Be 'Unavailable'
        $result.error | Should -Match 'METADATA_UNTRUSTED_REDIRECT'
    }
}
