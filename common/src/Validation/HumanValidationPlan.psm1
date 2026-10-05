Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\AtomicFile.psm1') -Force

function Get-MmtlHumanValidationProjectScore {
    param([Parameter(Mandatory)]$Project)
    $score=0
    if([bool](Get-MmtlHumanValidationProperty $Project 'buildReady' $false)){$score+=100}
    if([bool](Get-MmtlHumanValidationProperty $Project 'launchReady' $false)){$score+=100}
    if([bool](Get-MmtlHumanValidationProperty $Project 'historicalClientEvidence' $false)){$score+=25}
    $stability=0.0;$successRate=Get-MmtlHumanValidationProperty $Project 'buildSuccessRate';if($null -ne $successRate){$stability=[Math]::Clamp([double]$successRate,0,1)}
    $score+=[int][Math]::Round($stability*30)
    $dependencyCount=Get-MmtlHumanValidationProperty $Project 'dependencyCount';$dependencies=if($null -ne $dependencyCount){[Math]::Max(0,[int]$dependencyCount)}else{20}
    $score-=[Math]::Min(40,$dependencies*2)
    if([string](Get-MmtlHumanValidationProperty $Project 'binding' '') -eq 'SameAsBuildJvm'){$score+=10}
    return $score
}

function Get-MmtlHumanValidationProperty {
    param([Parameter(Mandatory)]$InputObject,[Parameter(Mandatory)][string]$Name,$Default=$null)
    $property=$InputObject.PSObject.Properties[$Name]
    if($null -eq $property){return $Default}
    return $property.Value
}

function New-MmtlHumanValidationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Portfolio,
        [string]$WorkspaceIdentity='local-workspace',
        [string[]]$CompletedSingleTargetIds=@(),
        [string[]]$CompletedDedicatedTargetIds=@(),
        [string[]]$IntegratedLanAuthReadyTargetIds=@()
    )
    $requiredLoaders=@('Forge','Fabric','NeoForge');$validProjects=[Collections.Generic.List[object]]::new()
    foreach($project in $Portfolio){
        if(-not $project.targetId -or -not $project.projectPath -or -not $project.loaderId){continue}
        $validProjects.Add([pscustomobject][ordered]@{targetId=[string]$project.targetId;project=[string]$project.project;projectPath=[string]$project.projectPath;minecraftId=[string]$project.minecraftId;loaderId=[string]$project.loaderId;loaderVersion=[string]$project.loaderVersion;toolchain=[string](Get-MmtlHumanValidationProperty $project 'toolchain' '');buildJava=(Get-MmtlHumanValidationProperty $project 'buildJava');runtimeJava=(Get-MmtlHumanValidationProperty $project 'runtimeJava');binding=[string](Get-MmtlHumanValidationProperty $project 'binding' '');buildReady=[bool](Get-MmtlHumanValidationProperty $project 'buildReady' $false);launchReady=[bool](Get-MmtlHumanValidationProperty $project 'launchReady' $false);launchBlockers=@(Get-MmtlHumanValidationProperty $project 'launchBlockers' @());planFailure=Get-MmtlHumanValidationProperty $project 'planFailure';historicalClientEvidence=[bool](Get-MmtlHumanValidationProperty $project 'historicalClientEvidence' $false);buildSuccessRate=if($null -ne (Get-MmtlHumanValidationProperty $project 'buildSuccessRate')){[double](Get-MmtlHumanValidationProperty $project 'buildSuccessRate')}else{$null};dependencyCount=if($null -ne (Get-MmtlHumanValidationProperty $project 'dependencyCount')){[int](Get-MmtlHumanValidationProperty $project 'dependencyCount')}else{$null};score=(Get-MmtlHumanValidationProjectScore -Project $project)})
    }
    $representatives=[Collections.Generic.List[object]]::new()
    foreach($loader in $requiredLoaders){
        $candidate=$validProjects|Where-Object loaderId -CEQ $loader|Sort-Object @{Expression='score';Descending=$true},@{Expression='targetId';Descending=$false}|Select-Object -First 1
        if($candidate){$representatives.Add($candidate)}
    }
    $singles=@($validProjects|Sort-Object @{Expression='loaderId';Descending=$false},@{Expression='project';Descending=$false}|ForEach-Object{[pscustomobject]@{targetId=$_.targetId;project=$_.project;projectPath=$_.projectPath;minecraftId=$_.minecraftId;loaderVersion=$_.loaderVersion;mode='Single';loaderId=$_.loaderId;toolchain=$_.toolchain;status=if($_.launchReady){'READY_FOR_USER_VALIDATION'}else{'BLOCKED_BY_LAUNCH_CHECK'};launchReady=[bool]$_.launchReady;buildReady=[bool]$_.buildReady;launchBlockers=@($_.launchBlockers);planFailure=$_.planFailure;binding=$_.binding;validationEligible=$false}})
    $missingLoaders=@($requiredLoaders|Where-Object{$_ -notin @($representatives|ForEach-Object loaderId)})
    $representativeIds=@($representatives|ForEach-Object targetId)
    $tier1Pass=$representativeIds.Count -gt 0 -and @($representativeIds|Where-Object{$_ -notin $CompletedSingleTargetIds}).Count -eq 0
    $singlePass=$singles.Count -gt 0 -and @($singles|Where-Object targetId -notin $CompletedSingleTargetIds).Count -eq 0
    $dedicatedPass=$representativeIds.Count -gt 0 -and @($representativeIds|Where-Object{$_ -notin $CompletedDedicatedTargetIds}).Count -eq 0
    $dedicatedRows=@($representatives|ForEach-Object{[pscustomobject]@{targetId=$_.targetId;project=$_.project;projectPath=$_.projectPath;mode='Dedicated';loaderId=$_.loaderId;status=if(-not $singlePass){'BLOCKED_SINGLE_VALIDATION_REQUIRED'}elseif($_.launchReady){'READY_AFTER_SINGLE_TIER'}else{'BLOCKED_BY_LAUNCH_CHECK'};enabled=[bool]($_.launchReady -and $singlePass);requiresUserEulaConsent=$true;validationEligible=$false}})
    $lanRows=@($representatives|ForEach-Object{[pscustomobject]@{targetId=$_.targetId;project=$_.project;projectPath=$_.projectPath;mode='IntegratedLAN';loaderId=$_.loaderId;status=if(-not $singlePass){'BLOCKED_SINGLE_VALIDATION_REQUIRED'}elseif(-not $dedicatedPass){'BLOCKED_DEDICATED_TIER_REQUIRED'}elseif($_.targetId -notin $IntegratedLanAuthReadyTargetIds){'AUTH_REQUIRED'}else{'READY_AFTER_AUTH_AND_PRIOR_TIERS'};enabled=[bool]($singlePass -and $dedicatedPass -and $_.targetId -in $IntegratedLanAuthReadyTargetIds);validationEligible=$false}})
    $tier1=[pscustomobject]@{tier='Tier1-Single';enabled=($missingLoaders.Count -eq 0);targetIds=$representativeIds;mode='Single';description='Forge、Fabric、NeoForge 各选一个易验证代表项目；每项由用户亲自完成真实 GUI 观察。';blockedReasonCode=if($missingLoaders.Count){'REPRESENTATIVE_LOADER_MISSING'}else{$null}}
    $tier2=[pscustomobject]@{tier='Tier2-Single-Portfolio';enabled=[bool]($tier1Pass -and $missingLoaders.Count -eq 0);targetIds=@($singles|Where-Object targetId -notin $representativeIds|ForEach-Object targetId);mode='Single';description='完成代表项目 Tier1 后开放其余真实项目的 Single GUI 验证；全部完成后才进入服务端层级。';blockedReasonCode=if(-not $tier1Pass){'TIER1_SINGLE_REQUIRED'}else{$null}}
    $tier3Enabled=$singlePass -and @($dedicatedRows|Where-Object{ -not $_.enabled -and $_.status -ne 'BLOCKED_BY_LAUNCH_CHECK'}).Count -eq 0
    $tier3=[pscustomobject]@{tier='Tier3-Dedicated';enabled=[bool]$tier3Enabled;targetIds=$representativeIds;mode='Dedicated';description='Single 验证全部完成后才可开始 Dedicated；每个项目仍须由用户明确接受 EULA。';blockedReasonCode=if(-not $singlePass){'SINGLE_VALIDATION_REQUIRED'}else{$null}}
    $tier4Enabled=$singlePass -and $dedicatedPass -and @($lanRows|Where-Object status -eq 'READY_AFTER_AUTH_AND_PRIOR_TIERS').Count -gt 0
    $tier4=[pscustomobject]@{tier='Tier4-IntegratedLAN';enabled=[bool]$tier4Enabled;targetIds=@($lanRows|Where-Object enabled|ForEach-Object targetId);mode='IntegratedLAN';description='Dedicated 层级结束且认证方案明确后才可由用户手动执行 IntegratedLAN。';blockedReasonCode=if(-not $singlePass){'SINGLE_VALIDATION_REQUIRED'}elseif(-not $dedicatedPass){'DEDICATED_VALIDATION_REQUIRED'}else{'AUTH_REQUIRED'}}
    $checklist=@(
        [pscustomobject]@{step=1;id='IDENTITY_AND_BACKUP';action='确认当前 Profile、项目、Minecraft/Loader 目标和 Runtime Root；确认已有 Session 与世界数据已备份。';expected='目标身份与验证矩阵完全一致；备份位置已由用户确认。';visualConfirmation='用户核对目标项目与目标版本。'},
        [pscustomobject]@{step=2;id='DOCTOR';action='运行 `--doctor`，检查 Java、平台能力、Runtime Root 和依赖诊断。';expected='无阻止当前验证的 Doctor failure。';visualConfirmation='不涉及游戏窗口。'},
        [pscustomobject]@{step=3;id='LAUNCH_CHECK';action='运行该目标的 `--launch-check --json` 并保存 JSON。';expected='BuildReady/LaunchReady、Runtime Java binding 与角色 blocker 明确。';visualConfirmation='不启动游戏。'},
        [pscustomobject]@{step=4;id='CLEAN_BUILD';action='按矩阵命令执行 `clean build`，确认退出码为 0。';expected='构建证据记录 source fingerprint、fresh artifact hash 与日志摘要。';visualConfirmation='不启动游戏。'},
        [pscustomobject]@{step=5;id='ARTIFACT_REVIEW';action='检查唯一 Mod JAR 的文件名、长度、SHA-256 和对应 source/build evidence。';expected='产物归属当前 source fingerprint，非 stale。';visualConfirmation='不涉及游戏窗口。'},
        [pscustomobject]@{step=6;id='LAUNCH_COMMAND';action='由用户手动复制矩阵中的精确命令启动目标。';expected='新 Session v2 与 Execution Plan digest 已创建。';visualConfirmation='用户看到预期目标的 Minecraft 窗口。'},
        [pscustomobject]@{step=7;id='CLIENT_MARKER';action='等待当前 Session 的客户端初始化观察完成。';expected='当前 Session、进程身份、Runtime Java 与 init marker 匹配。';visualConfirmation='用户确认客户端窗口显示正常且不是启动崩溃界面。'},
        [pscustomobject]@{step=8;id='MAIN_MENU';action='在游戏中等待进入主菜单；需要时由用户手动处理资源加载或提示。';expected='Observer 记录 main menu marker；marker 仍绑定当前进程。';visualConfirmation='用户确认主菜单可见、没有崩溃或认证错误。'},
        [pscustomobject]@{step=9;id='WORLD_OR_SERVER_ACTION';action='按对应 Tier 手动创建/选择世界、确认功能场景，或在已批准后启动 Dedicated；不自动输入游戏操作。';expected='只记录本阶段允许的人工观察事件。';visualConfirmation='用户亲自确认目标游戏行为；IntegratedLAN 认证由用户负责。'},
        [pscustomobject]@{step=10;id='SAFE_STOP';action='使用 MMTL Session Stop 或游戏内正常退出，等待登记进程和进程树结束。';expected='PROCESS_EXITED、safe stop 与端口释放证据齐全（适用时）。';visualConfirmation='用户确认窗口关闭且没有异常弹窗。'},
        [pscustomobject]@{step=11;id='SESSION_EVIDENCE';action='运行 `--session-info`、`--session-validate` 与只读 Observer；检查验证候选及失败分类。';expected='Session v2、Plan digest、artifact hash、binding、process identity、Observed Java、events 和 crash/stop evidence 已保存。';visualConfirmation='用户确认记录中的目标与刚才实际操作相符。'}
    )
    $matrix=[Collections.Generic.List[object]]::new();foreach($single in $singles){$matrix.Add($single)};foreach($row in $dedicatedRows){$matrix.Add($row)};foreach($row in $lanRows){$matrix.Add($row)}
    return [pscustomobject][ordered]@{schemaVersion=1;generatedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');workspaceIdentity=$WorkspaceIdentity;portfolioCount=$validProjects.Count;missingRepresentativeLoaders=$missingLoaders;representatives=@($representatives.ToArray());tiers=@($tier1,$tier2,$tier3,$tier4);matrix=@($matrix.ToArray());checklist=$checklist;manualOnly=$true;startsMinecraft=$false;startsDedicatedServer=$false;acceptsEula=$false;startsAuthentication=$false;validationEligible=$false;limits=@('IntegratedLAN 在合法认证准备完成前为 AUTH_REQUIRED。','Dedicated EULA 必须由用户先明确接受；本计划不会写 eula.txt。','Minecraft GUI 观察需要用户亲自执行。')}
}

function ConvertTo-MmtlPsSingleQuotedLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'"+$Value.Replace("'","''")+"'"
}

function Write-MmtlHumanValidationBundle {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$OutputRoot,[Parameter(Mandatory)][string]$LauncherPath,[string]$ConfigPath='',[string]$ProfileName='')
    $root=[IO.Path]::GetFullPath($OutputRoot);[void][IO.Directory]::CreateDirectory($root)
    $planPath=Join-Path $root 'human-validation-plan.json';$matrixPath=Join-Path $root 'matrix.json';$checklistPath=Join-Path $root 'checklist.md';$statusPath=Join-Path $root 'status.json';$helperPath=Join-Path $root 'manual-validation-helper.ps1'
    $helperLiteral=ConvertTo-MmtlPsSingleQuotedLiteral ([IO.Path]::GetFullPath($helperPath))
    $matrixRows=@($Plan.matrix|ForEach-Object{$row=$_;$targetLiteral=ConvertTo-MmtlPsSingleQuotedLiteral ([string]$row.targetId);$copy=[ordered]@{};foreach($property in $row.PSObject.Properties){$copy[$property.Name]=$property.Value};$copy.preflightCommand="& $helperLiteral -Preflight -TargetId $targetLiteral";$launchCommand="& $helperLiteral -Launch -ConfirmRealMinecraftLaunch -TargetId $targetLiteral";if($row.mode -eq 'Dedicated'){$launchCommand+=' -ConfirmEulaAcceptance'};$copy.launchCommand=$launchCommand;[pscustomobject]$copy})
    $matrix=[pscustomobject]@{schemaVersion=1;generatedAtUtc=$Plan.generatedAtUtc;rows=$matrixRows;validationEligible=$false}
    $status=[pscustomobject]@{schemaVersion=1;generatedAtUtc=$Plan.generatedAtUtc;overall='NOT_STARTED';validationEligible=$false;rows=@($Plan.matrix|ForEach-Object{[pscustomobject]@{targetId=$_.targetId;mode=$_.mode;status='NOT_STARTED';evidenceSessionId=$null;notes=''}})}
    $md=[Collections.Generic.List[string]]::new();$md.Add('# Minecraft 人工实机验证清单');$md.Add('');$md.Add('本地人工验证包；运行前先检查 `human-validation-plan.json` 和 `matrix.json`。本包不含原始 Minecraft 日志或自动认证。');$md.Add('');$md.Add('## 验证顺序');$md.Add('');foreach($tier in $Plan.tiers){$md.Add("- $($tier.tier)：enabled=$($tier.enabled)；targets=$($tier.targetIds -join ', ')；门禁=$($tier.blockedReasonCode)")};$md.Add('');$md.Add('## 11 步用户清单');$md.Add('');foreach($item in $Plan.checklist){$md.Add("$($item.step). **$($item.id)** — $($item.action)");$md.Add("   - 预期证据：$($item.expected)");$md.Add("   - 用户目视确认：$($item.visualConfirmation)");$md.Add('')};$md.Add('## Safe Stop');$md.Add('');$md.Add('每次验证结束均使用当前 Session 的受跟踪停止路径。不要结束全局 `java.exe` 或 Gradle daemon。')
    $launcherLiteral=ConvertTo-MmtlPsSingleQuotedLiteral ([IO.Path]::GetFullPath($LauncherPath));$configLiteral=ConvertTo-MmtlPsSingleQuotedLiteral $ConfigPath;$planLiteral=ConvertTo-MmtlPsSingleQuotedLiteral $planPath
    $helper=@"
[CmdletBinding()]
param([switch]`$Help,[Alias('Plan')][switch]`$ShowPlan,[switch]`$Preflight,[switch]`$Launch,[switch]`$ConfirmRealMinecraftLaunch,[switch]`$ConfirmEulaAcceptance,[string]`$TargetId)
`$ErrorActionPreference='Stop'
`$launcher=$launcherLiteral
`$config=$configLiteral
`$planPath=$planLiteral
if(-not (`$Help -or `$ShowPlan -or `$Preflight -or `$Launch)){`$ShowPlan=`$true}
if(`$Help){Write-Host '默认只显示验证计划。Preflight 只运行只读 --launch-check。真实 Launch 必须同时指定 -Launch -ConfirmRealMinecraftLaunch -TargetId。';exit 0}
if(`$ShowPlan){Get-Content -LiteralPath `$planPath -Raw;exit 0}
if(`$Preflight -and -not `$TargetId){throw 'PRECHECK_TARGET_REQUIRED'}
if(`$Launch -and (-not `$ConfirmRealMinecraftLaunch -or -not `$TargetId)){throw 'REAL_MINECRAFT_LAUNCH_REQUIRES_EXPLICIT_CONFIRMATION_AND_TARGET'}
if(-not (Test-Path -LiteralPath `$launcher -PathType Leaf)){throw 'MMTL_LAUNCHER_NOT_FOUND'}
`$plan=Get-Content -LiteralPath `$planPath -Raw|ConvertFrom-Json
`$target=`$plan.matrix|Where-Object targetId -CEQ `$TargetId|Select-Object -First 1
if(-not `$target){throw 'TARGET_NOT_IN_HUMAN_VALIDATION_PLAN'}
if(`$Launch -and `$target.mode -eq 'Dedicated' -and -not `$ConfirmEulaAcceptance){throw 'DEDICATED_LAUNCH_REQUIRES_EXPLICIT_EULA_ACCEPTANCE'}
if(`$ConfirmEulaAcceptance -and `$target.mode -ne 'Dedicated'){throw 'EULA_ACCEPTANCE_FLAG_ONLY_APPLIES_TO_DEDICATED'}
if(`$Preflight -or `$Launch){
  if(-not (Test-Path -LiteralPath `$config -PathType Leaf)){throw 'LOCAL_LAUNCHER_CONFIG_NOT_FOUND'}
  `$source=Get-Content -LiteralPath `$config -Raw|ConvertFrom-Json
  `$baseProfile=`$source.profiles.PSObject.Properties[`$source.defaultProfile].Value
  `$profileCopy=`$baseProfile|ConvertTo-Json -Depth 40|ConvertFrom-Json
  `$profileCopy.project=`$target.projectPath;`$profileCopy.linkedProjects=@();`$profileCopy.mode=`$target.mode
  `$profileCopy.players=if(`$target.mode -eq 'Single'){1}else{2};`$profileCopy.cleanBuild=`$true;`$profileCopy.autoBuild=`$true
  `$profileCopy|Add-Member -NotePropertyName acceptEula -NotePropertyValue ([bool]`$ConfirmEulaAcceptance) -Force
  `$tempProfile='human-validation-'+[guid]::NewGuid().ToString('N').Substring(0,8)
  `$source.profiles|Add-Member -NotePropertyName `$tempProfile -NotePropertyValue `$profileCopy -Force;`$source.defaultProfile=`$tempProfile
  `$tempConfig=Join-Path ([IO.Path]::GetTempPath()) (`$tempProfile+'.json')
  try{
    [IO.File]::WriteAllText(`$tempConfig,(`$source|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new(`$false))
    `$mode=if(`$Launch){'--launch'}else{'--launch-check'}
    if(`$launcher.EndsWith('.ps1',[StringComparison]::OrdinalIgnoreCase)){`$pwshPath=(Get-Command pwsh -ErrorAction Stop).Source;& `$pwshPath -NoProfile -File `$launcher --config-file `$tempConfig --profile `$tempProfile `$mode --json}
    else{& `$launcher --config-file `$tempConfig --profile `$tempProfile `$mode --json}
    if(`$LASTEXITCODE -ne 0){throw "MMTL_PREFLIGHT_OR_LAUNCH_FAILED:`$LASTEXITCODE"}
  }finally{if(Test-Path -LiteralPath `$tempConfig){Remove-Item -LiteralPath `$tempConfig -Force}}
}
if(`$Launch){Write-Warning 'MMTL 已请求用户选择的真实启动；后续 GUI、世界、菜单、认证与 EULA 均由用户本人操作。'}
"@
    Write-MmtlAtomicTextFile -Path $planPath -Content (($Plan|ConvertTo-Json -Depth 40)+"`n")
    Write-MmtlAtomicTextFile -Path $matrixPath -Content (($matrix|ConvertTo-Json -Depth 30)+"`n")
    Write-MmtlAtomicTextFile -Path $statusPath -Content (($status|ConvertTo-Json -Depth 30)+"`n")
    Write-MmtlAtomicTextFile -Path $checklistPath -Content (($md -join "`n")+"`n")
    Write-MmtlAtomicTextFile -Path $helperPath -Content ($helper.Trim()+"`n")
    return [pscustomobject]@{planPath=$planPath;matrixPath=$matrixPath;statusPath=$statusPath;checklistPath=$checklistPath;helperPath=$helperPath;rows=@($Plan.matrix).Count;validationEligible=$false}
}

Export-ModuleMember -Function New-MmtlHumanValidationPlan,Write-MmtlHumanValidationBundle
