Set-StrictMode -Version Latest

function Save-MmtlCompatibilitySourceSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,31}$')][string]$ProviderId,
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][DateTimeOffset]$RetrievedAt,
        [Parameter(Mandatory)][string]$SourceClass,
        [Parameter(Mandatory)][string]$TrustClass
    )

    $uri = $null
    if (-not [Uri]::TryCreate($SourceUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo.Length -gt 0) {
        throw 'COMPATIBILITY_SOURCE_URL_INVALID: 来源必须是无凭据的 HTTPS URL。'
    }
    if ($Bytes.Length -eq 0) { throw 'COMPATIBILITY_SOURCE_BODY_EMPTY: 不保存空响应。' }

    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    $relativePath = "$ProviderId/$hash.bin"
    $root = [IO.Path]::GetFullPath($OutputDirectory)
    $providerRoot = [IO.Path]::GetFullPath((Join-Path $root $ProviderId))
    if (-not $providerRoot.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'COMPATIBILITY_SOURCE_PATH_INVALID: Provider 目录越出快照目录。'
    }
    $path = Join-Path $providerRoot "$hash.bin"
    [IO.Directory]::CreateDirectory($providerRoot) | Out-Null
    if ([IO.File]::Exists($path)) {
        $existing = [IO.File]::ReadAllBytes($path)
        $existingHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($existing)).ToLowerInvariant()
        if ($existingHash -cne $hash) { throw 'COMPATIBILITY_SOURCE_HASH_COLLISION: 已有内容与目标摘要不匹配。' }
    } else {
        $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllBytes($temporary, $Bytes)
            [IO.File]::Move($temporary, $path)
        } finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }

    [pscustomobject][ordered]@{
        providerId = $ProviderId; sourceUrl = $uri.AbsoluteUri; sourceClass = $SourceClass; trustClass = $TrustClass
        transportSecurity = 'HTTPS'; retrievedAt = $RetrievedAt.ToUniversalTime().ToString('o')
        relativePath = $relativePath.Replace('\', '/'); byteLength = $Bytes.Length; sha256 = $hash
    }
}

function Get-MmtlCompatibilityArchiveMinecraftIds {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HtmlContent)

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($HtmlContent, '(?i)(?:\?|&)gvsn=([^&"''<>#]+)')) {
        $id = [Net.WebUtility]::HtmlDecode([Uri]::UnescapeDataString([string]$match.Groups[1].Value))
        if ([string]::IsNullOrWhiteSpace($id) -or $id -notmatch '^[A-Za-z0-9._-]{1,40}$') { continue }
        if ($seen.Add($id)) { $ids.Add($id) }
    }
    @($ids)
}

function Get-MmtlRiftMinecraftIdsFromMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JsonContent)

    try { $metadata = ConvertFrom-Json -InputObject $JsonContent -ErrorAction Stop }
    catch { throw 'RIFT_METADATA_INVALID: 官方仓库元数据不是有效 JSON。' }
    if ([string]$metadata.full_name -cne 'DimensionalDevelopment/Rift') {
        throw 'RIFT_METADATA_SOURCE_MISMATCH: 仓库元数据与固定来源不匹配。'
    }
    $description = [string]$metadata.description
    $ids = @([regex]::Matches($description, '(?i)loader and API for Minecraft\s+([0-9]+(?:\.[0-9]+){1,2})') | ForEach-Object { [string]$_.Groups[1].Value } | Sort-Object -Unique)
    if ($ids.Count -eq 0) { throw 'RIFT_METADATA_VERSION_MISSING: 官方仓库描述没有 Minecraft 版本。' }
    $ids
}

function Get-MmtlCompatibilitySourceSnapshotBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotDirectory,
        [Parameter(Mandatory)]$Record
    )

    $providerId = [string]$Record.providerId
    $relativePath = [string]$Record.relativePath
    $expectedHash = [string]$Record.sha256
    $relativeMatch = [regex]::Match($relativePath, '^' + [regex]::Escape($providerId) + '/([a-f0-9]{64})\.bin$')
    if ($providerId -notmatch '^[A-Za-z][A-Za-z0-9-]{1,31}$' -or -not $relativeMatch.Success -or $expectedHash -notmatch '^[a-f0-9]{64}$') {
        throw 'COMPATIBILITY_SOURCE_RECORD_INVALID: Provider、相对路径或 SHA-256 无效。'
    }
    if ($relativeMatch.Groups[1].Value -cne $expectedHash) { throw 'COMPATIBILITY_SOURCE_RECORD_INVALID: 路径摘要与记录摘要不一致。' }
    if ([int64]$Record.byteLength -lt 1) { throw 'COMPATIBILITY_SOURCE_RECORD_INVALID: byteLength 无效。' }

    $root = [IO.Path]::GetFullPath($SnapshotDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $root ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'COMPATIBILITY_SOURCE_PATH_INVALID: 来源快照路径越界。' }
    if (-not [IO.File]::Exists($path)) { throw 'COMPATIBILITY_SOURCE_SNAPSHOT_MISSING: 快照文件不存在。' }

    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.LongLength -ne [int64]$Record.byteLength) { throw 'COMPATIBILITY_SOURCE_LENGTH_MISMATCH: 快照长度与记录不一致。' }
    $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($actualHash -cne $expectedHash) { throw 'COMPATIBILITY_SOURCE_HASH_MISMATCH: 快照内容与记录摘要不一致。' }
    ,$bytes
}

Export-ModuleMember -Function Save-MmtlCompatibilitySourceSnapshot,Get-MmtlCompatibilityArchiveMinecraftIds,Get-MmtlRiftMinecraftIdsFromMetadata,Get-MmtlCompatibilitySourceSnapshotBytes
