[CmdletBinding()]
param(
    [string]$UniversePath,
    [string]$FamilyManifestPath,
    [string]$LedgerPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1, 100)][int]$ChunkSize = 25
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $UniversePath) { $UniversePath = Join-Path $repositoryRoot 'compatibility/universe-preview.json' }
if (-not $FamilyManifestPath) { $FamilyManifestPath = Join-Path $repositoryRoot 'compatibility/families.json' }
if (-not $LedgerPath) { $LedgerPath = Join-Path $repositoryRoot 'compatibility/ledger-template.json' }
foreach ($inputPath in @($UniversePath, $FamilyManifestPath, $LedgerPath)) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw "VALIDATION_MATRIX_INPUT_NOT_FOUND:$inputPath" }
}

Import-Module (Join-Path $repositoryRoot 'common/src/Validation/ValidationMatrixChunks.psm1') -Force
$universe = Get-Content -LiteralPath $UniversePath -Raw | ConvertFrom-Json -ErrorAction Stop
$families = Get-Content -LiteralPath $FamilyManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$ledger = Get-Content -LiteralPath $LedgerPath -Raw | ConvertFrom-Json -ErrorAction Stop
$manifest = New-MmtlValidationMatrixChunks -Ledger $ledger -Universe $universe -FamilyManifest $families -ChunkSize $ChunkSize
$directory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$json = ConvertTo-Json -InputObject $manifest -Depth 30
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json, [Text.UTF8Encoding]::new($false))
[pscustomobject][ordered]@{
    universeHash = [string]$manifest.universeHash
    manifestHash = [string]$manifest.manifestHash
    targetCount = [int]$manifest.targetCount
    chunkSize = [int]$manifest.chunkSize
    chunkCount = [int]$manifest.chunkCount
}
