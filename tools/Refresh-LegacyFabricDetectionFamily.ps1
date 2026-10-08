[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),[string]$UniversePath,[string]$FamilyManifestPath,[string]$LedgerPath)
$ErrorActionPreference='Stop'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $UniversePath){$UniversePath=Join-Path $RepositoryRoot 'compatibility/universe-preview.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $RepositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $RepositoryRoot 'compatibility/ledger-template.json'}
$universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
$families=Get-Content -LiteralPath $FamilyManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'LegacyFabric' -and $_.availability -ceq 'Available'})
if($targets.Count -ne 76){throw "LEGACYFABRIC_TARGET_COUNT_MISMATCH:$($targets.Count)"}
$ids=@($targets|ForEach-Object{[string]$_.minecraftId})
if(@($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'LEGACYFABRIC_DUPLICATE_MINECRAFT_ID'}
$orderedIds=[string[]]$ids
[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
foreach($target in $targets){
    if([string]$target.targetId -cne ('LegacyFabric@'+[string]$target.minecraftId)){throw "LEGACYFABRIC_TARGET_ID_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){throw "LEGACYFABRIC_CANDIDATES_UNRESOLVED:$($target.targetId)"}
    if([string]$target.candidateSourceUrl -cne ('https://meta.legacyfabric.net/v2/versions/loader/'+[string]$target.minecraftId)){throw "LEGACYFABRIC_CANDIDATE_SOURCE_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateSourceHash -notmatch '^(?i:[a-f0-9]{64})$'){throw "LEGACYFABRIC_CANDIDATE_HASH_MISSING:$($target.targetId)"}
}
$detectorPath=Join-Path $RepositoryRoot 'common/src/ProjectDetector.psm1'
$adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/LegacyFabric.psm1'
$testPath=Join-Path $RepositoryRoot 'common/tests/LegacyFabricAdapter.Tests.ps1'
foreach($requiredPath in @($detectorPath,$adapterPath,$testPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "LEGACYFABRIC_DETECTION_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$familyId='legacyfabric-looming-build-launch-plan-v1'
$fixtureCommit='422896c188108632da97825f801719f0015b1b32'
$loomingCommit='d0842b87a7fa6c1a74a0f16f7be6aaaa9bee4c79'
$lf=[string][char]10
$basis=(@($familyId,$universeHash,$detectorHash,$adapterHash,$fixtureCommit,$loomingCommit)+$orderedIds) -join $lf
$toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($basis))).ToLowerInvariant()
$family=[ordered]@{
    familyId=$familyId
    loaderId='LegacyFabric'
    minecraftIds=@($orderedIds)
    toolchainHash=$toolchainHash
    toolchain=[ordered]@{id='LegacyLoomingBuildLaunchPlans';version='per-project resolved Legacy Looming; only non-executable Build/Launch plans, actual execution remains unverified'}
    buildJava=[ordered]@{status='PerProjectWrapperAndCompilerEvidence';evidenceRef='common/src/ProjectDetector.psm1'}
    runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
    projectDetectionStrategy='识别 Legacy Looming 与兼容的 Fabric 模组元数据；读取项目配置中的精确 Minecraft ID / LegacyFabric Loader 版本，并逐字绑定到 frozen Universe Available target 与该游戏版本专属 LegacyFabric Meta candidates。'
    buildStrategy='Legacy Looming 官方示例使用 Gradle Wrapper，并声明 ./gradlew build；对 exact detected target 仅生成非执行式 build 计划，执行仍要求 MMTL managed Session copy 与 trusted validation runner。'
    launchStrategy='Legacy Looming 官方示例声明 ./gradlew runClient；对 exact detected target 仅生成非执行式 Single Client 计划，LaunchCheck 保持未验证。'
    agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
    evidence=@('https://meta.legacyfabric.net/','https://github.com/Legacy-Fabric/legacy-looming/tree/d0842b87a7fa6c1a74a0f16f7be6aaaa9bee4c79','https://github.com/Legacy-Fabric/fabric-example-mod/blob/422896c188108632da97825f801719f0015b1b32/README.md','https://github.com/Legacy-Fabric/fabric-example-mod/blob/422896c188108632da97825f801719f0015b1b32/build.gradle',"legacy-looming-commit:$loomingCommit","legacyfabric-fixture-commit:$fixtureCommit","universe-sha256:$universeHash","project-detector-sha256:$detectorHash","legacyfabric-adapter-sha256:$adapterHash","legacyfabric-plan-test-sha256:$testHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-legacyfabric-target-from-legacy-looming-coordinates','test:LegacyFabricAdapter.Tests.ps1:detects-and-plans-every-frozen-legacyfabric-target-without-making-plans-executable')
    capabilities=[ordered]@{
        ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@('https://meta.legacyfabric.net/', 'https://github.com/Legacy-Fabric/legacy-looming',"project-detector-sha256:$detectorHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-legacyfabric-target-from-legacy-looming-coordinates')}
        BuildPlan=[ordered]@{status='Supported';evidenceRefs=@('https://github.com/Legacy-Fabric/legacy-looming/tree/d0842b87a7fa6c1a74a0f16f7be6aaaa9bee4c79','https://github.com/Legacy-Fabric/fabric-example-mod/blob/422896c188108632da97825f801719f0015b1b32/README.md','https://github.com/Legacy-Fabric/fabric-example-mod/blob/422896c188108632da97825f801719f0015b1b32/build.gradle',"legacy-looming-commit:$loomingCommit","legacyfabric-fixture-commit:$fixtureCommit","legacyfabric-adapter-sha256:$adapterHash","legacyfabric-plan-test-sha256:$testHash",'test:LegacyFabricAdapter.Tests.ps1:detects-and-plans-every-frozen-legacyfabric-target-without-making-plans-executable')}
        LaunchPlan=[ordered]@{status='Supported';evidenceRefs=@('https://github.com/Legacy-Fabric/legacy-looming/tree/d0842b87a7fa6c1a74a0f16f7be6aaaa9bee4c79','https://github.com/Legacy-Fabric/fabric-example-mod/blob/422896c188108632da97825f801719f0015b1b32/README.md','https://github.com/Legacy-Fabric/fabric-example-mod/blob/422896c188108632da97825f801719f0015b1b32/build.gradle',"legacy-looming-commit:$loomingCommit","legacyfabric-fixture-commit:$fixtureCommit","legacyfabric-adapter-sha256:$adapterHash","legacyfabric-plan-test-sha256:$testHash",'test:LegacyFabricAdapter.Tests.ps1:detects-and-plans-every-frozen-legacyfabric-target-without-making-plans-executable')}
    }
}
$familyRows=[Collections.Generic.List[object]]::new()
foreach($entry in @($families.families|Where-Object{$_.familyId -notin @($familyId,'legacyfabric-looming-project-detection-v1')})){$familyRows.Add($entry)}
$familyRows.Add([pscustomobject]$family)
$newFamilies=[ordered]@{schemaVersion=[int]$families.schemaVersion;auditStatus=[string]$families.auditStatus;universeHash=$universeHash;families=@($familyRows.ToArray()|Sort-Object loaderId,familyId);unassignedTargetPolicy=[string]$families.unassignedTargetPolicy}
Set-Content -LiteralPath $FamilyManifestPath -Value (ConvertTo-Json -InputObject $newFamilies -Depth 50) -Encoding utf8
$generatedAt=[DateTimeOffset]::UtcNow
if(Test-Path -LiteralPath $LedgerPath -PathType Leaf){try{$existingLedger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json -ErrorAction Stop;$generatedAt=[DateTimeOffset]::Parse([string]$existingLedger.generatedAt)}catch{}}
& (Join-Path $RepositoryRoot 'tools/Generate-FullCompatibilityLedger.ps1') -UniversePath $UniversePath -FamilyManifestPath $FamilyManifestPath -OutputPath $LedgerPath -GeneratedAt $generatedAt
