Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../Observation/ObservationSafety.psm1') -Force

function Get-MmtlFindingRule {
    param([string]$Text)
    $rules=@(
        @{category='JVM_CRASH';pattern='(?i)hs_err_pid\d+|fatal error.*jvm|EXCEPTION_ACCESS_VIOLATION'},
        @{category='OUT_OF_MEMORY';pattern='(?i)OutOfMemoryError|Java heap space|GC overhead limit exceeded'},
        @{category='STACK_OVERFLOW';pattern='(?i)StackOverflowError'},
        @{category='MISSING_CLASS';pattern='(?i)ClassNotFoundException|NoClassDefFoundError'},
        @{category='DEPENDENCY_BINARY_MISMATCH';pattern='(?i)NoSuchMethodError|NoSuchFieldError'},
        @{category='MIXIN_TRANSFORM';pattern='(?i)MixinApplyError|MixinTransformerError|InvalidInjectionException|InjectionError'},
        @{category='DUPLICATE_MOD';pattern='(?i)Duplicate Mod|duplicate mod id|duplicate mods? detected'},
        @{category='MISSING_DEPENDENCY';pattern='(?i)missing dependenc|requires missing|depends on .* which is missing'},
        @{category='VERSION_MISMATCH';pattern='(?i)version mismatch|requires .* version|incompatible version'},
        @{category='INVALID_DIST';pattern='(?i)invalid dist|client[- ]only class.*dedicated|dedicated server.*client class'},
        @{category='REGISTRY_FAILURE';pattern='(?i)registry.*(freeze|frozen|duplicate)|duplicate.*registry'},
        @{category='NETWORK_CHANNEL';pattern='(?i)network channel mismatch|channel .* mismatch|packet decode error|DecoderException'},
        @{category='CONFIG_PARSE';pattern='(?i)config(uration)? parse (error|failure)|failed to parse config|toml.*(invalid|error)'},
        @{category='RESOURCE_RELOAD';pattern='(?i)datapack.*(reload|error|fail)|resource reload.*(error|fail)|failed to reload'},
        @{category='CRASH_REPORT';pattern='(?i)crash report generated|crash report saved|\bcrash report\b'},
        @{category='GENERIC_MOD_EXCEPTION';pattern='(?i)\b(?:ERROR|FATAL)\b|Exception:|Error:'}
    )
    foreach($rule in $rules){if($Text -match $rule.pattern){return $rule}}
    return $null
}

function Get-MmtlAnalyzerMetadataValues {
    param($Metadata,[string]$Name)
    if($Metadata -and $Metadata.PSObject.Properties[$Name]){return @($Metadata.$Name|Where-Object{$_})}
    return @()
}

function Get-MmtlAttribution {
    param([string]$Text,[string]$Category,$ProjectMetadata)
    $modIds=@($ProjectMetadata.modIds|Where-Object{$_}|ForEach-Object{[regex]::Escape([string]$_)})
    $packages=@($ProjectMetadata.packageCandidates|ForEach-Object{if($_ -is [string]){[string]$_}elseif($_.packageName){[string]$_.packageName}}|Where-Object{$_})
    foreach($package in $packages){$escaped=[regex]::Escape($package);if($Text -match "(?m)^\s*at\s+$escaped(?:\.[\w$]+)+\(" -or $Text -match "(?m)Caused by:.*\b$escaped(?:\.[\w$]+)+") {return [pscustomobject]@{value='Direct';matched=$package}}}
    foreach($className in @(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'entrypointClasses')){$escapedClass=[regex]::Escape([string]$className);if($Text -match "(?m)^\s*at\s+$escapedClass\."){return [pscustomobject]@{value='Direct';matched=[string]$className}}}
    foreach($id in $modIds){$idPattern=[regex]::Escape($id);if($Text -match ("(?i)(?:mod(?:id)?\s*[:=]?\s*{0}\b|\b{0}\b.*(?:requires|failed|error|mixin))" -f $idPattern)){return [pscustomobject]@{value='Direct';matched=($id.ToLowerInvariant())}}}
    foreach($mix in @(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'mixinConfigs')){if($Text.Contains([string]$mix)){return [pscustomobject]@{value='Indirect';matched=[string]$mix}}}
    foreach($package in $packages){if($Text.Contains([string]$package)){return [pscustomobject]@{value='Indirect';matched=[string]$package}}}
    foreach($artifact in @(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'artifactNames')){if($Text.Contains([string]$artifact)){return [pscustomobject]@{value='Indirect';matched=[string]$artifact}}}
    return [pscustomobject]@{value='Unknown';matched=$null}
}

function Get-MmtlNextCheck {
    param([string]$Category)
    switch($Category){
        'MISSING_CLASS' {'检查项目依赖声明、运行时 Mod 清单与目标版本兼容性。'}
        'DEPENDENCY_BINARY_MISMATCH' {'核对编译期与运行期依赖版本及调用 API 是否匹配。'}
        'MIXIN_TRANSFORM' {'检查 mixin 配置、目标方法签名与 Loader/Minecraft 版本。'}
        'MISSING_DEPENDENCY' {'核对被点名依赖的安装状态、版本范围与加载顺序。'}
        'DUPLICATE_MOD' {'检查运行目录中是否存在重复 Mod ID 或重复制品。'}
        'VERSION_MISMATCH' {'核对 Minecraft、Loader、Java 与 Mod 声明的版本范围。'}
        'INVALID_DIST' {'检查客户端专用类是否被 Dedicated Server 侧加载。'}
        'REGISTRY_FAILURE' {'检查注册表事件时序以及是否存在重复注册。'}
        'NETWORK_CHANNEL' {'核对 Host/Guest 双方 Mod 集与网络通道协议版本。'}
        'CONFIG_PARSE' {'检查配置文件格式、字段类型与默认配置迁移。'}
        'RESOURCE_RELOAD' {'检查 datapack/resource 内容与 reload 阶段的首个异常。'}
        'OUT_OF_MEMORY' {'检查堆内存配置、资源占用与异常前的增长趋势。'}
        'STACK_OVERFLOW' {'检查异常调用链是否存在递归或循环回调。'}
        'JVM_CRASH' {'检查 JVM 崩溃文件、JVM/驱动版本与原生库调用栈。'}
        'MMTL_INFRASTRUCTURE' {'检查 MMTL Agent 与 Session IPC/事件文件；不要归因给用户 Mod。'}
        default {'查看保留的前后文与完整 Caused-by 链，再定位最早异常。'}
    }
}

function Invoke-MmtlRuleBasedAnalysis {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$ProjectMetadata,[string]$ScenarioResult='PARTIAL',[string]$RuntimeStatus='Unknown',$SessionMetadata)
    $session=[IO.Path]::GetFullPath($SessionPath);if(-not(Test-Path -LiteralPath $session -PathType Container)){throw 'ANALYZER_SESSION_MISSING'}
    foreach($relative in @('logs','logs/structured','logs/relevant','analysis')){$target=Join-Path $session $relative;if(Test-Path -LiteralPath $target){$null=Resolve-MmtlObserverSafePath -SessionPath $session -Target $target}else{$null=Resolve-MmtlObserverSafePath -SessionPath $session -Target $target -AllowMissing;$null=New-Item -ItemType Directory -Path $target -Force}}
    $structuredRoot=Join-Path $session 'logs/structured';$groups=[Collections.Generic.List[object]]::new()
    foreach($file in @(Get-ChildItem -LiteralPath $structuredRoot -File -Filter '*.jsonl' -ErrorAction SilentlyContinue|Sort-Object Name)){
        $safe=Resolve-MmtlObserverSafePath -SessionPath $session -Target $file.FullName
        $rows=[Collections.Generic.List[object]]::new();$lineNo=0
        foreach($line in [IO.File]::ReadAllLines($safe,[Text.Encoding]::UTF8)){ $lineNo++;if(-not $line){continue};try{$row=$line|ConvertFrom-Json -ErrorAction Stop;$rows.Add([pscustomobject]@{lineNo=$lineNo;record=$row})}catch{continue} }
        if($rows.Count){$groups.Add([pscustomobject]@{file=$safe;rows=@($rows.ToArray())})}
    }
    $modId=if($ProjectMetadata.primaryModId){[string]$ProjectMetadata.primaryModId}elseif(@($ProjectMetadata.modIds).Count -eq 1){[string]$ProjectMetadata.modIds[0]}else{'unresolved'}
    $findings=[Collections.Generic.List[object]]::new();$relevant=[Collections.Generic.List[string]]::new();$findingIndex=0
    foreach($group in $groups){
        $records=@($group.rows|ForEach-Object{$_.record});$candidateIndexes=[Collections.Generic.List[int]]::new()
        for($i=0;$i -lt $records.Count;$i++){
            $record=$records[$i];$text=[string]$record.message;$rule=Get-MmtlFindingRule $text
            $isAgent=([string]$record.role -eq 'Agent' -or $text -match '(?i)dev\.mmtl\.agent|mmtl\.agent')
            $currentMention=$false;$markers=@((Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'modIds')+(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'modNames')+(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'entrypointClasses')+(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'mixinConfigs')+(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'artifactNames')+@($ProjectMetadata.packageCandidates|ForEach-Object{if($_ -is [string]){$_}else{$_.packageName}}));foreach($marker in @($markers|Where-Object{$_})){if($text -match ('(?i){0}' -f [regex]::Escape([string]$marker))){$currentMention=$true;break}}
            if($rule -or $isAgent -or ($record.level -eq 'WARN' -and ($text -match '(?i)mixin|resource reload|network channel' -or $currentMention))){$candidateIndexes.Add($i)}
        }
        $clusters=[Collections.Generic.List[object]]::new();foreach($index in $candidateIndexes){$separate=$false;if($clusters.Count){$prior=[int]$clusters[$clusters.Count-1].end;$separate=($index-$prior) -gt 40 -or [bool]$records[$index].sourceTimestamp};if(-not $clusters.Count -or $separate){$clusters.Add([pscustomobject]@{start=$index;end=$index})}else{$clusters[$clusters.Count-1].end=$index}}
        foreach($cluster in $clusters){
            $first=[Math]::Max(0,[int]$cluster.start-20);$last=[Math]::Min($records.Count-1,[int]$cluster.end+20);$evidence=[Collections.Generic.List[object]]::new();$textParts=[Collections.Generic.List[string]]::new()
            for($i=$first;$i -le $last;$i++){$r=$records[$i];$msg=[string]$r.message;$textParts.Add($msg);$evidence.Add([pscustomobject]@{role=[string]$r.role;identity=[string]$r.identity;sourceFile=[string]$r.sourceFile;lineNumber=[int]$group.rows[$i].lineNo;observedAtUtc=[string]$r.observedAtUtc;sourceTimestamp=[string]$r.sourceTimestamp;message=$msg})}
            $block=$textParts -join "`n";$clusterIndexes=@([int]$cluster.start..[int]$cluster.end);$clusterRecords=@($clusterIndexes|ForEach-Object{$records[$_]});$agentEvidence=(@($clusterRecords|Where-Object{[string]$_.role -eq 'Agent'}).Count -gt 0);$triggerText=(@($clusterRecords|ForEach-Object{[string]$_.message}) -join "`n")
            $rule=Get-MmtlFindingRule $triggerText;if($agentEvidence -or $triggerText -match '(?i)dev\.mmtl\.agent|mmtl\.agent'){$category='MMTL_INFRASTRUCTURE'}elseif($rule){$category=[string]$rule.category}else{$category='RELEVANT_WARNING'}
            $attribution=Get-MmtlAttribution -Text $block -Category $category -ProjectMetadata $ProjectMetadata
            $confidence=if($attribution.value -eq 'Direct'){'High'}elseif($attribution.value -eq 'Indirect'){'Medium'}else{'Low'}
            $matching=@($candidateIndexes|Where-Object{$_ -ge $cluster.start -and $_ -le $cluster.end});$headline=[string]$records[$matching[0]].message
            $findingIndex++;$findings.Add([pscustomobject][ordered]@{findingId=('F{0:D3}' -f $findingIndex);likelyCategory=$category;attribution=$attribution.value;matchedEvidence=$attribution.matched;observed=$headline;confidence=$confidence;evidence=@($evidence.ToArray());possibleNextCheck=(Get-MmtlNextCheck $category)})
            foreach($entry in $evidence){$relevant.Add(($entry|ConvertTo-Json -Depth 8 -Compress))}
        }
    }
    $safeMod=[regex]::Replace($modId,'[^A-Za-z0-9_-]','_');$relevantPath=Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $session "logs/relevant/$safeMod.jsonl") -AllowMissing
    $relevantContent=if($relevant.Count){($relevant -join "`n")+"`n"}else{''};$tmp=$relevantPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp';try{[IO.File]::WriteAllText($tmp,$relevantContent,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $relevantPath -Force}finally{if(Test-Path $tmp){Remove-Item $tmp -Force}}
    $roleSummary=@($groups|ForEach-Object{$_.rows}|ForEach-Object{$_.record}|ForEach-Object{[pscustomobject]@{role=[string]$_.role;identity=[string]$_.identity}}|Sort-Object role,identity -Unique)
    $buildSummary=@();if($SessionMetadata -and $SessionMetadata.PSObject.Properties['builds'] -and $SessionMetadata.builds){$buildSummary=@($SessionMetadata.builds|ForEach-Object{[pscustomobject]@{artifact=$(if($_.JarPath){[IO.Path]::GetFileName([string]$_.JarPath)}else{$null});sha256=[string]$_.JarSha256;exitCode=$_.ExitCode}})}
    $sessionJava=if($SessionMetadata -and $SessionMetadata.PSObject.Properties['javaMajor']){$SessionMetadata.javaMajor}else{$null};$sessionMode=if($SessionMetadata -and $SessionMetadata.PSObject.Properties['mode']){[string]$SessionMetadata.mode}else{$null};$agentVersion=if($SessionMetadata -and $SessionMetadata.PSObject.Properties['agentVersion']){[string]$SessionMetadata.agentVersion}else{$null}
    $findingsDoc=[pscustomobject][ordered]@{schemaVersion=1;sessionId=[IO.Path]::GetFileName($session);provider='RuleBasedAnalyzer';testObject=[string]$modId;project=@{primaryModId=$modId;modIds=@($ProjectMetadata.modIds);modNames=(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'modNames');loader=[string]$ProjectMetadata.loaderId;minecraft=[string]$ProjectMetadata.minecraftVersion;javaMajor=$sessionJava;mode=$sessionMode;artifactNames=(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'artifactNames');mixinConfigs=(Get-MmtlAnalyzerMetadataValues $ProjectMetadata 'mixinConfigs')};scenarioAssertions=$ScenarioResult;scopeNote='仅表示本 Profile 可观察的启动、加入与生命周期断言；不代表 Mod 全部功能正确。';runtimeStatus=$RuntimeStatus;roles=$roleSummary;builds=$buildSummary;agentVersion=$agentVersion;findingCount=$findings.Count;findings=@($findings.ToArray())}
    $findingsPath=Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $session 'analysis/findings.json') -AllowMissing;[IO.File]::WriteAllText($findingsPath,(($findingsDoc|ConvertTo-Json -Depth 20)+"`n"),[Text.UTF8Encoding]::new($false))
    $summaryPath=Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $session 'analysis/summary.json') -AllowMissing;[IO.File]::WriteAllText($summaryPath,(($findingsDoc|ConvertTo-Json -Depth 20)+"`n"),[Text.UTF8Encoding]::new($false))
    $md=[Collections.Generic.List[string]]::new();$md.Add('# MMTL 测试会话分析');$md.Add('');$md.Add("- Session：$([IO.Path]::GetFileName($session))");$md.Add("- 测试对象 / Mod ID：$modId");$md.Add("- Loader / Minecraft：$($ProjectMetadata.loaderId) / $($ProjectMetadata.minecraftVersion)");$md.Add("- Java：$(if($null -ne $sessionJava){$sessionJava}else{'未知'})");$md.Add("- Scenario assertions：$ScenarioResult");$md.Add("- 运行状态：$RuntimeStatus");$md.Add("- 角色：$(($roleSummary|ForEach-Object{'{0}/{1}' -f $_.role,$_.identity}) -join ', ')");$md.Add("- Findings：$($findings.Count)");$md.Add('');$md.Add('此结果只覆盖 Profile 定义的可观察断言，不代表 Mod 全部功能正确。');$md.Add('');$md.Add('## Findings')
    if(-not $findings.Count){$md.Add('');$md.Add('未发现满足当前规则的异常信号。')}
    foreach($finding in $findings){$md.Add('');$md.Add("### $($finding.findingId) — $($finding.likelyCategory)");$md.Add(('- 归属：{0}；置信度：{1}' -f $finding.attribution,$finding.confidence));$md.Add("- 观察到：$($finding.observed)");$md.Add("- 建议检查：$($finding.possibleNextCheck)");$md.Add('- 证据：');foreach($e in $finding.evidence){$md.Add(('  - [{0}/{1}] {2}' -f $e.role,$e.identity,$e.message))}}
    $md.Add('');$md.Add("- 相关日志：logs/relevant/$safeMod.jsonl");$markdownPath=Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $session 'analysis/summary.md') -AllowMissing;[IO.File]::WriteAllText($markdownPath,($md -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    return [pscustomobject][ordered]@{status='Analyzed';provider='RuleBasedAnalyzer';sessionId=[IO.Path]::GetFileName($session);findingCount=$findings.Count;findings=@($findings.ToArray());findingsPath='analysis/findings.json';summaryJsonPath='analysis/summary.json';summaryMarkdownPath='analysis/summary.md';relevantLogPath="logs/relevant/$safeMod.jsonl"}
}

function Invoke-MmtlAnalyzer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('RuleBasedAnalyzer')][string]$Provider,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$ProjectMetadata,[string]$ScenarioResult='PARTIAL',[string]$RuntimeStatus='Unknown',$SessionMetadata)
    switch($Provider){'RuleBasedAnalyzer'{return Invoke-MmtlRuleBasedAnalysis -SessionPath $SessionPath -ProjectMetadata $ProjectMetadata -ScenarioResult $ScenarioResult -RuntimeStatus $RuntimeStatus -SessionMetadata $SessionMetadata}}
}

Export-ModuleMember -Function Invoke-MmtlRuleBasedAnalysis,Invoke-MmtlAnalyzer
