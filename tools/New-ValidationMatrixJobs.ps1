[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MatrixManifestPath,
    [Parameter(Mandatory)][string]$ProvisioningManifestPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$UniversePath,
    [string]$FamilyManifestPath,
    [string]$LedgerPath,
    [string]$FamilyBatchSnapshotPath,
    [string]$BatchRecipesPath
)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
if(-not $UniversePath){$UniversePath=Join-Path $repositoryRoot 'compatibility/universe-preview.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $repositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $repositoryRoot 'compatibility/ledger-template.json'}
$hasBatchPath=-not [string]::IsNullOrWhiteSpace($FamilyBatchSnapshotPath)
$hasRecipesPath=-not [string]::IsNullOrWhiteSpace($BatchRecipesPath)
if($hasBatchPath -ne $hasRecipesPath){throw 'FAMILY_BATCH_INPUT_PATHS_MUST_BE_PAIRED'}
$optionalInputPaths=@();if($hasBatchPath){$optionalInputPaths=@($FamilyBatchSnapshotPath,$BatchRecipesPath)}
$inputPaths=@(@($MatrixManifestPath,$ProvisioningManifestPath,$UniversePath,$FamilyManifestPath,$LedgerPath)+$optionalInputPaths|ForEach-Object{[IO.Path]::GetFullPath($_)})
foreach($inputPath in $inputPaths){
    if(-not(Test-Path -LiteralPath $inputPath -PathType Leaf)){throw "MATRIX_INPUT_NOT_FOUND:$inputPath"}
    if(([IO.File]::GetAttributes($inputPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'MATRIX_INPUT_REPARSE_FILE'}
}
$outputFull=[IO.Path]::GetFullPath($OutputPath)
if($inputPaths -contains $outputFull){throw 'MATRIX_OUTPUT_OVERWRITES_INPUT'}
$matrix=Get-Content -LiteralPath $inputPaths[0] -Raw|ConvertFrom-Json -ErrorAction Stop
$provisioning=Get-Content -LiteralPath $inputPaths[1] -Raw|ConvertFrom-Json -ErrorAction Stop
$universe=Get-Content -LiteralPath $inputPaths[2] -Raw|ConvertFrom-Json -ErrorAction Stop
$families=Get-Content -LiteralPath $inputPaths[3] -Raw|ConvertFrom-Json -ErrorAction Stop
$ledger=Get-Content -LiteralPath $inputPaths[4] -Raw|ConvertFrom-Json -ErrorAction Stop
$batch=$null;$batchRecipes=$null
if($hasBatchPath){
    $batch=Get-Content -LiteralPath ([IO.Path]::GetFullPath($FamilyBatchSnapshotPath)) -Raw|ConvertFrom-Json -ErrorAction Stop
    $batchRecipes=@(Get-Content -LiteralPath ([IO.Path]::GetFullPath($BatchRecipesPath)) -Raw|ConvertFrom-Json -ErrorAction Stop)
}
Import-Module (Join-Path $repositoryRoot 'common/src/Validation/ValidationMatrixJobs.psm1') -Force
$jobParameters=@{MatrixManifest=$matrix;Universe=$universe;Ledger=$ledger;FamilyManifest=$families;ProvisioningManifest=$provisioning;ProvisioningRoot=(Split-Path -Parent $inputPaths[1])}
if($hasBatchPath){$jobParameters.FamilyBatchSnapshot=$batch;$jobParameters.BatchRecipes=$batchRecipes}
$result=New-MmtlValidationMatrixJobs @jobParameters
$resultJson=ConvertTo-Json -InputObject $result -Depth 40
$jobsSchema=Join-Path $repositoryRoot 'common/schemas/validation-matrix-job-manifest.schema.json'
if(-not(Test-Json -Json $resultJson -SchemaFile $jobsSchema -ErrorAction SilentlyContinue)){throw 'MATRIX_JOBS_OUTPUT_SCHEMA_INVALID'}
$outputDirectory=Split-Path -Parent $outputFull
if(-not $outputDirectory){throw 'MATRIX_OUTPUT_DIRECTORY_REQUIRED'}
[void][IO.Directory]::CreateDirectory($outputDirectory)
$temporary=$outputFull+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
try{
    [IO.File]::WriteAllText($temporary,$resultJson,[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$outputFull,$true)
}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
[Console]::Out.WriteLine((ConvertTo-Json -InputObject ([pscustomobject][ordered]@{status='GENERATED';targetCount=$result.jobs.Count;manifestHash=$result.manifestHash}) -Compress))
