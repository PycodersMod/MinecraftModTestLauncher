[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunRoot,
    [string]$UniversePath,
    [string]$EvidenceIndexPath,
    [string]$TargetReportsDirectory,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repositoryRoot 'common/src/Compatibility/GoalProgress.psm1'
Import-Module $modulePath -Force
$acceptancePathParameters = @('UniversePath','EvidenceIndexPath','TargetReportsDirectory') | Where-Object { $PSBoundParameters.ContainsKey($_) }
$summaryParameters = @{ RunRoot = $RunRoot }
if ($acceptancePathParameters.Count -gt 0 -and $acceptancePathParameters.Count -lt 3) {
    throw 'GOAL_ACCEPTANCE_INPUT_PATHS_INCOMPLETE'
}
if ($acceptancePathParameters.Count -eq 3) {
    if (-not (Test-Path -LiteralPath $UniversePath -PathType Leaf)) { throw 'GOAL_ACCEPTANCE_UNIVERSE_NOT_FOUND' }
    if (-not (Test-Path -LiteralPath $EvidenceIndexPath -PathType Leaf)) { throw 'GOAL_ACCEPTANCE_EVIDENCE_INDEX_NOT_FOUND' }
    if (-not (Test-Path -LiteralPath $TargetReportsDirectory -PathType Container)) { throw 'GOAL_ACCEPTANCE_REPORT_DIRECTORY_NOT_FOUND' }

    $summaryParameters.AcceptanceUniverse = Get-Content -LiteralPath $UniversePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $summaryParameters.AcceptanceEvidenceIndex = Get-Content -LiteralPath $EvidenceIndexPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $summaryParameters.TargetReports = @(
        Get-ChildItem -LiteralPath $TargetReportsDirectory -File -Filter '*.json' | Sort-Object Name | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
        }
    )
}
$summary = Get-MmtlGoalProgressSummary @summaryParameters

if ($Json) {
    ConvertTo-Json -InputObject $summary -Depth 30
    return
}

Write-Output ("Run {0}: phase={1}; attempts={2}; Build={3}; RuntimeBinding={4}; ClientLaunch={5}; MultiWindow={6}; Multiplayer={7}; Reports={8}; FullTargets={9}; wall={10}s; active={11}s; workers={12}s; repairs={13}s" -f `
    $summary.runId,$summary.phase,$summary.attemptCount,$summary.buildExactPassUnique,$summary.runtimeBindingPassUnique,
    $summary.clientLaunchPassUnique,$summary.multiWindowPassUnique,$summary.multiplayerJoinAndAssertionPassUnique,
    $summary.targetReportPassUnique,$summary.fullTargetPassUnique,$summary.goalWallElapsedSeconds,
    $summary.goalActiveElapsedSeconds,$summary.workerTestElapsedSeconds,$summary.adaptationActiveElapsedSeconds)
