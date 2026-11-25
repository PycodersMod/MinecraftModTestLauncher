[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetId,
    [Parameter(Mandatory)][string]$ProbeEvidencePath,
    [Parameter(Mandatory)][string]$BuildEvidencePath,
    [Parameter(Mandatory)][string]$BuildEvidenceIndexPath,
    [Parameter(Mandatory)][string]$UniversePath,
    [Parameter(Mandatory)][string]$LedgerPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$runtimeSchema=Join-Path $repoRoot 'common/schemas/runtime-binding-evidence.schema.json'
$probeModule=Join-Path $repoRoot 'common/src/RuntimeBindingProbe.psm1'
$bindingModule=Join-Path $repoRoot 'common/src/RunTaskJvmBinding.psm1'
Import-Module (Join-Path $repoRoot 'common/src/Validation/TargetIdentity.psm1') -Force
foreach($path in @($ProbeEvidencePath,$BuildEvidencePath,$BuildEvidenceIndexPath,$UniversePath,$LedgerPath,$probeModule,$bindingModule)){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "RUNTIME_BINDING_EVIDENCE_INPUT_MISSING:$path"}
}
Import-Module $bindingModule -Force
$probeSourceFingerprint=Get-MmtlRunTaskJvmBindingSourceFingerprint
$probe=Get-Content -LiteralPath $ProbeEvidencePath -Raw|ConvertFrom-Json -ErrorAction Stop
$build=Get-Content -LiteralPath $BuildEvidencePath -Raw|ConvertFrom-Json -ErrorAction Stop
$index=Get-Content -LiteralPath $BuildEvidenceIndexPath -Raw|ConvertFrom-Json -ErrorAction Stop
$universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
$ledger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json -ErrorAction Stop
$target=@($universe.targets|Where-Object targetId -CEQ $TargetId|Select-Object -First 1)[0]
$ledgerTarget=@($ledger.targets|Where-Object targetId -CEQ $TargetId|Select-Object -First 1)[0]
$buildIndexEntry=@($index.entries|Where-Object{$_.targetId -ceq $TargetId -and $_.dimension -ceq 'BuildVerified'}|Select-Object -First 1)[0]
if(-not $target -or -not $ledgerTarget -or -not $buildIndexEntry){throw "RUNTIME_BINDING_EVIDENCE_BUILD_CLAIM_MISSING:$TargetId"}
if([string]$index.universeHash -cne [string]$universe.catalogHash -or [string]$ledger.universeHash -cne [string]$universe.catalogHash){throw 'RUNTIME_BINDING_EVIDENCE_UNIVERSE_MISMATCH'}
$buildHash=(Get-FileHash -LiteralPath $BuildEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
if($buildHash -cne [string]$buildIndexEntry.evidenceSha256){throw "RUNTIME_BINDING_EVIDENCE_BUILD_HASH_MISMATCH:$TargetId"}
if([string]$ledgerTarget.targetSpecHash -cne [string]$buildIndexEntry.targetSpecHash){throw "RUNTIME_BINDING_EVIDENCE_BUILD_SPEC_MISMATCH:$TargetId"}
$candidateLoaderVersions = @(Get-MmtlLoaderVersionCandidateValues -Candidates $target.loaderVersionCandidates)
if([string]$build.targetId -cne $TargetId -or [string]$probe.minecraft -cne [string]$target.minecraftId -or [string]$probe.loader -cne [string]$target.loaderId -or [string]$probe.loaderVersion -cnotin $candidateLoaderVersions){throw "RUNTIME_BINDING_EVIDENCE_IDENTITY_MISMATCH:$TargetId"}
if([string]$probe.status -cne 'Observed' -or [string]$probe.runtimeJavaBinding.mode -notin @('Direct','SameAsBuildJvm','ToolchainManaged') -or [string]$probe.runtimeJavaBinding.confidence -cne 'High'){throw "RUNTIME_BINDING_EVIDENCE_PROBE_NOT_VERIFIED:$TargetId"}
$runtimeMajor=[int]$target.runtimeJavaRequirement.major
if($runtimeMajor -le 0 -and [string]$ledgerTarget.dimensions.RuntimeJava.status -ceq 'Supported'){
    $probeRequirement=$probe.runtimeJavaRequirement
    $provenance=$probeRequirement.provenance
    $runtimeJavaRefs=@($ledgerTarget.dimensions.RuntimeJava.evidenceRefs|ForEach-Object{[string]$_})
    $sourceRef="runtime-java-source-url:$([string]$provenance.url)"
    $hashRef="runtime-java-sha1:$([string]$provenance.hash)"
    if([string]$probeRequirement.requirementKind -ceq 'AuthoritativeMetadata' -and [string]$probeRequirement.confidence -ceq 'High' -and [string]$provenance.sourceType -ceq 'official' -and $runtimeJavaRefs -ccontains $sourceRef -and $runtimeJavaRefs -ccontains $hashRef){
        $runtimeMajor=[int]$probeRequirement.major
    }
}
$observedMajor=[int]$build.java.observedBuildJava.major
if($runtimeMajor -le 0 -or [int]$probe.runtimeJavaRequirement.major -ne $runtimeMajor -or [int]$probe.buildJavaMajor -ne $observedMajor -or [string]$probe.observedBuildJavaVersion -cne [string]$build.java.observedBuildJava.exactVersion){throw "RUNTIME_BINDING_EVIDENCE_JAVA_IDENTITY_MISMATCH:$TargetId"}
$normalizedProbeBuildSystem = switch -CaseSensitive ([string]$probe.buildSystem) {
    'GradleWrapper' { 'Gradle' }
    default { [string]$probe.buildSystem }
}
$normalizedBuildSystem = switch -CaseSensitive ([string]$build.buildSystem.id) {
    'GradleWrapper' { 'Gradle' }
    default { [string]$build.buildSystem.id }
}
if([string]$normalizedProbeBuildSystem -cne [string]$normalizedBuildSystem){throw "RUNTIME_BINDING_EVIDENCE_BUILDSYSTEM_MISMATCH:$TargetId"}
$forgeGradleVersion=[string]$build.forgeSecurity.forgeGradleSpec
if([string]::IsNullOrWhiteSpace($forgeGradleVersion)){$forgeGradleVersion=[string]$build.forgeSecurity.pluginVersion}
if([string]$target.loaderId -ceq 'Forge' -and ([string]$probe.toolchain -cne 'ForgeGradle' -or [string]$probe.toolchainVersion -cne $forgeGradleVersion)){throw "RUNTIME_BINDING_EVIDENCE_TOOLCHAIN_MISMATCH:$TargetId"}
if([string]$probe.runtimeJavaBinding.mode -ceq 'SameAsBuildJvm' -and (-not $probe.runtimeJavaBinding.requiresBuildJvmMatch -or $runtimeMajor -ne $observedMajor)){throw "RUNTIME_BINDING_EVIDENCE_MODE_INVALID:$TargetId"}
if([string]$probe.runtimeJavaBinding.mode -ceq 'Direct' -and -not $probe.runtimeJavaBinding.runtimeJavaControllable){throw "RUNTIME_BINDING_EVIDENCE_MODE_INVALID:$TargetId"}
$observedTasks=@($probe.observedTasks|Where-Object{$_.task -in @('runClient','runServer') -and $_.isJavaExec -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$_.executable)})
if(-not $observedTasks.Count){$observedTasks=@($probe.evidenceDetails|Where-Object{$_.task -in @('runClient','runServer') -and $_.taskType -match 'JavaExec' -and -not [string]::IsNullOrWhiteSpace([string]$_.executable)})}
if(-not $observedTasks.Count){throw "RUNTIME_BINDING_EVIDENCE_TASKS_MISSING:$TargetId"}
$tasks=@(foreach($task in $observedTasks){
    $javaToken=if([string]$probe.runtimeJavaBinding.mode -ceq 'SameAsBuildJvm'){'<BUILD_JAVA_HOME>'}else{'<RUNTIME_JAVA_HOME>'}
    $suffix=if([string]$task.executable -match '(?i)javaw?\.exe$'){'.exe'}else{''}
    [pscustomobject][ordered]@{task=[string]$task.task;taskType='JavaExec';isJavaExec=$true;launcherSource=[string]$task.launcherSource;executable="$javaToken/bin/java$suffix"}
})
$buildSystem=[pscustomobject][ordered]@{id=[string]$build.buildSystem.id;version=[string]$build.buildSystem.version}
$toolchain=if([string]$target.loaderId -ceq 'Forge'){
    [pscustomobject][ordered]@{id='ForgeGradle';version=$forgeGradleVersion}
}else{
    [pscustomobject][ordered]@{id=[string]$build.toolchain.id;version=[string]$build.toolchain.version}
}
$sanitized=[pscustomobject][ordered]@{
    schemaVersion=1;generatedAt=[DateTimeOffset]::Parse([string]$probe.timestamp).ToUniversalTime().ToString('o')
    targetId=$TargetId;targetSpecHash=[string]$ledgerTarget.targetSpecHash;loaderId=[string]$target.loaderId;minecraftId=[string]$target.minecraftId;loaderVersion=[string]$probe.loaderVersion
    status='Observed';probeStrategy=[string]$probe.runtimeJavaBinding.probeStrategy;evidenceSource=[string]$probe.runtimeJavaBinding.evidenceSource;confidence=[string]$probe.runtimeJavaBinding.confidence
    mode=[string]$probe.runtimeJavaBinding.mode;runtimeJavaControllable=[bool]$probe.runtimeJavaBinding.runtimeJavaControllable;requiresBuildJvmMatch=[bool]$probe.runtimeJavaBinding.requiresBuildJvmMatch
    runtimeJavaMajor=$runtimeMajor;observedBuildJavaMajor=$observedMajor;observedBuildJavaVersion=[string]$build.java.observedBuildJava.exactVersion
    buildSystem=$buildSystem;toolchain=$toolchain;tasks=$tasks
    probeSourceSha256=$probeSourceFingerprint.sha256
    buildEvidenceSha256=$buildHash;rawProbeEvidenceSha256=(Get-FileHash -LiteralPath $ProbeEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    platform=[pscustomobject][ordered]@{os=[string]$build.platform.os;arch=[string]$build.platform.arch}
}
$json=ConvertTo-Json -InputObject $sanitized -Depth 20
if(-not(Test-Json -Json $json -SchemaFile $runtimeSchema -ErrorAction Stop)){throw "RUNTIME_BINDING_EVIDENCE_SCHEMA_INVALID:$TargetId"}
$rawBytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
$fullOutput=[IO.Path]::GetFullPath($OutputPath);$directory=Split-Path -Parent $fullOutput
if(-not(Test-Path -LiteralPath $directory -PathType Container)){[IO.Directory]::CreateDirectory($directory)|Out-Null}
$temporary=$fullOutput+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
try{[IO.File]::WriteAllBytes($temporary,$rawBytes);[IO.File]::Move($temporary,$fullOutput,$true)}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
[pscustomobject][ordered]@{targetId=$TargetId;mode=$sanitized.mode;status=$sanitized.status;evidencePath=$fullOutput;evidenceSha256=(Get-FileHash -LiteralPath $fullOutput -Algorithm SHA256).Hash.ToLowerInvariant();buildEvidenceSha256=$buildHash;rawProbeEvidenceSha256=$sanitized.rawProbeEvidenceSha256}
