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
$testPath=Join-Path $RepositoryRoot 'common/tests/ProjectDetectorV2.Tests.ps1'
foreach($requiredPath in @($detectorPath,$adapterPath,$testPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "FABRIC_DETECTION_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$basis="fabric-project-metadata-detection-v1`n$universeHash`n$detectorHash`n$adapterHash`n$($orderedIds -join "`n")"
$basisBytes=[Text.Encoding]::UTF8.GetBytes($basis)
$toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($basisBytes)).ToLowerInvariant()
$family=[ordered]@{
    familyId='fabric-project-metadata-detection-v1'
    loaderId='Fabric'
    minecraftIds=@($orderedIds)
    toolchainHash=$toolchainHash
    toolchain=[ordered]@{id='ProjectDetectionOnly';version='fabric.mod.json plus exact Gradle project properties'}
    buildJava=[ordered]@{status='NotAssessedByDetectionFamily';evidence=@()}
    runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
    projectDetectionStrategy='识别 fabric.mod.json 与 Gradle Fabric Loom 项目；从项目配置读取精确 Minecraft ID / Loader 版本，并与 frozen Universe Available target 及官方候选逐字绑定。'
    buildStrategy='本 family 仅证明项目探测与 exact target binding；BuildPlan、BuildJava、BuildVerified 留给有证据的 Loom/toolchain families。'
    launchStrategy='本 family 不声明 LaunchPlan 或 LaunchCheck。'
    agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
    evidence=@(
        'https://docs.fabricmc.net/develop/loader/fabric-mod-json',
        "universe-sha256:$universeHash",
        "project-detector-sha256:$detectorHash",
        "fabric-adapter-sha256:$adapterHash",
        'test:ProjectDetectorV2.Tests.ps1:detect-and-bind-all-exact-fabric-targets'
    )
    capabilities=[ordered]@{
        ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@(
            "project-detector-sha256:$detectorHash",
            "fabric-adapter-sha256:$adapterHash",
            'test:ProjectDetectorV2.Tests.ps1:detect-and-bind-all-exact-fabric-targets'
        )}
    }
}
$familyRows=[Collections.Generic.List[object]]::new()
foreach($entry in @($families.families|Where-Object familyId -CNE 'fabric-project-metadata-detection-v1')){$familyRows.Add($entry)}
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
