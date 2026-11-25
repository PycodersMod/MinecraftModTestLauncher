[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FrozenUniversePath,
    [Parameter(Mandatory)][string]$CurrentUniversePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [DateTimeOffset]$GeneratedAt = [DateTimeOffset]::UtcNow
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$schemaPath = Join-Path $repositoryRoot 'common/schemas/compatibility-drift.schema.json'
Import-Module (Join-Path $repositoryRoot 'common/src/Compatibility/CompatibilityDrift.psm1') -Force

foreach ($path in @($FrozenUniversePath,$CurrentUniversePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "UNIVERSE_FILE_NOT_FOUND:$path" }
}
$frozen = Get-Content -LiteralPath $FrozenUniversePath -Raw | ConvertFrom-Json -ErrorAction Stop
$current = Get-Content -LiteralPath $CurrentUniversePath -Raw | ConvertFrom-Json -ErrorAction Stop
$report = Compare-MmtlCompatibilityUniverseDrift -FrozenUniverse $frozen -CurrentUniverse $current -GeneratedAt $GeneratedAt
$json = ConvertTo-Json -InputObject $report -Depth 30
if (-not (Test-Json -Json $json -SchemaFile $schemaPath)) { throw 'COMPATIBILITY_DRIFT_SCHEMA_INVALID' }
$directory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$fullPath = [IO.Path]::GetFullPath($OutputPath)
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
$temporaryPath = $fullPath + '.tmp.' + [guid]::NewGuid().ToString('N')
try {
    [IO.File]::WriteAllBytes($temporaryPath,$bytes)
    Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
} finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
$report | Select-Object schemaVersion,driftStatus,frozenTargetCount,currentTargetCount,@{n='added';e={$_.addedTargets.Count}},@{n='removed';e={$_.removedTargets.Count}},@{n='changed';e={$_.changedTargets.Count}},@{n='outputPath';e={$fullPath}}
