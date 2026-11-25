[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MatrixManifestPath,
    [Parameter(Mandatory)][string]$JobsPath,
    [Parameter(Mandatory)][ValidateRange(1,10000)][int]$ShardCount,
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1,16)][int]$MaxParallelShards=1,
    [switch]$MemoryAwareParallelism,
    [ValidateRange(1,60)][int]$MemorySampleIntervalSeconds=5,
    [string]$UniversePath,
    [string]$FamilyManifestPath,
    [string]$LedgerPath,
    [ValidateRange(1,10)][int]$MaxAttempts=3,
    [ValidateRange(1,7200)][int]$TimeoutSeconds=1800,
    [AllowEmptyCollection()][string[]]$AllowedOwners=@(),
    [string]$BuildJavaHome,
    [string]$GoalProgressRunRoot,
    [switch]$Clean
)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'common/src/Validation/FullCompatibilityMatrixRunner.psm1') -Force
$parameters=@{MatrixManifestPath=$MatrixManifestPath;JobsPath=$JobsPath;ShardCount=$ShardCount;RuntimeRoot=$RuntimeRoot;OutputDirectory=$OutputDirectory;MaxParallelShards=$MaxParallelShards;MaxAttempts=$MaxAttempts;TimeoutSeconds=$TimeoutSeconds;AllowedOwners=$AllowedOwners;Clean=$Clean;MemoryAwareParallelism=$MemoryAwareParallelism;MemorySampleIntervalSeconds=$MemorySampleIntervalSeconds}
foreach($name in @('UniversePath','FamilyManifestPath','LedgerPath','BuildJavaHome','GoalProgressRunRoot')){if($PSBoundParameters.ContainsKey($name)){$parameters[$name]=$PSBoundParameters[$name]}}
$result=Invoke-MmtlFullCompatibilityMatrix @parameters
$json=ConvertTo-Json -InputObject $result -Depth 30 -Compress
[Console]::Out.WriteLine($json)
if($result.status -eq 'PARTIAL'){exit 1}
if($result.status -eq 'INCOMPLETE'){exit 2}
