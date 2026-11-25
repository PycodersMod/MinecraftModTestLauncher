[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$universePath = Join-Path $RepositoryRoot 'compatibility/compatibility-universe.json'
$previewPath = Join-Path $RepositoryRoot 'compatibility/universe-preview.json'
$sourceIndexPath = Join-Path $RepositoryRoot 'compatibility/source-snapshots.json'
$candidateEvidencePath = Join-Path $RepositoryRoot 'compatibility/candidate-evidence.local.json'
$snapshotRoot = Join-Path $RepositoryRoot 'compatibility/snapshots'
$candidateLoaders = @('Fabric', 'Quilt', 'LegacyFabric', 'OrnitheLoader', 'LiteLoader')

Import-Module (Join-Path $RepositoryRoot 'common/src/Compatibility/SourceSnapshot.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Compatibility/CompatibilityCandidateCatalog.psm1') -Force

function Write-MmtlCandidateJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 50)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth $Depth), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Move($temporary, $Path, $true) } else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

foreach ($path in @($universePath, $sourceIndexPath, $candidateEvidencePath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "CANDIDATE_MERGE_INPUT_MISSING: $path" }
}
$universe = Get-Content -LiteralPath $universePath -Raw | ConvertFrom-Json -ErrorAction Stop
if ([string]$universe.auditStatus -cne 'FROZEN') { throw 'CANDIDATE_MERGE_REQUIRES_FROZEN_UNIVERSE' }
$sourceIndex = Get-Content -LiteralPath $sourceIndexPath -Raw | ConvertFrom-Json -ErrorAction Stop
$candidateEvidence = Get-Content -LiteralPath $candidateEvidencePath -Raw | ConvertFrom-Json -ErrorAction Stop
if ([int]$candidateEvidence.schemaVersion -ne 1 -or [int]$candidateEvidence.sourceCount -ne @($candidateEvidence.sources).Count) { throw 'CANDIDATE_EVIDENCE_INDEX_INVALID' }

$candidateCatalogs = [Collections.Generic.List[object]]::new()
foreach ($loaderId in $candidateLoaders) {
    $path = Join-Path $RepositoryRoot "compatibility/candidate-catalogs/$loaderId.json"
    if (-not (Test-Path -LiteralPath $path)) { throw "CANDIDATE_CATALOG_MISSING: $loaderId" }
    $candidateCatalogs.Add((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop))
}

foreach ($record in $candidateEvidence.sources) {
    $null = Get-MmtlCompatibilitySourceSnapshotBytes -SnapshotDirectory $snapshotRoot -Record $record
}
$allEvidenceByKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($record in @($sourceIndex.sources) + @($candidateEvidence.sources)) {
    $key = "$([string]$record.providerId)|$([string]$record.sourceUrl)|$([string]$record.sha256)"
    if ($allEvidenceByKey.ContainsKey($key)) {
        $prior = $allEvidenceByKey[$key]
        if ([string]$prior.relativePath -cne [string]$record.relativePath -or [int64]$prior.byteLength -ne [int64]$record.byteLength) { throw "CANDIDATE_MERGE_EVIDENCE_CONFLICT: $key" }
    } else { $allEvidenceByKey.Add($key, $record) }
}
$allSourceEvidence = @($allEvidenceByKey.Values)
$forgeMetadata = @($sourceIndex.sources | Where-Object { [string]$_.providerId -ceq 'Forge' -and [string]$_.sourceUrl -ceq 'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml' } | Select-Object -First 1)[0]
$neoModernMetadata = @($sourceIndex.sources | Where-Object { [string]$_.providerId -ceq 'NeoForge' -and [string]$_.sourceUrl -ceq 'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml' } | Select-Object -First 1)[0]
$neoTransitionMetadata = @($sourceIndex.sources | Where-Object { [string]$_.providerId -ceq 'NeoForge' -and [string]$_.sourceUrl -ceq 'https://maven.neoforged.net/releases/net/neoforged/forge/maven-metadata.xml' } | Select-Object -First 1)[0]
if (-not $forgeMetadata -or -not $neoModernMetadata -or -not $neoTransitionMetadata) { throw 'CANDIDATE_MERGE_LOADER_METADATA_MISSING' }
foreach ($target in $universe.targets) {
    if ([string]$target.loaderId -ceq 'Forge') {
        $target.candidateSourceUrl = [string]$forgeMetadata.sourceUrl
        $target.candidateSourceHash = [string]$forgeMetadata.sha256
    } elseif ([string]$target.loaderId -ceq 'NeoForge') {
        $metadata = if ([string]$target.minecraftId -ceq '1.20.1') { $neoTransitionMetadata } else { $neoModernMetadata }
        $target.candidateSourceUrl = [string]$metadata.sourceUrl
        $target.candidateSourceHash = [string]$metadata.sha256
    }
}
$mergedUniverse = Join-MmtlCompatibilityCandidateCatalogs -Universe $universe -CandidateCatalogs @($candidateCatalogs) -SourceEvidence $allSourceEvidence -RequiredLoaderIds $candidateLoaders
$schemaPath = Join-Path $RepositoryRoot 'common/schemas/compatibility-universe.schema.json'
$universeJson = ConvertTo-Json -InputObject $mergedUniverse -Depth 50
if (-not (Test-Json -Json $universeJson -SchemaFile $schemaPath)) { throw 'CANDIDATE_MERGE_UNIVERSE_SCHEMA_INVALID' }

$evidenceByKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($record in $allSourceEvidence) {
    $key = "$([string]$record.providerId)|$([string]$record.sourceUrl)|$([string]$record.sha256)"
    if ($evidenceByKey.ContainsKey($key)) {
        $prior = $evidenceByKey[$key]
        if ([string]$prior.relativePath -cne [string]$record.relativePath -or [int64]$prior.byteLength -ne [int64]$record.byteLength) { throw "CANDIDATE_MERGE_EVIDENCE_CONFLICT: $key" }
    } else { $evidenceByKey.Add($key, $record) }
}
$mergedSourceIndex = [pscustomobject][ordered]@{
    schemaVersion = [int]$sourceIndex.schemaVersion
    auditStatus = [string]$sourceIndex.auditStatus
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    sourceCount = $evidenceByKey.Count
    sources = @($evidenceByKey.Values | Sort-Object providerId, sourceUrl, sha256)
}

Write-MmtlCandidateJsonAtomic -Path $universePath -Value $mergedUniverse
Write-MmtlCandidateJsonAtomic -Path $previewPath -Value $mergedUniverse
Write-MmtlCandidateJsonAtomic -Path $sourceIndexPath -Value $mergedSourceIndex -Depth 40

[pscustomobject][ordered]@{
    auditStatus = [string]$mergedUniverse.auditStatus
    targetCount = @($mergedUniverse.targets).Count
    candidateStatusCounts = @($mergedUniverse.targets | Group-Object candidateStatus | Sort-Object Name | ForEach-Object { "$(($_.Name))=$($_.Count)" })
    candidateCatalogHash = [string]$mergedUniverse.candidateCatalogHash
    sourceEvidenceCount = $mergedSourceIndex.sourceCount
} | ConvertTo-Json -Depth 8
