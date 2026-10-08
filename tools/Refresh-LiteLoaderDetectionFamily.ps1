[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),[string]$UniversePath,[string]$CandidateCatalogPath,[string]$FamilyManifestPath,[string]$LedgerPath)
$ErrorActionPreference='Stop'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $UniversePath){$UniversePath=Join-Path $RepositoryRoot 'compatibility/universe-preview.json'}
if(-not $CandidateCatalogPath){$CandidateCatalogPath=Join-Path $RepositoryRoot 'compatibility/candidate-catalogs/LiteLoader.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $RepositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $RepositoryRoot 'compatibility/ledger-template.json'}
$universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
$catalog=Get-Content -LiteralPath $CandidateCatalogPath -Raw|ConvertFrom-Json -ErrorAction Stop
$families=Get-Content -LiteralPath $FamilyManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'LiteLoader' -and $_.availability -ceq 'Available'})
if($targets.Count -ne 16){throw "LITELOADER_TARGET_COUNT_MISMATCH:$($targets.Count)"}
if([int]$catalog.resultCount -ne 16 -or [int]$catalog.targetCount -ne 16){throw 'LITELOADER_CANDIDATE_CATALOG_COUNT_MISMATCH'}
$familyId='liteloader-project-metadata-detection-v1'
$orderedTargets=[Collections.Generic.List[object]]::new()
foreach($target in $targets){
    if([string]$target.targetId -cne ('LiteLoader@'+[string]$target.minecraftId)){throw "LITELOADER_TARGET_ID_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){throw "LITELOADER_CANDIDATES_UNRESOLVED:$($target.targetId)"}
    if([string]$target.candidateSourceUrl -cne 'https://dl.liteloader.com/versions/versions.json' -or [string]$target.candidateSourceHash -notmatch '^(?i:[a-f0-9]{64})$'){throw "LITELOADER_CANDIDATE_PROVENANCE_INVALID:$($target.targetId)"}
    $record=$catalog.results|Where-Object targetId -CEQ $target.targetId|Select-Object -First 1
    if(-not $record -or [string]$record.candidateStatus -cne 'Resolved' -or [string]$record.sourceUrl -cne [string]$target.candidateSourceUrl -or [string]$record.sourceHash -cne [string]$target.candidateSourceHash){throw "LITELOADER_CATALOG_RECORD_MISMATCH:$($target.targetId)"}
    $targetVersions=@($target.loaderVersionCandidates|ForEach-Object{[string]$_})
    $catalogVersions=@($record.loaderVersions|ForEach-Object{[string]$_})
    if(($targetVersions -join [char]10) -cne ($catalogVersions -join [char]10) -or [int]$record.candidateCount -ne $targetVersions.Count){throw "LITELOADER_CATALOG_CANDIDATES_MISMATCH:$($target.targetId)"}
    $orderedTargets.Add([pscustomobject]@{targetId=[string]$target.targetId;minecraftId=[string]$target.minecraftId;versions=$targetVersions;sourceHash=[string]$target.candidateSourceHash})
}
if(@($orderedTargets|Select-Object -ExpandProperty targetId -Unique).Count -ne 16){throw 'LITELOADER_DUPLICATE_TARGET_ID'}
$orderedTargetRows=[object[]]@($orderedTargets.ToArray()|Sort-Object targetId)
$detectorPath=Join-Path $RepositoryRoot 'common/src/ProjectDetector.psm1'
$adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/ContractV2.psm1'
foreach($requiredPath in @($detectorPath,$adapterPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "LITELOADER_DETECTION_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$hashLines=[Collections.Generic.List[string]]::new()
foreach($value in @($familyId,$universeHash,$detectorHash,$adapterHash)){ $hashLines.Add([string]$value) }
foreach($row in $orderedTargetRows){$hashLines.Add("$($row.targetId)|$($row.sourceHash)|$($row.versions -join ',')")}
$hashBasis=$hashLines -join [string][char]10
$toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()
$docsBase='https://www.liteloader.com/explore/docs/'
$family=[ordered]@{
    familyId=$familyId
    loaderId='LiteLoader'
    minecraftIds=@($orderedTargetRows|ForEach-Object{$_.minecraftId})
    toolchainHash=$toolchainHash
    toolchain=[ordered]@{id='LiteLoaderProjectMetadata';version='per-project historical Gradle configuration; no Build support implied'}
    buildJava=[ordered]@{status='PerProjectWrapperAndCompilerEvidence';evidenceRef='common/src/ProjectDetector.psm1'}
    runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
    projectDetectionStrategy='识别 LiteLoader Gradle 插件标记及 litemod.json；从项目配置读取精确 Minecraft ID 与 LiteLoader 版本，并逐字绑定到 frozen Universe Available target 及官方 LiteLoader versions.json 候选。'
    buildStrategy='尚未声明 BuildPlan 支持。官方历史版本元数据指向 HTTP Maven 仓库；安全核验完成前不下载或执行历史构建依赖。'
    launchStrategy='官方历史安装说明使用 LiteLoaderTweaker 与旧版依赖仓库；本 family 不声明可执行启动计划。'
    agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
    evidence=@('https://dl.liteloader.com/versions/versions.json',"source-sha256:$([string]$catalog.results[0].sourceHash)","universe-sha256:$universeHash","project-detector-sha256:$detectorHash","historical-adapter-contract-sha256:$adapterHash",("$($docsBase)dev%3Alitemod.json"),("$($docsBase)user%3Ainstall%3Amanual%3A1.7.10"),'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-liteloader-target-from-official-metadata-candidates')
    capabilities=[ordered]@{
        ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@('https://dl.liteloader.com/versions/versions.json',("$($docsBase)dev%3Alitemod.json"),"project-detector-sha256:$detectorHash","historical-adapter-contract-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-liteloader-target-from-official-metadata-candidates')}
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
