[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('ModLoader','ModLoaderMP')][string]$LoaderId,
    [Parameter(Mandatory)][string]$MinecraftId,
    [Parameter(Mandatory)][string]$BaseClientJar,
    [Parameter(Mandatory)][string]$OverlayArchive,
    [Parameter(Mandatory)][string]$OutputPath,
    [Parameter(Mandatory)][string]$EvidencePath,
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$candidatePath = Join-Path $RepositoryRoot "compatibility/candidate-catalogs/$LoaderId.json"
$metadataPath = Join-Path $RepositoryRoot 'compatibility/historical-mcp-artifact-metadata-catalog.json'
$modulePath = Join-Path $RepositoryRoot 'common/src/Compatibility/HistoricalJarOverlay.psm1'
foreach ($path in @($candidatePath, $metadataPath, $modulePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "REQUIRED_INPUT_NOT_FOUND: $path" }
}
$candidateCatalog = Get-Content -LiteralPath $candidatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$metadataCatalog = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
Import-Module $modulePath -Force
New-MmtlHistoricalJarOverlay -LoaderId $LoaderId -MinecraftId $MinecraftId -BaseClientJar $BaseClientJar -OverlayArchive $OverlayArchive -OutputPath $OutputPath -EvidencePath $EvidencePath -CandidateCatalog $candidateCatalog -MetadataCatalog $metadataCatalog
