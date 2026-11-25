Set-StrictMode -Version Latest

$script:expectedCatalogSha256 = 'e6c9b6c53ea88be0681a9e17660198fcc5914e8d0635f9b57426c3f3f63c6c57'

function Get-MmtlHistoricalDedicatedServerPaths {
    $repositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    return [pscustomobject]@{
        repositoryRoot = $repositoryRoot
        catalogPath = Join-Path $repositoryRoot 'compatibility/historical-dedicated-server-catalog.json'
        metadataRoot = Join-Path $repositoryRoot 'compatibility/snapshots/HistoricalDedicatedServer'
    }
}

function Test-MmtlHistoricalDedicatedServerCatalog {
    [CmdletBinding()]
    param()

    $paths = Get-MmtlHistoricalDedicatedServerPaths
    $errors = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $paths.catalogPath -PathType Leaf)) {
        return [pscustomobject]@{ isValid = $false; errors = @('HISTORICAL_SERVER_CATALOG_MISSING') }
    }
    $catalogHash = (Get-FileHash -LiteralPath $paths.catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($catalogHash -cne $script:expectedCatalogSha256) {
        return [pscustomobject]@{ isValid = $false; errors = @('HISTORICAL_SERVER_CATALOG_PIN_MISMATCH'); catalogSha256 = $catalogHash }
    }
    try {
        $catalog = Get-Content -LiteralPath $paths.catalogPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $schemaPath = Join-Path $paths.repositoryRoot 'common/schemas/historical-dedicated-server-catalog.schema.json'
        if (-not (Test-Json -Json ($catalog | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
            $errors.Add('HISTORICAL_SERVER_CATALOG_SCHEMA_INVALID')
        }
    }
    catch {
        return [pscustomobject]@{ isValid = $false; errors = @('HISTORICAL_SERVER_CATALOG_PARSE_FAILED'); catalogSha256 = $catalogHash }
    }
    if ($catalog.automaticDownloadAllowed -ne $false) { $errors.Add('HISTORICAL_SERVER_AUTOMATIC_DOWNLOAD_MUST_REMAIN_DENIED') }
    if ($catalog.automaticExecutionAllowed -ne $false) { $errors.Add('HISTORICAL_SERVER_AUTOMATIC_EXECUTION_MUST_REMAIN_DENIED') }

    foreach ($entry in @($catalog.entries)) {
        $id = [string]$entry.minecraftId
        $snapshotPath = Join-Path $paths.metadataRoot ([string]$entry.metadataSnapshotPath)
        if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
            $errors.Add("HISTORICAL_SERVER_METADATA_SNAPSHOT_MISSING:$id")
            continue
        }
        $metadataFile = Get-Item -LiteralPath $snapshotPath -Force
        $metadataSha1 = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA1).Hash.ToLowerInvariant()
        $metadataSha256 = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ([long]$metadataFile.Length -ne [long]$entry.metadataByteLength -or $metadataSha1 -cne [string]$entry.metadataSha1 -or $metadataSha256 -cne [string]$entry.metadataSha256) {
            $errors.Add("HISTORICAL_SERVER_METADATA_SNAPSHOT_PIN_MISMATCH:$id")
            continue
        }
        $metadataUri = $null
        if (-not [Uri]::TryCreate([string]$entry.metadataUrl, [UriKind]::Absolute, [ref]$metadataUri) -or
            $metadataUri.Scheme -cne 'https' -or $metadataUri.Host -cne 'piston-meta.mojang.com' -or
            $metadataUri.AbsolutePath -cne "/v1/packages/$($entry.metadataSha1)/$id.json" -or
            $metadataUri.Query -or $metadataUri.Fragment) {
            $errors.Add("HISTORICAL_SERVER_METADATA_URL_INVALID:$id")
            continue
        }
        try { $metadata = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { $errors.Add("HISTORICAL_SERVER_METADATA_PARSE_FAILED:$id"); continue }
        if ([string]$metadata.id -cne $id -or [string]$metadata.type -cne 'release' -or $null -eq $metadata.downloads.server) {
            $errors.Add("HISTORICAL_SERVER_OFFICIAL_ENTRY_MISSING:$id")
            continue
        }
        $server = $metadata.downloads.server
        $expectedArtifactUri = "https://launcher.mojang.com/v1/objects/$($entry.sha1)/server.jar"
        if ([string]$server.url -cne [string]$entry.artifactUrl -or [string]$server.url -cne $expectedArtifactUri -or
            [string]$server.sha1 -cne [string]$entry.sha1 -or [long]$server.size -ne [long]$entry.byteLength) {
            $errors.Add("HISTORICAL_SERVER_ARTIFACT_METADATA_MISMATCH:$id")
        }
        if ([string]$entry.artifactRole -ceq 'VanillaBase' -and ($entry.loaderId -or $entry.exactLoaderServerReady)) {
            $errors.Add("HISTORICAL_SERVER_VANILLA_ROLE_CONFLICT:$id")
        }
        if ([string]$entry.artifactRole -ceq 'LoaderReadyServer' -and ([string]::IsNullOrWhiteSpace([string]$entry.loaderId) -or -not [bool]$entry.exactLoaderServerReady)) {
            $errors.Add("HISTORICAL_SERVER_LOADER_READY_PIN_INCOMPLETE:$id")
        }
    }
    return [pscustomobject]@{ isValid = ($errors.Count -eq 0); errors = @($errors); catalogSha256 = $catalogHash; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
}

function Resolve-MmtlHistoricalDedicatedServerArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$MinecraftId,
        [Parameter(Mandatory)][string]$ArtifactPath
    )

    $targetParts = $TargetId -split '@', 2
    if ($targetParts.Count -ne 2 -or $targetParts[1] -cne $MinecraftId) {
        return [pscustomobject]@{ status = 'TargetIdentityMismatch'; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
    }
    $validation = Test-MmtlHistoricalDedicatedServerCatalog
    if (-not $validation.isValid) {
        return [pscustomobject]@{ status = 'CatalogInvalid'; errors = @($validation.errors); automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
    }
    $paths = Get-MmtlHistoricalDedicatedServerPaths
    $catalog = Get-Content -LiteralPath $paths.catalogPath -Raw | ConvertFrom-Json
    $entry = @($catalog.entries | Where-Object { [string]$_.minecraftId -ceq $MinecraftId }) | Select-Object -First 1
    if ($null -eq $entry) {
        return [pscustomobject]@{ status = 'OfficialServerEntryAbsent'; targetId = $TargetId; minecraftId = $MinecraftId; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
    }
    if ([string]$entry.artifactRole -ceq 'LoaderReadyServer' -and ([string]$entry.loaderId -cne $targetParts[0] -or -not [bool]$entry.exactLoaderServerReady)) {
        return [pscustomobject]@{ status = 'LoaderSpecificServerRecipeRequired'; targetId = $TargetId; minecraftId = $MinecraftId; artifactRole = [string]$entry.artifactRole; catalogSha256 = $validation.catalogSha256; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
    }
    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        return [pscustomobject]@{ status = 'LocalArtifactMissing'; targetId = $TargetId; minecraftId = $MinecraftId; catalogSha256 = $validation.catalogSha256; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
    }
    $artifact = Get-Item -LiteralPath $ArtifactPath -Force
    if (($artifact.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return [pscustomobject]@{ status = 'ArtifactPathRejected'; targetId = $TargetId; minecraftId = $MinecraftId; catalogSha256 = $validation.catalogSha256; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
    }
    $sha1 = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA1).Hash.ToLowerInvariant()
    $sha256 = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([long]$artifact.Length -ne [long]$entry.byteLength -or $sha1 -cne [string]$entry.sha1 -or $sha256 -cne [string]$entry.sha256) {
        return [pscustomobject]@{ status = 'ArtifactHashMismatch'; targetId = $TargetId; minecraftId = $MinecraftId; catalogSha256 = $validation.catalogSha256; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
    }
    $loaderReady = [string]$entry.artifactRole -ceq 'LoaderReadyServer' -and [bool]$entry.exactLoaderServerReady -and [string]$entry.loaderId -ceq $targetParts[0]
    return [pscustomobject]@{ status = $(if ($loaderReady) { 'VerifiedHistorical' } else { 'BaseArtifactVerified' }); targetId = $TargetId; minecraftId = $MinecraftId; minecraftType = [string]$entry.minecraftType; loaderId = $(if ($loaderReady) { $targetParts[0] } else { $null }); artifactRole = [string]$entry.artifactRole; sourceType = [string]$entry.sourceType; artifactUrl = [string]$entry.artifactUrl; sha1 = $sha1; sha256 = $sha256; artifactSha256 = $sha256; byteLength = [long]$artifact.Length; catalogSha256 = $validation.catalogSha256; sourceEvidenceSha256 = [string]$entry.metadataSha256; exactLoaderServerReady = $loaderReady; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false }
}

Export-ModuleMember -Function Test-MmtlHistoricalDedicatedServerCatalog, Resolve-MmtlHistoricalDedicatedServerArtifact
