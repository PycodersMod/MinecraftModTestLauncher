[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),[string]$UniversePath,[string]$FamilyManifestPath,[string]$LedgerPath)
$ErrorActionPreference='Stop'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $UniversePath){$UniversePath=Join-Path $RepositoryRoot 'compatibility/universe-preview.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $RepositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $RepositoryRoot 'compatibility/ledger-template.json'}
$universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
$families=Get-Content -LiteralPath $FamilyManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'OrnitheLoader' -and $_.availability -ceq 'Available'})
if($targets.Count -ne 406){throw "ORNITHE_TARGET_COUNT_MISMATCH:$($targets.Count)"}
$ids=@($targets|ForEach-Object{[string]$_.minecraftId})
if(@($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'ORNITHE_DUPLICATE_MINECRAFT_ID'}
$orderedIds=[string[]]$ids
[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
foreach($target in $targets){
    if([string]$target.targetId -cne ('OrnitheLoader@'+[string]$target.minecraftId)){throw "ORNITHE_TARGET_ID_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){throw "ORNITHE_CANDIDATES_UNRESOLVED:$($target.targetId)"}
    if([string]$target.candidateSourceUrl -cne ('https://meta.ornithemc.net/v2/versions/loader/'+[string]$target.minecraftId)){throw "ORNITHE_CANDIDATE_SOURCE_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateSourceHash -notmatch '^(?i:[a-f0-9]{64})$'){throw "ORNITHE_CANDIDATE_HASH_MISSING:$($target.targetId)"}
}
$detectorPath=Join-Path $RepositoryRoot 'common/src/ProjectDetector.psm1'
$adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/Ornithe.psm1'
$buildJavaResolverPath=Join-Path $RepositoryRoot 'common/src/BuildJavaResolver.psm1'
$testPath=Join-Path $RepositoryRoot 'common/tests/OrnitheAdapter.Tests.ps1'
foreach($requiredPath in @($detectorPath,$adapterPath,$buildJavaResolverPath,$testPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "ORNITHE_DETECTION_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$buildJavaResolverHash=(Get-FileHash -LiteralPath $buildJavaResolverPath -Algorithm SHA256).Hash.ToLowerInvariant()
$testHash=(Get-FileHash -LiteralPath $testPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$familyId='ornithemc-ploceus-project-detection-v1'
$lf=[string][char]10
$basis=(@($familyId,$universeHash,$detectorHash,$adapterHash,$buildJavaResolverHash)+$orderedIds) -join $lf
$toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($basis))).ToLowerInvariant()
$family=[ordered]@{
    familyId=$familyId
    loaderId='OrnitheLoader'
    minecraftIds=@($orderedIds)
    toolchainHash=$toolchainHash
    toolchain=[ordered]@{id='PloceusBuildLaunchPlans';version='per-project resolved Ploceus; only non-executable Build/Launch plans, actual execution remains unverified'}
    buildJava=[ordered]@{status='PerProjectWrapperAndCompilerEvidence';evidenceRef='common/src/ProjectDetector.psm1'}
    runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
    projectDetectionStrategy='识别 Ploceus 与 net.ornithemc:ornithe-loader 项目依赖；读取项目中的精确 Minecraft ID / Ornithe Loader 版本，并逐字绑定到 frozen Universe Available target 与其专属 Ornithe Meta candidates。'
    buildStrategy='Ploceus extends Fabric/Quilt Loom. For an exact detected Ploceus Gradle Wrapper project, generate a non-executable build task plan; execution requires an MMTL managed Session copy and trusted validation runner. Ploceus inheritance of Loom task semantics is an explicit inference from the official plugin description and official Ornithe project build file.'
    launchStrategy='For an exact detected Ploceus Gradle Wrapper project, generate a non-executable Single Client runClient plan. LaunchCheck remains unverified; the plan cannot be executed without the trusted validation runner.'
    agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
    evidence=@('https://meta.ornithemc.net/','https://github.com/OrnitheMC/ploceus','https://github.com/OrnitheMC/modmenu/blob/1.13/build.gradle','https://docs.fabricmc.net/develop/loom','https://github.com/FabricMC/fabric-docs/blob/main/versions/1.21.1/develop/getting-started/launching-the-game.md',"universe-sha256:$universeHash","project-detector-sha256:$detectorHash","ornithe-adapter-sha256:$adapterHash","build-java-resolver-sha256:$buildJavaResolverHash","ornithe-plan-test-sha256:$testHash",'test:OrnitheAdapter.Tests.ps1:detects-and-plans-every-frozen-ornithe-target-without-making-plans-executable')
    capabilities=[ordered]@{
        BuildJava=[ordered]@{status='PartiallySupported';evidenceRefs=@("build-java-resolver-sha256:$buildJavaResolverHash","project-detector-sha256:$detectorHash",'test:JavaEvidence.Tests.ps1:wrapper-minimum-and-compiler-target')}
        ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@('https://meta.ornithemc.net/','https://github.com/OrnitheMC/ploceus',"project-detector-sha256:$detectorHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-ornithe-target-from-ploceus-coordinates')}
        BuildPlan=[ordered]@{status='Supported';evidenceRefs=@('https://github.com/OrnitheMC/ploceus','https://github.com/OrnitheMC/modmenu/blob/1.13/build.gradle','https://docs.fabricmc.net/develop/loom',"ornithe-adapter-sha256:$adapterHash","ornithe-plan-test-sha256:$testHash",'test:OrnitheAdapter.Tests.ps1:detects-and-plans-every-frozen-ornithe-target-without-making-plans-executable')}
        LaunchPlan=[ordered]@{status='Supported';evidenceRefs=@('https://github.com/OrnitheMC/ploceus','https://github.com/OrnitheMC/modmenu/blob/1.13/build.gradle','https://docs.fabricmc.net/develop/loom','https://github.com/FabricMC/fabric-docs/blob/main/versions/1.21.1/develop/getting-started/launching-the-game.md',"ornithe-adapter-sha256:$adapterHash","ornithe-plan-test-sha256:$testHash",'test:OrnitheAdapter.Tests.ps1:detects-and-plans-every-frozen-ornithe-target-without-making-plans-executable')}
    }
}
$familyRows=[Collections.Generic.List[object]]::new()
foreach($entry in @($families.families|Where-Object{$_.familyId -cne $familyId})){$familyRows.Add($entry)}
$familyRows.Add([pscustomobject]$family)
$newFamilies=[ordered]@{schemaVersion=[int]$families.schemaVersion;auditStatus=[string]$families.auditStatus;universeHash=$universeHash;families=@($familyRows.ToArray()|Sort-Object loaderId,familyId);unassignedTargetPolicy=[string]$families.unassignedTargetPolicy}
Set-Content -LiteralPath $FamilyManifestPath -Value (ConvertTo-Json -InputObject $newFamilies -Depth 50) -Encoding utf8
$generatedAt=[DateTimeOffset]::UtcNow
if(Test-Path -LiteralPath $LedgerPath -PathType Leaf){try{$existingLedger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json -ErrorAction Stop;$generatedAt=[DateTimeOffset]::Parse([string]$existingLedger.generatedAt)}catch{}}
& (Join-Path $RepositoryRoot 'tools/Generate-FullCompatibilityLedger.ps1') -UniversePath $UniversePath -FamilyManifestPath $FamilyManifestPath -OutputPath $LedgerPath -GeneratedAt $generatedAt
