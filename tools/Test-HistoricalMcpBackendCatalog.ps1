[CmdletBinding()]
param(
    [string]$UniversePath,
    [string]$CatalogPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $UniversePath) { $UniversePath = Join-Path $repositoryRoot 'compatibility/universe-preview.json' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $repositoryRoot 'compatibility/mcp-backend-catalog.json' }
$modulePath = Join-Path $repositoryRoot 'common/src/Compatibility/HistoricalMcpBackendCatalog.psm1'
Import-Module $modulePath -Force
$universe = Get-Content -LiteralPath $UniversePath -Raw | ConvertFrom-Json
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$catalogValidation = Test-MmtlHistoricalMcpBackendCatalog -Catalog $catalog
if (-not $catalogValidation.isValid) { throw "MCP_BACKEND_CATALOG_INVALID:$($catalogValidation.errors -join ';')" }
if ([string]$universe.catalogHash -cne [string]$catalog.universeHash) { throw 'MCP_BACKEND_CATALOG_UNIVERSE_HASH_MISMATCH' }

$eligibleTargets = @($universe.targets | Where-Object { $_.availability -ceq 'Available' -and $_.loaderId -cin @('ModLoader', 'ModLoaderMP') })
$validUniversePairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($target in $eligibleTargets) { $null = $validUniversePairs.Add("$([string]$target.loaderId)@$([string]$target.minecraftId)") }
$catalogPairs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($pair in @($catalog.targetPairs)) {
    $key = "$([string]$pair.loaderId)@$([string]$pair.minecraftId)"
    if (-not $validUniversePairs.Contains($key)) { throw "MCP_BACKEND_TARGET_OUTSIDE_UNIVERSE:$key" }
    $null = $catalogPairs.Add($key)
}

$loaderResults = [ordered]@{}
foreach ($loaderId in @('ModLoader', 'ModLoaderMP')) {
    $targets = @($eligibleTargets | Where-Object { $_.loaderId -ceq $loaderId })
    $missing = [Collections.Generic.List[string]]::new()
    $candidateCount = 0
    foreach ($target in $targets) {
        $result = Resolve-MmtlHistoricalMcpBackend -Catalog $catalog -LoaderId $loaderId -MinecraftId ([string]$target.minecraftId)
        if ($result.status -ceq 'CataloguedOnly') { $candidateCount++ }
        else { $missing.Add([string]$target.targetId) }
    }
    $loaderResults[$loaderId] = [pscustomobject][ordered]@{
        targetCount = $targets.Count; candidateCount = $candidateCount; missingCount = $missing.Count
        missingTargetIds = @($missing.ToArray())
    }
}

[pscustomobject][ordered]@{
    schemaVersion = 1
    universeHash = [string]$universe.catalogHash
    targetCount = @($universe.targets).Count
    historicalTargetCount = $eligibleTargets.Count
    candidatePairCount = $catalogPairs.Count
    loaders = [pscustomobject]$loaderResults
    automaticDownloadAllowed = $false
    automaticExecutionAllowed = $false
}
