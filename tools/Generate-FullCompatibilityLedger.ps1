[CmdletBinding()]
param(
    [string]$UniversePath,
    [string]$FamilyManifestPath,
    [string]$OutputPath,
    [DateTimeOffset]$GeneratedAt = [DateTimeOffset]::UtcNow
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $UniversePath) { $UniversePath = Join-Path $repositoryRoot 'compatibility/universe-preview.json' }
if (-not $FamilyManifestPath) { $FamilyManifestPath = Join-Path $repositoryRoot 'compatibility/families.json' }
if (-not $OutputPath) { $OutputPath = Join-Path $repositoryRoot 'compatibility/ledger-template.json' }
$modulePath = Join-Path $repositoryRoot 'common/src/Compatibility/FullCompatibilityLedger.psm1'
$schemaPath = Join-Path $repositoryRoot 'common/schemas/full-compatibility-ledger.schema.json'

if (-not (Test-Path -LiteralPath $UniversePath -PathType Leaf)) { throw "UNIVERSE_NOT_FOUND:$UniversePath" }
if (-not (Test-Path -LiteralPath $FamilyManifestPath -PathType Leaf)) { throw "FAMILY_MANIFEST_NOT_FOUND:$FamilyManifestPath" }
Import-Module $modulePath -Force
$universe = Get-Content -LiteralPath $UniversePath -Raw | ConvertFrom-Json
$familyManifest = Get-Content -LiteralPath $FamilyManifestPath -Raw | ConvertFrom-Json
$ledger = New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt $GeneratedAt -FamilyManifest $familyManifest
$validation = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $universe -FamilyManifest $familyManifest
if (-not $validation.isValid) { throw "LEDGER_CONSISTENCY_VALIDATION_FAILED:$($validation.errors -join ';')" }
$json = ConvertTo-Json -InputObject $ledger -Depth 50
if (-not (Test-Json -Json $json -SchemaFile $schemaPath)) { throw 'LEDGER_SCHEMA_VALIDATION_FAILED' }

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
Set-Content -LiteralPath $OutputPath -Value $json -Encoding utf8
[pscustomobject][ordered]@{
    outputPath = [IO.Path]::GetFullPath($OutputPath)
    targetCount = $ledger.summary.targetCount
    unknownTargetCount = $ledger.summary.unknownTargetCount
    pendingImplementationDimensionCount = $ledger.summary.pendingImplementationDimensionCount
    unassignedFamilyCount = $ledger.summary.unassignedFamilyCount
    universeHash = $ledger.universeHash
}
