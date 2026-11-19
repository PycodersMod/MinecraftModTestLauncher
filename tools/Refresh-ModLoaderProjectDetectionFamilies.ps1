[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),[string]$UniversePath,[string]$FamilyManifestPath,[string]$LedgerPath)
$ErrorActionPreference='Stop'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $UniversePath){$UniversePath=Join-Path $RepositoryRoot 'compatibility/universe-preview.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $RepositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $RepositoryRoot 'compatibility/ledger-template.json'}
$universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
$families=Get-Content -LiteralPath $FamilyManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$detectorPath=Join-Path $RepositoryRoot 'common/src/ProjectDetector.psm1'
$testPath=Join-Path $RepositoryRoot 'common/tests/ProjectDetectorV2.Tests.ps1'
foreach($path in @($detectorPath,$testPath)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "MODLOADER_DETECTION_EVIDENCE_FILE_MISSING:$path"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$definitions=@(
    [pscustomobject]@{loaderId='ModLoader';count=42;familyId='modloader-mcp-source-project-detection-v1';catalog='compatibility/candidate-catalogs/ModLoader.json';source='https://mcarchive.net/mods/modloader'},
    [pscustomobject]@{loaderId='ModLoaderMP';count=20;familyId='modloadermp-mcp-source-project-detection-v1';catalog='compatibility/candidate-catalogs/ModLoaderMP.json';source='https://mcarchive.net/mods/modloadermp'}
)
$newFamilyIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$newFamilies=[Collections.Generic.List[object]]::new()
foreach($definition in $definitions){
    [void]$newFamilyIds.Add($definition.familyId)
    $catalogPath=Join-Path $RepositoryRoot $definition.catalog
    $catalog=Get-Content -LiteralPath $catalogPath -Raw|ConvertFrom-Json -ErrorAction Stop
    $targets=@($universe.targets|Where-Object{$_.loaderId -ceq $definition.loaderId -and $_.availability -ceq 'Available'})
    if($targets.Count -ne $definition.count){throw "$($definition.loaderId)_TARGET_COUNT_MISMATCH:$($targets.Count)"}
    if([int]$catalog.targetCount -ne $definition.count){throw "$($definition.loaderId)_CATALOG_TARGET_COUNT_MISMATCH"}
    $rows=[Collections.Generic.List[object]]::new()
    foreach($target in $targets){
        $targetId="$($definition.loaderId)@$([string]$target.minecraftId)"
        if([string]$target.targetId -cne $targetId){throw "TARGET_ID_MISMATCH:$targetId"}
        if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){throw "CANDIDATES_UNRESOLVED:$targetId"}
        if([string]$target.candidateSourceHash -notmatch '^(?i:[a-f0-9]{64})$'){throw "CANDIDATE_HASH_INVALID:$targetId"}
        $record=$catalog.results|Where-Object targetId -CEQ $targetId|Select-Object -First 1
        if(-not $record -or [string]$record.candidateStatus -cne 'Resolved' -or [string]$record.sourceHash -cne [string]$target.candidateSourceHash){throw "CANDIDATE_CATALOG_MISMATCH:$targetId"}
        $versions=@($target.loaderVersionCandidates|ForEach-Object{[string]$_.loaderVersion})
        $targetCandidateRows=@($target.loaderVersionCandidates|ForEach-Object{"$($_.loaderVersion)|$($_.artifactFilename)|$($_.sha256)"})
        $catalogCandidateRows=@($record.candidates|ForEach-Object{"$($_.loaderVersion)|$($_.artifactFilename)|$($_.sha256)"})
        if(($targetCandidateRows -join [char]10) -cne ($catalogCandidateRows -join [char]10)){throw "CANDIDATE_VERSION_MISMATCH:$targetId"}
        $rows.Add([pscustomobject]@{targetId=$targetId;minecraftId=[string]$target.minecraftId;sourceHash=[string]$target.candidateSourceHash;versions=$versions})
    }
    if(@($rows|Select-Object -ExpandProperty targetId -Unique).Count -ne $definition.count){throw "$($definition.loaderId)_DUPLICATE_TARGET"}
    $hashLines=[Collections.Generic.List[string]]::new()
    foreach($part in @($definition.familyId,$universeHash,$detectorHash)){[void]$hashLines.Add([string]$part)}
    foreach($row in @($rows|Sort-Object targetId)){[void]$hashLines.Add("$($row.targetId)|$($row.sourceHash)|$($row.versions -join ',')")}
    $toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashLines -join [string][char]10))).ToLowerInvariant()
    $newFamilies.Add([ordered]@{
        familyId=$definition.familyId;loaderId=$definition.loaderId;minecraftIds=@($rows|Sort-Object targetId|ForEach-Object minecraftId);toolchainHash=$toolchainHash
        toolchain=[ordered]@{id='ClassicMCPSourceDetection';version='historical source/layout inspection only; Build and Launch remain unverified'}
        buildJava=[ordered]@{status='PerProjectConfigurationRequired';evidenceRef='common/src/ProjectDetector.psm1'}
        runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
        projectDetectionStrategy='识别经典 MCP 源码目录中的 ModLoader API 形态：ModLoader 需 mod_* 类及 BaseMod/ModLoader 标记；ModLoaderMP 需 BaseModMp/ModLoaderMp 标记。仅在 conf/version.cfg 等版本配置恰好给出 frozen Universe 中的精确 Minecraft ID 时绑定目标；Gradle-less 项目不产生 Build/Launch 计划。'
        buildStrategy='尚未声明受支持的 Legacy MCP BuildPlan；不执行 MCP scripts、JAR patch 或未知构建工具。'
        launchStrategy='尚未声明受支持的 Legacy MCP LaunchPlan；不执行 startclient/startserver 或修改游戏 JAR。'
        agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
        evidence=@($definition.source,'https://legacymcmodding.github.io/ModLoader-JavaDoc/','https://minecraft.fandom.com/ru/wiki/Создание_модификаций_с_помощью_ModLoader_(Beta_1.7.3)','https://github.com/MCPHackers/RetroMCP-Java',"candidate-catalog:$($definition.catalog)","universe-sha256:$universeHash","project-detector-sha256:$detectorHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-frozen-modloader-target-from-mcp-source-layout')
        capabilities=[ordered]@{ProjectDetection=[ordered]@{status='Supported';evidenceRefs=@("project-detector-sha256:$detectorHash",'https://legacymcmodding.github.io/ModLoader-JavaDoc/','https://minecraft.fandom.com/ru/wiki/Создание_модификаций_с_помощью_ModLoader_(Beta_1.7.3)','https://github.com/MCPHackers/RetroMCP-Java','test:ProjectDetectorV2.Tests.ps1:detect-every-exact-frozen-modloader-target-from-mcp-source-layout')}}
    })
}
$rows=[Collections.Generic.List[object]]::new()
foreach($existing in @($families.families|Where-Object{$_.familyId -notin $newFamilyIds})){$rows.Add($existing)}
foreach($family in $newFamilies){$rows.Add($family)}
$manifest=[ordered]@{schemaVersion=[int]$families.schemaVersion;auditStatus=[string]$families.auditStatus;universeHash=$universeHash;families=@($rows.ToArray()|Sort-Object loaderId,familyId);unassignedTargetPolicy=[string]$families.unassignedTargetPolicy}
$schemaPath=Join-Path $RepositoryRoot 'common/schemas/compatibility-families.schema.json'
if(-not(Test-Json -Json ($manifest|ConvertTo-Json -Depth 50 -Compress) -SchemaFile $schemaPath)){throw 'FAMILY_MANIFEST_SCHEMA_INVALID'}
Set-Content -LiteralPath $FamilyManifestPath -Value (ConvertTo-Json -InputObject $manifest -Depth 50) -Encoding utf8
$generatedAt=[DateTimeOffset]::UtcNow
if(Test-Path -LiteralPath $LedgerPath -PathType Leaf){try{$existingLedger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json -ErrorAction Stop;$generatedAt=[DateTimeOffset]::Parse([string]$existingLedger.generatedAt)}catch{}}
& (Join-Path $RepositoryRoot 'tools/Generate-FullCompatibilityLedger.ps1') -UniversePath $UniversePath -FamilyManifestPath $FamilyManifestPath -OutputPath $LedgerPath -GeneratedAt $generatedAt
