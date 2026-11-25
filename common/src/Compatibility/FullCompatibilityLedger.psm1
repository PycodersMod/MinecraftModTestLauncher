Set-StrictMode -Version Latest

$script:LedgerDimensions = @(
    'Catalogued', 'LoaderResolved', 'ProjectDetection', 'BuildPlan', 'BuildJava',
    'RuntimeJava', 'RuntimeBinding', 'BuildVerified', 'LaunchPlan', 'LaunchCheck',
    'AgentBuild', 'AgentInjection', 'SingleCapability', 'IntegratedLANCapability',
    'DedicatedCapability', 'LogObservation', 'EvidenceLevel'
)
$script:LedgerStatuses = @('Supported', 'PartiallySupported', 'NotApplicable', 'ExternallyBlocked', 'Unsupported', 'Unknown', 'PendingImplementation')
$script:MmtlLogObservationEvidenceCache = $null

Import-Module (Join-Path $PSScriptRoot '../RunTaskJvmBinding.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../Validation/TargetIdentity.psm1') -Force

function Get-MmtlLedgerSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-MmtlCanonicalJson {
    param([Parameter(Mandatory)]$Value)
    ConvertTo-Json -InputObject $Value -Depth 50 -Compress
}

function Test-MmtlRuntimeBindingProbeSourceHashTrusted {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Hash)

    if($Hash -notmatch '^[a-f0-9]{64}$'){return $false}
    $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $manifestPath=Join-Path $repositoryRoot 'compatibility/runtime-binding-probe-sources.json'
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){return $false}
    try{$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{return $false}
    if([int]$manifest.schemaVersion -ne 1){return $false}
    try{$current=Get-MmtlRunTaskJvmBindingSourceFingerprint}catch{return $false}
    if([string]$manifest.currentSourceSha256 -cne [string]$current.sha256){return $false}
    $manifestSources=@($manifest.currentSourceFiles|Sort-Object path)
    $currentSources=@($current.sources|Sort-Object path)
    if($manifestSources.Count -ne 2 -or $currentSources.Count -ne 2){return $false}
    for($i=0;$i -lt 2;$i++){
        if([string]$manifestSources[$i].path -cne [string]$currentSources[$i].path -or [string]$manifestSources[$i].sha256 -cne [string]$currentSources[$i].sha256){return $false}
    }
    $trusted=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$trusted.Add([string]$current.sha256)
    foreach($source in @($manifest.historicalSources)){
        $historicalHash=[string]$source.sha256
        if($historicalHash -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace([string]$source.rationale)){return $false}
        [void]$trusted.Add($historicalHash)
    }
    return $trusted.Contains($Hash)
}

function Get-MmtlTargetSpecHash {
    param([Parameter(Mandatory)]$Target)
    $spec = [ordered]@{
        targetId = [string]$Target.targetId
        loaderId = [string]$Target.loaderId
        minecraftId = [string]$Target.minecraftId
        minecraftType = [string]$Target.minecraftType
        availability = [string]$Target.availability
        loaderVersionCandidates = @($Target.loaderVersionCandidates)
        candidateStatus = [string]$Target.candidateStatus
        candidateSourceHash = if ($Target.PSObject.Properties['candidateSourceHash']) { $Target.candidateSourceHash } else { $null }
        sourceHash = if ($Target.PSObject.Properties['sourceHash']) { $Target.sourceHash } else { $null }
        authoritativeSource = if ($Target.PSObject.Properties['authoritativeSource']) { $Target.authoritativeSource } else { $null }
        buildToolchainCandidates = if ($Target.PSObject.Properties['buildToolchainCandidates']) { @($Target.buildToolchainCandidates) } else { @() }
        buildJavaRequirement = if ($Target.PSObject.Properties['buildJavaRequirement']) { $Target.buildJavaRequirement } else { $null }
        runtimeJavaRequirement = if ($Target.PSObject.Properties['runtimeJavaRequirement']) { $Target.runtimeJavaRequirement } else { $null }
        agentRequirement = if ($Target.PSObject.Properties['agentRequirement']) { $Target.agentRequirement } else { $null }
    }
    Get-MmtlLedgerSha256 -Text (Get-MmtlCanonicalJson -Value $spec)
}

function Get-MmtlTargetEvidenceClaims {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Universe,[Parameter(Mandatory)]$Index,[Parameter(Mandatory)][string]$EvidenceRoot)

    if([int]$Index.schemaVersion -ne 1 -or [string]$Index.universeHash -cne [string]$Universe.catalogHash){throw 'TARGET_EVIDENCE_UNIVERSE_MISMATCH'}
    $indexSchema=Join-Path $PSScriptRoot '../../schemas/target-validation-evidence-index.schema.json'
    $indexJson=ConvertTo-Json -InputObject $Index -Depth 30 -Compress
    $indexIsValid=$false
    try{$indexIsValid=Test-Json -Json $indexJson -SchemaFile $indexSchema -ErrorAction Stop}catch{$indexIsValid=$false}
    if(-not $indexIsValid){throw 'TARGET_EVIDENCE_INDEX_SCHEMA_INVALID'}
    $root=[IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'TARGET_EVIDENCE_ROOT_MISSING'}
    $rootItem=Get-Item -LiteralPath $root -Force
    if(($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $rootItem.LinkType){throw 'TARGET_EVIDENCE_ROOT_REPARSE_PATH'}
    $universeById=@{}
    foreach($target in @($Universe.targets|Where-Object availability -CEQ 'Available')){$universeById[[string]$target.targetId]=$target}
    $claims=@{};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$buildEvidenceById=@{};$agentBuildEvidenceById=@{}
    $validationSchema=Join-Path $PSScriptRoot '../../schemas/validation-evidence.schema.json'
    $runtimeBindingSchema=Join-Path $PSScriptRoot '../../schemas/runtime-binding-evidence.schema.json'
    $agentBuildSchema=Join-Path $PSScriptRoot '../../schemas/agent-build-evidence.schema.json'
    $agentInjectionSchema=Join-Path $PSScriptRoot '../../schemas/agent-injection-evidence.schema.json'
    $launchCheckSchema=Join-Path $PSScriptRoot '../../schemas/launch-check-evidence.schema.json'
    $indexHash=Get-MmtlLedgerSha256 -Text $indexJson
    $orderedEntries=@($Index.entries|Sort-Object @{Expression={switch([string]$_.dimension){'BuildVerified'{0}'AgentBuild'{1}'RuntimeBinding'{2}'AgentInjection'{3}'LaunchCheck'{4}default{5}}}},@{Expression={[string]$_.targetId};Ascending=$true})
    foreach($entry in $orderedEntries){
        $targetId=[string]$entry.targetId;$dimension=[string]$entry.dimension
        $claimKey=$targetId+'|'+$dimension
        if(-not $seen.Add($claimKey)){throw "TARGET_EVIDENCE_DUPLICATE_CLAIM:$claimKey"}
        if($dimension -notin @('BuildVerified','RuntimeBinding','AgentBuild','AgentInjection','LaunchCheck')){throw "TARGET_EVIDENCE_DIMENSION_UNSUPPORTED:$dimension"}
        if(-not $universeById.ContainsKey($targetId)){throw "TARGET_EVIDENCE_TARGET_NOT_IN_UNIVERSE:$targetId"}
        $target=$universeById[$targetId]
        if([string]$entry.targetSpecHash -cne (Get-MmtlTargetSpecHash -Target $target)){throw "TARGET_EVIDENCE_TARGET_SPEC_MISMATCH:$targetId"}
        $relative=[string]$entry.evidencePath
        $segments=@($relative -split '/')
        if([IO.Path]::IsPathRooted($relative) -or $relative.Contains('\') -or @($segments|Where-Object{$_ -in @('','.','..')}).Count){throw "TARGET_EVIDENCE_PATH_INVALID:$targetId"}
        $path=[IO.Path]::GetFullPath((Join-Path $root ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
        $prefix=$root+[IO.Path]::DirectorySeparatorChar
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $path -PathType Leaf)){throw "TARGET_EVIDENCE_PATH_OUTSIDE_ROOT:$targetId"}
        $cursor=$root
        foreach($segment in $segments){$cursor=Join-Path $cursor $segment;if(-not(Test-Path -LiteralPath $cursor)){throw "TARGET_EVIDENCE_PATH_MISSING:$targetId"};$item=Get-Item -LiteralPath $cursor -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw "TARGET_EVIDENCE_REPARSE_PATH:$targetId"}}
        $evidenceHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if($evidenceHash -cne [string]$entry.evidenceSha256){throw "TARGET_EVIDENCE_HASH_MISMATCH:$targetId"}
        $raw=[IO.File]::ReadAllText($path)
        $evidenceSchema=switch($dimension){'BuildVerified'{$validationSchema}'RuntimeBinding'{$runtimeBindingSchema}'AgentBuild'{$agentBuildSchema}'AgentInjection'{$agentInjectionSchema}'LaunchCheck'{$launchCheckSchema}}
        if(-not(Test-Json -Json $raw -SchemaFile $evidenceSchema -ErrorAction SilentlyContinue)){throw "TARGET_EVIDENCE_RUN_SCHEMA_INVALID:${targetId}:$dimension"}
        $evidence=$raw|ConvertFrom-Json -ErrorAction Stop
        $candidateLoaderVersions = @(Get-MmtlLoaderVersionCandidateValues -Candidates $target.loaderVersionCandidates)
        if([string]$evidence.targetId -cne $targetId -or [string]$evidence.minecraftId -cne [string]$target.minecraftId -or [string]$evidence.loaderId -cne [string]$target.loaderId -or [string]$evidence.loaderVersion -cnotin $candidateLoaderVersions){throw "TARGET_EVIDENCE_IDENTITY_MISMATCH:$targetId"}
        if($dimension -ceq 'BuildVerified'){
            if([string]$evidence.result -cne 'PASSED' -or [string]$evidence.validationLevel -cne 'BUILD_VERIFIED' -or [string]$evidence.failureCode -cne 'NONE' -or -not $evidence.source.unchangedDuringBuild -or -not $evidence.source.artifactFresh -or [string]$evidence.artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or @($evidence.logs|Where-Object{$_.sha256 -match '^(?i:[a-f0-9]{64})$'}).Count -lt 2){throw "TARGET_EVIDENCE_BUILD_PROOF_INVALID:$targetId"}
            if([string]$evidence.sourceFixture.trust -notin @('TrustedOfficial','VerifiedHistorical')){throw "TARGET_EVIDENCE_FIXTURE_TRUST_INVALID:$targetId"}
            if([string]$target.loaderId -ceq 'Forge' -and (-not $evidence.forgeSecurity -or [string]$evidence.forgeSecurity.pinId -cne $targetId)){throw "TARGET_EVIDENCE_FORGE_PIN_MISMATCH:$targetId"}
            $buildEvidenceById[$targetId]=[pscustomobject]@{hash=$evidenceHash;evidence=$evidence}
        }elseif($dimension -ceq 'AgentBuild'){
            $provider=$evidence.provider
            if([string]$evidence.validationLevel -cne 'AGENT_BUILD_VERIFIED' -or [string]$evidence.result -cne 'PASSED' -or -not $evidence.source.unchangedDuringBuild -or [int]$evidence.tests.failed -ne 0 -or [int]$evidence.tests.passed -lt 1){throw "TARGET_EVIDENCE_AGENT_BUILD_PROOF_INVALID:$targetId"}
            $manifestRelative=[string]$provider.manifestPath;$manifestSegments=@($manifestRelative -split '/')
            if([IO.Path]::IsPathRooted($manifestRelative) -or $manifestRelative.Contains('\') -or @($manifestSegments|Where-Object{$_ -in @('','.','..')}).Count){throw "TARGET_EVIDENCE_AGENT_MANIFEST_PATH_INVALID:$targetId"}
            $manifestPath=[IO.Path]::GetFullPath((Join-Path $root ($manifestRelative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            if(-not $manifestPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw "TARGET_EVIDENCE_AGENT_MANIFEST_MISSING:$targetId"}
            $manifestCursor=$root
            foreach($segment in $manifestSegments){$manifestCursor=Join-Path $manifestCursor $segment;if(-not(Test-Path -LiteralPath $manifestCursor)){throw "TARGET_EVIDENCE_AGENT_MANIFEST_MISSING:$targetId"};$manifestItem=Get-Item -LiteralPath $manifestCursor -Force;if(($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $manifestItem.LinkType){throw "TARGET_EVIDENCE_AGENT_MANIFEST_REPARSE_PATH:$targetId"}}
            $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if($manifestHash -cne [string]$provider.manifestSha256){throw "TARGET_EVIDENCE_AGENT_MANIFEST_HASH_MISMATCH:$targetId"}
            $manifestRaw=[IO.File]::ReadAllText($manifestPath);$manifestSchema=Join-Path $PSScriptRoot '../../schemas/agent-manifest-v1.schema.json'
            if(-not(Test-Json -Json $manifestRaw -SchemaFile $manifestSchema)){throw "TARGET_EVIDENCE_AGENT_MANIFEST_INVALID:$targetId"}
            $manifest=$manifestRaw|ConvertFrom-Json -ErrorAction Stop
            if([string]$provider.providerId -cne [string]$evidence.providerId -or [string]$provider.providerId -cne [string]$manifest.providerId -or [string]$provider.loaderId -cne [string]$target.loaderId -or [string]$provider.loaderId -cne [string]$manifest.loaderId -or [string]$provider.agentVersion -cne [string]$evidence.agentVersion -or [string]$provider.agentVersion -cne [string]$manifest.agentVersion -or @($provider.minecraftVersions|ForEach-Object{[string]$_}) -cnotcontains [string]$target.minecraftId -or @($manifest.minecraftVersions|ForEach-Object{[string]$_}) -cnotcontains [string]$target.minecraftId -or @($provider.loaderVersions|ForEach-Object{[string]$_}) -cnotcontains [string]$evidence.loaderVersion -or @($manifest.loaderVersions|ForEach-Object{[string]$_}) -cnotcontains [string]$evidence.loaderVersion){throw "TARGET_EVIDENCE_AGENT_PROVIDER_MISMATCH:$targetId"}
            $artifactRelative=[string]$evidence.artifact.path;$artifactSegments=@($artifactRelative -split '/')
            if([IO.Path]::IsPathRooted($artifactRelative) -or $artifactRelative.Contains('\') -or @($artifactSegments|Where-Object{$_ -in @('','.','..')}).Count){throw "TARGET_EVIDENCE_AGENT_ARTIFACT_PATH_INVALID:$targetId"}
            $artifactPath=[IO.Path]::GetFullPath((Join-Path $root ($artifactRelative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            if(-not $artifactPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($artifactPath) -ine '.jar' -or -not(Test-Path -LiteralPath $artifactPath -PathType Leaf)){throw "TARGET_EVIDENCE_AGENT_ARTIFACT_MISSING:$targetId"}
            $artifactCursor=$root
            foreach($segment in $artifactSegments){$artifactCursor=Join-Path $artifactCursor $segment;if(-not(Test-Path -LiteralPath $artifactCursor)){throw "TARGET_EVIDENCE_AGENT_ARTIFACT_MISSING:$targetId"};$artifactItem=Get-Item -LiteralPath $artifactCursor -Force;if(($artifactItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $artifactItem.LinkType){throw "TARGET_EVIDENCE_AGENT_ARTIFACT_REPARSE_PATH:$targetId"}}
            $artifactHash=(Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if($artifactHash -cne [string]$evidence.artifact.sha256 -or $artifactHash -cne [string]$provider.artifactSha256 -or $artifactHash -cne [string]$manifest.sha256){throw "TARGET_EVIDENCE_AGENT_ARTIFACT_HASH_MISMATCH:$targetId"}
            if($raw -match '(?i)(?:[A-Z]:\\Users\\|/home/|/Users/)' -or $manifestRaw -match '(?i)(?:[A-Z]:\\Users\\|/home/|/Users/)'){throw "TARGET_EVIDENCE_AGENT_PRIVACY_VIOLATION:$targetId"} # public-hygiene: allow-generic-platform-location
            $agentBuildEvidenceById[$targetId]=[pscustomobject]@{hash=$evidenceHash;evidence=$evidence}
        }elseif($dimension -ceq 'AgentInjection'){
            if(-not $agentBuildEvidenceById.ContainsKey($targetId) -or [string]$evidence.agentBuildEvidenceSha256 -cne [string]$agentBuildEvidenceById[$targetId].hash){throw "TARGET_EVIDENCE_AGENT_INJECTION_BUILD_PROOF_MISSING:$targetId"}
            if([string]$evidence.validationLevel -cne 'AGENT_INJECTION_VERIFIED' -or [string]$evidence.result -cne 'PASSED' -or [int]$evidence.tests.failed -ne 0 -or [int]$evidence.tests.passed -lt 1){throw "TARGET_EVIDENCE_AGENT_INJECTION_PROOF_INVALID:$targetId"}
            $agentBuild=$agentBuildEvidenceById[$targetId].evidence
            $agentArtifactHash=[string]$agentBuild.artifact.sha256
            if([string]$evidence.loaderVersion -cne [string]$agentBuild.loaderVersion -or [string]$evidence.provider.providerId -cne [string]$agentBuild.provider.providerId -or [string]$evidence.provider.manifestSha256 -cne [string]$agentBuild.provider.manifestSha256 -or [string]$evidence.provider.artifactSha256 -cne $agentArtifactHash -or [string]$evidence.sessionInjection.sourceArtifactSha256 -cne $agentArtifactHash -or [string]$evidence.sessionInjection.copiedArtifactSha256 -cne $agentArtifactHash){throw "TARGET_EVIDENCE_AGENT_INJECTION_ARTIFACT_MISMATCH:$targetId"}
            $sessionArtifactRelative=[string]$evidence.sessionInjection.copiedArtifactEvidencePath
            $sessionArtifactSegments=@($sessionArtifactRelative -split '/')
            if([IO.Path]::IsPathRooted($sessionArtifactRelative) -or $sessionArtifactRelative.Contains('\') -or @($sessionArtifactSegments|Where-Object{$_ -in @('','.','..')}).Count){throw "TARGET_EVIDENCE_AGENT_INJECTION_PATH_INVALID:$targetId"}
            $sessionArtifactPath=[IO.Path]::GetFullPath((Join-Path $root ($sessionArtifactRelative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
            if(-not $sessionArtifactPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($sessionArtifactPath) -ine '.jar' -or -not(Test-Path -LiteralPath $sessionArtifactPath -PathType Leaf)){throw "TARGET_EVIDENCE_AGENT_INJECTION_ARTIFACT_MISSING:$targetId"}
            $sessionCursor=$root
            foreach($segment in $sessionArtifactSegments){$sessionCursor=Join-Path $sessionCursor $segment;if(-not(Test-Path -LiteralPath $sessionCursor)){throw "TARGET_EVIDENCE_AGENT_INJECTION_ARTIFACT_MISSING:$targetId"};$sessionItem=Get-Item -LiteralPath $sessionCursor -Force;if(($sessionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $sessionItem.LinkType){throw "TARGET_EVIDENCE_AGENT_INJECTION_REPARSE_PATH:$targetId"}}
            if((Get-FileHash -LiteralPath $sessionArtifactPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne [string]$evidence.sessionInjection.copiedArtifactSha256){throw "TARGET_EVIDENCE_AGENT_INJECTION_ARTIFACT_MISMATCH:$targetId"}
            if([string]$evidence.sessionInjection.sessionRelativeArtifactPath -cne [string]$evidence.sessionInjection.runtimeModRelativePath -or [string]$evidence.sessionInjection.sessionRelativeArtifactPath -notmatch '^agent/[^/]+\.jar$' -or [string]$evidence.sessionInjection.eventSinkRelativePath -notmatch '^agent-events/[^/]+\.jsonl$' -or [bool]$evidence.sessionInjection.rawTokenInJvmArguments){throw "TARGET_EVIDENCE_AGENT_INJECTION_SESSION_BINDING_INVALID:$targetId"}
            $expectedSourcePaths=@('common/src/Agent/AgentProvider.psm1','common/tests/AgentProvider.Tests.ps1')
            $actualSourcePaths=@($evidence.source.files|ForEach-Object{[string]$_.path}|Sort-Object -Unique)
            if(@(Compare-Object -ReferenceObject $expectedSourcePaths -DifferenceObject $actualSourcePaths -CaseSensitive).Count){throw "TARGET_EVIDENCE_AGENT_INJECTION_SOURCE_MANIFEST_INVALID:$targetId"}
            $repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
            foreach($sourceFile in $evidence.source.files){
                $sourceRelative=[string]$sourceFile.path
                $sourceSegments=@($sourceRelative -split '/')
                if([IO.Path]::IsPathRooted($sourceRelative) -or $sourceRelative.Contains('\') -or @($sourceSegments|Where-Object{$_ -in @('','.','..')}).Count){throw "TARGET_EVIDENCE_AGENT_INJECTION_SOURCE_PATH_INVALID:$targetId"}
                $sourcePath=[IO.Path]::GetFullPath((Join-Path $repoRoot ($sourceRelative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
                if(-not $sourcePath.StartsWith($repoRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $sourcePath -PathType Leaf) -or (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$sourceFile.sha256){throw "TARGET_EVIDENCE_AGENT_INJECTION_SOURCE_HASH_MISMATCH:$targetId"}
            }
            $sourceManifestText=(($evidence.source.files|Sort-Object path|ForEach-Object{"$($_.path)`t$($_.sha256)"}) -join "`n")+"`n"
            $sourceManifestHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($sourceManifestText))).ToLowerInvariant()
            if($sourceManifestHash -cne [string]$evidence.source.sha256){throw "TARGET_EVIDENCE_AGENT_INJECTION_SOURCE_HASH_MISMATCH:$targetId"}
            $logRefs=@()
            foreach($log in $evidence.logs){
                $logRelative=[string]$log.path;$logSegments=@($logRelative -split '/')
                if([IO.Path]::IsPathRooted($logRelative) -or $logRelative.Contains('\') -or @($logSegments|Where-Object{$_ -in @('','.','..')}).Count){throw "TARGET_EVIDENCE_AGENT_INJECTION_LOG_PATH_INVALID:$targetId"}
                $logPath=[IO.Path]::GetFullPath((Join-Path $root ($logRelative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
                if(-not $logPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath $logPath -PathType Leaf)){throw "TARGET_EVIDENCE_AGENT_INJECTION_LOG_MISSING:$targetId"}
                $logCursor=$root
                foreach($segment in $logSegments){$logCursor=Join-Path $logCursor $segment;if(-not(Test-Path -LiteralPath $logCursor)){throw "TARGET_EVIDENCE_AGENT_INJECTION_LOG_MISSING:$targetId"};$logItem=Get-Item -LiteralPath $logCursor -Force;if(($logItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $logItem.LinkType){throw "TARGET_EVIDENCE_AGENT_INJECTION_LOG_REPARSE_PATH:$targetId"}}
                $logHash=(Get-FileHash -LiteralPath $logPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if($logHash -cne [string]$log.sha256){throw "TARGET_EVIDENCE_AGENT_INJECTION_LOG_HASH_MISMATCH:$targetId"}
                $logRaw=[IO.File]::ReadAllText($logPath)
                if($logRaw -match '(?i)(?:[A-Z]:\\Users\\|/home/|/Users/)' -or $logRaw -match '(?i)(?:session.?token|access.?token|bearer)\s*[:=]\s*[^,\s"'']+'){throw "TARGET_EVIDENCE_AGENT_INJECTION_PRIVACY_VIOLATION:$targetId"} # public-hygiene: allow-generic-platform-location
                $logRefs+="agent-injection-log-sha256:$logHash"
            }
            if($raw -match '(?i)(?:[A-Z]:\\Users\\|/home/|/Users/)' -or $raw -match '(?i)(?:session.?token|access.?token|bearer)\s*[:=]\s*[^,\s"'']+'){throw "TARGET_EVIDENCE_AGENT_INJECTION_PRIVACY_VIOLATION:$targetId"} # public-hygiene: allow-generic-platform-location
        }elseif($dimension -ceq 'RuntimeBinding'){
            if(-not $buildEvidenceById.ContainsKey($targetId) -or [string]$evidence.buildEvidenceSha256 -cne [string]$buildEvidenceById[$targetId].hash){throw "TARGET_EVIDENCE_RUNTIME_BUILD_PROOF_MISSING:$targetId"}
            if(-not(Test-MmtlRuntimeBindingProbeSourceHashTrusted -Hash ([string]$evidence.probeSourceSha256))){throw "TARGET_EVIDENCE_RUNTIME_PROBE_SOURCE_MISMATCH:$targetId"}
            $buildEvidence=$buildEvidenceById[$targetId].evidence
            $expectedRuntimeMajor=0;$observedBuildMajor=0
            if(-not [int]::TryParse([string]$target.runtimeJavaRequirement.major,[ref]$expectedRuntimeMajor) -or -not [int]::TryParse([string]$buildEvidence.java.observedBuildJava.major,[ref]$observedBuildMajor)){throw "TARGET_EVIDENCE_RUNTIME_JAVA_REQUIREMENT_MISSING:$targetId"}
            if([int]$evidence.runtimeJavaMajor -ne $expectedRuntimeMajor -or [int]$evidence.observedBuildJavaMajor -ne $observedBuildMajor){throw "TARGET_EVIDENCE_RUNTIME_JAVA_IDENTITY_MISMATCH:$targetId"}
            if([string]$evidence.buildSystem.id -cne [string]$buildEvidence.buildSystem.id -or [string]$evidence.buildSystem.version -cne [string]$buildEvidence.buildSystem.version){throw "TARGET_EVIDENCE_RUNTIME_TOOLCHAIN_MISMATCH:$targetId"}
            $forgeGradleVersion=''
            $forgeSecurity=$buildEvidence.PSObject.Properties['forgeSecurity']
            if($forgeSecurity -and $forgeSecurity.Value -and $forgeSecurity.Value.PSObject.Properties['forgeGradleSpec']){$forgeGradleVersion=[string]$forgeSecurity.Value.forgeGradleSpec}
            if([string]::IsNullOrWhiteSpace($forgeGradleVersion) -and $forgeSecurity -and $forgeSecurity.Value -and $forgeSecurity.Value.PSObject.Properties['pluginVersion']){$forgeGradleVersion=[string]$forgeSecurity.Value.pluginVersion}
            if([string]$target.loaderId -ceq 'Forge' -and ([string]::IsNullOrWhiteSpace($forgeGradleVersion) -or [string]$evidence.toolchain.version -cne $forgeGradleVersion)){throw "TARGET_EVIDENCE_RUNTIME_TOOLCHAIN_MISMATCH:$targetId"}
            if([string]$evidence.mode -ceq 'SameAsBuildJvm' -and (-not $evidence.requiresBuildJvmMatch -or [int]$evidence.runtimeJavaMajor -ne [int]$evidence.observedBuildJavaMajor)){throw "TARGET_EVIDENCE_RUNTIME_BINDING_MODE_INVALID:$targetId"}
            if([string]$evidence.mode -ceq 'Direct' -and -not $evidence.runtimeJavaControllable){throw "TARGET_EVIDENCE_RUNTIME_BINDING_MODE_INVALID:$targetId"}
            if($raw -match '(?i)(?:[A-Z]:\\Users\\|/home/|/Users/)'){throw "TARGET_EVIDENCE_RUNTIME_PRIVACY_VIOLATION:$targetId"} # public-hygiene: allow-generic-platform-location
        }else{
            if([string]$evidence.targetSpecHash -cne [string]$entry.targetSpecHash -or [string]$evidence.status -cne 'Ready' -or -not $evidence.buildReady -or -not $evidence.launchReady -or [string]$evidence.buildJavaStatus -cne 'Resolved' -or [string]$evidence.runtimeJavaStatus -cne 'Resolved' -or @($evidence.blockingReasonCodes).Count -ne 0 -or [string]$evidence.executionPlanDigest -notmatch '^sha256:[a-f0-9]{64}$'){
                throw "TARGET_EVIDENCE_LAUNCH_CHECK_PROOF_INVALID:$targetId"
            }
            if($raw -match '(?i)(?:[A-Z]:\\Users\\|/home/|/Users/|(?:session.?token|access.?token|bearer)\s*[:=])'){throw "TARGET_EVIDENCE_LAUNCH_CHECK_PRIVACY_VIOLATION:$targetId"} # public-hygiene: allow-generic-platform-location
        }
        $refs=@("target-runner-evidence-sha256:$evidenceHash","target-evidence-index-sha256:$indexHash","target-universe-sha256:$([string]$Universe.catalogHash)","target-spec-sha256:$([string]$entry.targetSpecHash)","target-runner-evidence-path:$relative")
        if($dimension -ceq 'RuntimeBinding'){$refs+=@("runtime-binding-evidence-sha256:$evidenceHash","runtime-binding-build-evidence-sha256:$([string]$evidence.buildEvidenceSha256)","runtime-binding-probe-source-sha256:$([string]$evidence.probeSourceSha256)","runtime-binding-raw-probe-sha256:$([string]$evidence.rawProbeEvidenceSha256)")}
        if($dimension -ceq 'AgentBuild'){$refs+=@("agent-build-evidence-sha256:$evidenceHash","agent-source-sha256:$([string]$evidence.source.sha256)","agent-provider-manifest-sha256:$([string]$evidence.provider.manifestSha256)","agent-artifact-sha256:$([string]$evidence.artifact.sha256)")}
        if($dimension -ceq 'AgentInjection'){$refs+=@("agent-injection-evidence-sha256:$evidenceHash","agent-injection-build-evidence-sha256:$([string]$evidence.agentBuildEvidenceSha256)","agent-injection-provider-manifest-sha256:$([string]$evidence.provider.manifestSha256)","agent-injection-artifact-sha256:$([string]$evidence.sessionInjection.copiedArtifactSha256)","agent-injection-source-sha256:$([string]$evidence.source.sha256)")+@($logRefs)}
        if($dimension -ceq 'LaunchCheck'){$refs+=@("launch-check-evidence-sha256:$evidenceHash","execution-plan-digest:$([string]$evidence.executionPlanDigest)")}
        if(-not $claims.ContainsKey($targetId)){$claims[$targetId]=@{}}
        if($dimension -ceq 'BuildVerified'){
            $buildRequirement=$evidence.java.buildRequirement
            $observedBuildJava=$evidence.java.observedBuildJava
            $buildJavaMajor=0;$observedBuildMajor=0
            if(-not [int]::TryParse([string]$buildRequirement.major,[ref]$buildJavaMajor) -or $buildJavaMajor -le 0 -or -not [int]::TryParse([string]$observedBuildJava.major,[ref]$observedBuildMajor) -or $observedBuildMajor -ne $buildJavaMajor -or [string]$buildRequirement.kind -notin @('Exact','Minimum','Preferred') -or [string]::IsNullOrWhiteSpace([string]$buildRequirement.source)){
                throw "TARGET_EVIDENCE_BUILD_JAVA_PROOF_INVALID:$targetId"
            }
            $buildJavaRefs=@($refs+@("build-java-major:$buildJavaMajor","build-java-observed-major:$observedBuildMajor","build-java-requirement-kind:$([string]$buildRequirement.kind)","build-java-requirement-source:$([string]$buildRequirement.source)"))
            $claims[$targetId]['BuildJava']=[pscustomobject]@{status='Supported';evidenceRefs=$buildJavaRefs}
        }
        $claims[$targetId][$dimension]=[pscustomobject]@{status='Supported';evidenceRefs=$refs}
    }
    return $claims
}

function New-MmtlLedgerDimension {
    param([Parameter(Mandatory)][string]$Status, [string[]]$EvidenceRefs = @())
    [pscustomobject][ordered]@{ status = $Status; evidenceRefs = @($EvidenceRefs) }
}

function Get-MmtlLogObservationEvidenceRefs {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Universe,[Parameter(Mandatory)]$Target)
    if(-not $script:MmtlLogObservationEvidenceCache){
        $logSource=Join-Path $PSScriptRoot '../Logs/StructuredLogWorkspace.psm1'
        $fixtureSource=Join-Path $PSScriptRoot '../../tests/StructuredLogs.Tests.ps1'
        if(-not(Test-Path -LiteralPath $logSource -PathType Leaf) -or -not(Test-Path -LiteralPath $fixtureSource -PathType Leaf)){throw 'LOG_OBSERVATION_EVIDENCE_SOURCE_MISSING'}
        $script:MmtlLogObservationEvidenceCache=[pscustomobject]@{
            sourceHash=(Get-FileHash -LiteralPath $logSource -Algorithm SHA256).Hash.ToLowerInvariant()
            fixtureHash=(Get-FileHash -LiteralPath $fixtureSource -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $refs=[Collections.Generic.List[string]]::new()
    $refs.Add("universe-sha256:$([string]$Universe.catalogHash)")
    if(-not [string]::IsNullOrWhiteSpace([string]$Target.sourceHash)){$refs.Add("source-sha256:$([string]$Target.sourceHash)")}
    if(-not [string]::IsNullOrWhiteSpace([string]$Target.authoritativeSource)){$refs.Add("source-url:$([string]$Target.authoritativeSource)")}
    $refs.Add("structured-log-source-sha256:$($script:MmtlLogObservationEvidenceCache.sourceHash)")
    $refs.Add("structured-log-fixture-sha256:$($script:MmtlLogObservationEvidenceCache.fixtureHash)")
    $refs.Add('test:StructuredLogs.Tests.ps1:observes-every-exact-available-target')
    return @($refs.ToArray())
}

function Get-MmtlRuntimeJavaEvidenceRefs {
    param([Parameter(Mandatory)]$Target)
    if (-not $Target.PSObject.Properties['runtimeJavaRequirement']) { return @() }
    $requirement = $Target.runtimeJavaRequirement
    if (-not $requirement) { return @() }
    foreach ($name in @('major', 'requirementKind', 'provenance')) { if (-not $requirement.PSObject.Properties[$name]) { return @() } }
    $major = 0
    if (-not [int]::TryParse([string]$requirement.major, [ref]$major) -or $major -le 0) { return @() }
    $kind = [string]$requirement.requirementKind
    if ($kind -notin @('AuthoritativeMetadata', 'CompatibilityFallback')) { return @() }
    $provenance = $requirement.provenance
    if (-not $provenance) { return @() }
    $sourceUrl = [string]$provenance.url
    $uri = $null
    if (-not [Uri]::TryCreate($sourceUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo.Length -gt 0) { return @() }
    if ($kind -eq 'AuthoritativeMetadata') {
        $hash = [string]$provenance.hash
        if ($hash -notmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$' -or [string]$requirement.metadataStatus -cne 'VERIFIED') { return @() }
        $algorithm = if ($hash.Length -eq 40) { 'sha1' } else { 'sha256' }
        return @("runtime-java-source-url:$sourceUrl", "runtime-java-$algorithm`:$hash")
    }
    if ([string]$requirement.source -cne 'MMTLCompatibilityFallback' -or [string]::IsNullOrWhiteSpace([string]$requirement.reason)) { return @() }
    @("runtime-java-source-url:$sourceUrl", "runtime-java-fallback-reason:$([string]$requirement.reason)")
}

function Get-MmtlRuntimeJavaBlockerEvidence {
    param([Parameter(Mandatory)]$Target)
    if(-not $Target.PSObject.Properties['runtimeJavaRequirement']){return $null}
    $requirement=$Target.runtimeJavaRequirement
    if(-not $requirement){return $null}
    foreach($name in @('requirementKind','source','major','provenance','metadataStatus')){if(-not $requirement.PSObject.Properties[$name]){return $null}}
    if([string]$requirement.requirementKind -cne 'Unknown' -or [string]$requirement.source -cne 'Unknown' -or $null -ne $requirement.major){return $null}
    $provenance=$requirement.provenance
    if(-not $provenance -or [string]$provenance.minecraftId -cne [string]$Target.minecraftId){return $null}
    $uri=$null
    if(-not [Uri]::TryCreate([string]$provenance.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'piston-meta.mojang.com' -or $uri.UserInfo.Length -gt 0){return $null}
    if([string]$requirement.metadataStatus -ceq 'NOT_IN_MOJANG_MANIFEST'){
        if([string]$provenance.sourceType -cne 'official-manifest-absence' -or $uri.AbsolutePath -cne '/mc/game/version_manifest_v2.json' -or [string]$provenance.reasonCode -cne 'MOJANG_TARGET_NOT_IN_VERSION_MANIFEST' -or [string]$provenance.manifestSha256 -notmatch '^[a-f0-9]{64}$'){return $null}
        $refs=@("runtime-java-manifest-url:$($uri.AbsoluteUri)","runtime-java-manifest-sha256:$([string]$provenance.manifestSha256)","runtime-java-target-absent:$([string]$Target.minecraftId)")
        return [pscustomobject][ordered]@{reasonCode='MOJANG_RUNTIME_JAVA_METADATA_UNAVAILABLE';source='Official Mojang version manifest';evidence=($refs -join '; ');attemptedRemediation='Verified the frozen Mojang version manifest snapshot and exact Minecraft ID. No manifest entry exists; no neighboring-version Java inference was applied. Await an authoritative per-version metadata source.';evidenceRefs=$refs}
    }
    if([string]$requirement.metadataStatus -ceq 'VERIFIED_NO_JAVA_VERSION'){
        if([string]$provenance.sourceType -cne 'official-version-json-absence' -or [string]$provenance.reasonCode -cne 'MOJANG_JAVA_VERSION_FIELD_ABSENT' -or [string]$provenance.manifestSha1 -notmatch '^[a-f0-9]{40}$' -or [string]$provenance.snapshotSha256 -notmatch '^[a-f0-9]{64}$'){return $null}
        if($uri.AbsolutePath -notmatch '^/v1/packages/(?<sha1>[a-f0-9]{40})/(?<version>.+)\.json$' -or $Matches.sha1 -cne [string]$provenance.manifestSha1){return $null}
        $versionId=[Uri]::UnescapeDataString([string]$Matches.version)
        if($versionId -cne [string]$Target.minecraftId){return $null}
        $refs=@("runtime-java-version-url:$($uri.AbsoluteUri)","runtime-java-version-manifest-sha1:$([string]$provenance.manifestSha1)","runtime-java-snapshot-sha256:$([string]$provenance.snapshotSha256)","runtime-java-javaVersion-absent:$([string]$Target.minecraftId)")
        return [pscustomobject][ordered]@{reasonCode='MOJANG_RUNTIME_JAVA_METADATA_UNAVAILABLE';source='Official Mojang per-version JSON';evidence=($refs -join '; ');attemptedRemediation='Verified the manifest SHA-1 and exact per-version JSON snapshot SHA-256. The exact JSON has no javaVersion field and no compatibility fallback applies. Await an authoritative Java requirement source.';evidenceRefs=$refs}
    }
    return $null
}

function Get-MmtlCompatibilityFamilyMap {
    param([Parameter(Mandatory)]$Universe, $FamilyManifest)
    $map = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    if (-not $FamilyManifest) { return ,$map }
    if ([string]$FamilyManifest.universeHash -cne [string]$Universe.catalogHash) { throw 'FAMILY_MANIFEST_UNIVERSE_HASH_MISMATCH' }
    $familyIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $universeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($target in @($Universe.targets | Where-Object { $_.availability -ceq 'Available' })) { [void]$universeIds.Add([string]$target.targetId) }
    foreach ($family in @($FamilyManifest.families)) {
        $familyId = [string]$family.familyId
        if ([string]::IsNullOrWhiteSpace($familyId) -or -not $familyIds.Add($familyId)) { throw "FAMILY_MANIFEST_INVALID:DUPLICATE_OR_EMPTY_FAMILY:$familyId" }
        foreach ($field in @('loaderId','minecraftIds','toolchain','buildJava','runtimeJava','projectDetectionStrategy','launchStrategy','agentBridge','evidence')) {
            if (-not $family.PSObject.Properties[$field]) { throw "FAMILY_MANIFEST_INVALID:MISSING_FIELD:${familyId}:$field" }
        }
        if (@($family.minecraftIds).Count -eq 0 -or @($family.evidence).Count -eq 0) { throw "FAMILY_MANIFEST_INVALID:MISSING_EXACT_SCOPE_OR_EVIDENCE:$familyId" }
        if ($family.PSObject.Properties['toolchainHash'] -and [string]$family.toolchainHash -notmatch '^(?i:[a-f0-9]{64})$') { throw "FAMILY_MANIFEST_INVALID:TOOLCHAIN_HASH:$familyId" }
        if ($family.PSObject.Properties['capabilities'] -and $family.capabilities) {
            foreach ($dimensionName in @($family.capabilities.PSObject.Properties.Name)) {
                if ($dimensionName -notin $script:LedgerDimensions) { throw "FAMILY_MANIFEST_INVALID:UNKNOWN_CAPABILITY:$familyId`:$dimensionName" }
                $capability = $family.capabilities.$dimensionName
                if ([string]$capability.status -notin $script:LedgerStatuses -or -not $capability.PSObject.Properties['evidenceRefs']) { throw "FAMILY_MANIFEST_INVALID:CAPABILITY_SHAPE:$familyId`:$dimensionName" }
                if ([string]$capability.status -ceq 'Supported' -and @($capability.evidenceRefs).Count -eq 0) { throw "FAMILY_MANIFEST_INVALID:SUPPORTED_CAPABILITY_WITHOUT_EVIDENCE:$familyId`:$dimensionName" }
                if ([string]$capability.status -ceq 'ExternallyBlocked') {
                    foreach ($field in @('reasonCode','source','evidence','attemptedRemediation')) {
                        if (-not $capability.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$capability.$field)) { throw "FAMILY_MANIFEST_INVALID:EXTERNAL_BLOCKER_EVIDENCE_MISSING:$familyId`:$dimensionName`:$field" }
                    }
                }
                foreach ($evidenceRef in @($capability.evidenceRefs)) { if ([string]::IsNullOrWhiteSpace([string]$evidenceRef)) { throw "FAMILY_MANIFEST_INVALID:EMPTY_CAPABILITY_EVIDENCE:$familyId`:$dimensionName" } }
            }
        }
        foreach ($minecraftId in @($family.minecraftIds)) {
            $targetId = "$([string]$family.loaderId)@$([string]$minecraftId)"
            if (-not $universeIds.Contains($targetId)) { throw "FAMILY_TARGET_NOT_IN_UNIVERSE:${familyId}:$targetId" }
            if ($map.ContainsKey($targetId)) { throw "FAMILY_TARGET_OVERLAP:$targetId" }
            $map.Add($targetId, $familyId)
        }
    }
    return ,$map
}

function Get-MmtlTargetLedgerStatus {
    param([Parameter(Mandatory)]$Dimensions)
    $statuses = @($script:LedgerDimensions | ForEach-Object { [string]$Dimensions.$_.status })
    if ($statuses -contains 'Unknown') { return 'Unknown' }
    if ($statuses -contains 'ExternallyBlocked') { return 'ExternallyBlocked' }
    if ($statuses -contains 'PendingImplementation') { return 'PendingImplementation' }
    if ($statuses -contains 'Unsupported') { return 'Unsupported' }
    if ($statuses -contains 'PartiallySupported') { return 'PartiallySupported' }
    'Supported'
}

function New-MmtlFullCompatibilityLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)][DateTimeOffset]$GeneratedAt,
        $FamilyManifest,
        $TargetEvidenceIndex,
        [string]$EvidenceRoot
    )

    $familyMap = Get-MmtlCompatibilityFamilyMap -Universe $Universe -FamilyManifest $FamilyManifest
    $targetEvidenceClaims=@{}
    if($TargetEvidenceIndex){if([string]::IsNullOrWhiteSpace($EvidenceRoot)){throw 'TARGET_EVIDENCE_ROOT_REQUIRED'};$targetEvidenceClaims=Get-MmtlTargetEvidenceClaims -Universe $Universe -Index $TargetEvidenceIndex -EvidenceRoot $EvidenceRoot}
    $familyCapabilities = @{}
    $familyDetails = @{}
    $manifestFamilies = if ($FamilyManifest -and $FamilyManifest.PSObject.Properties['families']) { @($FamilyManifest.families) } else { @() }
    foreach ($family in $manifestFamilies) {
        foreach ($minecraftId in @($family.minecraftIds)) {
            $targetId = "$([string]$family.loaderId)@$([string]$minecraftId)"
            $familyDetails[$targetId] = $family
            if ($family.PSObject.Properties['capabilities'] -and $family.capabilities) { $familyCapabilities[$targetId] = $family.capabilities }
        }
    }
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($target in @($Universe.targets | Sort-Object { [string]$_.targetId })) {
        if ([string]$target.availability -cne 'Available') { continue }
        $candidateResolved = ([string]$target.candidateStatus -ceq 'Resolved' -and @($target.loaderVersionCandidates).Count -gt 0)
        $dimensions = [ordered]@{}
        foreach ($name in $script:LedgerDimensions) {
            $status = switch ($name) {
                'Catalogued' { 'Supported' }
                'LoaderResolved' { if ($candidateResolved) { 'Supported' } else { 'Unknown' } }
                'RuntimeJava' { if (@(Get-MmtlRuntimeJavaEvidenceRefs -Target $target).Count) { 'Supported' } elseif (Get-MmtlRuntimeJavaBlockerEvidence -Target $target) { 'ExternallyBlocked' } else { 'PendingImplementation' } }
                'LogObservation' { 'Supported' }
                default { 'PendingImplementation' }
            }
            $capability = $null
            if ($familyCapabilities.ContainsKey([string]$target.targetId)) {
                $familyDimension = $familyCapabilities[[string]$target.targetId].PSObject.Properties[$name]
                if ($familyDimension) { $capability = $familyDimension.Value }
            }
            if ($capability) { $status = [string]$capability.status }
            $evidenceRefs = @()
            if ($status -ceq 'Supported') {
                $evidenceRefs += "universe-sha256:$([string]$Universe.catalogHash)"
                if (-not [string]::IsNullOrWhiteSpace([string]$target.sourceHash)) { $evidenceRefs += "source-sha256:$([string]$target.sourceHash)" }
                if (-not [string]::IsNullOrWhiteSpace([string]$target.authoritativeSource)) { $evidenceRefs += "source-url:$([string]$target.authoritativeSource)" }
            }
            if ($name -ceq 'RuntimeJava' -and $status -ceq 'Supported') { $evidenceRefs += @(Get-MmtlRuntimeJavaEvidenceRefs -Target $target) }
            if ($name -ceq 'LogObservation' -and $status -ceq 'Supported') { $evidenceRefs += @(Get-MmtlLogObservationEvidenceRefs -Universe $Universe -Target $target) }
            if ($name -ceq 'RuntimeJava' -and $status -ceq 'ExternallyBlocked' -and -not $capability) {
                $blocker=Get-MmtlRuntimeJavaBlockerEvidence -Target $target
                if(-not $blocker){throw "RUNTIME_JAVA_EXTERNAL_BLOCKER_EVIDENCE_INVALID:$([string]$target.targetId)"}
                $dimensions[$name]=[pscustomobject][ordered]@{status=$status;evidenceRefs=@($blocker.evidenceRefs);reasonCode=$blocker.reasonCode;source=$blocker.source;evidence=$blocker.evidence;attemptedRemediation=$blocker.attemptedRemediation}
                continue
            }
            if ($capability) { $evidenceRefs += @($capability.evidenceRefs) }
            if ($status -ceq 'ExternallyBlocked' -and $capability) {
                $dimensions[$name] = [pscustomobject][ordered]@{
                    status = $status
                    evidenceRefs = @($evidenceRefs | Select-Object -Unique)
                    reasonCode = [string]$capability.reasonCode
                    source = [string]$capability.source
                    evidence = [string]$capability.evidence
                    attemptedRemediation = [string]$capability.attemptedRemediation
                }
                continue
            }
            $dimensions[$name] = New-MmtlLedgerDimension -Status $status -EvidenceRefs $evidenceRefs
        }
        if($targetEvidenceClaims.ContainsKey([string]$target.targetId)){
            foreach($name in $targetEvidenceClaims[[string]$target.targetId].Keys){$claim=$targetEvidenceClaims[[string]$target.targetId][$name];$dimensions[$name]=New-MmtlLedgerDimension -Status ([string]$claim.status) -EvidenceRefs @($claim.evidenceRefs)}
        }
        $targets.Add([pscustomobject][ordered]@{
            targetId = [string]$target.targetId
            loaderId = [string]$target.loaderId
            minecraftId = [string]$target.minecraftId
            familyId = if ($familyMap.ContainsKey([string]$target.targetId)) { $familyMap[[string]$target.targetId] } else { $null }
            dimensions = [pscustomobject]$dimensions
            status = Get-MmtlTargetLedgerStatus -Dimensions ([pscustomobject]$dimensions)
            sourceHash = if ($target.PSObject.Properties['sourceHash']) { $target.sourceHash } else { $null }
            toolchainHash = if ($familyDetails.ContainsKey([string]$target.targetId) -and $familyDetails[[string]$target.targetId].PSObject.Properties['toolchainHash']) { [string]$familyDetails[[string]$target.targetId].toolchainHash } else { $null }
            targetSpecHash = Get-MmtlTargetSpecHash -Target $target
        })
    }

    $records = @($targets.ToArray())
    [pscustomobject][ordered]@{
        schemaVersion = 1
        auditStatus = 'IN_PROGRESS'
        generatedAt = $GeneratedAt.ToUniversalTime().ToString('o')
        universeHash = [string]$Universe.catalogHash
        candidateCatalogHash = if ($Universe.PSObject.Properties['candidateCatalogHash']) { $Universe.candidateCatalogHash } else { $null }
        targets = $records
        summary = Get-MmtlFullCompatibilityLedgerSummary -Targets $records
    }
}

function Get-MmtlFullCompatibilityLedgerSummary {
    param([Parameter(Mandatory)][object[]]$Targets)
    $unknown = @($Targets | Where-Object { $_.status -ceq 'Unknown' }).Count
    $pendingCount = 0
    foreach ($target in $Targets) {
        foreach ($name in $script:LedgerDimensions) {
            if ([string]$target.dimensions.$name.status -ceq 'PendingImplementation') { $pendingCount++ }
        }
    }
    [pscustomobject][ordered]@{
        targetCount = $Targets.Count
        unknownTargetCount = $unknown
        pendingImplementationDimensionCount = $pendingCount
        unassignedFamilyCount = @($Targets | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.familyId) }).Count
    }
}

function Test-MmtlFullCompatibilityLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ledger, [Parameter(Mandatory)]$Universe, $FamilyManifest, $TargetEvidenceIndex, [string]$EvidenceRoot, [switch]$RequireFamilies)

    $errors = [Collections.Generic.List[string]]::new()
    $targetEvidenceClaims=@{}
    if($TargetEvidenceIndex){try{if([string]::IsNullOrWhiteSpace($EvidenceRoot)){throw 'TARGET_EVIDENCE_ROOT_REQUIRED'};$targetEvidenceClaims=Get-MmtlTargetEvidenceClaims -Universe $Universe -Index $TargetEvidenceIndex -EvidenceRoot $EvidenceRoot}catch{$errors.Add($_.Exception.Message)}}
    $familyMap = $null
    try { $familyMap = Get-MmtlCompatibilityFamilyMap -Universe $Universe -FamilyManifest $FamilyManifest }
    catch { $errors.Add($_.Exception.Message) }
    $universeById = @{}
    foreach ($universeTarget in @($Universe.targets | Where-Object { $_.availability -ceq 'Available' })) { $universeById[[string]$universeTarget.targetId] = $universeTarget }
    $expected = @($Universe.targets | Where-Object { [string]$_.availability -ceq 'Available' } | ForEach-Object { [string]$_.targetId } | Sort-Object -Unique)
    $actualRows = @($Ledger.targets)
    $actual = @($actualRows | ForEach-Object { [string]$_.targetId } | Sort-Object -Unique)
    if (($expected -join "`n") -cne ($actual -join "`n") -or $actualRows.Count -ne $actual.Count) { $errors.Add('LEDGER_TARGET_SET_MISMATCH') }

    foreach ($group in @($actualRows | Group-Object { [string]$_.targetId } | Where-Object Count -gt 1)) {
        $errors.Add("LEDGER_DUPLICATE_TARGET:$($group.Name)")
    }
    foreach ($row in $actualRows) {
        $targetId = [string]$row.targetId
        if ($universeById.ContainsKey($targetId)) {
            $sourceTarget = $universeById[$targetId]
            if ([string]$row.loaderId -cne [string]$sourceTarget.loaderId -or [string]$row.minecraftId -cne [string]$sourceTarget.minecraftId) { $errors.Add("LEDGER_TARGET_IDENTITY_MISMATCH:$targetId") }
            if ([string]$row.targetSpecHash -cne (Get-MmtlTargetSpecHash -Target $sourceTarget)) { $errors.Add("LEDGER_TARGET_SPEC_HASH_MISMATCH:$targetId") }
            if ([string]$row.sourceHash -cne [string]$sourceTarget.sourceHash) { $errors.Add("LEDGER_SOURCE_HASH_MISMATCH:$targetId") }
            $expectedFamily = if ($familyMap -and $familyMap.ContainsKey($targetId)) { $familyMap[$targetId] } else { $null }
            if ([string]$row.familyId -cne [string]$expectedFamily) { $errors.Add("LEDGER_FAMILY_ASSIGNMENT_MISMATCH:$targetId") }
        }
        foreach ($name in $script:LedgerDimensions) {
            if (-not $row.dimensions -or -not $row.dimensions.PSObject.Properties[$name]) {
                $errors.Add("LEDGER_DIMENSION_MISSING:$($row.targetId):$name")
                continue
            }
            $dimension = $row.dimensions.$name
            if($targetEvidenceClaims.ContainsKey($targetId) -and $targetEvidenceClaims[$targetId].ContainsKey($name)){
                $claim=$targetEvidenceClaims[$targetId][$name]
                if([string]$dimension.status -cne [string]$claim.status -or @($claim.evidenceRefs|Where-Object{$_ -notin @($dimension.evidenceRefs)}).Count){$errors.Add("LEDGER_TARGET_EVIDENCE_MISMATCH:$targetId`:$name")}
            }
            if ([string]$dimension.status -cnotin $script:LedgerStatuses) { $errors.Add("LEDGER_STATUS_INVALID:$($row.targetId):$name") }
            if ([string]$dimension.status -cin @('Supported', 'PartiallySupported') -and @($dimension.evidenceRefs).Count -eq 0) { $errors.Add("LEDGER_CAPABILITY_EVIDENCE_MISSING:$($row.targetId):$name") }
            if($name -ceq 'LogObservation' -and $universeById.ContainsKey([string]$row.targetId)){
                $expectedLogEvidence=@(Get-MmtlLogObservationEvidenceRefs -Universe $Universe -Target $universeById[[string]$row.targetId])
                if([string]$dimension.status -cne 'Supported' -or @($expectedLogEvidence|Where-Object{$_ -notin @($dimension.evidenceRefs)}).Count -gt 0){$errors.Add("LOG_OBSERVATION_EVIDENCE_INVALID:$($row.targetId)")}
            }
            if ([string]$dimension.status -ceq 'ExternallyBlocked') {
                foreach ($field in @('reasonCode','source','evidence','attemptedRemediation')) {
                    if (-not $dimension.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$dimension.$field)) {
                        $errors.Add("EXTERNAL_BLOCKER_EVIDENCE_MISSING:$($row.targetId):$name")
                        break
                    }
                }
                if($name -ceq 'RuntimeJava' -and $universeById.ContainsKey($targetId)){
                    $blocker=Get-MmtlRuntimeJavaBlockerEvidence -Target $universeById[$targetId]
                    if(-not $blocker -or [string]$dimension.reasonCode -cne [string]$blocker.reasonCode -or [string]$dimension.source -cne [string]$blocker.source -or [string]$dimension.evidence -cne [string]$blocker.evidence -or [string]$dimension.attemptedRemediation -cne [string]$blocker.attemptedRemediation -or (@($blocker.evidenceRefs|Where-Object{$_ -notin @($dimension.evidenceRefs)}).Count -gt 0)){$errors.Add("RUNTIME_JAVA_EXTERNAL_BLOCKER_EVIDENCE_INVALID:$targetId")}
                }
            }
        }
        if ($row.dimensions -and @($script:LedgerDimensions | Where-Object { -not $row.dimensions.PSObject.Properties[$_] }).Count -eq 0) {
            $calculatedStatus = Get-MmtlTargetLedgerStatus -Dimensions $row.dimensions
            if ([string]$row.status -cne $calculatedStatus) { $errors.Add("LEDGER_TARGET_STATUS_MISMATCH:$targetId") }
        }
        if ($RequireFamilies -and [string]::IsNullOrWhiteSpace([string]$row.familyId)) { $errors.Add("LEDGER_FAMILY_UNASSIGNED:$targetId") }
    }

    $summary = Get-MmtlFullCompatibilityLedgerSummary -Targets $actualRows
    foreach ($field in @('targetCount','unknownTargetCount','pendingImplementationDimensionCount','unassignedFamilyCount')) {
        if (-not $Ledger.summary -or [int]$Ledger.summary.$field -ne [int]$summary.$field) { $errors.Add("LEDGER_SUMMARY_MISMATCH:$field") }
    }
    [pscustomobject][ordered]@{ isValid = ($errors.Count -eq 0); errors = @($errors.ToArray() | Sort-Object -Unique); summary = $summary }
}

Export-ModuleMember -Function New-MmtlFullCompatibilityLedger, Test-MmtlFullCompatibilityLedger, Get-MmtlFullCompatibilityLedgerSummary
