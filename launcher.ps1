[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$ErrorActionPreference='Stop'
if($null -eq $Arguments){$Arguments=@()}
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here 'src/Platform/Platform.psm1') -Force
$platform=Get-MmtlPlatformProvider
Get-ChildItem (Join-Path $here 'src') -Filter '*.psm1' -Recurse | Where-Object { $platform.OS -eq 'Windows' -or $_.BaseName -ne 'WindowManager' } | ForEach-Object { Import-Module $_.FullName -Force }
# ValidationRunner imports these dependencies inside its module scope with -Force; restore the CLI's public command bindings after the bulk module load.
Import-Module (Join-Path $here 'src/ProjectDetector.psm1') -Force
Import-Module (Join-Path $here 'src/GradleRunner.psm1') -Force
Import-Module (Join-Path $here 'src/Platform/Platform.psm1') -Force
Import-Module (Join-Path $here 'src/Validation/ValidationPlan.psm1') -Force
Import-Module (Join-Path $here 'src/Validation/ValidationMatrix.psm1') -Force
$discoverProjectsIndex=[Array]::IndexOf($Arguments,'--discover-projects')
if($discoverProjectsIndex -ge 0){
    if($discoverProjectsIndex+1 -ge $Arguments.Count){throw '--discover-projects 缺少工作区或仓库路径。'}
    $discoveryPath=[string]$Arguments[$discoverProjectsIndex+1]
    $discoveredProjects=@(Find-MmtlGradleProjects -Path $discoveryPath)
    $discoveryResult=@($discoveredProjects|ForEach-Object{[pscustomobject][ordered]@{repositoryRoot=$_.RepositoryRoot;projectRoot=$_.ProjectRoot;loader=$_.Loader;minecraftVersion=$_.MinecraftVersion;loaderVersion=$_.LoaderVersion;detectionStatus=$_.DetectionStatus;toolchain=$_.Toolchain.id;buildJavaMajor=$_.BuildJavaMajor}})
    if($Arguments -contains '--json'){$discoveryResult|ConvertTo-Json -Depth 12}
    else{Write-Host "发现 Gradle 项目：$($discoveryResult.Count)";$discoveryResult|Format-Table repositoryRoot,projectRoot,loader,minecraftVersion,detectionStatus -AutoSize}
    exit 0
}
$configPath=Join-Path $here 'launcher.config.json'
$configFileIndex=[Array]::IndexOf($Arguments,'--config-file')
if($configFileIndex -ge 0){if($configFileIndex+1 -ge $Arguments.Count){throw '--config-file 缺少路径。'};$configPath=[IO.Path]::GetFullPath([string]$Arguments[$configFileIndex+1])}
$portable=($Arguments -contains '--portable') -and -not ($configPath -and (Test-Path $configPath) -and (Read-MmtlConfig -Path $configPath).runtimeRoot)
if($Arguments -contains '--help' -or $Arguments -contains '-h'){
    Write-Host 'Minecraft Mod Test Launcher';Write-Host '用法：launcher.cmd / launcher.sh [--validate|--dry-run|--build|--launch] [--profile NAME]';Write-Host '工作区发现：--discover-projects <workspace-or-repository> [--json]';Write-Host 'Catalog：--list-minecraft-versions | --minecraft-info <id|CurrentStable> | --refresh-catalog';Write-Host 'Loaders：--list-loaders <mc> [--include-historical] | --loader-info <mc> <loader> | --provider-status <loader>';Write-Host '覆盖审计：';foreach($option in Get-MmtlCoverageCliOptionDefinitions){Write-Host "  $($option.usage) — $($option.description)"};Write-Host '深度验证：--validation-plan --scope P0|CurrentStable | --validation-matrix <target-definitions.json> [--validation-output <path>] | --validation-summary [--validation-version <mc>] [--validation-loader <id>]';Write-Host 'Historical providers use HTTPS metadata/cache; HTTP-only artifacts are never auto-executed.';Write-Host 'Offline：--catalog-offline 仅影响 Mojang Catalog；--loader-offline 仅影响 Loader metadata；均不改变 Gradle Offline。';Write-Host 'Session：--list-sessions | --stop ID | --clean-session ID';Write-Host '运行目录：--portable';Write-Host '交互模式：不传参数；--config-file 仅供临时配置调用。';exit 0
}
$config=if(Test-Path $configPath){Read-MmtlConfig -Path $configPath}else{$null}
$runtimeConfigured=if($config -and $config.runtimeRoot){[string]$config.runtimeRoot}else{''}
$runtimeRoot=Resolve-MmtlRuntimeRoot -Path $runtimeConfigured -Portable:$portable -LauncherRoot $here
$catalogRuntimeRoot=$runtimeRoot
if($platform.OS -in @('Linux','MacOS') -and $runtimeConfigured -match '^%LOCALAPPDATA%([\\/]|$)'){
    $catalogRuntimeRoot=$platform.DefaultRuntimeRoot
    Write-Warning 'Catalog cache ignored the Windows-only %LOCALAPPDATA% runtimeRoot on this platform and will use the native platform Runtime Root.'
}
$catalogOffline=$Arguments -contains '--catalog-offline'
$loaderOffline=$Arguments -contains '--loader-offline'
$coverageCommands=@('--coverage-report','--coverage-gaps','--coverage-version')
$coverageCommandPresent=@($coverageCommands|Where-Object{$Arguments -ccontains $_}).Count -gt 0
if($coverageCommandPresent){
    Invoke-MmtlCoverageCli -Arguments $Arguments -RuntimeRoot $runtimeRoot -CatalogOffline:$catalogOffline -LoaderOffline:$loaderOffline -ForceRefresh:($Arguments -contains '--refresh-catalog')
    exit 0
}
$validationMatrixIndex=[Array]::IndexOf($Arguments,'--validation-matrix')
if($validationMatrixIndex -ge 0){
    if($validationMatrixIndex+1 -ge $Arguments.Count){throw '--validation-matrix 缺少 target definitions JSON 路径。'}
    $targetPath=[IO.Path]::GetFullPath([string]$Arguments[$validationMatrixIndex+1])
    if(-not(Test-Path -LiteralPath $targetPath -PathType Leaf)){throw 'Validation target definitions file was not found.'}
    $targets=Get-Content -LiteralPath $targetPath -Raw|ConvertFrom-Json -ErrorAction Stop
    $runEvidence=Get-MmtlValidationRunEvidence -RuntimeRoot $runtimeRoot
    $outputIndex=[Array]::IndexOf($Arguments,'--validation-output')
    $outputPath=if($outputIndex -ge 0 -and $outputIndex+1 -lt $Arguments.Count){[IO.Path]::GetFullPath([string]$Arguments[$outputIndex+1])}else{$null}
    $targetIds=@($targets|ForEach-Object {[string]$_.targetId})
    $relevantEvidence=@($runEvidence.evidence|Where-Object {[string]$_.targetId -in $targetIds})
    $outOfScopeCount=@($runEvidence.evidence|Where-Object {[string]$_.targetId -notin $targetIds}).Count
    $summary=New-MmtlValidationMatrix -Targets @($targets) -Evidence $relevantEvidence -OutputPath $outputPath
    [pscustomobject]@{targetCount=$summary.targetCount;levelCounts=$summary.levelCounts;outOfScopeEvidenceIgnored=$outOfScopeCount;warnings=@($runEvidence.warnings)+@($summary.warnings);matrixPath=$outputPath}|ConvertTo-Json -Depth 20
    exit 0
}
$validationSummaryIndex=[Array]::IndexOf($Arguments,'--validation-summary')
$validationVersionIndex=[Array]::IndexOf($Arguments,'--validation-version')
$validationLoaderIndex=[Array]::IndexOf($Arguments,'--validation-loader')
if($validationSummaryIndex -ge 0 -or $validationVersionIndex -ge 0 -or $validationLoaderIndex -ge 0){
    if($validationVersionIndex -ge 0 -and $validationVersionIndex+1 -ge $Arguments.Count){throw '--validation-version 缺少 Minecraft ID。'}
    if($validationLoaderIndex -ge 0 -and $validationLoaderIndex+1 -ge $Arguments.Count){throw '--validation-loader 缺少 Loader ID。'}
    $runRecords=Get-MmtlValidationRunEvidence -RuntimeRoot $runtimeRoot
    $derived=Get-MmtlValidationTargetsFromEvidence -Evidence @($runRecords.evidence)
    $targets=@($derived.targets)
    if($validationVersionIndex -ge 0){$version=[string]$Arguments[$validationVersionIndex+1];$targets=@($targets|Where-Object minecraftId -CEQ $version)}
    if($validationLoaderIndex -ge 0){$loader=[string]$Arguments[$validationLoaderIndex+1];$targets=@($targets|Where-Object {$_.loaderStack.primary.id -CEQ $loader})}
    $evidence=[Collections.Generic.List[object]]::new()
    foreach($target in $targets){
        $sourceTargetId=if($target.PSObject.Properties['evidenceTargetId']){[string]$target.evidenceTargetId}else{[string]$target.targetId}
        $source=[string]$target.sourceFixture.source;$commit=[string]$target.sourceFixture.commit
        foreach($record in @($runRecords.evidence|Where-Object {[string]$_.targetId -ceq $sourceTargetId -and [string]$_.sourceFixture.source -ceq $source -and [string]$_.sourceFixture.commit -ceq $commit})){
            $copy=$record|ConvertTo-Json -Depth 40|ConvertFrom-Json
            $copy.targetId=[string]$target.targetId
            $evidence.Add($copy)
        }
    }
    if($targets.Count){$summary=New-MmtlValidationMatrix -Targets $targets -Evidence $evidence -Scope P0}
    else{$summary=[pscustomobject]@{matrix=[pscustomobject]@{targets=@()};targetCount=0;warnings=@();levelCounts=[pscustomobject]@{catalogued=0;resolved=0;buildVerified=0;serverVerified=0;clientLaunchVerified=0;integrationVerified=0}}}
    $response=[ordered]@{targetCount=$summary.targetCount;levelCounts=$summary.levelCounts;warnings=@($runRecords.warnings)+@($derived.warnings)+@($summary.warnings)}
    if($Arguments -contains '--json'){$response.matrix=$summary.matrix}
    [pscustomobject]$response|ConvertTo-Json -Depth 40
    exit 0
}
$validationPlanIndex=[Array]::IndexOf($Arguments,'--validation-plan')
if($validationPlanIndex -ge 0){
    $scopeIndex=[Array]::IndexOf($Arguments,'--scope')
    if($scopeIndex -lt 0 -or $scopeIndex+1 -ge $Arguments.Count){throw '--validation-plan requires --scope P0 or --scope CurrentStable.'}
    $scope=[string]$Arguments[$scopeIndex+1]
    if($scope -notin @('P0','CurrentStable')){throw 'Validation plan scope must be P0 or CurrentStable.'}
    $catalog=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $catalogRuntimeRoot -Offline:$catalogOffline
    $fixturePath=Join-Path $here 'fixtures/deep-validation/fixtures.json'
    if(-not(Test-Path -LiteralPath $fixturePath -PathType Leaf)){throw 'Pinned official fixture manifest is missing.'}
    $fixtureManifest=Get-Content -LiteralPath $fixturePath -Raw|ConvertFrom-Json -ErrorAction Stop
    $platform=Get-MmtlPlatformProvider
    $fixtureTargets=@(New-MmtlValidationFixtureTargets -Fixtures @($fixtureManifest.fixtures) -Platform ([pscustomobject]@{os=$platform.OS;arch=$platform.Arch;isWSL=$platform.IsWSL}))
    foreach($fixture in $fixtureManifest.fixtures){Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC','QuiltMC','NeoForgeMDKs','MinecraftForge')|Out-Null}
    $plan=New-MmtlValidationPlan -Scope $scope -CurrentStable ([string]$catalog.latestRelease) -CatalogReleaseIds @($catalog.entries|ForEach-Object id) -FixtureTargets $fixtureTargets
    [pscustomobject]@{scope=$plan.scope;currentStable=$plan.currentStable;tier0=$plan.tier0;targetCount=@($plan.targets).Count;targets=@($plan.targets);execution='NOT_STARTED'}|ConvertTo-Json -Depth 40
    exit 0
}
$includeHistorical=$Arguments -contains '--include-historical' -or $Arguments -contains '--loader-scope-all'
$listLoadersIndex=[Array]::IndexOf($Arguments,'--list-loaders')
$loaderInfoIndex=[Array]::IndexOf($Arguments,'--loader-info')
$providerStatusIndex=[Array]::IndexOf($Arguments,'--provider-status')
$jarModArtifactIndex=[Array]::IndexOf($Arguments,'--jar-mod-artifact')
$jarModStrategyIndex=[Array]::IndexOf($Arguments,'--patch-strategy')
$hasListLoaders=$listLoadersIndex -ge 0;$hasLoaderInfo=$loaderInfoIndex -ge 0;$hasProviderStatus=$providerStatusIndex -ge 0
if(@($hasListLoaders,$hasLoaderInfo,$hasProviderStatus|Where-Object{$_}).Count -gt 1){throw 'LOADER_OPTION_CONFLICT: loader/provider 查询参数不能组合。'}
if($hasListLoaders -and ($listLoadersIndex+1 -ge $Arguments.Count)){throw '--list-loaders 缺少 Minecraft 版本 ID。'}
if($hasLoaderInfo -and ($loaderInfoIndex+2 -ge $Arguments.Count)){throw '--loader-info 需要 Minecraft 版本 ID 和 Loader ID。'}
if($hasProviderStatus -and ($providerStatusIndex+1 -ge $Arguments.Count)){throw '--provider-status 缺少 Provider ID。'}
if($hasLoaderInfo -and [string]$Arguments[$loaderInfoIndex+2] -notin @('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){throw "Unsupported Loader: $($Arguments[$loaderInfoIndex+2])"}
if($jarModArtifactIndex -ge 0 -and (-not $hasLoaderInfo -or [string]$Arguments[$loaderInfoIndex+2] -ne 'JarMod')){throw '--jar-mod-artifact 只能与 --loader-info <mc> JarMod 组合。'}
if($jarModArtifactIndex -ge 0 -and ($jarModArtifactIndex+1 -ge $Arguments.Count -or $jarModStrategyIndex -lt 0 -or $jarModStrategyIndex+1 -ge $Arguments.Count)){throw '--jar-mod-artifact 需要文件路径，且必须提供 --patch-strategy。'}
if($hasProviderStatus -and [string]$Arguments[$providerStatusIndex+1] -notin @('LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){throw "Unsupported historical Provider: $($Arguments[$providerStatusIndex+1])"}
if($hasListLoaders -or $hasLoaderInfo -or $hasProviderStatus){
    $loaderCatalog=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $catalogRuntimeRoot -Offline:$catalogOffline
    if($hasProviderStatus){$providerId=[string]$Arguments[$providerStatusIndex+1];Get-MmtlHistoricalProviderStatus -LoaderId $providerId -Catalog $loaderCatalog -RuntimeRoot $runtimeRoot -Offline:$loaderOffline|ConvertTo-Json -Depth 30;exit 0}
    if($hasListLoaders){
        $id=[string]$Arguments[$listLoadersIndex+1];if($id -eq 'CurrentStable'){$id=[string]$loaderCatalog.latestRelease};$null=Resolve-MmtlMinecraftVersion -MinecraftId $id -Catalog $loaderCatalog
        $index=Get-MmtlLoaderAvailabilityIndex -Catalog $loaderCatalog -RuntimeRoot $runtimeRoot -Offline:$loaderOffline
        $row=$index.entries|Where-Object minecraftId -CEQ $id|Select-Object -First 1
        foreach($loaderId in @('Forge','Fabric','NeoForge','Quilt')){$item=$row.loaders.$loaderId;[pscustomobject]@{Minecraft=$id;Loader=$loaderId;Availability=$item.availability;CacheStatus=$item.cacheStatus;Source=$item.source;LastChecked=$item.lastChecked;Notes=($item.notes -join '; ')}}
        if($includeHistorical){$historical=Get-MmtlHistoricalLoaderAvailability -MinecraftId $id -Catalog $loaderCatalog -RuntimeRoot $runtimeRoot -Offline:$loaderOffline;foreach($item in $historical.entries){[pscustomobject]@{Minecraft=$id;Loader=$item.loaderId;Availability=$item.availability;CacheStatus=$item.cacheStatus;Source=$item.source;LastChecked=$item.lastChecked;SourceClass=$item.sourceClass;Trust=$item.trustClass;Transport=$item.transportSecurity;Maintenance=$item.maintenanceState;CandidateCount=$item.candidateCount;Notes=($item.notes -join '; ')}}}
        exit 0
    }
    $id=[string]$Arguments[$loaderInfoIndex+1];if($id -eq 'CurrentStable'){$id=[string]$loaderCatalog.latestRelease};$null=Resolve-MmtlMinecraftVersion -MinecraftId $id -Catalog $loaderCatalog
    $loaderId=[string]$Arguments[$loaderInfoIndex+2]
    if($loaderId -in @('LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){
        $historicalCandidates=@();$snapshot=$null;$candidateQuery=$null
        switch($loaderId){'LegacyFabric'{$snapshot=Get-MmtlLegacyFabricProviderSnapshot -RuntimeRoot $runtimeRoot -Offline:$loaderOffline;$candidateQuery=Get-MmtlLegacyFabricCandidateQuery -MinecraftId $id -RuntimeRoot $runtimeRoot -Offline:$loaderOffline;$historicalCandidates=@($candidateQuery.candidates)}'OrnitheLoader'{$snapshot=Get-MmtlOrnitheProviderSnapshot -RuntimeRoot $runtimeRoot -Offline:$loaderOffline;$candidateQuery=Get-MmtlOrnitheCandidateQuery -MinecraftId $id -RuntimeRoot $runtimeRoot -Offline:$loaderOffline;$historicalCandidates=@($candidateQuery.candidates)}'LiteLoader'{$snapshot=Get-MmtlLiteLoaderProviderSnapshot -RuntimeRoot $runtimeRoot -Offline:$loaderOffline;$historicalCandidates=@(Get-MmtlLiteLoaderCandidates -MinecraftId $id -Snapshot $snapshot)}'Rift'{$historicalCandidates=@(Get-MmtlRiftCandidates -MinecraftId $id)}'ModLoader'{$historicalCandidates=@(Get-MmtlModLoaderArchiveCandidates -MinecraftId $id)}'ModLoaderMP'{$historicalCandidates=@(Get-MmtlModLoaderMPArchiveCandidates -MinecraftId $id)}'JarMod'{if($jarModArtifactIndex -ge 0){$artifactPath=[string]$Arguments[$jarModArtifactIndex+1];$patchStrategy=[string]$Arguments[$jarModStrategyIndex+1];$historicalCandidates=@(New-MmtlJarModManualCandidate -MinecraftId $id -ArtifactPath $artifactPath -PatchStrategy $patchStrategy)}else{$historicalCandidates=@()}}}
        [pscustomobject]@{Minecraft=$id;Loader=$loaderId;ProviderStatus=if($candidateQuery){$candidateQuery.providerStatus}elseif($snapshot){$snapshot.providerStatus}else{'CuratedOrManual'};Availability=if($loaderId -eq 'JarMod'){'Manual'}elseif($historicalCandidates.Count){'Available'}elseif($candidateQuery -and $candidateQuery.providerStatus -in @('Available','Stale')){'Unavailable'}elseif($snapshot -and $snapshot.providerStatus -in @('Available','Stale')){'Unavailable'}else{'Unknown'};CacheStatus=if($candidateQuery){$candidateQuery.cacheStatus}elseif($snapshot){$snapshot.cacheStatus}else{'Curated'};LastChecked=if($candidateQuery){$candidateQuery.validatedAt}elseif($snapshot -and $snapshot.validatedAt){$snapshot.validatedAt}else{$null};Notes=if($candidateQuery -and $candidateQuery.error){$candidateQuery.error}elseif($snapshot -and $snapshot.error){$snapshot.error}else{$null};SourceClass=if($historicalCandidates.Count){$historicalCandidates[0].sourceClass}else{$null};MaintenanceState=if($historicalCandidates.Count){$historicalCandidates[0].maintenanceState}else{$null};Trust=if($historicalCandidates.Count){$historicalCandidates[0].trustClass}else{$null};Transport=if($historicalCandidates.Count){$historicalCandidates[0].transportSecurity}else{$null};Integrity=if($historicalCandidates.Count){$historicalCandidates[0].integrity}else{$null};Toolchain=if($historicalCandidates.Count){$historicalCandidates[0].toolchain}else{$null};BuildStatus=if($historicalCandidates.Count){'CATALOGUED'}elseif($loaderId -eq 'JarMod'){'MANUAL'}else{'UNVERIFIED'};Candidates=$historicalCandidates;Provenance=if($historicalCandidates.Count){@($historicalCandidates|ForEach-Object provenance)}elseif($snapshot){$snapshot.provenance}else{@()}}|ConvertTo-Json -Depth 30
        exit 0
    }
    if($loaderId -notin @('Forge','Fabric','NeoForge','Quilt')){throw "Unsupported Loader: $loaderId"}
    $snapshot=switch($loaderId){'Forge'{Get-MmtlForgeProviderSnapshot -Catalog $loaderCatalog -RuntimeRoot $runtimeRoot -Offline:$loaderOffline};'Fabric'{Get-MmtlFabricProviderSnapshot -RuntimeRoot $runtimeRoot -Offline:$loaderOffline};'NeoForge'{Get-MmtlNeoForgeProviderSnapshot -Catalog $loaderCatalog -RuntimeRoot $runtimeRoot -Offline:$loaderOffline};'Quilt'{Get-MmtlQuiltProviderSnapshot -RuntimeRoot $runtimeRoot -Offline:$loaderOffline}}
    $candidates=switch($loaderId){'Forge'{Get-MmtlForgeCandidates -MinecraftId $id -Snapshot $snapshot};'Fabric'{Get-MmtlFabricCandidates -MinecraftId $id -RuntimeRoot $runtimeRoot -Offline:$loaderOffline};'NeoForge'{Get-MmtlNeoForgeCandidates -MinecraftId $id -Snapshot $snapshot};'Quilt'{Get-MmtlQuiltCandidates -MinecraftId $id -RuntimeRoot $runtimeRoot -Offline:$loaderOffline}}
    $preferred=switch($loaderId){'Forge'{Get-MmtlForgePreferredCandidate -MinecraftId $id -Candidates $candidates};'Fabric'{Get-MmtlFabricPreferredCandidate -MinecraftId $id -Candidates $candidates};'NeoForge'{Get-MmtlNeoForgePreferredCandidate -MinecraftId $id -Candidates $candidates};'Quilt'{Get-MmtlQuiltPreferredCandidate -MinecraftId $id -Candidates $candidates}}
    $providerStatus=Get-MmtlLoaderProviderStatus -LoaderId $loaderId -Snapshot $snapshot
    [pscustomobject]@{Minecraft=$id;Loader=$loaderId;ProviderStatus=$providerStatus;Preferred=$preferred;Candidates=@($candidates);Provenance=if($snapshot.provenance){$snapshot.provenance}else{@()}}|ConvertTo-Json -Depth 30
    exit 0
}
$refreshCatalog=$Arguments -contains '--refresh-catalog'
$listMinecraftVersions=$Arguments -contains '--list-minecraft-versions'
$minecraftInfoIndex=[Array]::IndexOf($Arguments,'--minecraft-info')
$hasMinecraftInfo=$minecraftInfoIndex -ge 0
if($catalogOffline -and $refreshCatalog){throw 'CATALOG_OPTION_CONFLICT: --refresh-catalog cannot be combined with --catalog-offline.'}
if($hasMinecraftInfo -and ($minecraftInfoIndex+1 -ge $Arguments.Count -or [string]::IsNullOrWhiteSpace([string]$Arguments[$minecraftInfoIndex+1]))){throw '--minecraft-info 缺少 Minecraft 版本 ID。'}
if($listMinecraftVersions -or $hasMinecraftInfo -or $refreshCatalog){
    $catalog=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $catalogRuntimeRoot -Offline:$catalogOffline -ForceRefresh:$refreshCatalog
    if($hasMinecraftInfo){
        $entry=Resolve-MmtlMinecraftVersion -MinecraftId ([string]$Arguments[$minecraftInfoIndex+1]) -Catalog $catalog
        $versionMetadata=Get-MmtlMinecraftVersionMetadata -CatalogEntry $entry -RuntimeRoot $catalogRuntimeRoot -Offline:$catalogOffline
        $runtimeJava=Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId $entry.id -CatalogEntry $entry -VersionMetadata $versionMetadata
        [pscustomobject]@{
            ID=$entry.id;Type=$entry.type;ReleaseTime=$entry.releaseTime;CatalogStatus=$entry.catalogStatus;CatalogCacheStatus=$catalog.cacheStatus
            MetadataStatus=$versionMetadata.metadataStatus;MetadataSource='Mojang per-version JSON';ExpectedSHA1=$versionMetadata.expectedSha1;ActualSHA1=$versionMetadata.actualSha1
            JavaVersionPresent=[bool]$versionMetadata.metadata.javaVersion;RuntimeJavaMajor=$runtimeJava.major;RuntimeJavaComponent=$runtimeJava.component
            RuntimeJavaSource=$runtimeJava.source;RuntimeJavaConfidence=$runtimeJava.confidence;RuntimeJavaRequirementKind=$runtimeJava.requirementKind
        } | Format-List
        exit 0
    }
    if($listMinecraftVersions){
        foreach($entry in $catalog.entries){$stable=if($entry.id -ceq $catalog.latestRelease){' CurrentStable'}else{''};Write-Output ('{0} | {1}{2}' -f $entry.id,$entry.releaseTime,$stable)}
        Write-Output "Catalog: $($catalog.cacheStatus); releases: $($catalog.entries.Count); minimum: $($catalog.minimumReleaseId); CurrentStable: $($catalog.latestRelease)"
        exit 0
    }
    Write-Output "Mojang Catalog refreshed. Status: $($catalog.cacheStatus); releases: $($catalog.entries.Count); CurrentStable: $($catalog.latestRelease)"
    exit 0
}
if ($Arguments -contains '--list-sessions') {
    $sessions=Join-Path $runtimeRoot 'sessions'
    if(Test-Path $sessions){foreach($dir in Get-ChildItem $sessions -Directory){try{$status=Update-MmtlSessionReport -SessionPath $dir.FullName;Write-Output "$($dir.Name) [$($status.Status)]"}catch{Write-Output "$($dir.Name) [Unknown]"}}}; exit 0
}
foreach($operation in @('--stop','--clean-session')){
    $index=[Array]::IndexOf($Arguments,$operation)
    if($index -ge 0){
        if($index+1 -ge $Arguments.Count){throw "$operation 缺少 Session ID。"}
        $id=[string]$Arguments[$index+1]
        if($id -notmatch '^\d{8}T\d{6}Z_[A-Za-z0-9_-]{1,40}$'){throw 'Session ID 格式不合法。'}
        $sessions=Join-Path $runtimeRoot 'sessions';$sessionPath=Join-Path $sessions $id
        if(-not (Test-MmtlInsideRoot -Root $sessions -Target $sessionPath)){throw 'Session 路径越界。'}
        if($operation -eq '--clean-session'){Remove-MmtlSession -RuntimeRoot $runtimeRoot -SessionPath $sessionPath;Write-Host "已清理 Session $id";exit 0}
        $registry=Join-Path $sessionPath 'pids.json';if(-not(Test-Path $registry)){throw '找不到 Session 进程清单。'}
        foreach($entry in @(Get-Content $registry -Raw|ConvertFrom-Json)){Stop-MmtlTrackedProcess -SessionPath $sessionPath -ProcessId ([int]$entry.PID) -Confirm:$false|Out-Null}
        $finalStatus=Update-MmtlSessionReport -SessionPath $sessionPath
        Write-Host "Session $id 状态：$($finalStatus.Status)`n报告：$($finalStatus.ReportPath)";exit 0
    }
}
if (-not (Test-Path $configPath)) {
    Write-Host 'Minecraft Mod Test Launcher - 临时向导'
    $examplePath=Join-Path $here 'launcher.config.example.json'
    $example=Read-MmtlConfig -Path $examplePath
    $profile=Read-MmtlWizardProfile -Defaults $null
    Show-MmtlLaunchSummary -Profile $profile -Config $example
    $next=Read-Host '[Enter] 临时启动 [E] 修改 [S] 保存本机 Profile [Q] 退出'
    if($next -match '^(?i:q)$'){exit 0}
    if($next -match '^(?i:e)$'){$profile=Read-MmtlWizardProfile -Defaults $profile;Show-MmtlLaunchSummary -Profile $profile -Config $example;$next=Read-Host '按 Enter 临时启动，或输入 Q 退出'}
    if($next -match '^(?i:s)$'){$profileName=Read-Host '输入 Profile 名称';if($profileName -notmatch '^[A-Za-z0-9_-]{1,40}$'){throw 'Profile 名称只允许字母、数字、下划线和短横线。'};$example.profiles|Add-Member -NotePropertyName $profileName -NotePropertyValue $profile -Force;$example.defaultProfile=$profileName;$example|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $here 'launcher.config.json') -Encoding utf8;exit 0}
    if($next -notin @('','E')){Write-Host '已退出临时向导。';exit 0}
    $temporaryConfig=Join-Path ([IO.Path]::GetTempPath()) ('mmtl-'+[guid]::NewGuid().ToString('N')+'.json')
    $example.profiles|Add-Member -NotePropertyName '__temporary' -NotePropertyValue $profile -Force;$example.defaultProfile='__temporary';$example|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $temporaryConfig -Encoding utf8
    try{$pwsh=(Get-Command pwsh -ErrorAction Stop).Source;& $pwsh -NoProfile -File $MyInvocation.MyCommand.Path --config-file $temporaryConfig --profile '__temporary' --launch;exit $LASTEXITCODE}
    finally{if(Test-Path -LiteralPath $temporaryConfig){Remove-Item -LiteralPath $temporaryConfig -Force}}
}
if($Arguments.Count -eq 0){
    $result=Invoke-MmtlConsoleMenu -Config $config -ConfigPath $configPath -LauncherPath $MyInvocation.MyCommand.Path
    exit ([int]$result)
}
$profileNameIndex=[Array]::IndexOf($Arguments,'--profile')
$profileName=if($profileNameIndex -ge 0 -and $profileNameIndex+1 -lt $Arguments.Count){[string]$Arguments[$profileNameIndex+1]}else{$null}
$profile=Get-MmtlProfile -Config $config -Name $profileName
Assert-MmtlProfile -Profile $profile | Out-Null
$project=Get-MmtlProject -Path $profile.project
function Get-MmtlProjectOutputJar {
    param([Parameter(Mandatory)]$Project)
    $jars=@(Get-ChildItem -LiteralPath (Join-Path $Project.Root 'build/libs') -Filter '*.jar' -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -notmatch '(?i)(sources|javadoc|dev)(?:[-.]|\.jar$)'})
    if($jars.Count -ne 1){throw "项目 $($Project.Root) 应有且仅有一个可用 Mod JAR，实际 $($jars.Count) 个。"}
    return $jars[0].FullName
}
function Start-MmtlConfiguredRun {
    param([Parameter(Mandatory)]$Primary,[Parameter(Mandatory)]$Profile,[Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$RuntimeRoot)
    if($env:OS -ne 'Windows_NT'){throw 'MMTL v1 仅支持 Windows 10/11。'}
    if($Primary.Loader -eq 'Unknown' -or -not $Primary.Wrapper -or -not $Primary.MinecraftVersion -or -not $Primary.LoaderVersion -or -not $Primary.JavaMajor){throw 'Primary 项目的 Loader、版本、Java 或 Gradle Wrapper 无法完整确认。'}
    if($Profile.mode -eq 'Dedicated' -and $Profile.acceptEula -ne $true){throw 'Dedicated 模式需先在本机配置中明确设置 acceptEula=true。'}
    $linked=@($Profile.linkedProjects|Where-Object{$_}|ForEach-Object{Get-MmtlProject -Path ([string]$_)})
    if($linked.Count){Assert-MmtlCompatible -Projects (@($Primary)+$linked)|Out-Null}
    $projects=@($Primary)+$linked
    foreach($candidate in $projects){if($candidate.Loader -eq 'Unknown' -or -not $candidate.Wrapper -or -not $candidate.LoaderVersion -or -not $candidate.JavaMajor){throw "项目检测信息不完整：$($candidate.Root)"}}
    $players=[int]$Profile.players
    if($players -gt 8){throw 'v1 单次最多运行 8 个游戏客户端。'}
    if($Profile.mode -eq 'Single' -and $players -ne 1){throw 'Single 模式的 players 必须为 1。'}
    if($Profile.mode -eq 'IntegratedLAN' -and $players -lt 2){throw 'IntegratedLAN 的 players 包含 Host，至少为 2。'}
    $memoryBudget=Get-MmtlMemoryBudget -Profile $Profile -Mode $Profile.mode;$memoryOverageConfirmed=$false
    if($memoryBudget.ExceedsLimit){Write-Warning "预计 Xmx 总和 $($memoryBudget.RequestedMb) MB，超过物理内存 80% 预算 $($memoryBudget.LimitMb) MB。";$memoryApproval=Read-Host '继续可能造成系统变慢或实例崩溃。输入 Y 明确继续，其他输入取消';if($memoryApproval -notmatch '^(?i:y|yes)$'){throw '用户未确认超额内存预算，已取消启动。'};$memoryOverageConfirmed=$true}
    $hostName=if($Profile.hostUsername){[string]$Profile.hostUsername}else{'Dev'}
    $prefix=if($Profile.clientPrefix){[string]$Profile.clientPrefix}else{'Dev_'}
    if($hostName -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'hostUsername 必须为 1 到 16 位 ASCII 字母、数字或下划线。'}
    if($prefix -notmatch '^[A-Za-z0-9_]{1,15}$'){throw 'clientPrefix 必须为 1 到 15 位 ASCII 字母、数字或下划线。'}
    $java=Resolve-MmtlJava -Config $Config -Major ([int]$Primary.JavaMajor)
    $portSetting=if($Profile.port){$Profile.port}else{'Auto'}
    $requestedPort=0
    if([string]$portSetting -ne 'Auto'){$requestedPort=[int]$portSetting}
    if($requestedPort -and $Profile.mode -in @('Dedicated','IntegratedLAN')){$null=Get-MmtlPort -Port $requestedPort}
    $name=[IO.Path]::GetFileName($Primary.Root)-replace '[^A-Za-z0-9_-]','_'
    $metadata=[pscustomobject]@{project=$Primary.Root;linkedProjects=@($linked.Root);minecraft=$Primary.MinecraftVersion;loader=$Primary.Loader;loaderVersion=$Primary.LoaderVersion;javaMajor=$Primary.JavaMajor;mode=$Profile.mode;players=$players;hostUsername=$hostName;clientPrefix=$prefix;hostCheats=[bool]$Profile.hostCheats;clientPermissionLevel=[int]$Profile.clientPermissionLevel;gameMode=$Profile.gameMode;difficulty=$Profile.difficulty;worldName=$Profile.worldName;seed=$Profile.seed;newWorld=[bool]$Profile.newWorld;resetWorld=[bool]$Profile.resetWorld;worldResetCount=0;resolution=$Profile.resolution;guiScale=$Profile.guiScale;windowLayout=$Profile.windowLayout;windowLayoutStatus='Pending';memoryMb=$Profile.memoryMb;hostMemoryMb=$Profile.hostMemoryMb;clientMemoryMb=$Profile.clientMemoryMb;serverMemoryMb=$Profile.serverMemoryMb;memoryBudget=$memoryBudget;memoryOverageConfirmed=$memoryOverageConfirmed;port=$requestedPort;builds=@();processes=@();createdBy='MinecraftModTestLauncher'}
    $session=New-MmtlSession -RuntimeRoot $RuntimeRoot -Name $name -Metadata $metadata
    $sessionId=Split-Path $session -Leaf
    $builds=[Collections.Generic.List[object]]::new();$linkedJars=[Collections.Generic.List[string]]::new()
    try{
        Write-Host "Session: $sessionId`nMinecraft: $($Primary.MinecraftVersion)`nLoader: $($Primary.Loader) $($Primary.LoaderVersion)`nJava: $($Primary.JavaMajor)`nMode: $($Profile.mode)`nPlayers: $players`nRuntime: $session"
        if($Profile.resetWorld -eq $true){$resetWorldCount=0;foreach($username in @($hostName)+@(for($i=1;$i -lt $players;$i++){$prefix+$i})){if(Reset-MmtlSessionWorld -RuntimeRoot $RuntimeRoot -SessionPath $session -PlayerName $username -WorldName ([string]$Profile.worldName) -Reset -Confirm:$false){$resetWorldCount++}};$metadata.worldResetCount=$resetWorldCount;Write-Host "当前 Session 测试世界重置数：$resetWorldCount"}
        if($Profile.autoBuild -ne $false){
            foreach($candidate in $projects){
                $projectJava=Resolve-MmtlJava -Config $Config -Major ([int]$candidate.JavaMajor)
                $build=Invoke-MmtlGradleBuild -Project $candidate -JavaPath $projectJava -SessionPath $session -Clean:([bool]$Profile.cleanBuild)
                $builds.Add($build)
                if($candidate.Root -ne $Primary.Root){$linkedJars.Add([string]$build.JarPath)}
            }
        }else{
            foreach($candidate in $linked){$linkedJars.Add((Get-MmtlProjectOutputJar -Project $candidate))}
        }
        $extraJars=[Collections.Generic.List[string]]::new()
        foreach($path in @($linkedJars)){$extraJars.Add([string]$path)}
        foreach($configuredJar in @($Profile.extraMods|Where-Object{$_})){
            $jarPath=[string]$configuredJar
            if(-not [IO.Path]::IsPathRooted($jarPath)){$jarPath=Join-Path $here $jarPath}
            $resolvedJar=(Resolve-Path -LiteralPath $jarPath -ErrorAction Stop).Path
            if([IO.Path]::GetExtension($resolvedJar) -ne '.jar'){throw "extraMods 仅接受 JAR：$configuredJar"}
            $extraJars.Add($resolvedJar)
        }
        if($Profile.mode -eq 'Dedicated'){
            $port=if($requestedPort){$requestedPort}else{Get-MmtlPort}
            $serverInit=Initialize-MmtlDedicatedServerRuntime -SessionPath $session -Port $port -Profile $Profile
            $serverPlan=New-MmtlGradleRunPlan -Project $Primary -Mode Dedicated -RuntimeRoot $session -Role Server -Profile $Profile
            $server=Start-MmtlGradleInstance -Project $Primary -Plan $serverPlan -JavaPath $java -SessionPath $session -ModJars @($extraJars)
            Write-Host "Dedicated Server 已启动，等待端口 $port 就绪。日志：$($server.LogPath)"
            $null=Wait-MmtlDedicatedReady -Path $server.LogPath -ProcessId $server.ProcessId -TimeoutSeconds 300
            $metadata.port=$port
            $clientNames=@($hostName)
            for($i=1;$i -lt $players;$i++){$clientNames+=($prefix+$i)}
            foreach($username in $clientNames){
                $plan=New-MmtlGradleRunPlan -Project $Primary -Mode Dedicated -RuntimeRoot $session -Role Client -Username $username -Port $port -Profile $Profile
                $started=Start-MmtlGradleInstance -Project $Primary -Plan $plan -JavaPath $java -SessionPath $session -ModJars @($extraJars)
                $metadata.processes+=@([pscustomobject]@{PID=$started.ProcessId;role=$started.Role;username=$started.Username;log=$started.LogPath})
                Write-Host "客户端 $username 已启动；日志：$($started.LogPath)"
            }
            $metadata.processes+=@([pscustomobject]@{PID=$server.ProcessId;role='Server';username='';log=$server.LogPath})
        }elseif($Profile.mode -eq 'IntegratedLAN'){
            $hostPlan=New-MmtlGradleRunPlan -Project $Primary -Mode IntegratedLAN -RuntimeRoot $session -Role Host -Username $hostName -Profile $Profile
            $hostProcess=Start-MmtlGradleInstance -Project $Primary -Plan $hostPlan -JavaPath $java -SessionPath $session -ModJars @($extraJars)
            $metadata.processes+=@([pscustomobject]@{PID=$hostProcess.ProcessId;role='Host';username=$hostName;log=$hostProcess.LogPath})
            Write-Host "Host 客户端已启动。请进入测试世界并在游戏菜单中手动 Open to LAN。若选择固定端口，请使用 $requestedPort。"
            $null=Read-Host '发布局域网后按 Enter，启动器将从日志读取端口并启动其他客户端'
            $port=Wait-MmtlLanPort -Path $hostProcess.LogPath -ProcessId $hostProcess.ProcessId -TimeoutSeconds 180
            if($requestedPort -and $port -ne $requestedPort){throw "游戏实际开放端口 $port 与配置固定端口 $requestedPort 不同。"}
            $metadata.port=$port
            for($i=1;$i -lt $players;$i++){
                $username=$prefix+$i
                $plan=New-MmtlGradleRunPlan -Project $Primary -Mode IntegratedLAN -RuntimeRoot $session -Role Client -Username $username -Port $port -Profile $Profile
                $started=Start-MmtlGradleInstance -Project $Primary -Plan $plan -JavaPath $java -SessionPath $session -ModJars @($extraJars)
                $metadata.processes+=@([pscustomobject]@{PID=$started.ProcessId;role='Client';username=$username;log=$started.LogPath})
                Write-Host "LAN 客户端 $username 已启动；日志：$($started.LogPath)"
            }
        }else{
            $plan=New-MmtlGradleRunPlan -Project $Primary -Mode Single -RuntimeRoot $session -Role Client -Username $hostName -Profile $Profile
            $started=Start-MmtlGradleInstance -Project $Primary -Plan $plan -JavaPath $java -SessionPath $session -ModJars @($extraJars)
            $metadata.processes+=@([pscustomobject]@{PID=$started.ProcessId;role='Client';username=$hostName;log=$started.LogPath})
            Write-Host "Single 客户端已启动；日志：$($started.LogPath)"
        }
        if($Profile.windowLayout -and $Profile.windowLayout -ne 'None' -and ($Profile.mode -ne 'Single' -or $Profile.windowLayout -ne 'Auto')){
            try{$layoutResult=Set-MmtlSessionWindowLayout -SessionPath $session -Mode $Profile.windowLayout -TimeoutSeconds 90;$metadata.windowLayoutStatus=$layoutResult.Status;if($layoutResult.Status -in @('Partial','UnavailableFallbackNone')){Write-Warning "窗口布局结果：$($layoutResult.Status) ($($layoutResult.Reason))"}else{Write-Host "窗口布局：$($layoutResult.Status) ($($layoutResult.Windows) 个窗口)"}}
            catch{$metadata.windowLayoutStatus='UnavailableFallbackNone';Write-Warning "窗口布局失败并安全跳过：$($_.Exception.Message)"}
        }else{$metadata.windowLayoutStatus='Skipped'}
        $metadata.builds=@($builds)
        $statePath=Join-Path $session 'session.json';$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json;$state.metadata=$metadata;$state|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $statePath -Encoding utf8
        $report=@("# Session $sessionId",'',"- Mode: $($Profile.mode)","- Project: $($Primary.Root)","- Minecraft: $($Primary.MinecraftVersion)","- Loader: $($Primary.Loader) $($Primary.LoaderVersion)","- Java: $($Primary.JavaMajor)","- Players: $($metadata.processes.username -join ', ')","- Port: $($metadata.port)","- Memory budget MB: $($memoryBudget.RequestedMb) / $($memoryBudget.LimitMb); overage confirmed=$memoryOverageConfirmed","- World reset count: $($metadata.worldResetCount)","- Window layout: $($metadata.windowLayoutStatus)","- Runtime: $session",'', '## Builds')
        foreach($build in $builds){$report+=@("- Project: $($build.Project)","  - Git SHA: $($build.GitSha)","  - Jar: $($build.JarPath)","  - SHA-256: $($build.JarSha256)","  - Log: $($build.LogPath)")}
        $report+=@('','## Processes');foreach($process in $metadata.processes){$report+="- $($process.role) $($process.username) PID $($process.PID): $($process.log)"};Set-Content -LiteralPath (Join-Path $session 'report.md') -Value $report -Encoding utf8
        Write-Host "会话清单：$session`n停止命令：launcher.cmd --stop $sessionId`n清理命令：launcher.cmd --clean-session $sessionId"
    }catch{Write-Error "Session $sessionId 已保留现场和日志。检查后可用 --stop $sessionId 停止登记进程。$($_.Exception.Message)";throw}
}
if($Arguments -contains '--validate') {
    if($project.Loader -eq 'Unknown'){throw '无法检测 Mod Loader。'}
    $java=if($project.JavaMajor){Resolve-MmtlJava -Config $config -Major $project.JavaMajor}else{'未能自动判断 Java 主版本'}
    $linked=@($profile.linkedProjects|Where-Object{$_}|ForEach-Object{Get-MmtlProject -Path $_})
    if($linked.Count){Assert-MmtlCompatible -Projects (@($project)+$linked)|Out-Null}
    Assert-MmtlNoReparsePath -Path $runtimeRoot|Out-Null
    $extra=@();foreach($item in @($profile.extraMods|Where-Object{$_})){$path=[string]$item;if(-not[IO.Path]::IsPathRooted($path)){$path=Join-Path $here $path};$resolved=(Resolve-Path -LiteralPath $path -ErrorAction Stop).Path;if([IO.Path]::GetExtension($resolved) -ne '.jar'){throw "Extra Mod 必须为 JAR：$item"};$extra+=$resolved}
    $portStatus='Not required'
    if($profile.mode -in @('IntegratedLAN','Dedicated')){if([string]$profile.port -eq 'Auto'){$portStatus='Auto (assigned at launch)'}else{$fixed=[int]$profile.port;$null=Get-MmtlPort -Port $fixed;$portStatus="Available: $fixed"}}
    $minecraftCatalogStatus='Unavailable';$metadataStatus='Unavailable';$currentStable='Unknown';$runtimeJavaMajor=$null;$runtimeJavaSource='Unknown';$runtimeJavaKind='Unknown'
    try{
        $catalog=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $catalogRuntimeRoot -Offline
        $currentStable=[string]$catalog.latestRelease
        $entry=if($project.MinecraftVersion){Resolve-MmtlMinecraftVersion -MinecraftId ([string]$project.MinecraftVersion) -Catalog $catalog}else{$null}
        if($entry){$minecraftCatalogStatus=[string]$entry.catalogStatus;try{$metadata=Get-MmtlMinecraftVersionMetadata -CatalogEntry $entry -RuntimeRoot $catalogRuntimeRoot -Offline;$resolvedRuntime=Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId $entry.id -CatalogEntry $entry -VersionMetadata $metadata;$metadataStatus=$metadata.metadataStatus;$runtimeJavaMajor=$resolvedRuntime.major;$runtimeJavaSource=$resolvedRuntime.source;$runtimeJavaKind=$resolvedRuntime.requirementKind}catch{$metadataStatus=if($_.Exception.Message -match 'CACHE_UNAVAILABLE'){'Unavailable'}else{'Error'};$resolvedRuntime=Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId $entry.id -CatalogEntry $entry;$runtimeJavaMajor=$resolvedRuntime.major;$runtimeJavaSource=$resolvedRuntime.source;$runtimeJavaKind=$resolvedRuntime.requirementKind}}
    }catch{}
    [pscustomobject]@{Platform=(Get-MmtlPlatformDisplayName -OS $platform.OS);Architecture=$platform.Arch;WSL=$platform.IsWSL;Project=$project.Root;LinkedProjects=($linked.Root -join '; ');ExtraMods=($extra -join '; ');Loader=$project.Loader;LoaderVersion=$project.LoaderVersion;Minecraft=$project.MinecraftVersion;Java=$java;BuildJavaMajor=$project.BuildJavaMajor;RuntimeJavaMajor=$runtimeJavaMajor;RuntimeJavaSource=$runtimeJavaSource;RuntimeJavaRequirementKind=$runtimeJavaKind;MinecraftCatalogStatus=$minecraftCatalogStatus;MinecraftMetadataStatus=$metadataStatus;CurrentStable=$currentStable;Wrapper=$project.Wrapper;Mode=$profile.mode;Players=$profile.players;RuntimeRoot=$runtimeRoot;Port=$portStatus} | Format-List
    exit 0
}
if($Arguments -contains '--dry-run') {
    $linked=@($profile.linkedProjects|Where-Object{$_}|ForEach-Object{Get-MmtlProject -Path $_});if($linked.Count){Assert-MmtlCompatible -Projects (@($project)+$linked)|Out-Null}
    $java=Resolve-MmtlJava -Config $config -Major ([int]$project.JavaMajor);$resolvedProfileName=if($profileName){$profileName}else{[string]$config.defaultProfile};$previewRoot=Join-Path (Join-Path $runtimeRoot 'sessions') ('preview-'+$resolvedProfileName);$players=[int]$profile.players;$hostName=if($profile.hostUsername){[string]$profile.hostUsername}else{'Dev'};$prefix=if($profile.clientPrefix){[string]$profile.clientPrefix}else{'Dev_'}
    $autoPort=([string]$profile.port -eq 'Auto');$port=if($autoPort){25565}else{[int]$profile.port};$roles=[Collections.Generic.List[object]]::new()
    if($profile.mode -eq 'Single'){$roles.Add([pscustomobject]@{Role='Client';Username=$hostName})}
    elseif($profile.mode -eq 'IntegratedLAN'){$roles.Add([pscustomobject]@{Role='Host';Username=$hostName});for($i=1;$i -lt $players;$i++){$roles.Add([pscustomobject]@{Role='Client';Username=($prefix+$i)})}}
    else{$roles.Add([pscustomobject]@{Role='Server';Username=''});$roles.Add([pscustomobject]@{Role='Client';Username=$hostName});for($i=1;$i -lt $players;$i++){$roles.Add([pscustomobject]@{Role='Client';Username=($prefix+$i)})}}
    Write-Host "模式：$($profile.mode)；Minecraft：$($project.MinecraftVersion)；Loader：$($project.Loader) $($project.LoaderVersion)；Java：$java"
    $budget=Get-MmtlMemoryBudget -Profile $profile -Mode $profile.mode
    Write-Host "Runtime：$previewRoot；玩家数：$players；项目：$((@($project.Root)+@($linked.Root))-join '; ')；Build：$($profile.autoBuild -ne $false)；Clean：$([bool]$profile.cleanBuild)；内存：$($budget.RequestedMb)/$($budget.LimitMb) MB"
    if($autoPort -and $profile.mode -ne 'Single'){Write-Host '端口：Auto（命令预览中的 25565 仅占位，运行时会实际分配或读取端口）'}elseif($profile.mode -ne 'Single'){Write-Host "端口：$port"}
    if($profile.autoBuild -ne $false){foreach($candidate in @($project)+@($linked)){$buildCmd=Get-MmtlGradleCommand -Project $candidate -Task build -Clean:([bool]$profile.cleanBuild);Write-Host "[Build] $($buildCmd.File) $($buildCmd.Arguments -join ' ')"}}
    Write-Host "额外 Mod：$(@($profile.extraMods) -join '; ')"
    foreach($role in $roles){$plan=New-MmtlGradleRunPlan -Project $project -Mode $profile.mode -RuntimeRoot $previewRoot -Role $role.Role -Username $role.Username -Port $port -Profile $profile;$wrapper=Get-MmtlGradleCommand -Project $project -Task $plan.Task;$prefix=@($wrapper.File);if($wrapper.Invocation -eq 'sh'){$prefix=@('sh',$wrapper.WrapperPath)};Write-Host "[$($role.Role) $($role.Username)] $($prefix -join ' ') $($plan.Arguments -join ' ')"}
    Write-Host '安全说明：dry-run 不创建 Runtime、不执行 Gradle，也不启动 Minecraft。'
    exit 0
}
if($Arguments -contains '--launch') { Start-MmtlConfiguredRun -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot;exit 0 }
if($Arguments -contains '--build') {
    if($project.Loader -eq 'Unknown' -or -not $project.Wrapper){throw '项目 Loader 或 Gradle Wrapper 无法确认。'}
    if(-not $project.JavaMajor){throw '无法确定项目所需 Java 主版本；拒绝回退到系统 Java。'}
    $java=Resolve-MmtlJava -Config $config -Major $project.JavaMajor
    $javaHome=Split-Path (Split-Path $java -Parent) -Parent
    $session=New-MmtlSession -RuntimeRoot $runtimeRoot -Name ([IO.Path]::GetFileName($project.Root)) -Metadata ([pscustomobject]@{project=$project.Root;loader=$project.Loader;minecraft=$project.MinecraftVersion;javaMajor=$project.JavaMajor;players=$profile.players;mode=$profile.mode})
    $log=New-MmtlLogPath -RuntimeRoot $runtimeRoot -SessionPath $session -Name 'gradle-build'
    $cmd=Get-MmtlGradleCommand -Project $project -Task 'build' -Clean:([bool]$profile.cleanBuild)
    $oldJavaHome=$env:JAVA_HOME;$oldPath=$env:Path
    try{$env:JAVA_HOME=$javaHome;$env:Path=(Join-Path $javaHome 'bin')+[string]$platform.PathListSeparator+$oldPath;Push-Location $cmd.WorkingDirectory;try{$cmdArgs=$cmd.Arguments;& $cmd.File @cmdArgs *> $log;$buildExit=$LASTEXITCODE}finally{Pop-Location}}
    finally{$env:JAVA_HOME=$oldJavaHome;$env:Path=$oldPath}
    $jar=if($buildExit -eq 0){Get-ChildItem (Join-Path $project.Root 'build/libs') -Filter '*.jar' -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -notmatch 'sources|javadoc'}|Sort-Object LastWriteTime -Descending|Select-Object -First 1}else{$null}
    $gitSha=(& git -C $project.Root rev-parse HEAD 2>$null)
    $jarHash=if($jar){(Get-FileHash -LiteralPath $jar.FullName -Algorithm SHA256).Hash}else{$null}
    $statePath=Join-Path $session 'session.json';$state=Get-Content $statePath -Raw|ConvertFrom-Json
    $state|Add-Member -NotePropertyName exitCode -NotePropertyValue $buildExit -Force
    $state|Add-Member -NotePropertyName gitSha -NotePropertyValue $gitSha -Force
    $state|Add-Member -NotePropertyName jarPath -NotePropertyValue $(if($jar){$jar.FullName}else{$null}) -Force
    $state|Add-Member -NotePropertyName jarSha256 -NotePropertyValue $jarHash -Force
    $state|ConvertTo-Json -Depth 20|Set-Content $statePath -Encoding utf8
    "# Session $($state.sessionId)`n`nProject: $($project.Root)`nMinecraft: $($project.MinecraftVersion)`nLoader: $($project.Loader)`nJava: $($project.JavaMajor)`nGit SHA: $gitSha`nBuild exit code: $buildExit`nJar: $($jar.FullName)`nJar SHA-256: $jarHash`nGradle log: $log`n" | Set-Content (Join-Path $session 'report.md') -Encoding utf8
    Write-Host "Build exit code: $buildExit`nSession: $session`nLog: $log`nJar SHA-256: $jarHash"
    if($buildExit -ne 0){Get-Content $log -Tail 30;exit $buildExit};exit 0
}
Write-Host '当前版本只提供配置验证与 dry-run。实际 Minecraft 启动、多实例、LAN 与 Dedicated 编排尚未实现。'
exit 3
