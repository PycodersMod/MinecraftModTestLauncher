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
$adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/ContractV2.psm1'
$testPath=Join-Path $RepositoryRoot 'common/tests/ProjectDetectorV2.Tests.ps1'
foreach($requiredPath in @($detectorPath,$adapterPath,$testPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "LEGACYFABRIC_DETECTION_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$familyId='legacyfabric-looming-project-detection-v1'
$lf=[string][char]10
$basis=(@($familyId,$universeHash,$detectorHash,$adapterHash)+$orderedIds) -join $lf
$toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($basis))).ToLowerInvariant()
$family=[ordered]@{
    familyId=$familyId
    loaderId='LegacyFabric'
    minecraftIds=@($orderedIds)
    toolchainHash=$toolchainHash
    toolchain=[ordered]@{id='LegacyLoomingProjectDetection';version='per-project resolved Legacy Looming; no Build or Launch support implied'}
    buildJava=[ordered]@{status='PerProjectWrapperAndCompilerEvidence';evidenceRef='common/src/ProjectDetector.psm1'}
    runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
    projectDetectionStrategy='识别 Legacy Looming 与兼容的 Fabric 模组元数据；读取项目配置中的精确 Minecraft ID / LegacyFabric Loader 版本，并逐字绑定到 frozen Universe Available target 与该游戏版本专属 LegacyFabric Meta candidates。'
    buildStrategy='尚未为该兼容家族声明 build task 计划支持。'
    launchStrategy='尚未为该兼容家族声明客户端或服务端启动计划支持。'
    agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
    evidence=@('https://meta.legacyfabric.net/','https://github.com/Legacy-Fabric/legacy-looming',"universe-sha256:$universeHash","project-detector-sha256:$detectorHash","legacyfabric-adapter-contract-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-legacyfabric-target-from-legacy-looming-coordinates')
    capabilities=[ordered]@{
        ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@('https://meta.legacyfabric.net/', 'https://github.com/Legacy-Fabric/legacy-looming',"project-detector-sha256:$detectorHash","legacyfabric-adapter-contract-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-legacyfabric-target-from-legacy-looming-coordinates')}
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
