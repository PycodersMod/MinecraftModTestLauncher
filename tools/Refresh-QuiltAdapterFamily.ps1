[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),[string]$UniversePath,[string]$FamilyManifestPath,[string]$LedgerPath)
$ErrorActionPreference='Stop'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $UniversePath){$UniversePath=Join-Path $RepositoryRoot 'compatibility/universe-preview.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $RepositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $RepositoryRoot 'compatibility/ledger-template.json'}
$universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
$families=Get-Content -LiteralPath $FamilyManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Quilt' -and $_.availability -ceq 'Available'})
if($targets.Count -ne 441){throw "QUILT_TARGET_COUNT_MISMATCH:$($targets.Count)"}
$ids=@($targets|ForEach-Object{[string]$_.minecraftId})
if(@($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'QUILT_DUPLICATE_MINECRAFT_ID'}
$orderedIds=[string[]]$ids
[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
foreach($target in $targets){
    if([string]$target.targetId -cne ('Quilt@'+[string]$target.minecraftId)){throw "QUILT_TARGET_ID_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){throw "QUILT_CANDIDATES_UNRESOLVED:$($target.targetId)"}
}
$detectorPath=Join-Path $RepositoryRoot 'common/src/ProjectDetector.psm1'
$adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/Quilt.psm1'
$testPath=Join-Path $RepositoryRoot 'common/tests/ProjectDetectorV2.Tests.ps1'
foreach($requiredPath in @($detectorPath,$adapterPath,$testPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "QUILT_ADAPTER_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$familyId='quilt-loom-build-launch-plan-v1'
$lf=[string][char]10
$basis=(@($familyId,$universeHash,$detectorHash,$adapterHash)+$orderedIds) -join $lf
$toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($basis))).ToLowerInvariant()
$family=[ordered]@{
    familyId=$familyId;loaderId='Quilt';minecraftIds=@($orderedIds);toolchainHash=$toolchainHash
    toolchain=[ordered]@{id='QuiltLoomBuildLaunchPlan';version='project-resolved Quilt Loom version; plan contract remains version-independent'}
    buildJava=[ordered]@{status='PerProjectGradleWrapperAndCompilerEvidence';evidenceRef='common/src/ProjectDetector.psm1'}
    runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
    projectDetectionStrategy='识别 Quilt mod 元数据与 Gradle Quilt Loom 项目；从项目配置读取精确 Minecraft ID / Quilt Loader 版本，并与 frozen Universe Available target 及官方候选逐字绑定。'
    buildStrategy='精确目标绑定后生成 Gradle Wrapper build 计划；计划要求 MMTL managed session copy 与受控验证 runner，不代表构建成功或允许任意项目自动执行。'
    launchStrategy='为精确目标生成 Quilt Loom runClient Single Client 计划；工作目录限定 MMTL managed session copy，LaunchCheck 未验证且计划不可直接执行。'
    agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
    evidence=@('https://github.com/QuiltMC/quilt-loom','https://github.com/QuiltMC/quilt-loader',"universe-sha256:$universeHash","project-detector-sha256:$detectorHash","quilt-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-quilt-targets')
    capabilities=[ordered]@{
        ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@("project-detector-sha256:$detectorHash","quilt-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-quilt-targets')}
        BuildPlan=[ordered]@{status='Supported';evidenceRefs=@('https://github.com/QuiltMC/quilt-loom',"quilt-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-quilt-targets')}
        LaunchPlan=[ordered]@{status='Supported';evidenceRefs=@('https://github.com/QuiltMC/quilt-loom',"quilt-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-quilt-targets')}
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
