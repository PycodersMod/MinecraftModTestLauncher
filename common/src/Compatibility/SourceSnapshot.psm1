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

Export-ModuleMember -Function Save-MmtlCompatibilitySourceSnapshot,Get-MmtlCompatibilityArchiveMinecraftIds
