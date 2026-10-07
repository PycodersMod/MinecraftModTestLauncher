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
$targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'NeoForge' -and $_.availability -ceq 'Available'})
if($targets.Count -ne 23){throw "NEOFORGE_TARGET_COUNT_MISMATCH:$($targets.Count)"}
$ids=@($targets|ForEach-Object{[string]$_.minecraftId})
if(@($ids|Select-Object -Unique).Count -ne $ids.Count){throw 'NEOFORGE_DUPLICATE_MINECRAFT_ID'}
$orderedIds=[string[]]$ids
[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
foreach($target in $targets){
    if([string]$target.targetId -cne "NeoForge@$([string]$target.minecraftId)"){throw "NEOFORGE_TARGET_ID_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){throw "NEOFORGE_CANDIDATES_UNRESOLVED:$($target.targetId)"}
}
$detectorPath=Join-Path $RepositoryRoot 'common/src/ProjectDetector.psm1'
$adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/NeoForge.psm1'
$testPath=Join-Path $RepositoryRoot 'common/tests/ProjectDetectorV2.Tests.ps1'
foreach($requiredPath in @($detectorPath,$adapterPath,$testPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "NEOFORGE_ADAPTER_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$familyId='neoforge-gradle-build-launch-plan-v1'
$basis="$familyId`n$universeHash`n$detectorHash`n$adapterHash`n$($orderedIds -join "`n")"
$basisBytes=[Text.Encoding]::UTF8.GetBytes($basis)
$toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($basisBytes)).ToLowerInvariant()
$family=[ordered]@{
    familyId=$familyId
    loaderId='NeoForge'
    minecraftIds=@($orderedIds)
    toolchainHash=$toolchainHash
    toolchain=[ordered]@{id='NeoGradleOrModDevGradle';version='project-resolved toolchain version; plan contract is version-independent'}
    buildJava=[ordered]@{status='PerProjectGradleWrapperAndCompilerEvidence';evidenceRef='common/src/ProjectDetector.psm1'}
    runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
    projectDetectionStrategy='识别 neoforge.mods.toml 与 Gradle NeoGradle 或 ModDevGradle 项目；从项目配置读取精确 Minecraft ID / Loader 版本，并逐字绑定 frozen Universe 的 Available target 与官方候选。'
    buildStrategy='精确目标绑定后生成 Gradle Wrapper build 计划；计划要求 MMTL managed session copy 与受控验证 runner，不代表构建成功或允许任意项目自动执行。'
    launchStrategy='为精确目标生成 NeoGradle/ModDevGradle runClient Single Client 计划；工作目录限定 MMTL managed session copy，LaunchCheck 未验证且计划不可直接执行。'
    agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
    evidence=@(
        'https://github.com/neoforged/NeoGradle',
        'https://github.com/neoforged/ModDevGradle',
        'https://github.com/neoforged/Documentation/blob/main/docs/gettingstarted/index.md',
        'https://github.com/NeoForgeMDKs',
        "universe-sha256:$universeHash",
        "project-detector-sha256:$detectorHash",
        "neoforge-adapter-sha256:$adapterHash",
        'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-neoforge-targets'
    )
    capabilities=[ordered]@{
        ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@("project-detector-sha256:$detectorHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-neoforge-targets')}
        BuildPlan=[ordered]@{status='Supported';evidenceRefs=@('https://github.com/neoforged/Documentation/blob/main/docs/gettingstarted/index.md',"neoforge-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-neoforge-targets')}
        LaunchPlan=[ordered]@{status='Supported';evidenceRefs=@('https://github.com/neoforged/Documentation/blob/main/docs/gettingstarted/index.md',"neoforge-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-bind-and-plan-all-exact-neoforge-targets')}
    }
}
$familyRows=[Collections.Generic.List[object]]::new()
foreach($entry in @($families.families|Where-Object{$_.familyId -cne $familyId})){$familyRows.Add($entry)}
$familyRows.Add([pscustomobject]$family)
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
