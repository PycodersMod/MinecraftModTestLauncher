Set-StrictMode -Version Latest

function Get-MmtlLiteLoaderArtifactPin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)]$Catalog
    )

    if ([string]$Catalog.universeHash -cne [string]$Universe.catalogHash) { throw 'LITELOADER_ARTIFACT_UNIVERSE_MISMATCH' }
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $schemaPath = Join-Path $root 'compatibility/liteloader-artifact-pins.schema.json'
    if (-not (Test-Json -Json ($Catalog | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'LITELOADER_ARTIFACT_CATALOG_SCHEMA_INVALID' }
    if ([int]$Catalog.verifiedArtifactCount -ne @($Catalog.pins).Count) { throw 'LITELOADER_ARTIFACT_PIN_COUNT_MISMATCH' }
    $targets = @($Universe.targets | Where-Object { [string]$_.targetId -ceq $TargetId -and [string]$_.availability -ceq 'Available' })
    if ($targets.Count -ne 1 -or [string]$targets[0].loaderId -cne 'LiteLoader') { throw 'LITELOADER_ARTIFACT_TARGET_NOT_EXACT' }
    $matches = @($Catalog.pins | Where-Object { [string]$_.targetId -ceq $TargetId })
    if ($matches.Count -eq 0) { throw 'LITELOADER_ARTIFACT_PIN_NOT_FOUND' }
    if ($matches.Count -ne 1) { throw 'LITELOADER_ARTIFACT_PIN_DUPLICATE' }
    $target = $targets[0]
    $pin = $matches[0]
    if ([string]$pin.minecraftId -cne [string]$target.minecraftId -or [string]$pin.sourceSha256 -cne [string]$target.sourceHash -or [string]$pin.sourceSha256 -cne [string]$Catalog.sourceSha256 -or [string]$pin.loaderVersion -cnotin @($target.loaderVersionCandidates | ForEach-Object { [string]$_ })) {
        throw 'LITELOADER_ARTIFACT_TARGET_BINDING_MISMATCH'
    }
    $uri = $null
    if (-not [Uri]::TryCreate([string]$pin.artifactUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cnotin @('dl.liteloader.com', 'repo.mumfrey.com') -or $uri.UserInfo.Length -gt 0 -or $uri.Query -or $uri.Fragment) {
        throw 'LITELOADER_ARTIFACT_URL_UNTRUSTED'
    }
    return $pin
}

function Test-MmtlLiteLoaderArtifactFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Pin)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'LITELOADER_ARTIFACT_FILE_MISSING' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) { throw 'LITELOADER_ARTIFACT_FILE_REPARSE' }
    if ([long]$item.Length -ne [long]$Pin.bytes) { throw 'LITELOADER_ARTIFACT_LENGTH_MISMATCH' }
    $sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -cne ([string]$Pin.sha256).ToLowerInvariant()) { throw 'LITELOADER_ARTIFACT_SHA256_MISMATCH' }
    $md5 = (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToLowerInvariant()
    if ($md5 -cne ([string]$Pin.officialMd5).ToLowerInvariant()) { throw 'LITELOADER_ARTIFACT_OFFICIAL_MD5_MISMATCH' }
    return $true
}

Export-ModuleMember -Function Get-MmtlLiteLoaderArtifactPin, Test-MmtlLiteLoaderArtifactFile
