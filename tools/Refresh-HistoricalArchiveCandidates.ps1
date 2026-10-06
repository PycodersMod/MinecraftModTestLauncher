[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$universePath = Join-Path $RepositoryRoot 'compatibility/universe-preview.json'
$sourceIndexPath = Join-Path $RepositoryRoot 'compatibility/source-snapshots.json'
$snapshotRoot = Join-Path $RepositoryRoot 'compatibility/snapshots'
$catalogRoot = Join-Path $RepositoryRoot 'compatibility/candidate-catalogs'
$archivePath = Join-Path $RepositoryRoot 'common/src/Catalog/data/historical-archive-records.json'

Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/HistoricalProviders.psm1') -Force

function Write-MmtlHistoricalCandidateJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 40)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth $Depth), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Move($temporary, $Path, $true) } else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

$universe = Get-Content -LiteralPath $universePath -Raw | ConvertFrom-Json -ErrorAction Stop
$sourceIndex = Get-Content -LiteralPath $sourceIndexPath -Raw | ConvertFrom-Json -ErrorAction Stop
$archiveData = Get-Content -LiteralPath $archivePath -Raw | ConvertFrom-Json -ErrorAction Stop
$summaries = [Collections.Generic.List[object]]::new()

foreach ($loaderId in @('ModLoader', 'ModLoaderMP')) {
    $source = @($sourceIndex.sources | Where-Object { [string]$_.providerId -ceq $loaderId })
    if ($source.Count -ne 1 -or [string]$source[0].sha256 -notmatch '^[a-f0-9]{64}$') { throw "HISTORICAL_CANDIDATE_SOURCE_INDEX_INVALID:$loaderId" }
    $snapshotPath = Join-Path $snapshotRoot ([string]$source[0].relativePath)
    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) { throw "HISTORICAL_CANDIDATE_SNAPSHOT_MISSING:$loaderId" }
    $actualHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne [string]$source[0].sha256) { throw "HISTORICAL_CANDIDATE_SNAPSHOT_HASH_MISMATCH:$loaderId" }

    $html = [IO.File]::ReadAllText($snapshotPath)
    $sourceIds = @([regex]::Matches($html, '(?is)<h2>For Minecraft <a href="/mods\?gvsn=([^"]+)">') | ForEach-Object { [Net.WebUtility]::HtmlDecode([string]$_.Groups[1].Value) } | Sort-Object -Unique)
    $targets = @($universe.targets | Where-Object { [string]$_.loaderId -ceq $loaderId } | Sort-Object { [string]$_.minecraftId })
    $targetIds = @($targets | ForEach-Object { [string]$_.minecraftId } | Sort-Object -Unique)
    $idDifference = @(Compare-Object -ReferenceObject $sourceIds -DifferenceObject $targetIds -CaseSensitive)
    if ($idDifference.Count -or $targets.Count -ne $sourceIds.Count) { throw "HISTORICAL_CANDIDATE_TARGET_SET_MISMATCH:$loaderId" }

    $results = [Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        $minecraftId = [string]$target.minecraftId
        $candidates = @()
        if ($loaderId -ceq 'ModLoader') { $candidates = @(Get-MmtlModLoaderArchiveCandidates -MinecraftId $minecraftId) }
        else { $candidates = @(Get-MmtlModLoaderMPArchiveCandidates -MinecraftId $minecraftId) }
        if (-not $candidates.Count) { throw "HISTORICAL_CANDIDATE_RECORD_MISSING:$loaderId@$minecraftId" }
        foreach ($candidate in $candidates) {
            if ([string]$candidate.sourceSnapshotHash -cne $actualHash -or [string]$candidate.hashProvenance -cne 'SourceDeclared' -or [bool]$candidate.hashVerifiedLocally) { throw "HISTORICAL_CANDIDATE_PROVENANCE_INVALID:$loaderId@$minecraftId" }
            if ([string]$candidate.executePermission -cne 'Denied') { throw "HISTORICAL_CANDIDATE_EXECUTION_NOT_DENIED:$loaderId@$minecraftId" }
            if ([string]$candidate.artifactTransport -ceq 'HTTPOnly' -and [string]$candidate.downloadPermission -cne 'Denied') { throw "HISTORICAL_HTTP_DOWNLOAD_NOT_DENIED:$loaderId@$minecraftId" }
        }
        $target.loaderVersionCandidates = [object[]]$candidates
        $target.candidateStatus = 'Resolved'
        $target.candidateSourceUrl = [string]$source[0].sourceUrl
        $target.candidateSourceHash = $actualHash
        $results.Add([pscustomobject][ordered]@{
            targetId = [string]$target.targetId; minecraftId = $minecraftId; candidateStatus = 'Resolved'
            candidateCount = $candidates.Count; candidates = [object[]]$candidates; sourceUrl = [string]$source[0].sourceUrl
            sourceHash = $actualHash; sourceClass = [string]$source[0].sourceClass; trustClass = [string]$source[0].trustClass
            transportSecurity = 'HTTPS'
        })
    }

    $definition = @($archiveData.records | Where-Object { [string]$_.providerId -ceq $loaderId })
    $idsWithRecords = @($definition | ForEach-Object { [string]$_.minecraftId } | Sort-Object -Unique)
    if (@(Compare-Object -ReferenceObject $sourceIds -DifferenceObject $idsWithRecords -CaseSensitive).Count) { throw "HISTORICAL_CANDIDATE_DATASET_TARGET_MISMATCH:$loaderId" }
    $catalog = [pscustomobject][ordered]@{
        schemaVersion = 1; loaderId = $loaderId; sourceUrl = [string]$source[0].sourceUrl
        sourceHash = $actualHash; targetCount = $targets.Count; resultCount = $results.Count; results = @($results)
    }
    Write-MmtlHistoricalCandidateJson -Path (Join-Path $catalogRoot "$loaderId.json") -Value $catalog -Depth 50
    $summaries.Add([pscustomobject]@{ loaderId = $loaderId; targets = $targets.Count; artifacts = @($results | ForEach-Object candidateCount | Measure-Object -Sum).Sum; sourceHash = $actualHash })
}

$candidateMaterial = @($universe.targets | Sort-Object { [string]$_.targetId } | ForEach-Object {
    [ordered]@{
        targetId = [string]$_.targetId; candidateStatus = [string]$_.candidateStatus
        loaderVersionCandidates = @($_.loaderVersionCandidates); candidateSourceUrl = $_.candidateSourceUrl
        candidateSourceHash = $_.candidateSourceHash
    }
})
$candidateJson = ConvertTo-Json -InputObject $candidateMaterial -Depth 40 -Compress
$universe.candidateCatalogHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($candidateJson))).ToLowerInvariant()
Write-MmtlHistoricalCandidateJson -Path $universePath -Value $universe -Depth 50

$ledgerPath = Join-Path $RepositoryRoot 'compatibility/ledger-template.json'
$ledgerSummary = & (Join-Path $RepositoryRoot 'tools/Generate-FullCompatibilityLedger.ps1') -UniversePath $universePath -FamilyManifestPath (Join-Path $RepositoryRoot 'compatibility/families.json') -OutputPath $ledgerPath
[pscustomobject][ordered]@{
    loaders = @($summaries); candidateCatalogHash = $universe.candidateCatalogHash
    targetCount = $ledgerSummary.targetCount; unknownTargetCount = $ledgerSummary.unknownTargetCount
    pendingImplementationDimensionCount = $ledgerSummary.pendingImplementationDimensionCount
    unassignedFamilyCount = $ledgerSummary.unassignedFamilyCount
} | ConvertTo-Json -Depth 20
