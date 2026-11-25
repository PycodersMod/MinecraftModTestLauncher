[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$ExecutionPlanPath,
    [Parameter(Mandatory)][string]$UniversePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ObservedAt
)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
$executionPlanModule=Join-Path $repositoryRoot 'common/src/Execution/ExecutionPlan.psm1'
$ledgerModulePath=Join-Path $repositoryRoot 'common/src/Compatibility/FullCompatibilityLedger.psm1'
$universeSchema=Join-Path $repositoryRoot 'common/schemas/compatibility-universe.schema.json'
$evidenceSchema=Join-Path $repositoryRoot 'common/schemas/launch-check-evidence.schema.json'
foreach($requiredPath in @($ExecutionPlanPath,$UniversePath,$executionPlanModule,$ledgerModulePath,$universeSchema,$evidenceSchema)){
    if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "LAUNCH_CHECK_INPUT_NOT_FOUND:$requiredPath"}
}

$planRaw=[IO.File]::ReadAllText([IO.Path]::GetFullPath($ExecutionPlanPath))
$plan=$planRaw|ConvertFrom-Json -ErrorAction Stop
Import-Module $executionPlanModule -Force
$planValidation=Test-MmtlExecutionPlan -Plan $plan
if(-not $planValidation.valid){throw "LAUNCH_CHECK_EXECUTION_PLAN_INVALID:$($planValidation.errors -join ',')"}
$planDigest=Get-MmtlExecutionPlanSemanticDigest -Plan $plan
if([string]$plan.semanticDigest -cne $planDigest){throw 'LAUNCH_CHECK_EXECUTION_PLAN_DIGEST_MISMATCH'}

$universeRaw=[IO.File]::ReadAllText([IO.Path]::GetFullPath($UniversePath))
if(-not(Test-Json -Json $universeRaw -SchemaFile $universeSchema -ErrorAction SilentlyContinue)){throw 'LAUNCH_CHECK_UNIVERSE_INVALID'}
$universe=$universeRaw|ConvertFrom-Json -ErrorAction Stop
$target=@($universe.targets|Where-Object{[string]$_.targetId -ceq $TargetId -and [string]$_.availability -ceq 'Available'})
if($target.Count -ne 1){throw "LAUNCH_CHECK_TARGET_NOT_UNIQUE_AVAILABLE:$TargetId"}
$target=$target[0]
$project=$plan.project
$actualTargetId=([string]$project.loader.id)+'@'+[string]$project.minecraftId
if($actualTargetId -cne $TargetId -or [string]$project.loader.id -cne [string]$target.loaderId -or [string]$project.minecraftId -cne [string]$target.minecraftId){throw 'LAUNCH_CHECK_TARGET_IDENTITY_MISMATCH'}
$ledgerModule=Import-Module $ledgerModulePath -Force -PassThru
$targetSpecHash=& $ledgerModule {param($item) Get-MmtlTargetSpecHash -Target $item} $target
$candidateVersions=& $ledgerModule {param($candidates) Get-MmtlLoaderVersionCandidateValues -Candidates $candidates} $target.loaderVersionCandidates
if([string]$project.loader.version -cnotin @($candidateVersions)){throw 'LAUNCH_CHECK_LOADER_VERSION_NOT_IN_UNIVERSE'}

$buildReady=[bool]$plan.capabilityGates.buildReady
$launchReady=[bool]$plan.capabilityGates.launchReady
$buildJavaStatus=[string]$plan.buildJava.resolution.status
$runtimeJavaStatus=[string]$plan.runtimeJava.resolution.status
$bindingMode=[string]$plan.runtimeJava.bindingMode
$blockingCodes=@($plan.launchBlockingReasons|ForEach-Object{[string]$_.code})
if(-not $buildReady -or -not $launchReady -or $buildJavaStatus -cne 'Resolved' -or $runtimeJavaStatus -cne 'Resolved' -or $blockingCodes.Count -ne 0){throw 'LAUNCH_CHECK_NOT_READY'}
$profileMode=[string]$plan.profile.mode
if($profileMode -notin @('Single','IntegratedLAN','Dedicated')){throw 'LAUNCH_CHECK_PROFILE_MODE_UNSUPPORTED'}
if($bindingMode -notin @('Direct','SameAsBuildJvm','ToolchainManaged')){throw 'LAUNCH_CHECK_RUNTIME_BINDING_UNSUPPORTED'}
if(-not $ObservedAt){$ObservedAt=[DateTimeOffset]::UtcNow.ToString('o')}
$observedAtValue=[DateTimeOffset]::MinValue
if(-not [DateTimeOffset]::TryParse($ObservedAt,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$observedAtValue)){throw 'LAUNCH_CHECK_OBSERVED_AT_INVALID'}

$evidence=[pscustomobject][ordered]@{
    schemaVersion=1
    targetId=$TargetId
    minecraftId=[string]$target.minecraftId
    loaderId=[string]$target.loaderId
    loaderVersion=[string]$project.loader.version
    targetSpecHash=$targetSpecHash
    status='Ready'
    observedAt=$observedAtValue.ToUniversalTime().ToString('o')
    executionPlanDigest=$planDigest
    profileMode=$profileMode
    buildReady=$buildReady
    launchReady=$launchReady
    buildJavaStatus=$buildJavaStatus
    runtimeJavaStatus=$runtimeJavaStatus
    runtimeBindingMode=$bindingMode
    blockingReasonCodes=@()
    platform=[pscustomobject][ordered]@{os=[string]$plan.platform.os;arch=[string]$plan.platform.arch}
}
$evidenceJson=ConvertTo-Json -InputObject $evidence -Depth 12
if(-not(Test-Json -Json $evidenceJson -SchemaFile $evidenceSchema -ErrorAction SilentlyContinue)){throw 'LAUNCH_CHECK_EVIDENCE_SCHEMA_INVALID'}
if($evidenceJson -match '(?i)(?:[A-Z]:\\Users\\|/home/|/Users/|(?:session.?token|access.?token|bearer)\s*[:=])'){throw 'LAUNCH_CHECK_EVIDENCE_PRIVACY_VIOLATION'} # public-hygiene: allow-generic-platform-location

$fullOutputPath=[IO.Path]::GetFullPath($OutputPath)
$outputDirectory=Split-Path -Parent $fullOutputPath
if(-not(Test-Path -LiteralPath $outputDirectory -PathType Container)){[IO.Directory]::CreateDirectory($outputDirectory)|Out-Null}
$cursor=$outputDirectory
while($cursor){
    if(Test-Path -LiteralPath $cursor){$directoryItem=Get-Item -LiteralPath $cursor -Force;if(($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $directoryItem.LinkType){throw 'LAUNCH_CHECK_OUTPUT_REPARSE_PATH'}}
    $parent=Split-Path -Parent $cursor
    if(-not $parent -or $parent -ceq $cursor){break}
    $cursor=$parent
}
if(Test-Path -LiteralPath $fullOutputPath){throw 'LAUNCH_CHECK_OUTPUT_ALREADY_EXISTS'}
$temporaryPath=$fullOutputPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
try{
    [IO.File]::WriteAllText($temporaryPath,$evidenceJson+"`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryPath,$fullOutputPath,$false)
}catch{
    if(Test-Path -LiteralPath $temporaryPath){Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue}
    throw
}
$evidenceHash=(Get-FileHash -LiteralPath $fullOutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject][ordered]@{targetId=$TargetId;status='READY';targetSpecHash=$targetSpecHash;evidenceSha256=$evidenceHash;executionPlanDigest=$planDigest}
