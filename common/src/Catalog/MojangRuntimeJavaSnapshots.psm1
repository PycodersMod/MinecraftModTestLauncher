Set-StrictMode -Version Latest

function Get-MmtlMojangVersionSnapshotIndexRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$SnapshotRoot
    )

    $root = [IO.Path]::GetFullPath($SnapshotRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Catalog.entries)) {
        if (-not $entry.PSObject.Properties['metadataSource'] -or -not $entry.metadataSource) { continue }
        $minecraftId = [string]$entry.minecraftId
        if ($minecraftId -notmatch '^[A-Za-z0-9._ -]{1,80}$' -or -not $seen.Add($minecraftId)) { throw "MOJANG_VERSION_CATALOG_ID_INVALID:$minecraftId" }
        $source = $entry.metadataSource
        foreach ($name in @('url','manifestSha1','sourceSha1','snapshotSha256','retrievedAt')) {
            if (-not $source.PSObject.Properties[$name]) { throw "MOJANG_VERSION_CATALOG_SOURCE_FIELD_MISSING:$minecraftId`:$name" }
        }
        $manifestSha1 = ([string]$source.manifestSha1).ToLowerInvariant()
        $sourceSha1 = ([string]$source.sourceSha1).ToLowerInvariant()
        $sha256 = ([string]$source.snapshotSha256).ToLowerInvariant()
        if ($manifestSha1 -notmatch '^[a-f0-9]{40}$' -or $sourceSha1 -cne $manifestSha1 -or $sha256 -notmatch '^[a-f0-9]{64}$') {
            throw "MOJANG_VERSION_CATALOG_HASH_INVALID:$minecraftId"
        }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$source.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'piston-meta.mojang.com' -or $uri.UserInfo.Length -gt 0) {
            throw "MOJANG_VERSION_CATALOG_URL_INVALID:$minecraftId"
        }
        $pathMatch = [regex]::Match($uri.AbsolutePath, '^/v1/packages/(?<sha1>[a-f0-9]{40})/(?<id>(?:[A-Za-z0-9._-]|%[a-fA-F0-9]{2}){1,240})\.json$')
        $urlMinecraftId = if ($pathMatch.Success) { [Uri]::UnescapeDataString($pathMatch.Groups['id'].Value) } else { $null }
        if (-not $pathMatch.Success -or $pathMatch.Groups['sha1'].Value -cne $manifestSha1 -or $urlMinecraftId -cne $minecraftId) {
            throw "MOJANG_VERSION_CATALOG_ID_MISMATCH:$minecraftId"
        }
        $retrievedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$source.retrievedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$retrievedAt)) {
            throw "MOJANG_VERSION_CATALOG_TIMESTAMP_INVALID:$minecraftId"
        }

        $relativePath = "MojangVersions/$sha256.bin"
        $path = [IO.Path]::GetFullPath((Join-Path $root ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "MOJANG_VERSION_CATALOG_PATH_INVALID:$minecraftId" }
        if (-not [IO.File]::Exists($path)) { throw "MOJANG_VERSION_CATALOG_SNAPSHOT_MISSING:$minecraftId" }
        $bytes = [IO.File]::ReadAllBytes($path)
        $actualSha1 = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $actualSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($actualSha1 -cne $manifestSha1 -or $actualSha256 -cne $sha256) { throw "MOJANG_VERSION_CATALOG_SNAPSHOT_HASH_MISMATCH:$minecraftId" }
        try { $metadata = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop } catch { throw "MOJANG_VERSION_CATALOG_SNAPSHOT_JSON_INVALID:$minecraftId" }
        if ([string]$metadata.id -cne $minecraftId) { throw "MOJANG_VERSION_METADATA_ID_MISMATCH:$minecraftId" }

        $records.Add([pscustomobject][ordered]@{
            providerId = 'MojangVersion'; minecraftId = $minecraftId; sourceUrl = $uri.AbsoluteUri
            manifestSha1 = $manifestSha1; sourceClass = 'ActiveOfficial'; trustClass = 'TrustedOfficial'
            transportSecurity = 'HTTPS'; retrievedAt = $retrievedAt.ToUniversalTime().ToString('o')
            relativePath = $relativePath; byteLength = $bytes.LongLength; sha256 = $sha256
        })
    }
    @($records.ToArray())
}

Export-ModuleMember -Function Get-MmtlMojangVersionSnapshotIndexRecords
