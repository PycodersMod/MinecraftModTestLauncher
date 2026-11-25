[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$UniversePath,
    [string]$FamilyManifestPath,
    [string]$LedgerPath
)

$ErrorActionPreference='Stop'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $UniversePath){$UniversePath=Join-Path $RepositoryRoot 'compatibility/universe-preview.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $RepositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $RepositoryRoot 'compatibility/ledger-template.json'}
$universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
$families=Get-Content -LiteralPath $FamilyManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Fabric' -and $_.availability -ceq 'Available'})
if(-not $targets.Count){throw 'FABRIC_TARGETS_NOT_FOUND'}
$ids=@($targets|ForEach-Object{[string]$_.minecraftId})
if(@($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'FABRIC_DUPLICATE_MINECRAFT_ID'}
$orderedIds=[string[]]$ids
[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
foreach($target in $targets){
    if([string]$target.targetId -cne "Fabric@$([string]$target.minecraftId)"){throw "FABRIC_TARGET_ID_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){throw "FABRIC_CANDIDATES_UNRESOLVED:$($target.targetId)"}
}
$detectorPath=Join-Path $RepositoryRoot 'common/src/ProjectDetector.psm1'
$adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/Fabric.psm1'
$buildJavaResolverPath=Join-Path $RepositoryRoot 'common/src/BuildJavaResolver.psm1'
$testPath=Join-Path $RepositoryRoot 'common/tests/ProjectDetectorV2.Tests.ps1'
foreach($requiredPath in @($detectorPath,$adapterPath,$buildJavaResolverPath,$testPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "FABRIC_DETECTION_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$buildJavaResolverHash=(Get-FileHash -LiteralPath $buildJavaResolverPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$familySpecs=@(
    [pscustomobject]@{familyId='fabric-loom-remap-build-launch-plan-v1';pluginId='net.fabricmc.fabric-loom-remap';selector={param($id) if($id -match '^\d{2}w' -or $id -ceq '3D Shareware v1.34'){return $true};$match=[regex]::Match($id,'^(?<major>[0-9]+)\.(?<minor>[0-9]+)');if(-not $match.Success){throw "FABRIC_MINECRAFT_VERSION_UNPARSEABLE:$id"};$major=[int]$match.Groups['major'].Value;$minor=[int]$match.Groups['minor'].Value;($major -lt 26 -or ($major -eq 26 -and $minor -lt 1))};changePoint='Minecraft 1.21.11 and older use the remap plugin ID'},
    [pscustomobject]@{familyId='fabric-loom-unobfuscated-build-launch-plan-v1';pluginId='net.fabricmc.fabric-loom';selector={param($id) if($id -match '^\d{2}w' -or $id -ceq '3D Shareware v1.34'){return $false};$match=[regex]::Match($id,'^(?<major>[0-9]+)\.(?<minor>[0-9]+)');if(-not $match.Success){throw "FABRIC_MINECRAFT_VERSION_UNPARSEABLE:$id"};$major=[int]$match.Groups['major'].Value;$minor=[int]$match.Groups['minor'].Value;($major -gt 26 -or ($major -eq 26 -and $minor -ge 1))};changePoint='Minecraft 26.1 and newer use the non-remap plugin ID'}
)
$generatedFamilies=[Collections.Generic.List[object]]::new()
foreach($spec in $familySpecs){
    $memberIds=[string[]]@($orderedIds|Where-Object{& $spec.selector $_})
    if(-not $memberIds.Count){throw "FABRIC_LOOM_GENERATION_EMPTY:$($spec.familyId)"}
    $basis="$($spec.familyId)`n$universeHash`n$detectorHash`n$adapterHash`n$buildJavaResolverHash`n$($memberIds -join "`n")"
    $toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($basis))).ToLowerInvariant()
    $evidenceRefs=@(
        'https://docs.fabricmc.net/develop/loader/fabric-mod-json',
        'https://docs.fabricmc.net/develop/loom',
        'https://docs.fabricmc.net/develop/getting-started/building-a-mod',
        "plugin-generation:$($spec.changePoint)",
        "plugin-id:$($spec.pluginId)",
        "universe-sha256:$universeHash",
        "project-detector-sha256:$detectorHash",
        "fabric-adapter-sha256:$adapterHash",
        "build-java-resolver-sha256:$buildJavaResolverHash",
        'test:ProjectDetectorV2.Tests.ps1:detect-and-bind-all-exact-fabric-targets'
    )
    $generatedFamilies.Add([ordered]@{
        familyId=$spec.familyId;loaderId='Fabric';minecraftIds=@($memberIds);toolchainHash=$toolchainHash
        toolchain=[ordered]@{id=$spec.pluginId;version='project-resolved Loom version; exact plugin generation is family-bound'}
        buildJava=[ordered]@{status='PerProjectGradleWrapperAndCompilerEvidence';evidenceRef='common/src/ProjectDetector.psm1'}
        runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
        projectDetectionStrategy='识别 fabric.mod.json 与 Gradle Fabric Loom 项目；从项目配置读取精确 Minecraft ID / Loader 版本，并与 frozen Universe Available target 及官方候选逐字绑定。'
        buildStrategy='精确目标绑定后生成 Gradle Wrapper build 计划；计划要求 MMTL managed session copy 与受控验证 runner，不代表构建成功或允许任意项目自动执行。'
        launchStrategy='为精确目标生成 Loom runClient Single Client 计划；工作目录限定 MMTL managed session copy，LaunchCheck 未验证且计划不可直接执行。'
        agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
        evidence=$evidenceRefs
        capabilities=[ordered]@{
            BuildJava=[ordered]@{status='PartiallySupported';evidenceRefs=@("build-java-resolver-sha256:$buildJavaResolverHash","project-detector-sha256:$detectorHash",'test:JavaEvidence.Tests.ps1:wrapper-minimum-and-compiler-target')}
            ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@("project-detector-sha256:$detectorHash","fabric-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-fabric-targets')}
            BuildPlan=[ordered]@{status='Supported';evidenceRefs=@('https://docs.fabricmc.net/develop/loom',"plugin-id:$($spec.pluginId)","fabric-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-fabric-targets')}
            LaunchPlan=[ordered]@{status='Supported';evidenceRefs=@('https://docs.fabricmc.net/develop/loom',"plugin-id:$($spec.pluginId)","fabric-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-fabric-targets')}
        }
    })
}
$familyRows=[Collections.Generic.List[object]]::new()
foreach($entry in @($families.families|Where-Object{$_.familyId -cnotin @('fabric-project-metadata-detection-v1','fabric-loom-build-launch-plan-v1','fabric-loom-remap-build-launch-plan-v1','fabric-loom-unobfuscated-build-launch-plan-v1')})){$familyRows.Add($entry)}
foreach($entry in $generatedFamilies){$familyRows.Add([pscustomobject]$entry)}
$newFamilies=[ordered]@{
    schemaVersion=[int]$families.schemaVersion
    auditStatus=[string]$families.auditStatus
    universeHash=$universeHash
    families=@($familyRows.ToArray()|Sort-Object loaderId,familyId)
    unassignedTargetPolicy=[string]$families.unassignedTargetPolicy
}
$familiesJson=ConvertTo-Json -InputObject $newFamilies -Depth 50
Set-Content -LiteralPath $FamilyManifestPath -Value $familiesJson -Encoding utf8
$generatedAt=[DateTimeOffset]::UtcNow
if(Test-Path -LiteralPath $LedgerPath -PathType Leaf){
    try{$existingLedger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json -ErrorAction Stop;$generatedAt=[DateTimeOffset]::Parse([string]$existingLedger.generatedAt)}catch{}
}
& (Join-Path $RepositoryRoot 'tools/Generate-FullCompatibilityLedger.ps1') -UniversePath $UniversePath -FamilyManifestPath $FamilyManifestPath -OutputPath $LedgerPath -GeneratedAt $generatedAt
