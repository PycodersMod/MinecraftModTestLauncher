[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MatrixManifestPath,
    [Parameter(Mandatory)][string]$JobsPath,
    [Parameter(Mandatory)][ValidateRange(0,9999)][int]$ShardIndex,
    [Parameter(Mandatory)][ValidateRange(1,10000)][int]$ShardCount,
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [string]$UniversePath,
    [string]$FamilyManifestPath,
    [string]$LedgerPath,
    [string]$OutputPath,
    [ValidateRange(1,10)][int]$MaxAttempts=3,
    [ValidateRange(1,7200)][int]$TimeoutSeconds=1800,
    [AllowEmptyCollection()][string[]]$AllowedOwners=@(),
    [string]$BuildJavaHome,
    [string]$GoalProgressRunRoot,
    [switch]$Clean
)

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repositoryRoot=Split-Path -Parent $PSScriptRoot
if(-not $UniversePath){$UniversePath=Join-Path $repositoryRoot 'compatibility/universe-preview.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $repositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $repositoryRoot 'compatibility/ledger-template.json'}

function Read-MmtlMatrixInput {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw "MATRIX_INPUT_NOT_FOUND:$full"}
    $item=Get-Item -LiteralPath $full -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'MATRIX_INPUT_REPARSE_FILE'}
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($full)) -ErrorAction Stop
}

$universe=Read-MmtlMatrixInput -Path $UniversePath
$families=Read-MmtlMatrixInput -Path $FamilyManifestPath
$ledger=Read-MmtlMatrixInput -Path $LedgerPath
$manifest=Read-MmtlMatrixInput -Path $MatrixManifestPath
$jobsDocument=Read-MmtlMatrixInput -Path $JobsPath
$jobsSchema=Join-Path $repositoryRoot 'common/schemas/validation-matrix-job-manifest.schema.json'
$jobsJson=ConvertTo-Json -InputObject $jobsDocument -Depth 40
if(-not(Test-Json -Json $jobsJson -SchemaFile $jobsSchema -ErrorAction SilentlyContinue)){throw 'MATRIX_JOB_MANIFEST_SCHEMA_INVALID'}
if([string]$jobsDocument.manifestHash -cne [string]$manifest.manifestHash){throw 'MATRIX_JOB_MANIFEST_HASH_MISMATCH'}
if($ShardIndex -ge $ShardCount){throw 'SHARD_INDEX_INVALID:must be within shard count'}

Import-Module (Join-Path $repositoryRoot 'common/src/Validation/ValidationMatrixChunks.psm1') -Force
$shard=Get-MmtlValidationMatrixShard -Manifest $manifest -Ledger $ledger -Universe $universe -FamilyManifest $families -ShardIndex $ShardIndex -ShardCount $ShardCount
$wanted=@{};foreach($chunk in $shard.chunks){foreach($target in $chunk.targets){$wanted[[string]$target.targetId]=$target}}
$jobsById=@{}
$jobsRoot=Split-Path -Parent ([IO.Path]::GetFullPath($JobsPath))
foreach($entry in $jobsDocument.jobs){
    $id=[string]$entry.targetId
    if($jobsById.ContainsKey($id)){throw "MATRIX_JOB_DUPLICATE:$id"}
    if(-not $wanted.ContainsKey($id)){continue}
    if([string]$entry.target.targetId -cne $id -or [string]$entry.cacheIdentity.targetId -cne $id){throw "MATRIX_JOB_TARGET_MISMATCH:$id"}
    $path=[string]$entry.projectPath
    if(-not [IO.Path]::IsPathRooted($path)){$path=Join-Path $jobsRoot $path}
    $path=[IO.Path]::GetFullPath($path)
    if(-not(Test-Path -LiteralPath $path -PathType Container)){throw "MATRIX_PROJECT_PATH_NOT_FOUND:$id"}
    if(([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "MATRIX_PROJECT_ROOT_REPARSE:$id"}
    $project=[pscustomobject][ordered]@{
        Root=$path;MinecraftVersion=[string]$entry.project.minecraftVersion;Loader=[string]$entry.project.loader
        LoaderVersion=[string]$entry.project.loaderVersion;Wrapper=[string]$entry.project.wrapper
        JavaMajor=if($entry.project.PSObject.Properties['javaMajor']){[int]$entry.project.javaMajor}else{$null}
        Toolchain=if($entry.project.PSObject.Properties['toolchain']){[string]$entry.project.toolchain}else{$null}
        ToolchainVersion=if($entry.project.PSObject.Properties['toolchainVersion']){[string]$entry.project.toolchainVersion}else{$null}
        BuildSystem=if($entry.project.PSObject.Properties['buildSystem']){[pscustomobject]@{id=[string]$entry.project.buildSystem;version=if($entry.project.PSObject.Properties['buildSystemVersion']){[string]$entry.project.buildSystemVersion}else{$null}}}else{$null}
    }
    $jobsById[$id]=[pscustomobject]@{targetId=$id;target=$entry.target;project=$project;cacheIdentity=$entry.cacheIdentity}
}
if($jobsById.Count -ne [int]$shard.targetCount){throw 'MATRIX_JOB_SET_INCOMPLETE'}
$jobs=[object[]]@($shard.chunks|ForEach-Object{$_.targets}|ForEach-Object{$jobsById[[string]$_.targetId]})

Import-Module (Join-Path $repositoryRoot 'common/src/Platform/Platform.psm1') -Force -Global
$platformRoot=$null
if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){$platformRoot='windows'}
elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){$platformRoot='linux'}
elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$platformRoot='macos'}
else{throw 'MATRIX_PLATFORM_UNSUPPORTED'}
$providerName=switch($platformRoot){'windows'{'WindowsPlatformProvider.psm1'}'linux'{'LinuxPlatformProvider.psm1'}'macos'{'MacOSPlatformProvider.psm1'}}
$providerPath=Join-Path $repositoryRoot "$platformRoot/src/$providerName"
Import-Module $providerPath -Force
$registerCommand=switch($platformRoot){'windows'{'Register-MmtlWindowsPlatform'}'linux'{'Register-MmtlLinuxPlatform'}'macos'{'Register-MmtlMacOSPlatform'}}
& $registerCommand -RepositoryRoot $repositoryRoot
Import-Module (Join-Path $repositoryRoot 'common/src/Platform/Platform.psm1') -Force
Import-Module (Join-Path $repositoryRoot 'common/src/Validation/ValidationMatrixShardRunner.psm1') -Force
$result=Invoke-MmtlValidationMatrixShard -Shard $shard -Jobs $jobs -RuntimeRoot $RuntimeRoot -MaxAttempts $MaxAttempts -AllowedOwners $AllowedOwners -BuildJavaHome $BuildJavaHome -TimeoutSeconds $TimeoutSeconds -GoalProgressRunRoot $GoalProgressRunRoot -Clean:$Clean
$summary=[pscustomobject][ordered]@{
    schemaVersion=1;status=$result.status;universeHash=$result.universeHash;manifestHash=$result.manifestHash
    shardIndex=$result.shardIndex;shardCount=$result.shardCount;targetCount=$result.targetCount
    statusCounts=$result.statusCounts;results=$result.results
    statePath=[string]$result.runState.statePath
}
$json=ConvertTo-Json -InputObject $summary -Depth 20
if($OutputPath){
    $output=[IO.Path]::GetFullPath($OutputPath);$directory=Split-Path -Parent $output
    if(-not(Test-Path -LiteralPath $directory -PathType Container)){[void][IO.Directory]::CreateDirectory($directory)}
    $temporary=$output+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{[IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false));[IO.File]::Move($temporary,$output,$true)}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}else{[Console]::Out.WriteLine($json)}
if($result.status -eq 'PARTIAL'){exit 1}
if($result.status -eq 'INCOMPLETE'){exit 2}
