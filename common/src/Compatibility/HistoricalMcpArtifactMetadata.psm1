Set-StrictMode -Version Latest

$backendCatalogModulePath = Join-Path $PSScriptRoot 'HistoricalMcpBackendCatalog.psm1'
if (Test-Path -LiteralPath $backendCatalogModulePath -PathType Leaf) {
    Import-Module $backendCatalogModulePath -Force
}

function Test-MmtlHistoricalMcpArtifactMetadataCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$SnapshotRoot
    )

    $errors = [Collections.Generic.List[string]]::new()
    $schemaPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'schemas/historical-mcp-artifact-metadata.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ isValid = $false; errors = @('MCP_ARTIFACT_SCHEMA_NOT_FOUND') }
    }
    try {
        $json = ConvertTo-Json -InputObject $Catalog -Depth 30 -Compress -ErrorAction Stop
        if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
            $errors.Add('MCP_ARTIFACT_SCHEMA_VALIDATION_FAILED')
        }
    }
    catch {
        return [pscustomobject][ordered]@{ isValid = $false; errors = @('MCP_ARTIFACT_CATALOG_SERIALIZATION_FAILED') }
    }

    if ([int]$Catalog.schemaVersion -ne 1) { $errors.Add('MCP_ARTIFACT_SCHEMA_VERSION_INVALID') }
    if ([string]$Catalog.universeHash -cne 'c15c01a750f74971a1b322cd3d5c2366a2ac05394a3ad56563fde0f75764241c') { $errors.Add('MCP_ARTIFACT_UNIVERSE_HASH_INVALID') }
    if ($Catalog.automaticDownloadAllowed -ne $false) { $errors.Add('MCP_ARTIFACT_AUTOMATIC_DOWNLOAD_MUST_REMAIN_DENIED') }
    if ($Catalog.automaticExecutionAllowed -ne $false) { $errors.Add('MCP_ARTIFACT_AUTOMATIC_EXECUTION_MUST_REMAIN_DENIED') }

    try { $root = [IO.Path]::GetFullPath($SnapshotRoot) }
    catch { return [pscustomobject][ordered]@{ isValid = $false; errors = @('MCP_ARTIFACT_SNAPSHOT_ROOT_INVALID') } }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $errors.Add('MCP_ARTIFACT_SNAPSHOT_ROOT_NOT_FOUND')
    }
    $rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($entry in @($Catalog.entries)) {
        $minecraftId = [string]$entry.minecraftId
        if (-not $seen.Add($minecraftId)) { $errors.Add("MCP_ARTIFACT_DUPLICATE_MINECRAFT_ID:$minecraftId"); continue }

        $sourceUri = $null
        $expectedPath = "/BetterJSONs/jsons/$minecraftId.json"
        if (-not [Uri]::TryCreate([string]$entry.sourceUrl, [UriKind]::Absolute, [ref]$sourceUri) -or
            $sourceUri.Scheme -cne 'https' -or $sourceUri.Host -cne 'mcphackers.org' -or
            $sourceUri.AbsolutePath -cne $expectedPath -or -not [string]::IsNullOrEmpty($sourceUri.Query) -or -not [string]::IsNullOrEmpty($sourceUri.Fragment)) {
            $errors.Add("MCP_ARTIFACT_SOURCE_URL_INVALID:$minecraftId")
        }

        if ([string]::IsNullOrWhiteSpace([string]$entry.officialMetadataSha256)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.officialMetadataUrl)) { $errors.Add("MCP_ARTIFACT_OFFICIAL_SOURCE_HASH_MISSING:$minecraftId") }
            if ([string]$entry.clientComparison.status -cne 'OfficialEntryAbsent' -or [string]$entry.serverComparison.status -cne 'OfficialEntryAbsent') {
                $errors.Add("MCP_ARTIFACT_OFFICIAL_METADATA_ABSENCE_NOT_RECORDED:$minecraftId")
            }
        }
        else {
            $officialUri = $null
            if (-not [Uri]::TryCreate([string]$entry.officialMetadataUrl, [UriKind]::Absolute, [ref]$officialUri) -or
                $officialUri.Scheme -cne 'https' -or $officialUri.Host -cne 'piston-meta.mojang.com' -or
                $officialUri.AbsolutePath -cnotmatch "^/v1/packages/[a-f0-9]{40}/$([regex]::Escape($minecraftId))\.json$" -or
                -not [string]::IsNullOrEmpty($officialUri.Query) -or -not [string]::IsNullOrEmpty($officialUri.Fragment)) {
                $errors.Add("MCP_ARTIFACT_OFFICIAL_SOURCE_URL_INVALID:$minecraftId")
            }
        }

        $snapshotName = [string]$entry.snapshotPath
        if ([string]::IsNullOrWhiteSpace($snapshotName) -or
            [IO.Path]::GetFileName($snapshotName) -cne $snapshotName -or
            $snapshotName -match '[/\\:]') {
            $errors.Add("MCP_ARTIFACT_SNAPSHOT_PATH_INVALID:$minecraftId")
            continue
        }

        try { $snapshotFullPath = [IO.Path]::GetFullPath((Join-Path $root $snapshotName)) }
        catch { $errors.Add("MCP_ARTIFACT_SNAPSHOT_PATH_INVALID:$minecraftId"); continue }
        if (-not $snapshotFullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("MCP_ARTIFACT_SNAPSHOT_PATH_OUTSIDE_ROOT:$minecraftId")
            continue
        }
        if (-not (Test-Path -LiteralPath $snapshotFullPath -PathType Leaf)) {
            $errors.Add("MCP_ARTIFACT_SNAPSHOT_MISSING:$minecraftId")
            continue
        }

        $file = Get-Item -LiteralPath $snapshotFullPath -Force
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            $errors.Add("MCP_ARTIFACT_SNAPSHOT_REPARSE_POINT:$minecraftId")
            continue
        }
        if ([long]$file.Length -ne [long]$entry.snapshotByteLength) { $errors.Add("MCP_ARTIFACT_SNAPSHOT_LENGTH_MISMATCH:$minecraftId") }
        $actualHash = (Get-FileHash -LiteralPath $snapshotFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne [string]$entry.snapshotSha256) { $errors.Add("MCP_ARTIFACT_SNAPSHOT_HASH_MISMATCH:$minecraftId") }

        try {
            $metadata = Get-Content -LiteralPath $snapshotFullPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $errors.Add("MCP_ARTIFACT_SNAPSHOT_JSON_INVALID:$minecraftId")
            continue
        }
        if ([string]$metadata.id -cne $minecraftId) { $errors.Add("MCP_ARTIFACT_SNAPSHOT_ID_MISMATCH:$minecraftId") }

        foreach ($kind in @('client', 'server')) {
            $comparison = $entry."${kind}Comparison"
            $artifact = $metadata.downloads."$kind"
            $comparisonStatus = [string]$comparison.status
            $officialSha1 = [string]$comparison.officialSha1
            if ($null -eq $artifact) {
                if ($comparisonStatus -cne 'RetroEntryAbsent') { $errors.Add("MCP_ARTIFACT_RETRO_ENTRY_ABSENCE_NOT_RECORDED:$kind`:$minecraftId") }
                continue
            }
            if ([string]$artifact.sha1 -cnotmatch '^[a-fA-F0-9]{40}$') { $errors.Add("MCP_ARTIFACT_SHA1_INVALID:$kind`:$minecraftId") }
            $artifactUri = $null
            if (-not [Uri]::TryCreate([string]$artifact.url, [UriKind]::Absolute, [ref]$artifactUri) -or $artifactUri.Scheme -cne 'https') {
                $errors.Add("MCP_ARTIFACT_URL_INVALID:$kind`:$minecraftId")
            }
            elseif ($artifactUri.Host -cnotin @('launcher.mojang.com', 'vault.omniarchive.uk')) {
                $errors.Add("MCP_ARTIFACT_HOST_NOT_ALLOWED:$kind`:$minecraftId")
            }
            switch ($comparisonStatus) {
                'Match' {
                    if ([string]::IsNullOrWhiteSpace($officialSha1) -or [string]$artifact.sha1 -cne $officialSha1) { $errors.Add("MCP_ARTIFACT_MATCH_COMPARISON_INVALID:$kind`:$minecraftId") }
                }
                'Mismatch' {
                    if ([string]::IsNullOrWhiteSpace($officialSha1) -or [string]$artifact.sha1 -ceq $officialSha1) { $errors.Add("MCP_ARTIFACT_MISMATCH_COMPARISON_INVALID:$kind`:$minecraftId") }
                }
                'OfficialEntryAbsent' {
                    if (-not [string]::IsNullOrWhiteSpace($officialSha1)) { $errors.Add("MCP_ARTIFACT_OFFICIAL_ABSENCE_HAS_HASH:$kind`:$minecraftId") }
                }
            }
        }
    }

    [pscustomobject][ordered]@{ isValid = ($errors.Count -eq 0); errors = @($errors.ToArray()) }
}

function Resolve-MmtlHistoricalMcpArtifactMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MinecraftId,
        [Parameter(Mandatory)][string]$SnapshotRoot
    )

    $validation = Test-MmtlHistoricalMcpArtifactMetadataCatalog -Catalog $Catalog -SnapshotRoot $SnapshotRoot
    if (-not $validation.isValid) {
        return [pscustomobject][ordered]@{
            status = 'InvalidCatalog'; targetId = $MinecraftId; clientComparisonStatus = $null; serverComparisonStatus = $null
            automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; errors = @($validation.errors)
        }
    }

    $entry = @($Catalog.entries | Where-Object { [string]$_.minecraftId -ceq $MinecraftId } | Select-Object -First 1)
    if (-not $entry.Count) {
        return [pscustomobject][ordered]@{
            status = 'NoArtifactMetadata'; targetId = $MinecraftId; clientComparisonStatus = $null; serverComparisonStatus = $null
            automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; errors = @()
        }
    }

    $comparisons = @($entry[0].clientComparison, $entry[0].serverComparison)
    $metadataConflict = @($comparisons | Where-Object { [string]$_.status -in @('Mismatch', 'RetroEntryAbsent') }).Count -gt 0
    [pscustomobject][ordered]@{
        status = if ($metadataConflict) { 'ArtifactMetadataConflict' } else { 'MetadataReviewed' }
        targetId = $MinecraftId
        snapshotSha256 = [string]$entry[0].snapshotSha256
        clientComparisonStatus = [string]$entry[0].clientComparison.status
        serverComparisonStatus = [string]$entry[0].serverComparison.status
        evidenceRefs = @("retro-metadata-sha256:$([string]$entry[0].snapshotSha256)")
        automaticDownloadAllowed = $false
        automaticExecutionAllowed = $false
        errors = @()
    }
}

function Resolve-MmtlHistoricalMcpCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$BackendCatalog,
        [Parameter(Mandatory)]$ArtifactCatalog,
        [Parameter(Mandatory)][ValidateSet('ModLoader', 'ModLoaderMP')][string]$LoaderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MinecraftId,
        [Parameter(Mandatory)][string]$SnapshotRoot
    )

    if (-not (Get-Command Test-MmtlHistoricalMcpBackendCatalog -ErrorAction SilentlyContinue)) {
        return [pscustomobject][ordered]@{
            status = 'BackendValidatorUnavailable'; targetId = "$LoaderId@$MinecraftId"; evidenceRefs = @()
            automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; errors = @('MCP_BACKEND_VALIDATOR_UNAVAILABLE')
        }
    }
    $backendValidation = Test-MmtlHistoricalMcpBackendCatalog -Catalog $BackendCatalog
    if (-not $backendValidation.isValid) {
        return [pscustomobject][ordered]@{
            status = 'InvalidBackendCatalog'; targetId = "$LoaderId@$MinecraftId"; evidenceRefs = @()
            automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; errors = @($backendValidation.errors)
        }
    }

    $candidate = @($BackendCatalog.targetPairs | Where-Object {
        [string]$_.loaderId -ceq $LoaderId -and [string]$_.minecraftId -ceq $MinecraftId
    } | Select-Object -First 1)
    if (-not $candidate.Count) {
        return [pscustomobject][ordered]@{
            status = 'NoBackendCandidate'; targetId = "$LoaderId@$MinecraftId"; loaderId = $LoaderId; minecraftId = $MinecraftId
            evidenceRefs = @(); automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; errors = @()
        }
    }

    $metadata = Resolve-MmtlHistoricalMcpArtifactMetadata -Catalog $ArtifactCatalog -MinecraftId $MinecraftId -SnapshotRoot $SnapshotRoot
    $status = switch ([string]$metadata.status) {
        'MetadataReviewed' { 'CandidateMetadataReviewed' }
        'ArtifactMetadataConflict' { 'ArtifactMetadataConflict' }
        'NoArtifactMetadata' { 'NoArtifactMetadata' }
        default { 'InvalidArtifactCatalog' }
    }
    [pscustomobject][ordered]@{
        status = $status
        targetId = "$LoaderId@$MinecraftId"
        loaderId = $LoaderId
        minecraftId = $MinecraftId
        clientComparisonStatus = $metadata.clientComparisonStatus
        serverComparisonStatus = $metadata.serverComparisonStatus
        evidenceRefs = @($candidate[0].evidenceRefs) + @($metadata.evidenceRefs)
        automaticDownloadAllowed = $false
        automaticExecutionAllowed = $false
        errors = @($metadata.errors)
    }
}

Export-ModuleMember -Function Test-MmtlHistoricalMcpArtifactMetadataCatalog, Resolve-MmtlHistoricalMcpArtifactMetadata, Resolve-MmtlHistoricalMcpCandidate
