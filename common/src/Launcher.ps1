[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$ErrorActionPreference='Stop'
if($null -eq $Arguments){$Arguments=@()}
 $here=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$commonRoot=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $commonRoot 'src/Platform/Platform.psm1') -Force
$platform=Get-MmtlPlatformProvider
Get-ChildItem (Join-Path $commonRoot 'src') -Filter '*.psm1' -Recurse | ForEach-Object { Import-Module $_.FullName -Force }
# ValidationRunner 会在模块作用域内强制重载依赖；批量加载后需恢复 CLI 的公开命令绑定。
Import-Module (Join-Path $commonRoot 'src/RuntimeBindingProbe.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/JavaDiscovery.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/Doctor.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/GradleRunner.psm1') -Force
Import-Module (Join-Path $commonRoot 'src/Platform/Platform.psm1') -Force
Import-Module (Join-Path $commonRoot 'src/Execution/ExecutionPlan.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/Execution/ExecutionPlanner.psm1') -Force
Import-Module (Join-Path $commonRoot 'src/SessionLifecycle.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/SessionRecovery.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/SessionLock.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/AtomicFile.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/RuntimeManager.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/Execution/ExecutionPlan.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/Platform/Platform.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/Catalog/JavaRuntimeResolver.psm1') -Force -Global
Import-Module (Join-Path $commonRoot 'src/Config.psm1') -Force
Import-Module (Join-Path $commonRoot 'src/ProjectDetector.psm1') -Force
Import-Module (Join-Path $commonRoot 'src/Validation/ValidationPlan.psm1') -Force
Import-Module (Join-Path $commonRoot 'src/Validation/ValidationMatrix.psm1') -Force
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
    Write-Host 'Minecraft Mod 开发者测试启动器';Write-Host '用法：launcher.cmd / launcher.sh [--import-project <path>|--list-projects|--project-info <id>|--remove-project <id>|--plan|--scenario-plan|--launch-check|--runtime-binding|--doctor|--capabilities|--explain-java|--validate|--dry-run|--build|--launch|--launch-rehearsal|--human-validation-plan] [--profile NAME]';Write-Host '项目：--import-project <path> [--primary-mod-id ID] [--json]（只读探测并登记）| --list-projects [--json] | --project-info <id> [--json] | --remove-project <id> [--json]';Write-Host '执行计划：--plan [--json] [--plan-output <path>]；场景只读计划：--scenario-plan [--json]；启动预检：--launch-check [--json]；Runtime Binding：--runtime-binding [--probe] [--json]';Write-Host '环境诊断：--doctor [--offline] [--json]；平台能力：--capabilities [--json]；Java 解析：--explain-java [--json]';Write-Host '人工验证准备：--human-validation-plan [--json]；只生成本地计划与 HANDOVER/manual-validation 包，不启动 Minecraft。';Write-Host '工作区发现：--discover-projects <workspace-or-repository> [--json]';Write-Host '版本目录：--list-minecraft-versions | --minecraft-info <id|CurrentStable> | --refresh-catalog';Write-Host '加载器：--list-loaders <mc> [--include-historical] | --loader-info <mc> <loader> | --provider-status <loader>';Write-Host '覆盖审计：';foreach($option in Get-MmtlCoverageCliOptionDefinitions){Write-Host "  $($option.usage) — $($option.description)"};Write-Host '深度验证：--validation-plan --scope P0|CurrentStable | --validation-matrix <target-definitions.json> [--validation-output <path>] | --validation-summary [--validation-version <mc>] [--validation-loader <id>]';Write-Host '历史生态提供器仅使用 HTTPS 元数据与缓存；不会自动执行仅提供 HTTP 的制品。';Write-Host '离线选项：--catalog-offline 仅影响 Mojang 版本目录；--loader-offline 仅影响加载器元数据；均不改变 Gradle 离线模式。';Write-Host '会话：--list-sessions [--json] | --recover-sessions [--dry-run] [--json] | --session-info ID [--json] | --session-validate ID | --stop ID | --clean-session ID';Write-Host '日志分析：--analyze-session ID [--json] | --session-report ID [--json]；规则分析会保留 raw 日志，不把无异常信号解释为 Mod 功能通过。';Write-Host '运行时观察：--observe-session ID [--timeout-seconds N] [--json] | --session-events ID [--json]；只观察当前 Session 登记数据，不启动 Minecraft。';Write-Host '场景：--scenario-plan [--json] 只读生成顺序；--run-scenario 执行非交互场景；--scenario-status ID 查询；--scenario-action ID WAIT|SEND_COMMAND|SCREENSHOT|STOP_ROLE|STOP_ALL；SEND_COMMAND 需显式 --grant-command-permission，SCREENSHOT 需受管 Agent。';Write-Host '安全演练：--launch-rehearsal [--json]；按 Plan 模式执行 Single、Dedicated 或 IntegratedLAN 合成 harness，不启动真实 Minecraft。';Write-Host '运行目录：--portable';Write-Host '不传参数时进入交互模式；--config-file 仅供临时配置调用。';exit 0
}
$capabilitiesIndex=[Array]::IndexOf($Arguments,'--capabilities')
if($capabilitiesIndex -ge 0){
    $capabilities=Get-MmtlPlatformCapabilities -Platform $platform
    if($Arguments -contains '--json'){$capabilities|ConvertTo-Json -Depth 20}else{Write-Host "平台：$($capabilities.os) / $($capabilities.arch)";foreach($name in @('Build','Launch','WindowManagement','ProcessManagement','FabricRuntimeLink','RuntimeBinding','JavaDiscovery','Doctor','SessionManagement')){Write-Host "${name}：$($capabilities.$name)"}}
    exit 0
}
$projectRegistryOperations=@('--import-project','--list-projects','--project-info','--remove-project')
$projectRegistryMode=@($Arguments|Where-Object{$_ -in $projectRegistryOperations}).Count -gt 0
$readOnlyPlanMode=($Arguments -contains '--plan' -or $Arguments -contains '--scenario-plan' -or $Arguments -contains '--scenario-status' -or $Arguments -contains '--scenario-action' -or $Arguments -contains '--explain-java' -or $Arguments -contains '--launch-check' -or $Arguments -contains '--runtime-binding' -or $Arguments -contains '--doctor' -or $Arguments -contains '--human-validation-plan' -or $Arguments -contains '--analyze-session' -or $Arguments -contains '--session-report' -or $projectRegistryMode)
$config=if(Test-Path $configPath){try{Read-MmtlConfig -Path $configPath -AllowInvalidProfiles:$readOnlyPlanMode}catch{if($Arguments -contains '--doctor'){$null}else{throw}}}else{$null}
$runtimeConfigured=if($config -and $config.runtimeRoot){[string]$config.runtimeRoot}else{''}
$runtimeRoot=Resolve-MmtlRuntimeRoot -Path $runtimeConfigured -Portable:$portable -LauncherRoot $here
foreach($analysisOption in @('--analyze-session','--session-report')){
    $analysisIndex=[Array]::IndexOf($Arguments,$analysisOption)
    if($analysisIndex -ge 0){
        if($analysisIndex+1 -ge $Arguments.Count){throw "$analysisOption 缺少 Session ID。"}
        $id=[string]$Arguments[$analysisIndex+1];if($id -notmatch '^\d{8}T\d{6}Z_[A-Za-z0-9_-]{1,60}$'){throw 'ANALYSIS_SESSION_ID_INVALID'}
        $sessionsRoot=Join-Path $runtimeRoot 'sessions';$sessionPath=Join-Path $sessionsRoot $id
        if(-not(Test-MmtlInsideRoot -Root $sessionsRoot -Target $sessionPath) -or -not(Test-Path -LiteralPath $sessionPath -PathType Container)){throw 'ANALYSIS_SESSION_NOT_FOUND'}
        $sessionManifest=Join-Path $sessionPath 'session.json';if(-not(Test-Path -LiteralPath $sessionManifest -PathType Leaf)){throw 'ANALYSIS_SESSION_MANIFEST_MISSING'}
        $sessionDoc=Get-Content -LiteralPath $sessionManifest -Raw|ConvertFrom-Json -ErrorAction Stop;if([string]$sessionDoc.sessionId -and [string]$sessionDoc.sessionId -cne $id){throw 'ANALYSIS_SESSION_ID_MISMATCH'}
        $sessionMetadata=$sessionDoc.metadata;$projectRoot=[string]$sessionMetadata.project
        if(-not $projectRoot -or -not(Test-Path -LiteralPath $projectRoot -PathType Container)){throw 'ANALYSIS_PROJECT_METADATA_UNAVAILABLE'}
        $projectModel=Get-MmtlProject -Path $projectRoot;$modMetadata=Get-MmtlProjectModMetadata -Project $projectModel
        $projectMetadata=[pscustomobject][ordered]@{modIds=@($modMetadata.modIds);primaryModId=$(if($sessionMetadata.primaryModId){[string]$sessionMetadata.primaryModId}elseif($modMetadata.primaryModId){[string]$modMetadata.primaryModId}else{$null});modNames=@($modMetadata.modNames);packageCandidates=@($modMetadata.packageCandidates);mixinConfigs=@($modMetadata.mixinConfigs);entrypointClasses=@($modMetadata.entrypointClasses);artifactNames=@($modMetadata.artifactNames);loaderId=[string]$sessionMetadata.loader;minecraftVersion=[string]$sessionMetadata.minecraft}
        if(Test-Path -LiteralPath (Join-Path $sessionPath 'pids.json') -PathType Leaf){$null=Import-MmtlSessionLogs -SessionPath $sessionPath}
        $scenarioResult='PARTIAL';$scenarioPath=Join-Path $sessionPath 'scenario.json';if(Test-Path -LiteralPath $scenarioPath){$scenarioDoc=Get-Content -LiteralPath $scenarioPath -Raw|ConvertFrom-Json;$scenarioResult=switch([string]$scenarioDoc.state){'Completed'{'PASS'}'Failed'{'FAIL'}'Blocked'{'BLOCKED'}'Aborted'{'ABORTED'}default{'PARTIAL'}}}
        $analysis=Invoke-MmtlAnalyzer -Provider RuleBasedAnalyzer -SessionPath $sessionPath -ProjectMetadata $projectMetadata -ScenarioResult $scenarioResult -RuntimeStatus ([string]$sessionDoc.state) -SessionMetadata $sessionMetadata
        if($analysisOption -eq '--session-report'){$markdown=Get-Content -LiteralPath (Join-Path $sessionPath 'analysis/summary.md') -Raw;if($Arguments -contains '--json'){$report=[pscustomobject][ordered]@{status=$analysis.status;sessionId=$id;summary=$analysis;markdown=$markdown};$report|ConvertTo-Json -Depth 30 -Compress}else{Write-Output $markdown};exit 0}
        if($Arguments -contains '--json'){$analysis|ConvertTo-Json -Depth 30 -Compress}else{Write-Host "分析完成：$($analysis.findingCount) finding(s)，Session $id";$analysis.findings|Format-Table findingId,likelyCategory,attribution,confidence -AutoSize};exit 0
    }
}
$observationResult=Invoke-MmtlObservationCommand -Arguments $Arguments -RuntimeRoot $runtimeRoot
if($null -ne $observationResult){if($Arguments -contains '--json'){$observationResult|ConvertTo-Json -Depth 30 -Compress}else{$observationResult|ConvertTo-Json -Depth 30};exit 0}
if($Arguments -contains '--scenario-status'){
    $index=[Array]::IndexOf($Arguments,'--scenario-status');if($index+1 -ge $Arguments.Count){throw 'SCENARIO_SESSION_ID_REQUIRED'}
    $id=[string]$Arguments[$index+1];if($id -notmatch '^\d{8}T\d{6}Z_[A-Za-z0-9_-]{1,60}$'){throw 'SCENARIO_SESSION_ID_INVALID'}
    $sessionRoot=Join-Path $runtimeRoot 'sessions';$sessionPath=Join-Path $sessionRoot $id
    if(-not(Test-MmtlInsideRoot -Root $sessionRoot -Target $sessionPath)){throw 'SCENARIO_SESSION_PATH_INVALID'}
    $status=Get-MmtlScenarioStatus -SessionPath $sessionPath
    if([string]$status.sessionId -cne $id){throw 'SCENARIO_SESSION_ID_MISMATCH'}
    if($Arguments -contains '--json'){$status|ConvertTo-Json -Depth 30 -Compress}else{$status|Format-List}
    exit 0
}
if($Arguments -contains '--scenario-action'){
    $index=[Array]::IndexOf($Arguments,'--scenario-action');if($index+2 -ge $Arguments.Count){throw 'SCENARIO_ACTION_ARGUMENTS_REQUIRED'}
    $id=[string]$Arguments[$index+1];$action=[string]$Arguments[$index+2]
    if($id -notmatch '^\d{8}T\d{6}Z_[A-Za-z0-9_-]{1,60}$'){throw 'SCENARIO_SESSION_ID_INVALID'}
    $sessionRoot=Join-Path $runtimeRoot 'sessions';$sessionPath=Join-Path $sessionRoot $id
    if(-not(Test-MmtlInsideRoot -Root $sessionRoot -Target $sessionPath)){throw 'SCENARIO_SESSION_PATH_INVALID'}
    $roleIndex=[Array]::IndexOf($Arguments,'--role');$role=if($roleIndex -ge 0 -and $roleIndex+1 -lt $Arguments.Count){[string]$Arguments[$roleIndex+1]}else{$null}
    $secondsIndex=[Array]::IndexOf($Arguments,'--seconds');$seconds=if($secondsIndex -ge 0 -and $secondsIndex+1 -lt $Arguments.Count){[int]$Arguments[$secondsIndex+1]}else{0}
    $commandIndex=[Array]::IndexOf($Arguments,'--command');$command=if($commandIndex -ge 0 -and $commandIndex+1 -lt $Arguments.Count){[string]$Arguments[$commandIndex+1]}else{$null}
    $grantPermission=$Arguments -contains '--grant-command-permission'
    $actionParameters=@{SessionPath=$sessionPath;Action=$action;Seconds=$seconds;PermissionGranted=$grantPermission;AgentDispatcher={param($agentAction,$agentRole,$agentCommand,$agentSession,$agentPermission) Invoke-MmtlAgentAction -SessionPath $agentSession -Role $agentRole -Action $agentAction -Command $agentCommand -PermissionGranted:([bool]$agentPermission)};StopProcess={param($targetSession,$processId) Stop-MmtlTrackedProcess -SessionPath $targetSession -ProcessId $processId -Confirm:$false}}
    if($role){$actionParameters.Role=$role};if($command){$actionParameters.Command=$command}
    $actionResult=Invoke-MmtlScenarioAction @actionParameters
    if($action -eq 'STOP_ALL'){$null=Import-MmtlSessionLogs -SessionPath $sessionPath;$finalStatus=Update-MmtlSessionReport -SessionPath $sessionPath;$sessionV2=Test-MmtlSessionV2 -SessionPath $sessionPath;if($sessionV2.valid -and $sessionV2.state -eq 'Running' -and $finalStatus.Status -eq 'Stopped'){Set-MmtlSessionV2State -SessionPath $sessionPath -State Stopped|Out-Null};$actionResult|Add-Member -NotePropertyName sessionState -NotePropertyValue $finalStatus.Status -Force}
    if($Arguments -contains '--json'){$actionResult|ConvertTo-Json -Depth 20 -Compress}else{$actionResult|Format-List}
    exit 0
}
if($projectRegistryMode){
    $operations=@($Arguments|Where-Object{$_ -in $projectRegistryOperations})
    if($operations.Count -ne 1){[Console]::Error.WriteLine('每次只能指定一个项目 Registry 命令。');exit 2}
    $operation=[string]$operations[0];$index=[Array]::IndexOf($Arguments,$operation);$result=$null
    try{
        switch($operation){
            '--import-project' {
                if($index+1 -ge $Arguments.Count){throw 'PROJECT_PATH_REQUIRED'}
                $primaryIndex=[Array]::IndexOf($Arguments,'--primary-mod-id');$primaryModId=$null
                if($primaryIndex -ge 0 -and $primaryIndex+1 -lt $Arguments.Count){$primaryModId=[string]$Arguments[$primaryIndex+1]}
                else{$selectedProfileIndex=[Array]::IndexOf($Arguments,'--profile');$selectedProfileName=if($selectedProfileIndex -ge 0 -and $selectedProfileIndex+1 -lt $Arguments.Count){[string]$Arguments[$selectedProfileIndex+1]}else{$null};if($config){$selectedProfile=Get-MmtlProfile -Config $config -Name $selectedProfileName;if($selectedProfile.PSObject.Properties['primaryModId'] -and $selectedProfile.primaryModId){$primaryModId=[string]$selectedProfile.primaryModId}}}
                $result=Import-MmtlProject -Path ([string]$Arguments[$index+1]) -RuntimeRoot $runtimeRoot -PrimaryModId $primaryModId
            }
            '--list-projects' { $registry=Get-MmtlProjectRegistry -RuntimeRoot $runtimeRoot;$result=[pscustomobject][ordered]@{schemaVersion=1;projects=@($registry.projects)} }
            '--project-info' {
                if($index+1 -ge $Arguments.Count){throw 'PROJECT_ID_REQUIRED'}
                $id=[guid]::Empty;if(-not[guid]::TryParse([string]$Arguments[$index+1],[ref]$id)){throw 'PROJECT_ID_INVALID'}
                $registry=Get-MmtlProjectRegistry -RuntimeRoot $runtimeRoot;$result=$registry.projects|Where-Object{[string]$_.projectId -ceq $id.ToString('D')}|Select-Object -First 1
                if(-not $result){throw 'PROJECT_NOT_FOUND'}
            }
            '--remove-project' {
                if($index+1 -ge $Arguments.Count){throw 'PROJECT_ID_REQUIRED'}
                $id=[guid]::Empty;if(-not[guid]::TryParse([string]$Arguments[$index+1],[ref]$id)){throw 'PROJECT_ID_INVALID'}
                $removed=Remove-MmtlProjectRegistryEntry -RuntimeRoot $runtimeRoot -ProjectId $id
                if(-not $removed){throw 'PROJECT_NOT_FOUND'}
                $result=[pscustomobject][ordered]@{schemaVersion=1;removed=$true;projectId=$id.ToString('D')}
            }
        }
        if($Arguments -contains '--json'){$result|ConvertTo-Json -Depth 40 -Compress}else{
            switch($operation){
                '--import-project' { Write-Host "项目已登记：$($result.projectId)；Gradle targets=$($result.targetCount)" }
                '--list-projects' { Write-Host "本地项目数：$(@($result.projects).Count)";@($result.projects)|Select-Object projectId,targetCount,importedAtUtc|Format-Table -AutoSize }
                '--project-info' { $result|Format-List }
                '--remove-project' { Write-Host "已从本地 Registry 移除项目登记：$($result.projectId)" }
            }
        }
        exit 0
    }catch{
        $code=[string]$_.Exception.Message
        if($Arguments -contains '--json'){
            [pscustomobject][ordered]@{schemaVersion=1;status='Failed';error=[pscustomobject][ordered]@{code=$code;message=if($code -eq 'PROJECT_REGISTRY_CORRUPT'){'本地项目 Registry 已损坏，未覆盖原文件。'}else{$code}}}|ConvertTo-Json -Depth 10 -Compress
        }else{[Console]::Error.WriteLine($code)}
        exit 2
    }
}
$catalogRuntimeRoot=$runtimeRoot
if($platform.OS -in @('Linux','MacOS') -and $runtimeConfigured -match '^%LOCALAPPDATA%([\\/]|$)'){
    $catalogRuntimeRoot=$platform.DefaultRuntimeRoot
    Write-Warning '当前平台不支持 Windows 专用的 %LOCALAPPDATA% runtimeRoot；已忽略该目录并改用本平台的 Runtime Root。'
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
    if($validationMatrixIndex+1 -ge $Arguments.Count){throw '--validation-matrix 缺少目标定义 JSON 文件路径。'}
    $targetPath=[IO.Path]::GetFullPath([string]$Arguments[$validationMatrixIndex+1])
    if(-not(Test-Path -LiteralPath $targetPath -PathType Leaf)){throw '未找到验证目标定义文件。'}
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
    if($scopeIndex -lt 0 -or $scopeIndex+1 -ge $Arguments.Count){throw '--validation-plan 需要搭配 --scope P0 或 --scope CurrentStable。'}
    $scope=[string]$Arguments[$scopeIndex+1]
    if($scope -notin @('P0','CurrentStable')){throw '验证计划范围必须为 P0 或 CurrentStable。'}
    $catalog=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $catalogRuntimeRoot -Offline:$catalogOffline
    $fixturePath=Join-Path $commonRoot 'fixtures/deep-validation/fixtures.json'
    if(-not(Test-Path -LiteralPath $fixturePath -PathType Leaf)){throw '缺少已固定版本的官方 fixture 清单。'}
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
if($hasLoaderInfo -and [string]$Arguments[$loaderInfoIndex+2] -notin @('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){throw "不支持的 Loader：$($Arguments[$loaderInfoIndex+2])"}
if($jarModArtifactIndex -ge 0 -and (-not $hasLoaderInfo -or [string]$Arguments[$loaderInfoIndex+2] -ne 'JarMod')){throw '--jar-mod-artifact 只能与 --loader-info <mc> JarMod 组合。'}
if($jarModArtifactIndex -ge 0 -and ($jarModArtifactIndex+1 -ge $Arguments.Count -or $jarModStrategyIndex -lt 0 -or $jarModStrategyIndex+1 -ge $Arguments.Count)){throw '--jar-mod-artifact 需要文件路径，且必须提供 --patch-strategy。'}
if($hasProviderStatus -and [string]$Arguments[$providerStatusIndex+1] -notin @('LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){throw "不支持的历史 Provider：$($Arguments[$providerStatusIndex+1])"}
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
    if($loaderId -notin @('Forge','Fabric','NeoForge','Quilt')){throw "不支持的 Loader：$loaderId"}
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
if($catalogOffline -and $refreshCatalog){throw 'CATALOG_OPTION_CONFLICT: --refresh-catalog 不能与 --catalog-offline 同时使用。'}
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
    Write-Output "Mojang 版本目录已刷新。状态：$($catalog.cacheStatus)；正式版本数：$($catalog.entries.Count)；当前稳定版：$($catalog.latestRelease)"
    exit 0
}
if ($Arguments -contains '--list-sessions') {
    $sessions=Join-Path $runtimeRoot 'sessions'
    $rows=@();if(Test-Path $sessions){foreach($dir in Get-ChildItem $sessions -Directory){$v2=Test-MmtlSessionV2 -SessionPath $dir.FullName;if($v2.status -ne 'LegacyOrManifestMissing'){$created=$null;try{$created=[DateTimeOffset](Get-Content (Join-Path $dir.FullName 'session.v2.json') -Raw|ConvertFrom-Json).createdUtc}catch{};$rows+=@([pscustomobject]@{sessionId=$dir.Name;schemaVersion=2;state=$v2.state;validation=$v2.status;planDigest=$v2.planDigest;createdUtc=$created})}else{$legacy=Join-Path $dir.FullName 'session.json';$state=$null;$created=$null;if(Test-Path $legacy){try{$legacyState=Get-Content $legacy -Raw|ConvertFrom-Json;$state=$legacyState.sessionId;$created=[DateTimeOffset]$legacyState.createdUtc}catch{}};$rows+=@([pscustomobject]@{sessionId=$dir.Name;schemaVersion=1;state='LegacyReadOnly';validation='Legacy';planDigest=$null;createdUtc=$created})}}}
    $sessionSort=[Collections.Generic.List[object]]::new();foreach($row in $rows){$sessionSort.Add($row)}
    $sessionSort.Sort([System.Comparison[object]]{param($left,$right)$leftTicks=0L;$rightTicks=0L;if($left.createdUtc){$leftTicks=([DateTimeOffset]$left.createdUtc).UtcTicks};if($right.createdUtc){$rightTicks=([DateTimeOffset]$right.createdUtc).UtcTicks};$dateOrder=$rightTicks.CompareTo($leftTicks);if($dateOrder -ne 0){return $dateOrder};return [StringComparer]::Ordinal.Compare([string]$left.sessionId,[string]$right.sessionId)})
    $rows=@($sessionSort.ToArray())
    if($Arguments -contains '--json'){$rows|ConvertTo-Json -Depth 10;exit 0};foreach($row in $rows){Write-Output "$($row.sessionId) [v$($row.schemaVersion):$($row.state); $($row.validation)]"};exit 0
}
if($Arguments -contains '--recover-sessions'){
    $plan=Get-MmtlSessionRecoveryPlan -RuntimeRoot $runtimeRoot
    $result=if($Arguments -contains '--dry-run'){[pscustomobject]@{schemaVersion=1;dryRun=$true;actions=$plan.actions}}else{Invoke-MmtlSessionRecovery -RuntimeRoot $runtimeRoot -Plan $plan}
    if($Arguments -contains '--json'){
        $safeActions=@($result.actions|ForEach-Object{[pscustomobject][ordered]@{sessionId=$_.sessionId;code=$_.code;reasonCode=$_.reasonCode;plannedAction=$_.plannedAction;tempName=$_.tempName}})
        if($Arguments -contains '--dry-run'){[pscustomobject]@{schemaVersion=1;dryRun=$true;actions=$safeActions}|ConvertTo-Json -Depth 20}else{[pscustomobject]@{schemaVersion=1;recovered=$result.recovered;skipped=$result.skipped;results=$result.results}|ConvertTo-Json -Depth 20}
    }else{
        if($Arguments -contains '--dry-run'){Write-Host "Session 恢复预览：$($result.actions.Count) 项";foreach($action in $result.actions){Write-Host "[$($action.code)] $($action.sessionId)：$($action.reasonCode)；操作=$($action.plannedAction)"}}
        else{Write-Host "Session 恢复：修复 $($result.recovered)；跳过 $($result.skipped)";foreach($item in $result.results){Write-Host "[$($item.status)] $($item.sessionId)：$($item.code)"}}
    }
    exit 0
}
foreach($operation in @('--session-info','--session-validate')){
    $index=[Array]::IndexOf($Arguments,$operation)
    if($index -ge 0){
        if($index+1 -ge $Arguments.Count){throw "$operation 缺少 Session ID。"}
        $id=[string]$Arguments[$index+1];if($id -notmatch '^\d{8}T\d{6}Z_[A-Za-z0-9_-]{1,60}$'){throw 'Session ID 格式不合法。'}
        $sessions=Join-Path $runtimeRoot 'sessions';$sessionPath=Join-Path $sessions $id
        if(-not(Test-MmtlInsideRoot -Root $sessions -Target $sessionPath)){throw 'Session 路径越界。'}
        $result=Test-MmtlSessionV2 -SessionPath $sessionPath
        if($operation -eq '--session-info'){
            if($result.status -eq 'LegacyOrManifestMissing'){$legacyPath=Join-Path $sessionPath 'session.json';if(-not(Test-Path $legacyPath)){throw 'SESSION_NOT_FOUND'};$legacy=Get-Content $legacyPath -Raw|ConvertFrom-Json;$result=[pscustomobject]@{sessionId=$id;schemaVersion=1;state='LegacyReadOnly';createdUtc=$legacy.createdUtc;metadata=$legacy.metadata}}
            if($Arguments -contains '--json'){$result|ConvertTo-Json -Depth 40}else{$result|Format-List};exit 0
        }
        if($Arguments -contains '--json'){$result|ConvertTo-Json -Depth 20}else{Write-Host "Session 验证：$($result.status)；合法=$($result.valid)；错误=$($result.errors -join ', ')"}
        if(-not $result.valid){exit 2};exit 0
    }
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
        $null=Import-MmtlSessionLogs -SessionPath $sessionPath
        $finalStatus=Update-MmtlSessionReport -SessionPath $sessionPath
        $sessionV2=Test-MmtlSessionV2 -SessionPath $sessionPath
        if($sessionV2.valid -and $sessionV2.state -eq 'Running'){$nextState=switch($finalStatus.Status){'Completed'{'Completed'}'Stopped'{'Stopped'}'Failed'{'Failed'}default{$null}};if($nextState){Set-MmtlSessionV2State -SessionPath $sessionPath -State $nextState|Out-Null}}
        Write-Host "Session $id 状态：$($finalStatus.Status)`n报告：$($finalStatus.ReportPath)";exit 0
    }
}
if (-not (Test-Path $configPath) -and $Arguments -notcontains '--human-validation-plan' -and -not $projectRegistryMode) {
    Write-Host 'Minecraft 模组测试启动器 - 临时向导'
    $examplePath=Join-Path $commonRoot 'config/launcher.config.example.json'
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
$profile=$null;$project=$null
if($config -and $Arguments -notcontains '--human-validation-plan' -and -not $projectRegistryMode){$profile=Get-MmtlProfile -Config $config -Name $profileName;if(-not $readOnlyPlanMode){Assert-MmtlProfile -Profile $profile | Out-Null};if($Arguments -notcontains '--scenario-plan' -and $Arguments -notcontains '--scenario-status' -and $Arguments -notcontains '--scenario-action'){$project=Get-MmtlProject -Path $profile.project}}
if($Arguments -contains '--scenario-plan'){
    if(-not $profile){throw 'SCENARIO_PROFILE_REQUIRED'}
    $hostName=if($profile.hostUsername){[string]$profile.hostUsername}else{'MMTL_Host'}
    $guestPrefix=if($profile.clientPrefix){[string]$profile.clientPrefix}else{'MMTL_C'}
    $scenarioPlan=New-MmtlScenarioPlan -Mode ([string]$profile.mode) -Players ([int]$profile.players) -HostUsername $hostName -GuestPrefix $guestPrefix -AutoCreateWorld:([bool]$profile.newWorld) -DurationSeconds $(if($profile.durationSeconds){[int]$profile.durationSeconds}else{60})
    $result=[pscustomobject][ordered]@{schemaVersion=1;status='PlanOnly';plan=$scenarioPlan;dedicatedEulaAccepted=([string]$profile.mode -ne 'Dedicated' -or $profile.acceptEula -eq $true)}
    if($Arguments -contains '--json'){$result|ConvertTo-Json -Depth 20 -Compress}else{$result.plan|Format-List}
    exit 0
}
function New-MmtlCliExecutionPlan {
    param([Parameter(Mandatory)]$Primary,[Parameter(Mandatory)]$Profile,[Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$RuntimeRoot,[string]$Name,[switch]$RequireBuild,[switch]$Clean)
    $catalogEntry=$null;$versionMetadata=$null;$metadataWarning=$null
    if($Primary.MinecraftVersion){
        try{$catalog=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $catalogRuntimeRoot -Offline;$catalogEntry=Resolve-MmtlMinecraftVersion -MinecraftId ([string]$Primary.MinecraftVersion) -Catalog $catalog}
        catch{$metadataWarning=$_.Exception.Message}
        if($catalogEntry){try{$versionMetadata=Get-MmtlMinecraftVersionMetadata -CatalogEntry $catalogEntry -RuntimeRoot $catalogRuntimeRoot -Offline}catch{$metadataWarning=$_.Exception.Message}}
        if(-not $catalogEntry){$catalogEntry=[pscustomobject]@{id=[string]$Primary.MinecraftVersion;metadataStatus='UNAVAILABLE'}}
    }
    $context=Get-MmtlPlatformContext
    $launchCapability=if($context.os -eq 'Windows'){'Native'}else{'BuildOnly'}
    $context.capabilities|Add-Member -NotePropertyName Launch -NotePropertyValue $launchCapability -Force
    $physicalMemory=0L;try{$physicalMemory=[long](Get-MmtlPhysicalMemoryMb)}catch{}
    $parameters=@{Project=$Primary;Profile=$Profile;Config=$Config;Platform=$context;RuntimeRoot=$RuntimeRoot;ProfileName=$Name;CatalogEntry=$catalogEntry;VersionMetadata=$versionMetadata;MetadataWarning=$metadataWarning;PhysicalMemoryMb=$physicalMemory}
    if($RequireBuild){$parameters.BuildRequired=$true}
    if($Clean){$parameters.CleanBuild=$true}
    $basePlan=New-MmtlExecutionPlan @parameters
    $cachedBinding=Get-MmtlCachedRuntimeBindingEvidence -Project $Primary -Plan $basePlan -RuntimeRoot $RuntimeRoot
    if(-not $cachedBinding){return $basePlan}
    $parameters.AdapterEvidence=[pscustomobject]@{runtimeJavaBindingMode=[string]$cachedBinding.runtimeJavaBinding.mode;runtimeJavaBindingEvidence=$cachedBinding.runtimeJavaBinding}
    return New-MmtlExecutionPlan @parameters
}
$humanValidationPlanIndex=[Array]::IndexOf($Arguments,'--human-validation-plan')
if($humanValidationPlanIndex -ge 0){
    $workspaceRoot=$here
    while($workspaceRoot -and -not (Test-Path -LiteralPath (Join-Path $workspaceRoot 'PycodersMod.projects.json') -PathType Leaf)){$parent=Split-Path -Parent $workspaceRoot;if($parent -eq $workspaceRoot){$workspaceRoot=$null}else{$workspaceRoot=$parent}}
    if(-not $workspaceRoot){throw 'PORTFOLIO_FILE_NOT_FOUND: 未找到工作区 PycodersMod.projects.json。'}
    $portfolioFile=Join-Path $workspaceRoot 'PycodersMod.projects.json';$portfolioMap=Get-Content -LiteralPath $portfolioFile -Raw|ConvertFrom-Json -ErrorAction Stop
    $localConfigCandidate=Join-Path (Join-Path $workspaceRoot 'MinecraftModTestLauncher') 'launcher.config.json'
    $sourceConfigPath=if($config){$configPath}elseif(Test-Path -LiteralPath $localConfigCandidate){$localConfigCandidate}else{Join-Path $commonRoot 'config/launcher.config.example.json'}
    $sourceConfig=if($config){$config}else{Read-MmtlConfig -Path $sourceConfigPath -AllowInvalidProfiles}
    $baseProfile=Get-MmtlProfile -Config $sourceConfig
    $history=@();$historyFile=Join-Path $workspaceRoot 'HANDOVER/logs/phase-i-k/portfolio-plans.local.json';if(Test-Path -LiteralPath $historyFile){try{$history=@(Get-Content -LiteralPath $historyFile -Raw|ConvertFrom-Json)}catch{}}
    $buildHistory=@();$buildHistoryFile=Join-Path $workspaceRoot 'HANDOVER/logs/phase-i-k/portfolio-builds.local.json';if(Test-Path -LiteralPath $buildHistoryFile){try{$buildHistory=@(Get-Content -LiteralPath $buildHistoryFile -Raw|ConvertFrom-Json)}catch{}}
    $portfolio=[Collections.Generic.List[object]]::new()
    foreach($entry in $portfolioMap.projects.PSObject.Properties){
        $record=$entry.Value;$projectRoot=Join-Path (Join-Path $workspaceRoot ([string]$record.path)) ([string]$record.gradleProject)
        $targetId=([string]$record.repository).ToLowerInvariant();$prior=$history|Where-Object{[string]$_.Project -ceq [string]$record.modId}|Select-Object -First 1;$priorBuild=$buildHistory|Where-Object{[string]$_.Project -ceq [string]$record.modId}|Select-Object -First 1
        $project=$null;$executionPlan=$null;$failure=$null
        try{
            $project=Get-MmtlProject -Path $projectRoot
            $profileCopy=$baseProfile|ConvertTo-Json -Depth 40|ConvertFrom-Json
            $profileCopy.project=$project.Root;$profileCopy.linkedProjects=@();$profileCopy.mode='Single';$profileCopy.players=1;$profileCopy.autoBuild=$false;$profileCopy.cleanBuild=$false;$profileCopy|Add-Member -NotePropertyName acceptEula -NotePropertyValue $false -Force
            $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profileCopy -Config $sourceConfig -RuntimeRoot $runtimeRoot -Name $targetId
        }catch{$failure=$_.Exception.Message}
        $dependencyCount=20
        if($project){$buildFile=Join-Path $project.Root $project.BuildFile;if(Test-Path -LiteralPath $buildFile){$dependencyCount=@(Select-String -LiteralPath $buildFile -Pattern '(?i)\b(implementation|modImplementation|minecraft|forge|neoforge|fabric-loader)\b' -AllMatches).Count}}
        $portfolio.Add([pscustomobject]@{targetId=$targetId;project=[string]$record.repository;projectPath=$projectRoot;minecraftId=[string]$record.minecraft;loaderId=[string]$record.loader;loaderVersion=[string]$record.loaderVersion;toolchain=if($executionPlan){[string]$executionPlan.project.toolchain.id}else{[string]$record.loader};buildJava=if($executionPlan){$executionPlan.buildJava.resolution}else{$null};runtimeJava=if($executionPlan){$executionPlan.runtimeJava.resolution}else{$null};binding=if($executionPlan){[string]$executionPlan.runtimeJava.bindingMode}else{''};buildReady=[bool]($executionPlan -and $executionPlan.capabilityGates.buildReady);launchReady=[bool]($executionPlan -and $executionPlan.capabilityGates.launchReady);historicalClientEvidence=$false;buildSuccessRate=if($priorBuild -and $priorBuild.Status -eq 'PASS'){1.0}elseif($priorBuild){0.0}else{$null};dependencyCount=$dependencyCount;launchBlockers=if($executionPlan){@($executionPlan.launchBlockingReasons|ForEach-Object code)}else{@('PLAN_GENERATION_FAILED')};planFailure=$failure})
    }
    $plan=New-MmtlHumanValidationPlan -Portfolio @($portfolio.ToArray()) -WorkspaceIdentity 'PycodersMod-local-workspace'
    $manualRoot=Join-Path $workspaceRoot 'HANDOVER/manual-validation';if(Test-MmtlInsideRoot -Root $here -Target $manualRoot){throw 'MANUAL_BUNDLE_INSIDE_REPOSITORY: 本地人工验证包必须位于仓库外。'}
    $configForHelper=$sourceConfigPath
    $launcherForHelper=[string]$platform.LauncherPath
    if(-not $launcherForHelper){throw 'PLATFORM_LAUNCHER_ENTRYPOINT_UNAVAILABLE: 平台提供器未提供本机启动入口。'}
    $bundle=Write-MmtlHumanValidationBundle -Plan $plan -OutputRoot $manualRoot -LauncherPath $launcherForHelper -ConfigPath $configForHelper -ProfileName ([string]$sourceConfig.defaultProfile)
    $result=[pscustomobject][ordered]@{status='PLAN_GENERATED';projectCount=$portfolio.Count;representatives=@($plan.representatives|ForEach-Object{[pscustomobject]@{loaderId=$_.loaderId;targetId=$_.targetId;project=$_.project;score=$_.score}});tiers=$plan.tiers;bundle=$bundle;startsMinecraft=$false;startsDedicatedServer=$false;startsAuthentication=$false;acceptsEula=$false;validationEligible=$false}
    if($Arguments -contains '--json'){$result|ConvertTo-Json -Depth 40 -Compress}else{$result|ConvertTo-Json -Depth 40}
    exit 0
}
$planProfileName=if($profileName){$profileName}elseif($config){[string]$config.defaultProfile}else{$null}
$doctorIndex=[Array]::IndexOf($Arguments,'--doctor')
if($doctorIndex -ge 0){
    $doctorPlan=$null
    if($config -and $profile -and $project){try{$doctorPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName}catch{}}
    $doctor=Invoke-MmtlDoctor -Config $config -Plan $doctorPlan -ConfigPath $configPath -RuntimeRoot $runtimeRoot -Offline:($Arguments -contains '--offline')
    if($Arguments -contains '--json'){$doctor|ConvertTo-Json -Depth 80}else{Write-Host "Doctor：PASS=$($doctor.summary.pass) WARN=$($doctor.summary.warn) FAIL=$($doctor.summary.fail) SKIP=$($doctor.summary.skip)";foreach($check in $doctor.checks){Write-Host "[$($check.status)] $($check.id)：$($check.message)"}}
    if($doctor.summary.fail -gt 0){exit 2};exit 0
}
if($Arguments -contains '--launch-check'){
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName
    if($Arguments -contains '--json'){$executionPlan|ConvertTo-Json -Depth 100}else{
        Write-Host "项目：$($executionPlan.repository.identity)"
        Write-Host "Minecraft：$($executionPlan.project.minecraftId)；Loader：$($executionPlan.project.loader.id) $($executionPlan.project.loader.version)；模式：$($executionPlan.profile.mode)"
        Write-Host "BuildReady：$($executionPlan.capabilityGates.buildReady)；LaunchReady：$($executionPlan.capabilityGates.launchReady)"
        Write-Host "Build Java：$($executionPlan.buildJava.resolution.status) $($executionPlan.buildJava.resolution.actualMajor)；Runtime Java：$($executionPlan.runtimeJava.resolution.status) $($executionPlan.runtimeJava.resolution.actualMajor)；绑定：$($executionPlan.runtimeJava.bindingMode)"
        Write-Host "内存：$($executionPlan.runtime.memory.requestedMb)/$($executionPlan.runtime.memory.limitMb) MB；端口策略：$($executionPlan.network.portPolicy)；平台 Launch：$($executionPlan.platform.capabilities.Launch)"
        foreach($reason in $executionPlan.launchBlockingReasons){Write-Host "阻塞 [$($reason.code)]：$($reason.messageZh)"}
        foreach($warning in $executionPlan.launchWarnings){Write-Host "提示 [$($warning.code)]：$($warning.messageZh)"}
        foreach($role in $executionPlan.runtime.roles){Write-Host "角色 $($role.role)：LaunchReady=$($role.launchReady)；阻塞=$($role.blockingReasons -join ', ')"}
        Write-Host 'LaunchReady 仅表示预检门禁通过，不代表 CLIENT_LAUNCH_VERIFIED。'
    }
    if(-not $executionPlan.capabilityGates.launchReady){exit 2};exit 0
}
if($Arguments -contains '--runtime-binding'){
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName
    $probeResult=$null
    if($Arguments -contains '--probe'){
        $trustedProjectRoots=@();if($config -and $config.PSObject.Properties['trustedProjectRoots']){$trustedProjectRoots=@($config.trustedProjectRoots|ForEach-Object{[string]$_})}
        try{$probeResult=Invoke-MmtlRuntimeBindingProbe -Project $project -Plan $executionPlan -RuntimeRoot $runtimeRoot -TrustedProjectRoots $trustedProjectRoots -Offline}
        catch{[Console]::Error.WriteLine([string]$_);exit 2}
        $bindingMode=[string]$probeResult.runtimeJavaBinding.mode;$bindingEvidence=$probeResult.runtimeJavaBinding
    }else{$bindingMode=[string]$executionPlan.runtimeJava.bindingMode;$bindingEvidence=$executionPlan.runtimeJava.bindingEvidence}
    $buildMajor=$executionPlan.buildJava.resolution.actualMajor;$runtimeMajor=$executionPlan.runtimeJava.resolution.actualMajor
    $compatibility=if($bindingMode -eq 'SameAsBuildJvm' -and $buildMajor -and $runtimeMajor -and $buildMajor -eq $runtimeMajor){'Compatible'}elseif($bindingMode -eq 'SameAsBuildJvm' -and $buildMajor -and $runtimeMajor){'RUNTIME_JAVA_BINDING_MISMATCH'}elseif($bindingMode -eq 'Unknown'){'Unknown'}elseif($bindingMode -eq 'ToolchainManaged'){'ProviderRequired'}else{'RuntimeJavaResolved'}
    $bindingOutput=[ordered]@{mode=$bindingMode;evidence=$bindingEvidence;buildJavaMajor=$buildMajor;runtimeJavaMajor=$runtimeMajor;compatibility=$compatibility;probe=$probeResult}
    if($Arguments -contains '--json'){$bindingOutput|ConvertTo-Json -Depth 60}else{
        Write-Host "Runtime Java Binding：$bindingMode；兼容性：$compatibility"
        if($bindingEvidence){Write-Host "证据来源：$($bindingEvidence.evidenceSource)；置信度：$($bindingEvidence.confidence)；方法：$($bindingEvidence.probeStrategy)"}
        if($probeResult){Write-Host "探测状态：$($probeResult.status)；任务：$($probeResult.taskNames -join ', ')；缓存命中：$($probeResult.cacheHit)；错误码：$($probeResult.errorCode)"}
    }
    if($probeResult -and $probeResult.status -notin @('Observed','TaskNotFound')){exit 2};exit 0
}
if($Arguments -contains '--validate') {
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName
    $checked=Test-MmtlExecutionPlan -Plan $executionPlan
    if(-not $checked.valid){throw "Execution Plan 校验失败：$($checked.errors -join ', ')"}
    Write-Host ("Platform          : {0}" -f (Get-MmtlPlatformDisplayName -OS $executionPlan.platform.os))
    Write-Host ("Architecture      : {0}" -f $executionPlan.platform.arch)
    Write-Host ("WSL               : {0}" -f $executionPlan.platform.isWSL)
    Write-Host "Plan 校验：PASS ($($executionPlan.semanticDigest))"
    Write-Host "Build Java：$($executionPlan.buildJava.resolution.status)；Runtime Java：$($executionPlan.runtimeJava.resolution.status)；绑定：$($executionPlan.runtimeJava.bindingMode)"
    Write-Host "BuildReady：$($executionPlan.capabilityGates.buildReady)；LaunchReady：$($executionPlan.capabilityGates.launchReady)"
    foreach($reason in $executionPlan.blockingReasons){Write-Host "阻塞 [$($reason.code)]：$($reason.messageZh)"}
    if(-not $executionPlan.capabilityGates.buildReady){exit 2};exit 0
}
if($Arguments -contains '--dry-run') {
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName -RequireBuild:([bool]$profile.autoBuild) -Clean:([bool]$profile.cleanBuild)
    $checked=Test-MmtlExecutionPlan -Plan $executionPlan
    if(-not $checked.valid){throw "Execution Plan 校验失败：$($checked.errors -join ', ')"}
    Write-Host "Plan：$($executionPlan.planId)；语义摘要：$($executionPlan.semanticDigest)"
    Write-Host "目标：Minecraft $($executionPlan.project.minecraftId)，$($executionPlan.project.loader.id) $($executionPlan.project.loader.version)；模式：$($executionPlan.session.intendedMode)"
    Write-Host "Build Java：$($executionPlan.buildJava.requirement.requirementKind) $($executionPlan.buildJava.requirement.major) => $($executionPlan.buildJava.resolution.status) $($executionPlan.buildJava.resolution.exactVersion)"
    Write-Host "Runtime Java：$($executionPlan.runtimeJava.requirement.requirementKind) $($executionPlan.runtimeJava.requirement.major) => $($executionPlan.runtimeJava.resolution.status)；绑定：$($executionPlan.runtimeJava.bindingMode)"
    Write-Host "角色：$(@($executionPlan.runtime.roles|ForEach-Object{"$($_.role):$($_.username)"}) -join ', ')；内存：$($executionPlan.runtime.memory.requestedMb)/$($executionPlan.runtime.memory.limitMb) MB；端口策略：$($executionPlan.network.portPolicy)"
    Write-Host "BuildReady：$($executionPlan.capabilityGates.buildReady)；LaunchReady：$($executionPlan.capabilityGates.launchReady)"
    foreach($reason in $executionPlan.blockingReasons){Write-Host "阻塞 [$($reason.code)]：$($reason.messageZh)"}
    if($executionPlan.build.required -and $executionPlan.capabilityGates.buildReady){$buildCmd=Get-MmtlGradleCommand -Project $project -Task 'build' -Clean:$executionPlan.build.clean;Write-Host "[Build] $($buildCmd.File) $($buildCmd.Arguments -join ' ')"}
    Write-Host '安全说明：dry-run 不创建 Runtime/Session，不分配 Auto 端口，不执行 Gradle/Java，也不启动 Minecraft。'
    exit 0
}
$planOutputIndex=[Array]::IndexOf($Arguments,'--plan-output')
if($planOutputIndex -ge 0 -and $planOutputIndex+1 -ge $Arguments.Count){throw '--plan-output 缺少目标文件路径。'}
if($planOutputIndex -ge 0 -and $Arguments -notcontains '--plan'){throw '--plan-output 只能与 --plan 一起使用。'}
if(($Arguments -contains '--plan') -and ($Arguments -contains '--explain-java')){throw '--plan 与 --explain-java 必须分开调用。'}
if($Arguments -contains '--plan'){
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $(if($profileName){$profileName}else{[string]$config.defaultProfile})
    $planJson=$executionPlan|ConvertTo-Json -Depth 100
    if($planOutputIndex -ge 0){$outputPath=[IO.Path]::GetFullPath([string]$Arguments[$planOutputIndex+1]);[IO.File]::WriteAllText($outputPath,$planJson+"`n",[Text.UTF8Encoding]::new($false))}
    if($Arguments -contains '--json'){Write-Output $planJson;exit 0}
    Write-Host "执行计划：$($executionPlan.planId)";Write-Host "语义摘要：$($executionPlan.semanticDigest)";Write-Host "目标：Minecraft $($executionPlan.project.minecraftId)，$($executionPlan.project.loader.id) $($executionPlan.project.loader.version)";Write-Host "构建 Java：要求 $($executionPlan.buildJava.requirement.major)，解析 $($executionPlan.buildJava.resolution.status) $($executionPlan.buildJava.resolution.exactVersion)";Write-Host "运行 Java：要求 $($executionPlan.runtimeJava.requirement.major)，解析 $($executionPlan.runtimeJava.resolution.status)，绑定 $($executionPlan.runtimeJava.bindingMode)";Write-Host "构建可执行：$($executionPlan.capabilityGates.buildReady)；启动可执行：$($executionPlan.capabilityGates.launchReady)";foreach($reason in $executionPlan.blockingReasons){Write-Host "阻塞 [$($reason.code)]：$($reason.messageZh)"};foreach($warning in $executionPlan.warnings){Write-Host "提示 [$($warning.code)]：$($warning.messageZh)"};if($planOutputIndex -ge 0){Write-Host "计划文件：$outputPath"};exit 0
}
if($Arguments -contains '--explain-java'){
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $(if($profileName){$profileName}else{[string]$config.defaultProfile})
    $explanation=[ordered]@{schemaVersion=1;planId=$executionPlan.planId;semanticDigest=$executionPlan.semanticDigest;buildJava=$executionPlan.buildJava;runtimeJava=$executionPlan.runtimeJava;blockingReasons=@($executionPlan.blockingReasons);warnings=@($executionPlan.warnings)}
    if($Arguments -contains '--json'){$explanation|ConvertTo-Json -Depth 40;exit 0}
    foreach($track in @(@{title='构建 Java';value=$executionPlan.buildJava},@{title='Minecraft Runtime Java';value=$executionPlan.runtimeJava})){$resolution=$track.value.resolution;$requirement=$track.value.requirement;Write-Host "$($track.title)：";Write-Host "  要求：$($requirement.major)（$($requirement.requirementKind)；来源 $($requirement.source)；置信度 $($requirement.confidence)）";Write-Host "  本机解析：$($resolution.status)";if($resolution.javaPath){Write-Host "  Java：$($resolution.javaPath)";Write-Host "  实际版本：$($resolution.exactVersion)；供应商：$($resolution.vendor)；架构：$($resolution.arch)"}elseif($resolution.reasonCode){Write-Host "  原因码：$($resolution.reasonCode)"};if($track.title -eq 'Minecraft Runtime Java'){Write-Host "  绑定模式：$($track.value.bindingMode)"}};exit 0
}
function Get-MmtlProjectOutputJar {
    param([Parameter(Mandatory)]$Project)
    $jars=@(Get-ChildItem -LiteralPath (Join-Path $Project.Root 'build/libs') -Filter '*.jar' -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -notmatch '(?i)(sources|javadoc|dev)(?:[-.]|\.jar$)'})
    if($jars.Count -ne 1){throw "项目 $($Project.Root) 应有且仅有一个可用 Mod JAR，实际 $($jars.Count) 个。"}
    return $jars[0].FullName
}
function Invoke-MmtlSessionMetadataWrite {
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][scriptblock]$Action)
    $session=[IO.Path]::GetFullPath($SessionPath);$lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
    try{& $Action}finally{Remove-MmtlSessionLock -Lock $lock}
}
function Start-MmtlConfiguredRun {
    param([Parameter(Mandatory)]$Primary,[Parameter(Mandatory)]$Profile,[Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)]$ExecutionPlan,[switch]$NonInteractive)
    $planCheck=Test-MmtlExecutionPlan -Plan $ExecutionPlan
    if(-not $planCheck.valid){throw "Execution Plan 无效：$($planCheck.errors -join ', ')"}
    if(-not $ExecutionPlan.capabilityGates.launchReady){$blockers=@($ExecutionPlan.capabilityGates.launchReasons)-join ', ';throw "Execution Plan 阻止 Launch：$blockers"}
    if($env:OS -ne 'Windows_NT'){throw 'MMTL v1 仅支持 Windows 10/11。'}
    if($Primary.Loader -eq 'Unknown' -or -not $Primary.Wrapper -or -not $Primary.MinecraftVersion -or -not $Primary.LoaderVersion){throw 'Primary 项目的 Loader、版本或 Gradle Wrapper 无法完整确认。'}
    if($Profile.mode -eq 'Dedicated' -and $Profile.acceptEula -ne $true){throw 'Dedicated 模式需先在本机配置中明确设置 acceptEula=true。'}
    $linked=@($Profile.linkedProjects|Where-Object{$_}|ForEach-Object{Get-MmtlProject -Path ([string]$_)})
    if($linked.Count){Assert-MmtlCompatible -Projects (@($Primary)+$linked)|Out-Null}
    $projects=@($Primary)+$linked
    foreach($candidate in $projects){if($candidate.Loader -eq 'Unknown' -or -not $candidate.Wrapper -or -not $candidate.LoaderVersion){throw "项目检测信息不完整：$($candidate.Root)"}}
    $players=[int]$Profile.players
    if($players -gt 8){throw 'v1 单次最多运行 8 个游戏客户端。'}
    if($Profile.mode -eq 'Single' -and $players -ne 1){throw 'Single 模式的 players 必须为 1。'}
    if($Profile.mode -eq 'IntegratedLAN' -and $players -lt 2){throw 'IntegratedLAN 的 players 包含 Host，至少为 2。'}
    $memoryBudget=Get-MmtlMemoryBudget -Profile $Profile -Mode $Profile.mode;$memoryOverageConfirmed=$false
    if($memoryBudget.ExceedsLimit){if($NonInteractive){throw 'SCENARIO_MEMORY_BUDGET_EXCEEDED: non-interactive scenario refuses to prompt for over-budget confirmation.'};Write-Warning "预计 Xmx 总和 $($memoryBudget.RequestedMb) MB，超过物理内存 80% 预算 $($memoryBudget.LimitMb) MB。";$memoryApproval=Read-Host '继续可能造成系统变慢或实例崩溃。输入 Y 明确继续，其他输入取消';if($memoryApproval -notmatch '^(?i:y|yes)$'){throw '用户未确认超额内存预算，已取消启动。'};$memoryOverageConfirmed=$true}
    $hostName=if($Profile.hostUsername){[string]$Profile.hostUsername}else{'Dev'}
    $prefix=if($Profile.clientPrefix){[string]$Profile.clientPrefix}else{'Dev_'}
    if($hostName -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'hostUsername 必须为 1 到 16 位 ASCII 字母、数字或下划线。'}
    if($prefix -notmatch '^[A-Za-z0-9_]{1,15}$'){throw 'clientPrefix 必须为 1 到 15 位 ASCII 字母、数字或下划线。'}
    $java=switch([string]$ExecutionPlan.runtimeJava.bindingMode){
        'Direct' {[string]$ExecutionPlan.runtimeJava.resolution.javaPath}
        'SameAsBuildJvm' {if($ExecutionPlan.buildJava.resolution.actualMajor -ne $ExecutionPlan.runtimeJava.resolution.actualMajor){throw 'RUNTIME_JAVA_BINDING_MISMATCH'};[string]$ExecutionPlan.buildJava.resolution.javaPath}
        default {throw "RUNTIME_JAVA_BINDING_NOT_EXECUTABLE: $($ExecutionPlan.runtimeJava.bindingMode)"}
    }
    if(-not $java -or -not(Test-Path -LiteralPath $java -PathType Leaf)){throw 'RUNTIME_JAVA_CANDIDATE_UNAVAILABLE'}
    $portSetting=if($Profile.port){$Profile.port}else{'Auto'}
    $requestedPort=0
    if([string]$portSetting -ne 'Auto'){$requestedPort=[int]$portSetting}
    if($requestedPort -and $Profile.mode -in @('Dedicated','IntegratedLAN')){$null=Get-MmtlPort -Port $requestedPort}
    $agentProvider=$null;$scenarioLanPort=0
    if($NonInteractive -and $Profile.mode -eq 'IntegratedLAN'){
        if($Profile.newWorld -ne $true){throw 'WORLD_TEMPLATE_REQUIRED: non-interactive IntegratedLAN currently requires a fresh Session-local world or a supported template.'}
        if([string]$Profile.gameMode -notin @('survival','creative')){throw 'WORLD_MODE_UNSUPPORTED_FOR_AUTOMATION: Forge world creation supports survival or creative.'}
        $agentProvider=Get-MmtlAgentProviderStatus -AgentRoot (Join-Path $here 'common/agent') -LoaderId ([string]$Primary.Loader) -MinecraftVersion ([string]$Primary.MinecraftVersion)
        if($agentProvider.status -cne 'Supported'){throw "SCENARIO_AGENT_PROVIDER_UNSUPPORTED: $($agentProvider.reason)"}
        foreach($capability in @('OfflineIntegratedLanHost','LoopbackOnlyListener','LanDiscoverySuppressed','GuestLoopbackVerification')){if(@($agentProvider.capabilities) -notcontains $capability){throw "SCENARIO_AGENT_CAPABILITY_MISSING: $capability"}}
        $scenarioLanPort=if($requestedPort){$requestedPort}else{Get-MmtlPort}
    }elseif($NonInteractive -and $Profile.mode -eq 'Single'){
        $candidateAgent=Get-MmtlAgentProviderStatus -AgentRoot (Join-Path $here 'common/agent') -LoaderId ([string]$Primary.Loader) -MinecraftVersion ([string]$Primary.MinecraftVersion)
        if($candidateAgent.status -ceq 'Supported' -and @($candidateAgent.roles) -contains 'Client'){$agentProvider=$candidateAgent}
    }
    $name=[IO.Path]::GetFileName($Primary.Root)-replace '[^A-Za-z0-9_-]','_'
    $metadata=[pscustomobject]@{project=$Primary.Root;linkedProjects=@($linked.Root);linkedArtifacts=@();minecraft=$Primary.MinecraftVersion;loader=$Primary.Loader;loaderVersion=$Primary.LoaderVersion;javaMajor=$Primary.JavaMajor;runtimeJavaMajor=[int]$ExecutionPlan.runtimeJava.requirement.major;runtimeJavaPath=$java;mode=$Profile.mode;players=$players;hostUsername=$hostName;clientPrefix=$prefix;hostCheats=[bool]$Profile.hostCheats;clientPermissionLevel=[int]$Profile.clientPermissionLevel;gameMode=$Profile.gameMode;difficulty=$Profile.difficulty;worldName=$Profile.worldName;seed=$Profile.seed;newWorld=[bool]$Profile.newWorld;resetWorld=[bool]$Profile.resetWorld;worldResetCount=0;resolution=$Profile.resolution;guiScale=$Profile.guiScale;windowLayout=$Profile.windowLayout;windowLayoutStatus='Pending';memoryMb=$Profile.memoryMb;hostMemoryMb=$Profile.hostMemoryMb;clientMemoryMb=$Profile.clientMemoryMb;serverMemoryMb=$Profile.serverMemoryMb;memoryBudget=$memoryBudget;memoryOverageConfirmed=$memoryOverageConfirmed;port=$requestedPort;builds=@();processes=@();createdBy='MinecraftModTestLauncher'}
    $session=New-MmtlSession -RuntimeRoot $RuntimeRoot -Name $name -Metadata $metadata
    Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $ExecutionPlan|Out-Null
    $sessionId=Split-Path $session -Leaf
    $scenarioPlan=$null;$sessionToken=$null
    if($NonInteractive){
        $scenarioPlan=New-MmtlScenarioPlan -Mode ([string]$Profile.mode) -Players $players -HostUsername $hostName -GuestPrefix $prefix -AutoCreateWorld:([bool]$Profile.newWorld) -DurationSeconds $(if($Profile.durationSeconds){[int]$Profile.durationSeconds}else{60})
        Initialize-MmtlScenarioState -SessionPath $session -SessionId $sessionId -Plan $scenarioPlan|Out-Null
        Set-MmtlScenarioState -SessionPath $session -NextState Building -EventCode ROLE_START_REQUESTED -Summary 'Session 准备完毕，开始执行 Scenario。'|Out-Null
        $randomBytes=[byte[]]::new(32);$generator=[Security.Cryptography.RandomNumberGenerator]::Create();try{$generator.GetBytes($randomBytes)}finally{$generator.Dispose()};$sessionToken=[Convert]::ToHexString($randomBytes).ToLowerInvariant()
        if($scenarioLanPort){$metadata.port=$scenarioLanPort}
    }
    $builds=[Collections.Generic.List[object]]::new();$linkedJars=[Collections.Generic.List[string]]::new()
    try{
        Write-Host "会话：$sessionId`nMinecraft：$($Primary.MinecraftVersion)`nLoader：$($Primary.Loader) $($Primary.LoaderVersion)`nJava：$($Primary.JavaMajor)`n模式：$($Profile.mode)`n玩家：$players`n运行目录：$session"
        if($Profile.resetWorld -eq $true){$resetWorldCount=0;foreach($username in @($hostName)+@(for($i=1;$i -lt $players;$i++){$prefix+$i})){if(Reset-MmtlSessionWorld -RuntimeRoot $RuntimeRoot -SessionPath $session -PlayerName $username -WorldName ([string]$Profile.worldName) -Reset -Confirm:$false){$resetWorldCount++}};$metadata.worldResetCount=$resetWorldCount;Write-Host "当前 Session 测试世界重置数：$resetWorldCount"}
        $projectJava=[string]$ExecutionPlan.buildJava.resolution.javaPath
        if($Profile.autoBuild -ne $false){
            Set-MmtlSessionV2State -SessionPath $session -State Building|Out-Null
            $projectPipeline=Invoke-MmtlProjectBuildPipeline -Primary $Primary -LinkedProjects $linked -JavaPath $projectJava -SessionPath $session -AutoBuild -Clean:([bool]$Profile.cleanBuild) -BuildAction {param($Project,$JavaPath,$SessionPath,$Clean) Invoke-MmtlGradleBuild -Project $Project -JavaPath $JavaPath -SessionPath $SessionPath -Clean:$Clean}
        }else{
            $projectPipeline=Invoke-MmtlProjectBuildPipeline -Primary $Primary -LinkedProjects $linked -JavaPath $projectJava -SessionPath $session -ArtifactResolver {param($Project) Get-MmtlProjectOutputJar -Project $Project}
        }
        foreach($build in $projectPipeline.builds){$builds.Add($build)}
        foreach($artifact in $projectPipeline.linkedArtifacts){$linkedJars.Add([string]$artifact.path)}
        $metadata.linkedArtifacts=@($projectPipeline.linkedArtifacts)
        if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState SessionReady -EventCode SCENARIO_BUILD_COMPLETED -Summary '构建步骤已完成。'|Out-Null}
        Set-MmtlSessionV2State -SessionPath $session -State Launching|Out-Null
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
            if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState ServerStarting -EventCode ROLE_START_REQUESTED -Role Server -Summary '启动 loopback Dedicated Server。'|Out-Null}
            $serverPlan=New-MmtlGradleRunPlan -Project $Primary -Mode Dedicated -RuntimeRoot $session -Role Server -Profile $Profile
            $serverAttempt={param($candidatePort,$attempt)
                if($attempt -eq 1){$null=Initialize-MmtlDedicatedServerRuntime -SessionPath $session -Port $candidatePort -Profile $Profile}
                else{$null=Set-MmtlDedicatedServerPort -SessionPath $session -Port $candidatePort}
                $startedServer=$null
                try{
                    $startedServer=Start-MmtlGradleInstance -Project $Primary -Plan $serverPlan -JavaPath $java -SessionPath $session -ModJars @($extraJars) -ExpectedModHashes $projectPipeline.expectedModHashes
                    Write-Host "Dedicated Server 已启动，等待端口 $candidatePort 就绪。日志：$($startedServer.LogPath)"
                    $null=Wait-MmtlDedicatedReady -Path $startedServer.LogPath -ProcessId $startedServer.ProcessId -TimeoutSeconds 300
                    return $startedServer
                }catch{
                    if($startedServer -and $requestedPort -eq 0){
                        # Stop-MmtlTrackedProcess verifies this exact PID against this Session identity before acting.
                        $null=Stop-MmtlTrackedProcess -SessionPath $session -ProcessId ([int]$startedServer.ProcessId) -Confirm:$false
                    }
                    throw
                }
            }
            $allocation=Invoke-MmtlPortAllocation -Port $requestedPort -OnAllocated $serverAttempt -MaximumAttempts 3
            $port=[int]$allocation.Port;$server=$allocation.Value
            if($allocation.Attempts -gt 1){Write-Host "端口绑定冲突后已安全重试，共尝试 $($allocation.Attempts) 次。"}
            if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState ServerReady -EventCode ROLE_READY -Role Server -Summary 'Dedicated Server 已就绪。'|Out-Null;Set-MmtlScenarioState -SessionPath $session -NextState ClientsStarting -EventCode ROLE_START_REQUESTED -Role Client -Summary '启动 Dedicated 客户端。'|Out-Null}
            $metadata.port=$port
            $clientNames=@($hostName)
            for($i=1;$i -lt $players;$i++){$clientNames+=($prefix+$i)}
            foreach($username in $clientNames){
                $plan=New-MmtlGradleRunPlan -Project $Primary -Mode Dedicated -RuntimeRoot $session -Role Client -Username $username -Port $port -Profile $Profile
                $started=Start-MmtlGradleInstance -Project $Primary -Plan $plan -JavaPath $java -SessionPath $session -ModJars @($extraJars) -ExpectedModHashes $projectPipeline.expectedModHashes
                $metadata.processes+=@([pscustomobject]@{PID=$started.ProcessId;role=$started.Role;username=$started.Username;log=$started.LogPath})
                Write-Host "客户端 $username 已启动；日志：$($started.LogPath)"
            }
            $metadata.processes+=@([pscustomobject]@{PID=$server.ProcessId;role='Server';username='';log=$server.LogPath})
            if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState ClientsReady -EventCode ROLE_READY -Role Client -Summary 'Dedicated 客户端均已启动。'|Out-Null}
        }elseif($Profile.mode -eq 'IntegratedLAN'){
            if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState HostStarting -EventCode ROLE_START_REQUESTED -Role Host -Summary '启动受管 IntegratedLAN Host。'|Out-Null;$hostBinding=New-MmtlAgentLaunchBinding -Provider $agentProvider -SessionPath $session -SessionId $sessionId -Role Host -SessionToken $sessionToken -IntegratedLanPort $scenarioLanPort -AutoCreateWorld:([bool]$Profile.newWorld) -WorldName $(if($Profile.worldName){[string]$Profile.worldName}else{'MMTL-Test'}) -WorldGameMode $(if($Profile.gameMode){[string]$Profile.gameMode}else{'survival'}) -WorldDifficulty $(if($Profile.difficulty){[string]$Profile.difficulty}else{'normal'}) -WorldSeed ([string]$Profile.seed) -WorldAllowCommands:([bool]$Profile.hostCheats);$hostAgentArgs=@($hostBinding.jvmArgs)}else{$hostBinding=$null;$hostAgentArgs=@()}
            $hostPlan=New-MmtlGradleRunPlan -Project $Primary -Mode IntegratedLAN -RuntimeRoot $session -Role Host -Username $hostName -Profile $Profile -AgentJvmArguments $hostAgentArgs
            $hostProcess=Start-MmtlGradleInstance -Project $Primary -Plan $hostPlan -JavaPath $java -SessionPath $session -ModJars @($extraJars) -ExpectedModHashes $projectPipeline.expectedModHashes
            $metadata.processes+=@([pscustomobject]@{PID=$hostProcess.ProcessId;role='Host';username=$hostName;log=$hostProcess.LogPath})
            if($NonInteractive){
                Write-Host "IntegratedLAN Host 已启动；等待 Agent world join、loopback publish 与端口 $scenarioLanPort 就绪。"
                $hostReady=Wait-MmtlAgentIntegratedLanReady -SessionPath $session -EventPath $hostBinding.eventSink -SessionId $sessionId -ExpectedNonceHash $hostBinding.sessionNonceHash -Port $scenarioLanPort -ProcessId $hostProcess.ProcessId -TimeoutSeconds 300
                Set-MmtlScenarioState -SessionPath $session -NextState HostReady -EventCode ROLE_READY -Role Host -Summary 'Host world join 和 loopback listener 均已验证。'|Out-Null
                $port=$scenarioLanPort
            }else{
                Write-Host "主机客户端已启动。请进入测试世界，并在游戏菜单中手动选择“对局域网开放”（Open to LAN）。若选择固定端口，请使用 $requestedPort。"
                $null=Read-Host '发布局域网后按 Enter，启动器将从日志读取端口并启动其他客户端'
                $port=Wait-MmtlLanPort -Path $hostProcess.LogPath -ProcessId $hostProcess.ProcessId -TimeoutSeconds 180
                if($requestedPort -and $port -ne $requestedPort){throw "游戏实际开放端口 $port 与配置固定端口 $requestedPort 不同。"}
            }
            $metadata.port=$port
            if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState GuestsStarting -EventCode ROLE_START_REQUESTED -Role Guest -Summary 'Host 就绪；开始依次启动 Guest。'|Out-Null}
            for($i=1;$i -lt $players;$i++){
                $username=$prefix+$i
                if($NonInteractive){$guestBinding=New-MmtlAgentLaunchBinding -Provider $agentProvider -SessionPath $session -SessionId $sessionId -Role Guest -SessionToken $sessionToken -ExpectedLoopbackPort $port;$guestAgentArgs=@($guestBinding.jvmArgs)}else{$guestBinding=$null;$guestAgentArgs=@()}
                $plan=New-MmtlGradleRunPlan -Project $Primary -Mode IntegratedLAN -RuntimeRoot $session -Role Client -Username $username -Port $port -Profile $Profile -AgentJvmArguments $guestAgentArgs
                $started=Start-MmtlGradleInstance -Project $Primary -Plan $plan -JavaPath $java -SessionPath $session -ModJars @($extraJars) -ExpectedModHashes $projectPipeline.expectedModHashes
                $metadata.processes+=@([pscustomobject]@{PID=$started.ProcessId;role='Client';username=$username;log=$started.LogPath})
                Write-Host "LAN 客户端 $username 已启动；日志：$($started.LogPath)"
                if($NonInteractive){$null=Wait-MmtlAgentGuestJoined -SessionPath $session -EventPath $guestBinding.eventSink -SessionId $sessionId -ExpectedNonceHash $guestBinding.sessionNonceHash -Port $port -ProcessId $started.ProcessId -TimeoutSeconds 180}
            }
            if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState GuestsReady -EventCode ROLE_READY -Role Guest -Summary '所有 Guest 均通过 Agent join observation。'|Out-Null}
        }else{
            if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState ClientStarting -EventCode ROLE_START_REQUESTED -Role Client -Summary '启动 Single 客户端。'|Out-Null}
            $clientAgentArgs=@();$clientBinding=$null
            if($NonInteractive -and $agentProvider -and $agentProvider.status -ceq 'Supported'){$clientBinding=New-MmtlAgentLaunchBinding -Provider $agentProvider -SessionPath $session -SessionId $sessionId -Role Client -SessionToken $sessionToken;$clientAgentArgs=@($clientBinding.jvmArgs)}
            $plan=New-MmtlGradleRunPlan -Project $Primary -Mode Single -RuntimeRoot $session -Role Client -Username $hostName -Profile $Profile -AgentJvmArguments $clientAgentArgs
            $started=Start-MmtlGradleInstance -Project $Primary -Plan $plan -JavaPath $java -SessionPath $session -ModJars @($extraJars) -ExpectedModHashes $projectPipeline.expectedModHashes
            $metadata.processes+=@([pscustomobject]@{PID=$started.ProcessId;role='Client';username=$hostName;log=$started.LogPath})
            Write-Host "Single 客户端已启动；日志：$($started.LogPath)"
            if($clientBinding){$null=Wait-MmtlAgentClientReady -SessionPath $session -EventPath $clientBinding.eventSink -SessionId $sessionId -ExpectedNonceHash $clientBinding.sessionNonceHash -ProcessId $started.ProcessId -TimeoutSeconds 300}
        }
        Set-MmtlSessionV2State -SessionPath $session -State Running|Out-Null
        if($NonInteractive){Set-MmtlScenarioState -SessionPath $session -NextState Observing -EventCode SCENARIO_OBSERVATION_STARTED -Summary '全部场景角色就绪，进入观察阶段。'|Out-Null}
        if($Profile.windowLayout -and $Profile.windowLayout -ne 'None' -and ($Profile.mode -ne 'Single' -or $Profile.windowLayout -ne 'Auto')){
            try{$layoutResult=Set-MmtlSessionWindowLayout -SessionPath $session -Mode $Profile.windowLayout -TimeoutSeconds 90;$metadata.windowLayoutStatus=$layoutResult.Status;if($layoutResult.Status -in @('Partial','UnavailableFallbackNone')){Write-Warning "窗口布局结果：$($layoutResult.Status) ($($layoutResult.Reason))"}else{Write-Host "窗口布局：$($layoutResult.Status) ($($layoutResult.Windows) 个窗口)"}}
            catch{$metadata.windowLayoutStatus='UnavailableFallbackNone';Write-Warning "窗口布局失败并安全跳过：$($_.Exception.Message)"}
        }else{$metadata.windowLayoutStatus='Skipped'}
        if($NonInteractive){
            $duration=[int]$scenarioPlan.durationSeconds
            $observeUntil=[DateTime]::UtcNow.AddSeconds($duration)
            do{$liveScenario=Get-MmtlScenarioStatus -SessionPath $session;if([string]$liveScenario.state -eq 'Stopped'){break};$remaining=($observeUntil-[DateTime]::UtcNow).TotalMilliseconds;if($remaining -gt 0){Start-Sleep -Milliseconds ([Math]::Min(500,[Math]::Max(1,[int]$remaining)))}}while([DateTime]::UtcNow -lt $observeUntil)
            $liveScenario=Get-MmtlScenarioStatus -SessionPath $session
            if([string]$liveScenario.state -eq 'Observing'){
                Set-MmtlScenarioState -SessionPath $session -NextState Analyzing -EventCode SCENARIO_ANALYSIS_STARTED -Summary "观察时长 $duration 秒结束，进入分析和安全回收。"|Out-Null
                $metadata.analysisStatus='DeferredUntilPhaseT'
                Set-MmtlScenarioState -SessionPath $session -NextState Stopping -EventCode SCENARIO_SAFE_STOP_STARTED -Summary 'Scenario 到达配置的观察时长，开始停止当前 Session 进程。'|Out-Null
                $registryPath=Join-Path $session 'pids.json';Assert-MmtlNoReparsePath -Path $registryPath|Out-Null
                foreach($entry in @(Get-Content -LiteralPath $registryPath -Raw|ConvertFrom-Json|Sort-Object {switch([string]$_.Role){'Client'{0}'Host'{1}'Server'{2}default{3}}})){$null=Stop-MmtlTrackedProcess -SessionPath $session -ProcessId ([int]$entry.PID) -Confirm:$false}
                $null=Import-MmtlSessionLogs -SessionPath $session
                $metadata.builds=@($builds)
                try{
                    $modMetadata=Get-MmtlProjectModMetadata -Project $Primary
                    $analysisProject=[pscustomobject][ordered]@{modIds=@($modMetadata.modIds);primaryModId=$(if($Profile.primaryModId){[string]$Profile.primaryModId}else{$modMetadata.primaryModId});modNames=@($modMetadata.modNames);packageCandidates=@($modMetadata.packageCandidates);mixinConfigs=@($modMetadata.mixinConfigs);entrypointClasses=@($modMetadata.entrypointClasses);artifactNames=@($modMetadata.artifactNames);loaderId=[string]$Primary.Loader;minecraftVersion=[string]$Primary.MinecraftVersion}
                    $analysis=Invoke-MmtlAnalyzer -Provider RuleBasedAnalyzer -SessionPath $session -ProjectMetadata $analysisProject -ScenarioResult 'PASS' -RuntimeStatus 'Stopped' -SessionMetadata $metadata
                    $metadata.analysisStatus='Complete';$metadata.analysisFindingCount=$analysis.findingCount
                }catch{$metadata.analysisStatus='Failed';$metadata.analysisErrorCode=([string]$_.Exception.Message -replace '[^A-Z0-9_:-]','_')}
                $finalStatus=Update-MmtlSessionReport -SessionPath $session
                if($finalStatus.Status -in @('Stopped','Completed')){$nextSessionState=if($finalStatus.Status -eq 'Stopped'){'Stopped'}else{'Completed'};Set-MmtlSessionV2State -SessionPath $session -State $nextSessionState|Out-Null}
                Set-MmtlScenarioState -SessionPath $session -NextState Completed -EventCode SCENARIO_COMPLETED -Summary "Scenario 已完成；分析状态 $($metadata.analysisStatus)。"|Out-Null
                $metadata.scenarioState='Completed';$metadata.sessionState=$finalStatus.Status
            }else{$metadata.scenarioState=[string]$liveScenario.state;$metadata.sessionState='Stopped';$metadata.analysisStatus='SkippedByStopAllAction'}
        }
        $metadata.builds=@($builds)
        Invoke-MmtlSessionMetadataWrite -SessionPath $session -Action {
            $statePath=Join-Path $session 'session.json';$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json;$state.metadata=$metadata;Write-MmtlAtomicTextFile -Path $statePath -Content (($state|ConvertTo-Json -Depth 30)+"`n")
            $report=@("# 会话 $sessionId",'',"- 模式：$($Profile.mode)","- 项目：$($Primary.Root)","- Minecraft：$($Primary.MinecraftVersion)","- Loader：$($Primary.Loader) $($Primary.LoaderVersion)","- Java：$($Primary.JavaMajor)","- 玩家：$($metadata.processes.username -join ', ')","- 端口：$($metadata.port)","- 内存预算 MB：$($memoryBudget.RequestedMb) / $($memoryBudget.LimitMb)；已确认超额=$memoryOverageConfirmed","- 世界重置次数：$($metadata.worldResetCount)","- 窗口布局：$($metadata.windowLayoutStatus)","- 运行目录：$session",'', '## 构建')
            foreach($build in $builds){$report+=@("- 项目：$($build.Project)","  - Git SHA：$($build.GitSha)","  - Jar：$($build.JarPath)","  - SHA-256：$($build.JarSha256)","  - 日志：$($build.LogPath)")}
            $report+=@('','## Processes');foreach($process in $metadata.processes){$report+="- $($process.role) $($process.username) PID $($process.PID): $($process.log)"};Write-MmtlAtomicTextFile -Path (Join-Path $session 'report.md') -Content (($report -join "`n")+"`n")
        }
        Write-Host "会话清单：$session`n停止命令：launcher.cmd --stop $sessionId`n清理命令：launcher.cmd --clean-session $sessionId"
    }catch{
        try{$current=Test-MmtlSessionV2 -SessionPath $session;if($current.valid -and $current.state -notin @('Completed','Failed','Stopped')){Set-MmtlSessionV2State -SessionPath $session -State Failed|Out-Null}}catch{}
        if($NonInteractive){
            try{
                $scenarioStatus=Get-MmtlScenarioStatus -SessionPath $session
                if(Test-MmtlScenarioTransition -Current ([string]$scenarioStatus.state) -Next Failed){Set-MmtlScenarioState -SessionPath $session -NextState Failed -EventCode SCENARIO_FAILED -Summary 'Scenario 因阶段错误失败。'|Out-Null}
                $scenarioStatus=Get-MmtlScenarioStatus -SessionPath $session
                if(Test-MmtlScenarioTransition -Current ([string]$scenarioStatus.state) -Next Stopping){Set-MmtlScenarioState -SessionPath $session -NextState Stopping -EventCode SCENARIO_SAFE_STOP_STARTED -Summary '失败后回收本 Session 登记进程。'|Out-Null}
                $registry=Join-Path $session 'pids.json'
                if(Test-Path -LiteralPath $registry){foreach($entry in @(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json|Sort-Object {switch([string]$_.Role){'Guest'{0}'Client'{1}'Host'{2}'Server'{3}default{4}}})){$null=Stop-MmtlTrackedProcess -SessionPath $session -ProcessId ([int]$entry.PID) -Confirm:$false}}
                $scenarioStatus=Get-MmtlScenarioStatus -SessionPath $session
                if(Test-MmtlScenarioTransition -Current ([string]$scenarioStatus.state) -Next Stopped){Set-MmtlScenarioState -SessionPath $session -NextState Stopped -EventCode SCENARIO_SAFE_STOP_COMPLETED -Summary '本 Session 登记进程已安全停止。'|Out-Null}
            }catch{Write-Warning "Scenario safe stop 未能完整确认：$($_.Exception.Message)"}
        }
        Write-Error "Session $sessionId 已保留现场和日志。检查后可用 --stop $sessionId 停止登记进程。$($_.Exception.Message)";throw
    }
}
if($Arguments -contains '--launch') {
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName -RequireBuild:([bool]$profile.autoBuild) -Clean:([bool]$profile.cleanBuild)
    Start-MmtlConfiguredRun -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -ExecutionPlan $executionPlan;exit 0
}
if($Arguments -contains '--run-scenario') {
    if(($Arguments|Where-Object{$_ -notin @('--run-scenario','--json','--config-file',$configPath,'--profile',$profileName)}).Count){throw 'SCENARIO_OPTION_INVALID'}
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName -RequireBuild:([bool]$profile.autoBuild) -Clean:([bool]$profile.cleanBuild)
    Start-MmtlConfiguredRun -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -ExecutionPlan $executionPlan -NonInteractive
    exit 0
}
if($Arguments -contains '--launch-rehearsal') {
    if(($Arguments|Where-Object{$_ -notin @('--launch-rehearsal','--json','--config-file',$configPath,'--profile',$profileName)}).Count){throw 'REHEARSAL_OPTION_INVALID: 演练命令不接受额外参数。'}
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName -RequireBuild:([bool]$profile.autoBuild) -Clean:([bool]$profile.cleanBuild)
    $result=switch([string]$executionPlan.profile.mode){
        'Single' { Invoke-MmtlSingleLaunchRehearsal -ExecutionPlan $executionPlan -RuntimeRoot $runtimeRoot -RepositoryRoot $here }
        'Dedicated' { Invoke-MmtlDedicatedLaunchRehearsal -ExecutionPlan $executionPlan -RuntimeRoot $runtimeRoot -RepositoryRoot $here }
        'IntegratedLAN' { Invoke-MmtlIntegratedLanLaunchRehearsal -ExecutionPlan $executionPlan -RuntimeRoot $runtimeRoot -RepositoryRoot $here }
        default { throw 'REHEARSAL_MODE_UNSUPPORTED: Execution Plan 模式没有对应的合成演练编排。' }
    }
    if($Arguments -contains '--json'){$result|ConvertTo-Json -Depth 40 -Compress}else{
        Write-Host "模式：$($result.mode)；角色：$($result.roles -join ', ')"
        Write-Host "Java：Build $($result.buildJavaMajor) / Runtime $($result.runtimeJavaMajor)；内存：$($result.memoryMb) MB"
        Write-Host "端口：$($result.port)；进程：$(@($result.processes).Count)；事件：$(@($result.events).Count)；停止：$(@($result.stopResult) -join ', ')；Session：$($result.finalSessionState)"
        Write-Host '演练结果为 synthetic，validationEligible=false；不代表 Minecraft 实机验证。'
    }
    if($result.finalSessionState -ne 'Stopped'){exit 2};exit 0
}
if($Arguments -contains '--build') {
    $executionPlan=New-MmtlCliExecutionPlan -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot -Name $planProfileName -RequireBuild -Clean:([bool]$profile.cleanBuild)
    $check=Test-MmtlExecutionPlan -Plan $executionPlan
    if(-not $check.valid){throw "Execution Plan 无效：$($check.errors -join ', ')"}
    if(-not $executionPlan.capabilityGates.buildReady){throw "Execution Plan 阻止 Build：$(@($executionPlan.capabilityGates.buildReasons)-join ', ')"}
    $metadata=[pscustomobject]@{project=$project.Root;loader=$project.Loader;minecraft=$project.MinecraftVersion;buildJavaMajor=$executionPlan.buildJava.requirement.major;runtimeJavaMajor=$executionPlan.runtimeJava.requirement.major;players=$profile.players;mode=$profile.mode;executionPlanDigest=$executionPlan.semanticDigest}
    $sessionName=[IO.Path]::GetFileName($project.Root)-replace '[^A-Za-z0-9_-]','_'
    $session=New-MmtlSession -RuntimeRoot $runtimeRoot -Name $sessionName -Metadata $metadata
    Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $executionPlan|Out-Null
    Set-MmtlSessionV2State -SessionPath $session -State Building|Out-Null
    try{$build=Invoke-MmtlGradleBuild -Project $project -JavaPath ([string]$executionPlan.buildJava.resolution.javaPath) -SessionPath $session -Clean:([bool]$executionPlan.build.clean)}catch{Set-MmtlSessionV2State -SessionPath $session -State Failed|Out-Null;throw}
    Set-MmtlSessionV2State -SessionPath $session -State Completed|Out-Null
    Invoke-MmtlSessionMetadataWrite -SessionPath $session -Action {
        $statePath=Join-Path $session 'session.json';$state=Get-Content $statePath -Raw|ConvertFrom-Json
        $state|Add-Member -NotePropertyName buildResult -NotePropertyValue $build -Force
        $state|Add-Member -NotePropertyName executionPlanDigest -NotePropertyValue $executionPlan.semanticDigest -Force
        $state|Add-Member -NotePropertyName exitCode -NotePropertyValue $build.ExitCode -Force
        $state|Add-Member -NotePropertyName gitSha -NotePropertyValue $build.GitSha -Force
        $state|Add-Member -NotePropertyName jarPath -NotePropertyValue $build.JarPath -Force
        $state|Add-Member -NotePropertyName jarSha256 -NotePropertyValue $build.JarSha256 -Force
        Write-MmtlAtomicTextFile -Path $statePath -Content (($state|ConvertTo-Json -Depth 40)+"`n")
    }
    Write-Host "构建完成：$($build.ExitCode)`n会话：$session`nPlan 摘要：$($executionPlan.semanticDigest)`n日志：$($build.LogPath)`nJAR SHA-256：$($build.JarSha256)"
    if($build.ExitCode -ne 0){exit $build.ExitCode};exit 0
}
Write-Host '当前版本只提供配置验证与 dry-run。实际 Minecraft 启动、多实例、LAN 与 Dedicated 编排尚未实现。'
exit 3
