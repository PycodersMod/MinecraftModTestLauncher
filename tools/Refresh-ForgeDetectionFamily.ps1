[CmdletBinding()]
param(
    [string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),
    [string]$UniversePath,
    [string]$FamilyManifestPath,
    [string]$LedgerPath,
    [string]$ForgeMdkCatalogPath
)
$ErrorActionPreference='Stop'
$RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot)
if(-not $UniversePath){$UniversePath=Join-Path $RepositoryRoot 'compatibility/universe-preview.json'}
if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $RepositoryRoot 'compatibility/families.json'}
if(-not $LedgerPath){$LedgerPath=Join-Path $RepositoryRoot 'compatibility/ledger-template.json'}
if(-not $ForgeMdkCatalogPath){$ForgeMdkCatalogPath=Join-Path $RepositoryRoot 'compatibility/forge-mdk-generations.json'}
$universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
$families=Get-Content -LiteralPath $FamilyManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
$catalog=Get-Content -LiteralPath $ForgeMdkCatalogPath -Raw|ConvertFrom-Json -ErrorAction Stop
$targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Forge' -and $_.availability -ceq 'Available'})
if($targets.Count -ne 76){throw "FORGE_TARGET_COUNT_MISMATCH:$($targets.Count)"}
if([string]$catalog.universeHash -cne [string]$universe.catalogHash -or [int]$catalog.targetCount -ne $targets.Count){throw 'FORGE_MDK_CATALOG_UNIVERSE_MISMATCH'}
$catalogCore=[pscustomobject][ordered]@{schemaVersion=[int]$catalog.schemaVersion;generatedAt=[string]$catalog.generatedAt;auditStatus=[string]$catalog.auditStatus;universeHash=[string]$catalog.universeHash;targetCount=[int]$catalog.targetCount;targets=@($catalog.targets)}
$expectedCatalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $catalogCore -Depth 20 -Compress)))).ToLowerInvariant()
if([string]$catalog.catalogHash -cne $expectedCatalogHash){throw 'FORGE_MDK_CATALOG_HASH_MISMATCH'}
$targetIds=@($targets|ForEach-Object{[string]$_.targetId}|Sort-Object -Unique)
$catalogTargetIds=@($catalog.targets|ForEach-Object{[string]$_.targetId}|Sort-Object -Unique)
if(($targetIds -join "`n") -cne ($catalogTargetIds -join "`n")){throw 'FORGE_MDK_CATALOG_TARGET_SET_MISMATCH'}
foreach($target in $targets){
    if([string]$target.targetId -cne ('Forge@'+[string]$target.minecraftId)){throw "FORGE_TARGET_ID_MISMATCH:$($target.targetId)"}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){throw "FORGE_CANDIDATES_UNRESOLVED:$($target.targetId)"}
}
$detectorPath=Join-Path $RepositoryRoot 'common/src/ProjectDetector.psm1'
$adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/Forge.psm1'
$buildJavaResolverPath=Join-Path $RepositoryRoot 'common/src/BuildJavaResolver.psm1'
$testPath=Join-Path $RepositoryRoot 'common/tests/ProjectDetectorV2.Tests.ps1'
foreach($requiredPath in @($detectorPath,$adapterPath,$buildJavaResolverPath,$testPath)){if(-not(Test-Path -LiteralPath $requiredPath -PathType Leaf)){throw "FORGE_DETECTION_EVIDENCE_FILE_MISSING:$requiredPath"}}
$detectorHash=(Get-FileHash -LiteralPath $detectorPath -Algorithm SHA256).Hash.ToLowerInvariant()
$adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
$buildJavaResolverHash=(Get-FileHash -LiteralPath $buildJavaResolverPath -Algorithm SHA256).Hash.ToLowerInvariant()
$universeHash=[string]$universe.catalogHash
if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
$lf=[string][char]10
$catalogGroups=[Collections.Generic.List[object]]::new()
foreach($group in @($catalog.targets|Where-Object status -CEQ 'Available'|Group-Object forgeGradleSpec)){$catalogGroups.Add([pscustomobject]@{kind='Mdk';name=[string]$group.Name;rows=@($group.Group)})}
foreach($group in @($catalog.targets|Where-Object sourceProjectType -CEQ 'GradleProject'|Group-Object {"$($_.alternateForgeGradleSpec)|$($_.alternateGradleDistributionUrl)"})){$catalogGroups.Add([pscustomobject]@{kind='SourceGradle';name=[string]$group.Name;rows=@($group.Group)})}
$overlayRows=@($catalog.targets|Where-Object sourceProjectType -CEQ 'ForgeSourceOverlay')
if($overlayRows.Count){$catalogGroups.Add([pscustomobject]@{kind='SourceOverlay';name='ForgeSourceOverlay';rows=$overlayRows})}
$newForgeFamilies=[Collections.Generic.List[object]]::new()
foreach($group in $catalogGroups){
    $rows=@($group.rows|Sort-Object targetId)
    if($group.kind -eq 'Mdk'){$familyId='forge-gradle-spec-'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$group.name))).ToLowerInvariant().Substring(0,12));$toolchainId="ForgeGradleSpec:$($group.name)"}
    elseif($group.kind -eq 'SourceGradle'){$familyId='forge-gradle-source-'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$group.name))).ToLowerInvariant().Substring(0,12));$toolchainId="ForgeGradleSpec:$((([string]$group.name)-split '\|',2)[0])"}
    else{$familyId='forge-legacy-source-overlay-v1';$toolchainId='ForgeSourceOverlay'}
    $orderedIds=[string[]]@($rows|ForEach-Object{([string]$_.targetId -split '@',2)[1]});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
    $basisRows=if($group.kind -eq 'Mdk'){@($rows|ForEach-Object{"$($_.targetId)|$($_.forgeCoordinate)|$($_.archiveSha256)|$($_.buildGradleSha256)|$($_.forgeGradleSpec)|$($_.gradleDistributionUrl)|$($_.buildJavaMajor)"})}else{@($rows|ForEach-Object{"$($_.targetId)|$($_.forgeCoordinate)|$($_.alternateArchiveSha256)|$($_.alternateBuildGradleSha256)|$($_.alternateForgeGradleSpec)|$($_.alternateGradleDistributionUrl)|$($_.alternateBuildJavaMajor)"})}
    $basis=(@($familyId,$universeHash,[string]$catalog.catalogHash,$detectorHash,$adapterHash,$buildJavaResolverHash)+$basisRows) -join $lf
    $toolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($basis))).ToLowerInvariant()
    $rowEvidence=@($rows|ForEach-Object{if($_.alternateSourceUrl){"forge-source-archive-target:$($_.targetId):coordinate=$($_.forgeCoordinate);archive-sha256=$($_.alternateArchiveSha256);type=$($_.sourceProjectType);build-gradle-sha256=$($_.alternateBuildGradleSha256);spec=$($_.alternateForgeGradleSpec);wrapper=$($_.alternateGradleDistributionUrl);build-java=$($_.alternateBuildJavaMajor)"}else{"forge-mdk-target:$($_.targetId):coordinate=$($_.forgeCoordinate);archive-sha256=$($_.archiveSha256);build-gradle-sha256=$($_.buildGradleSha256);spec=$($_.forgeGradleSpec);wrapper=$($_.gradleDistributionUrl);build-java=$($_.buildJavaMajor)"}})
    $isSourceOverlay=$group.kind -eq 'SourceOverlay'
    $sourceVersion=if($group.kind -eq 'Mdk'){[string]$group.name}elseif($group.kind -eq 'SourceGradle'){[string]$group.name}else{'Official Forge source overlay only; no Gradle project metadata in inspected source ZIP'}
    $buildJavaStatus=if($isSourceOverlay){'PendingImplementation'}else{'PartiallySupported'}
    $projectDetectionStatus='Supported'
    $buildPlanStatus=if($isSourceOverlay){'PendingImplementation'}else{'Supported'}
    $launchPlanStatus=if($isSourceOverlay){'PendingImplementation'}else{'Supported'}
    $family=[ordered]@{
        familyId=$familyId
        loaderId='Forge'
        minecraftIds=@($orderedIds)
        toolchainHash=$toolchainHash
        toolchain=[ordered]@{id=$toolchainId;version=$sourceVersion}
        buildJava=[ordered]@{status=$buildJavaStatus;evidenceRef='common/src/BuildJavaResolver.psm1'}
        runtimeJava=[ordered]@{status='PerTargetMojangMetadata';evidenceRef='compatibility/runtime-java-catalog.json'}
        projectDetectionStrategy=if($isSourceOverlay){'对历史 MCP 项目，要求唯一精确 Minecraft 版本配置，并以 net.minecraftforge 专属 import/API 源码标记识别 Forge；不推断用户项目采用的 Forge build 版本。将检测结果逐字绑定到 frozen Universe Available target 与官方 source-overlay 目标。'}else{'识别 ForgeGradle 项目标记与 Forge 运行依赖，并从项目配置读取精确 Minecraft ID / Forge 坐标版本；将目标逐字绑定到 frozen Universe Available target 和官方候选。'}
        buildStrategy=if($isSourceOverlay){'官方 source overlay 不是独立 Mod build project；MCP/历史构建环境尚未适配，暂不生成构建计划。'}else{'使用该项目 ForgeGradle Gradle Wrapper build task；只生成不可执行 plan，执行必须经过 MMTL managed session copy 与可信 validation runner。'}
        launchStrategy=if($isSourceOverlay){'仅有历史 MCP Forge 项目识别；MCP build/launch contract 尚未实现，不生成构建或启动计划。'}else{'为 exact Forge target 生成 Single Client runClient plan；LaunchCheck 未验证，plan 不可直接执行。'}
        agentBridge='本 family 不声明 Agent、Single、LAN 或 Dedicated 能力。'
        evidence=@('https://docs.minecraftforge.net/en/1.12.x/gettingstarted/','https://docs.minecraftforge.net/en/1.14.x/gettingstarted/','https://docs.minecraftforge.net/en/1.16.x/gettingstarted/','https://docs.minecraftforge.net/en/latest/gettingstarted/','https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml',"universe-sha256:$universeHash","forge-mdk-catalog-sha256:$($catalog.catalogHash)","project-detector-sha256:$detectorHash","forge-adapter-sha256:$adapterHash","build-java-resolver-sha256:$buildJavaResolverHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-forge-target-from-project-coordinates','test:ProjectDetectorV2.Tests.ps1:detects-every-forge-source-overlay-minecraft-target-from-forge-api-imports-in-mcp-projects')+$rowEvidence
        capabilities=[ordered]@{
            BuildJava=[ordered]@{status=$buildJavaStatus;evidenceRefs=if($isSourceOverlay){@($rowEvidence)}else{@("build-java-resolver-sha256:$buildJavaResolverHash","project-detector-sha256:$detectorHash",'test:JavaEvidence.Tests.ps1:wrapper-minimum-and-compiler-target')}}
            ProjectDetection=[ordered]@{status=$projectDetectionStatus;evidenceRefs=if($isSourceOverlay){@($rowEvidence)+@("project-detector-sha256:$detectorHash",'test:ProjectDetectorV2.Tests.ps1:detects-every-forge-source-overlay-minecraft-target-from-forge-api-imports-in-mcp-projects')}else{@('https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml',"project-detector-sha256:$detectorHash","forge-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-forge-target-from-project-coordinates')}}
            BuildPlan=[ordered]@{status=$buildPlanStatus;evidenceRefs=if($isSourceOverlay){@($rowEvidence)}else{@('https://docs.minecraftforge.net/en/1.12.x/gettingstarted/','https://docs.minecraftforge.net/en/1.14.x/gettingstarted/','https://docs.minecraftforge.net/en/1.16.x/gettingstarted/','https://docs.minecraftforge.net/en/latest/gettingstarted/',"forge-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-forge-target-from-project-coordinates')}}
            LaunchPlan=[ordered]@{status=$launchPlanStatus;evidenceRefs=if($isSourceOverlay){@($rowEvidence)}else{@('https://docs.minecraftforge.net/en/1.12.x/gettingstarted/','https://docs.minecraftforge.net/en/1.14.x/gettingstarted/','https://docs.minecraftforge.net/en/1.16.x/gettingstarted/','https://docs.minecraftforge.net/en/latest/gettingstarted/',"forge-adapter-sha256:$adapterHash",'test:ProjectDetectorV2.Tests.ps1:detect-every-exact-forge-target-from-project-coordinates')}}
        }
    }
    $newForgeFamilies.Add([pscustomobject]$family)
}
$familyRows=[Collections.Generic.List[object]]::new()
foreach($entry in @($families.families|Where-Object{$_.loaderId -cne 'Forge'})){$familyRows.Add($entry)}
foreach($entry in $newForgeFamilies){$familyRows.Add($entry)}
$newFamilies=[ordered]@{schemaVersion=[int]$families.schemaVersion;auditStatus=[string]$families.auditStatus;universeHash=$universeHash;families=@($familyRows.ToArray()|Sort-Object loaderId,familyId);unassignedTargetPolicy=[string]$families.unassignedTargetPolicy}
Set-Content -LiteralPath $FamilyManifestPath -Value (ConvertTo-Json -InputObject $newFamilies -Depth 50) -Encoding utf8
$generatedAt=[DateTimeOffset]::UtcNow
if(Test-Path -LiteralPath $LedgerPath -PathType Leaf){try{$existingLedger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json -ErrorAction Stop;$generatedAt=[DateTimeOffset]::Parse([string]$existingLedger.generatedAt)}catch{}}
& (Join-Path $RepositoryRoot 'tools/Generate-FullCompatibilityLedger.ps1') -UniversePath $UniversePath -FamilyManifestPath $FamilyManifestPath -OutputPath $LedgerPath -GeneratedAt $generatedAt
