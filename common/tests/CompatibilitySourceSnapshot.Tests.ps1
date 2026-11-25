BeforeAll {
    $script:modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Compatibility/SourceSnapshot.psm1'
    if (Test-Path -LiteralPath $script:modulePath) { Import-Module $script:modulePath -Force }
}

Describe 'Compatibility source snapshot evidence' {
    It 'hashes and stores the exact response bytes under a deterministic content address' {
        $bytes = [byte[]](0, 255, 13, 10, 128, 1)
        $directory = Join-Path $TestDrive 'sources'
        $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()

        $evidence = Save-MmtlCompatibilitySourceSnapshot -ProviderId 'Fabric' -SourceUrl 'https://meta.fabricmc.net/v2/versions/game' -Bytes $bytes -OutputDirectory $directory -RetrievedAt ([DateTimeOffset]'2026-10-07T00:00:00Z') -SourceClass 'ActiveOfficial' -TrustClass 'TrustedOfficial'

        $evidence.sha256 | Should -Be $expectedHash
        $evidence.relativePath | Should -Be "Fabric/$expectedHash.bin"
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $directory $evidence.relativePath))) | Should -Be ([Convert]::ToBase64String($bytes))
    }

    It 'rejects non-HTTPS source URLs before writing evidence' {
        $bytes = [Text.Encoding]::UTF8.GetBytes('untrusted')
        { Save-MmtlCompatibilitySourceSnapshot -ProviderId 'Forge' -SourceUrl 'http://example.invalid/metadata' -Bytes $bytes -OutputDirectory (Join-Path $TestDrive 'unsafe') -RetrievedAt ([DateTimeOffset]::UtcNow) -SourceClass 'Unknown' -TrustClass 'Unknown' } | Should -Throw '*HTTPS*'
        (Test-Path -LiteralPath (Join-Path $TestDrive 'unsafe')) | Should -BeFalse
    }

    It 'extracts exact legacy Minecraft IDs from archive version groups without SemVer normalization' {
        $html = '<h2>For Minecraft <a href="/mods?gvsn=b1.2_02">b1.2_02</a></h2><h2>For Minecraft <a href="/mods?gvsn=1.2.3">1.2.3</a></h2><a href="/mods?gvsn=b1.2_02">duplicate</a>'

        $ids = @(Get-MmtlCompatibilityArchiveMinecraftIds -HtmlContent $html)

        $ids | Should -HaveCount 2
        $ids | Should -Contain 'b1.2_02'
        $ids | Should -Contain '1.2.3'
    }

    It 'extracts the Rift Minecraft version from official repository API metadata' {
        $json = '{"full_name":"DimensionalDevelopment/Rift","archived":true,"description":"A lightweight mod loader and API for Minecraft 1.13"}'

        $ids = @(Get-MmtlRiftMinecraftIdsFromMetadata -JsonContent $json)

        $ids | Should -HaveCount 1
        $ids | Should -Be @('1.13')
    }

    It 'rejects Rift API metadata that does not state a supported Minecraft version' {
        $json = '{"full_name":"DimensionalDevelopment/Rift","archived":true,"description":"A lightweight mod loader"}'

        { Get-MmtlRiftMinecraftIdsFromMetadata -JsonContent $json } | Should -Throw '*RIFT_METADATA_VERSION_MISSING*'
    }

    It 'loads a cached source only when its path, byte length, and SHA-256 match the index record' {
        $bytes = [Text.Encoding]::UTF8.GetBytes('pinned-official-source')
        $directory = Join-Path $TestDrive 'cached-sources'
        $evidence = Save-MmtlCompatibilitySourceSnapshot -ProviderId 'Rift' -SourceUrl 'https://github.com/DimensionalDevelopment/Rift' -Bytes $bytes -OutputDirectory $directory -RetrievedAt ([DateTimeOffset]'2026-10-07T00:00:00Z') -SourceClass 'HistoricalOfficial' -TrustClass 'TrustedOfficial'

        $loaded = Get-MmtlCompatibilitySourceSnapshotBytes -SnapshotDirectory $directory -Record $evidence

        [Text.Encoding]::UTF8.GetString($loaded) | Should -Be 'pinned-official-source'
    }

    It 'rejects a cached source whose bytes no longer match the recorded SHA-256' {
        $bytes = [Text.Encoding]::UTF8.GetBytes('original')
        $directory = Join-Path $TestDrive 'tampered-sources'
        $evidence = Save-MmtlCompatibilitySourceSnapshot -ProviderId 'Rift' -SourceUrl 'https://github.com/DimensionalDevelopment/Rift' -Bytes $bytes -OutputDirectory $directory -RetrievedAt ([DateTimeOffset]'2026-10-07T00:00:00Z') -SourceClass 'HistoricalOfficial' -TrustClass 'TrustedOfficial'
        [IO.File]::WriteAllText((Join-Path $directory $evidence.relativePath), 'tampered')

        { Get-MmtlCompatibilitySourceSnapshotBytes -SnapshotDirectory $directory -Record $evidence } | Should -Throw '*HASH_MISMATCH*'
    }
}
