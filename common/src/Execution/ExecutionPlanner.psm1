Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'JavaResolution.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ExecutionPlan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../Catalog/JavaRuntimeResolver.psm1') -Force

function Get-MmtlPlannerProperty {
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name, $Default=$null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { if ([string]$key -ieq $Name) { return $InputObject[$key] } }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function ConvertTo-MmtlJavaRequirementForPlan {
    param([AllowNull()]$Requirement, [Parameter(Mandatory)][ValidateSet('BuildJava','RuntimeJava')][string]$Purpose)
    if ($null -eq $Requirement) { $Requirement = [pscustomobject]@{major=$null;requirementKind='Unknown';source='Unknown';confidence='Unknown'} }
    $major = Get-MmtlPlannerProperty $Requirement 'major'
    if ($major -and [int]$major -lt 1) { throw "${Purpose}_REQUIREMENT_INVALID: major 必须为正整数。" }
    $kind = [string](Get-MmtlPlannerProperty $Requirement 'requirementKind' 'Unknown')
    $source = [string](Get-MmtlPlannerProperty $Requirement 'source' 'Unknown')
    $confidence = [string](Get-MmtlPlannerProperty $Requirement 'confidence' 'Unknown')
    $result = [ordered]@{purpose=$Purpose;major=$(if($major){[int]$major}else{$null});minimumMajor=$null;preferredMajor=$null;exactMajor=$null;requirementKind=$kind;source=$source;confidence=$confidence;component=(Get-MmtlPlannerProperty $Requirement 'component');provenance=(Get-MmtlPlannerProperty $Requirement 'provenance')}
    foreach ($name in @('minimumMajor','preferredMajor','exactMajor')) { $value=Get-MmtlPlannerProperty $Requirement $name; if ($value) { $result[$name]=[int]$value } }
    if ($Purpose -eq 'BuildJava' -and $kind -eq 'Minimum' -and -not $result.minimumMajor -and $major) { $result.minimumMajor=[int]$major }
    if ($Purpose -eq 'RuntimeJava' -and $kind -eq 'Exact' -and -not $result.exactMajor -and $major) { $result.exactMajor=[int]$major }
    return [pscustomobject]$result
}

function Get-MmtlPlannerRuntimeJavaRequirement {
    param($Project, $Profile, $RuntimeJavaRequirement, $CatalogEntry, $VersionMetadata)
    $override = Get-MmtlPlannerProperty $Profile 'runtimeJavaOverride'
    if ($override) {
        $major=0
        if (-not [int]::TryParse([string](Get-MmtlPlannerProperty $override 'major'), [ref]$major) -or $major -lt 1) { throw 'RUNTIME_JAVA_OVERRIDE_INVALID: major 必须为正整数。' }
        return [pscustomobject]@{purpose='RuntimeJava';major=$major;requirementKind='Exact';source='ProjectOverride';confidence='High';component=(Get-MmtlPlannerProperty $override 'component');provenance='launcher profile runtimeJavaOverride'}
    }
    if ($RuntimeJavaRequirement) { return $RuntimeJavaRequirement }
    $projectRequirement=Get-MmtlPlannerProperty $Project 'RuntimeJavaRequirement'
    if ($projectRequirement -and (Get-MmtlPlannerProperty $projectRequirement 'major')) { return $projectRequirement }
    if ($CatalogEntry) {
        $version=[string](Get-MmtlPlannerProperty $Project 'MinecraftVersion')
        return Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId $version -CatalogEntry $CatalogEntry -VersionMetadata $VersionMetadata
    }
    return [pscustomobject]@{purpose='RuntimeJava';major=$null;requirementKind='Unknown';source='Unknown';confidence='Unknown';provenance=$null}
}

function Get-MmtlPlannerRuntimeRoles {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Mode)
    $players=0;if(-not[int]::TryParse([string](Get-MmtlPlannerProperty $Profile 'players' ''),[ref]$players)){return ,@()}
    $hostName=[string](Get-MmtlPlannerProperty $Profile 'hostUsername' 'Dev')
    $prefix=[string](Get-MmtlPlannerProperty $Profile 'clientPrefix' 'Dev_')
    $roles=[Collections.Generic.List[object]]::new()
    if ($Mode -notin @('Single','IntegratedLAN','Dedicated')) { return ,@() }
    if ($Mode -eq 'Single') { $roles.Add([pscustomobject]@{role='Client';username=$hostName}) }
    elseif ($Mode -eq 'IntegratedLAN') {
        $roles.Add([pscustomobject]@{role='Host';username=$hostName})
        for ($i=1; $i -lt $players; $i++) { $roles.Add([pscustomobject]@{role='Client';username="$prefix$i"}) }
    }
    else {
        $roles.Add([pscustomobject]@{role='Server';username=''})
        for ($i=0; $i -lt $players; $i++) { $roles.Add([pscustomobject]@{role='Client';username=$(if($i -eq 0){$hostName}else{"$prefix$i"})}) }
    }
    return ,@($roles.ToArray())
}

function Get-MmtlPlannerMemory {
    param($Profile, [string]$Mode, [object[]]$Roles, [long]$PhysicalMemoryMb)
    $base=[long](Get-MmtlPlannerProperty $Profile 'memoryMb' 0)
    $host=[long](Get-MmtlPlannerProperty $Profile 'hostMemoryMb' $base)
    $client=[long](Get-MmtlPlannerProperty $Profile 'clientMemoryMb' $base)
    $server=[long](Get-MmtlPlannerProperty $Profile 'serverMemoryMb' $base)
    if ($host -le 0) { $host=$base }; if ($client -le 0) { $client=$base }; if ($server -le 0) { $server=$base }
    $requested=0L
    foreach ($role in $Roles) { if ($role.role -eq 'Server') { $requested += $server } elseif ($role.role -eq 'Host') { $requested += $host } else { $requested += if($Mode -eq 'Single'){$host}else{$client} } }
    $limit=if($PhysicalMemoryMb -gt 0){[long][Math]::Floor($PhysicalMemoryMb*0.8)}else{$null}
    [pscustomobject]@{requestedMb=$requested;limitMb=$limit;physicalMemoryMb=$(if($PhysicalMemoryMb -gt 0){$PhysicalMemoryMb}else{$null});exceedsLimit=($null -ne $limit -and $requested -gt $limit)}
}

function Get-MmtlPlannerBindingMode {
    param($Project, $AdapterEvidence)
    $value=Get-MmtlPlannerProperty $AdapterEvidence 'runtimeJavaBindingMode'
    if (-not $value) { $value=Get-MmtlPlannerProperty $Project 'RuntimeJavaBindingMode' }
    $evidence=Get-MmtlPlannerProperty $AdapterEvidence 'runtimeJavaBindingEvidence'
    if (-not $evidence) { $evidence=Get-MmtlPlannerProperty $Project 'RuntimeJavaBindingEvidence' }
    if ($value -in @('Direct','ToolchainManaged','SameAsBuildJvm','Unsupported') -and $evidence) { return [string]$value }
    return 'Unknown'
}

function New-MmtlPlannerDiagnostic {
    param([string]$Code,[ValidateSet('Build','Launch','Plan')][string]$Action,[string]$Message,[string]$Source='')
    [pscustomobject][ordered]@{code=$Code;action=$Action;messageZh=$Message;source=$(if($Source){$Source}else{$null})}
}

function New-MmtlExecutionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Platform,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [string]$ProfileName,
        $CatalogEntry,
        $VersionMetadata,
        $RuntimeJavaRequirement,
        $AdapterEvidence,
        [string]$MetadataWarning,
        [long]$PhysicalMemoryMb=0,
        [switch]$BuildRequired,
        [switch]$CleanBuild
    )

    $diagnostics=[Collections.Generic.List[object]]::new()
    $warnings=[Collections.Generic.List[object]]::new()
    $mode=[string](Get-MmtlPlannerProperty $Profile 'mode' '')
    $metadataOnlyFields=switch($mode){
        'Single' {@('hostCheats','clientPermissionLevel','gameMode','difficulty','worldName','seed','newWorld')}
        'IntegratedLAN' {@('hostCheats','clientPermissionLevel','gameMode','difficulty','worldName','seed','newWorld')}
        'Dedicated' {@('hostCheats','newWorld')}
        default {@()}
    }
    foreach($field in $metadataOnlyFields){
        $fieldProperty=$Profile.PSObject.Properties[$field]
        if($fieldProperty -and $null -ne $fieldProperty.Value){
            $warnings.Add((New-MmtlPlannerDiagnostic 'PROFILE_FIELD_METADATA_ONLY' 'Plan' "Profile 字段 $field 仅记录在计划/会话元数据中，不会由 MMTL 自动应用；需要时请在游戏内手动设置或确认。" $field))
        }
    }
    if((Get-MmtlPlannerProperty $Profile 'resetWorld' $false) -eq $true){
        $warnings.Add((New-MmtlPlannerDiagnostic 'WORLD_RESET_SCOPED_TO_SESSION' 'Plan' 'resetWorld 只作用于本次隔离 Session 的世界目录；新建 Session 不会清理或修改其他 Session 的世界。' 'resetWorld'))
    }
    $players=0;$playersValid=[int]::TryParse([string](Get-MmtlPlannerProperty $Profile 'players' ''),[ref]$players)
    if (-not $playersValid -or $mode -notin @('Single','IntegratedLAN','Dedicated') -or $players -lt 1 -or $players -gt 8 -or ($mode -eq 'Single' -and $players -ne 1)) {
        $diagnostics.Add((New-MmtlPlannerDiagnostic 'INVALID_PROFILE' 'Launch' 'Profile 的 mode 或 players 不符合配置规范。'))
    }
    $projectRoot=[IO.Path]::GetFullPath([string](Get-MmtlPlannerProperty $Project 'Root' (Get-MmtlPlannerProperty $Project 'ProjectRoot' '')))
    if ([string]::IsNullOrWhiteSpace($projectRoot) -or -not (Test-Path -LiteralPath $projectRoot -PathType Container)) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'PROJECT_ROOT_UNAVAILABLE' 'Plan' '项目目录不存在或不可访问。')) }
    $repositoryRootValue=[string](Get-MmtlPlannerProperty $Project 'RepositoryRoot' $projectRoot)
    $repositoryRoot=if($repositoryRootValue){[IO.Path]::GetFullPath($repositoryRootValue)}else{$projectRoot}
    $relativeLocator=if($projectRoot -and $repositoryRoot){[IO.Path]::GetRelativePath($repositoryRoot,$projectRoot).Replace('\','/')}else{''}
    $pathOutsideRepo=([IO.Path]::IsPathRooted($relativeLocator) -or $relativeLocator -eq '..' -or $relativeLocator.StartsWith('../',[StringComparison]::Ordinal))
    if ($pathOutsideRepo) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'PROJECT_PATH_OUTSIDE_REPOSITORY' 'Plan' 'ProjectRoot 必须位于 RepositoryRoot 内。')) }

    $loader=[string](Get-MmtlPlannerProperty $Project 'Loader' 'Unknown')
    $loaderVersion=Get-MmtlPlannerProperty $Project 'LoaderVersion'
    $minecraft=[string](Get-MmtlPlannerProperty $Project 'MinecraftVersion' '')
    $hasWrapper=[bool](Get-MmtlPlannerProperty $Project 'Wrapper' $false)
    if ($loader -eq 'Unknown' -or -not $minecraft -or -not $loaderVersion) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'PROJECT_TARGET_UNRESOLVED' 'Build' 'Loader、Loader 版本或 Minecraft 目标无法确认。')) }
    if (-not $hasWrapper) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'GRADLE_WRAPPER_UNAVAILABLE' 'Build' '项目缺少可用的 Gradle Wrapper。')) }

    $buildRequirement=ConvertTo-MmtlJavaRequirementForPlan -Requirement (Get-MmtlPlannerProperty $Project 'BuildJavaRequirement') -Purpose BuildJava
    $javaHomes=Get-MmtlJavaHomesForPlatform -Config $Config -Platform $Platform
    $buildResolution=Resolve-MmtlJavaCandidate -Requirement $buildRequirement -JavaHomes $javaHomes -Platform $Platform
    if ($buildResolution.status -ne 'Resolved') { $diagnostics.Add((New-MmtlPlannerDiagnostic $buildResolution.reasonCode 'Build' '找不到符合构建 Java 要求且与当前平台匹配的 JDK。' $buildRequirement.source)) }

    $runtimeRaw=Get-MmtlPlannerRuntimeJavaRequirement -Project $Project -Profile $Profile -RuntimeJavaRequirement $RuntimeJavaRequirement -CatalogEntry $CatalogEntry -VersionMetadata $VersionMetadata
    $runtimeRequirement=ConvertTo-MmtlJavaRequirementForPlan -Requirement $runtimeRaw -Purpose RuntimeJava
    $runtimeResolution=Resolve-MmtlJavaCandidate -Requirement $runtimeRequirement -JavaHomes $javaHomes -Platform $Platform
    if ($runtimeRequirement.requirementKind -eq 'Unknown' -or -not $runtimeRequirement.major) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'RUNTIME_JAVA_REQUIREMENT_UNKNOWN' 'Launch' 'Runtime Java 要求目前未知；构建计划仍可用，但不能确认启动条件。' $runtimeRequirement.source)) }
    elseif ($runtimeResolution.status -ne 'Resolved') { $diagnostics.Add((New-MmtlPlannerDiagnostic $runtimeResolution.reasonCode 'Launch' '找不到符合 Minecraft Runtime Java 要求且与当前平台匹配的 JDK。' $runtimeRequirement.source)) }
    if ($runtimeRequirement.confidence -in @('Low','Medium') -and $runtimeRequirement.major -and $runtimeRequirement.source -eq 'MMTLCompatibilityFallback') { $warnings.Add((New-MmtlPlannerDiagnostic 'RUNTIME_JAVA_REQUIREMENT_FALLBACK' 'Plan' 'Runtime Java 要求来自 MMTL 兼容性回退规则，并非 Mojang 对该版本的权威元数据。' $runtimeRequirement.source)) }
    if ($MetadataWarning) { $warnings.Add((New-MmtlPlannerDiagnostic 'MINECRAFT_METADATA_UNAVAILABLE' 'Plan' '未能读取本地缓存的 Minecraft Runtime Java 元数据；计划采用兼容性回退或 Unknown。' 'MojangVersionMetadataCache')) }

    $binding=Get-MmtlPlannerBindingMode -Project $Project -AdapterEvidence $AdapterEvidence
    if ($binding -eq 'Unknown') { $diagnostics.Add((New-MmtlPlannerDiagnostic 'RUNTIME_JAVA_BINDING_UNKNOWN' 'Launch' '当前 Loader/Gradle 工具链没有足够证据证明可独立绑定 Minecraft Runtime Java。')) }
    elseif ($binding -eq 'Unsupported') { $diagnostics.Add((New-MmtlPlannerDiagnostic 'RUNTIME_JAVA_BINDING_UNSUPPORTED' 'Launch' '当前 Loader/Gradle 工具链不支持所要求的 Runtime Java 绑定。')) }
    elseif ($binding -eq 'ToolchainManaged') { $diagnostics.Add((New-MmtlPlannerDiagnostic 'RUNTIME_JAVA_BINDING_NOT_EXECUTABLE' 'Launch' '当前 MMTL 执行器尚无可调用的 ToolchainManaged Runtime provider。')) }
    elseif ($binding -eq 'SameAsBuildJvm' -and $buildResolution.status -eq 'Resolved' -and $runtimeResolution.status -eq 'Resolved' -and $buildResolution.actualMajor -ne $runtimeResolution.actualMajor) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'RUNTIME_JAVA_BINDING_MISMATCH' 'Launch' '适配器声明 Runtime Java 与 Build JVM 相同，但两条解析结果的主版本不同。')) }
    $roles=Get-MmtlPlannerRuntimeRoles -Profile $Profile -Mode $mode
    $bindingEvidence=Get-MmtlPlannerProperty $AdapterEvidence 'runtimeJavaBindingEvidence' (Get-MmtlPlannerProperty $Project 'RuntimeJavaBindingEvidence')
    if([string](Get-MmtlPlannerProperty $bindingEvidence 'evidenceSource' '') -eq 'GradleInitScriptJavaExecInspection'){
        $requiredTasks=@($roles|ForEach-Object{if([string]$_.role -eq 'Server'){'runServer'}else{'runClient'}}|Select-Object -Unique)
        $observedBindingTasks=@(Get-MmtlPlannerProperty $bindingEvidence 'evidenceDetails' @()|ForEach-Object{[string](Get-MmtlPlannerProperty $_ 'task' '')})
        $missingBindingTasks=@($requiredTasks|Where-Object{$_ -notin $observedBindingTasks})
        if($missingBindingTasks.Count){$diagnostics.Add((New-MmtlPlannerDiagnostic 'RUNTIME_BINDING_ROLE_TASK_UNAVAILABLE' 'Launch' 'Runtime Binding 证据没有覆盖当前 Profile 所需的全部角色任务。' ($missingBindingTasks -join ',')))}
    }

    $capabilities=Get-MmtlPlannerProperty $Platform 'capabilities'
    $buildCapability=[string](Get-MmtlPlannerProperty $capabilities 'Build' 'Native')
    $launchCapability=[string](Get-MmtlPlannerProperty $capabilities 'Launch' $(if($Platform.os -eq 'Windows'){'Native'}else{'BuildOnly'}))
    if ($buildCapability -eq 'Unsupported') { $diagnostics.Add((New-MmtlPlannerDiagnostic 'PLATFORM_BUILD_UNSUPPORTED' 'Build' '当前平台不支持构建。')) }
    if ($launchCapability -in @('Unsupported','BuildOnly')) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'PLATFORM_LAUNCH_UNSUPPORTED' 'Launch' '当前平台提供 CLI/Build 能力，但未声明 Minecraft Launch 支持。')) }

    if ($mode -eq 'Dedicated' -and (Get-MmtlPlannerProperty $Profile 'acceptEula' $false) -ne $true) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'EULA_NOT_PREAUTHORIZED' 'Launch' 'Dedicated Server 需要用户在配置中明确预先接受 EULA；Plan 不会修改配置或 EULA 文件。')) }
    # MMTL-managed IntegratedLAN uses Session-local offline Test Identities; real account auth is never a launch prerequisite.

    if ($PhysicalMemoryMb -le 0) { $physicalProperty=Get-MmtlPlannerProperty $Platform 'physicalMemoryMb'; if ($physicalProperty) { $PhysicalMemoryMb=[long]$physicalProperty } }
    $memory=Get-MmtlPlannerMemory -Profile $Profile -Mode $mode -Roles $roles -PhysicalMemoryMb $PhysicalMemoryMb
    if ($memory.exceedsLimit) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'MEMORY_LIMIT_EXCEEDED' 'Launch' 'Profile 请求的内存超过当前平台可用预算。')) }
    elseif ($null -eq $memory.limitMb) { $diagnostics.Add((New-MmtlPlannerDiagnostic 'MEMORY_LIMIT_UNKNOWN' 'Plan' '没有注入可验证的物理内存容量，Plan 未推断运行预算。')) }

    $runtimeRootFull=[IO.Path]::GetFullPath($RuntimeRoot)
    $runtimeDirectories=@($roles|ForEach-Object{
        $safeRole=if($_.role -eq 'Server'){'Server'}else{[string]$_.username}
        $relative="sessions/planned-$($ProfileName ?? [string](Get-MmtlPlannerProperty $Config 'defaultProfile' 'default'))/$safeRole"
        [pscustomobject][ordered]@{role=[string]$_.role;username=[string]$_.username;path=[IO.Path]::GetFullPath((Join-Path $runtimeRootFull ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)));relativePath=$relative}
    })
    $portSetting=Get-MmtlPlannerProperty $Profile 'port' 'Auto'
    $portPolicy=if($mode -eq 'Single'){'None'}elseif($mode -notin @('IntegratedLAN','Dedicated')){'Unsupported'}elseif([string]$portSetting -eq 'Auto' -or -not $portSetting){'Auto'}else{'Fixed'}
    $fixedPort=if($portPolicy -eq 'Fixed'){[int]$portSetting}else{$null}

    $buildProfileRequired=if($PSBoundParameters.ContainsKey('BuildRequired')){[bool]$BuildRequired}else{[bool](Get-MmtlPlannerProperty $Profile 'autoBuild' $true)}
    $clean=[bool]$(if($PSBoundParameters.ContainsKey('CleanBuild')){$CleanBuild}else{Get-MmtlPlannerProperty $Profile 'cleanBuild' $false})
    $blockArray=@($diagnostics.ToArray())
    $buildReasons=@($blockArray|Where-Object{$_.action -eq 'Build'}|ForEach-Object code)
    $launchReasons=@($blockArray|Where-Object{$_.action -eq 'Launch'}|ForEach-Object code)
    $buildReady=($buildReasons.Count -eq 0 -and $buildResolution.status -eq 'Resolved' -and -not $pathOutsideRepo)
    $launchReady=($launchReasons.Count -eq 0 -and ($buildProfileRequired -eq $false -or $buildReady))
    $planStatus=if($launchReady){'Ready'}elseif($buildReady){'BuildReadyLaunchBlocked'}else{'Blocked'}
    $roleRecords=@($roles|ForEach-Object{
        $roleReasons=@($launchReasons)
        if($mode -eq 'IntegratedLAN' -and $_.role -eq 'Host'){$roleReasons=@($roleReasons|Where-Object{$_ -ne 'AUTH_REQUIRED'})}
        if($mode -eq 'Dedicated' -and $_.role -ne 'Server'){$roleReasons=@($roleReasons|Where-Object{$_ -ne 'EULA_NOT_PREAUTHORIZED'})}
        $roleBuildReady=($buildProfileRequired -eq $false -or $buildReady)
        [pscustomobject][ordered]@{role=$_.role;username=$_.username;launchReady=($roleBuildReady -and $roleReasons.Count -eq 0);blockingReasons=$roleReasons}
    })
    $launchBlockingReasons=@($blockArray|Where-Object{$_.action -eq 'Launch'})
    $launchWarnings=@($warnings|Where-Object{$_.action -eq 'Launch'})
    $identity=[string](Get-MmtlPlannerProperty $Project 'ModId' '')
    if (-not $identity) { $identity=[IO.Path]::GetFileName($repositoryRoot) }
    $profileNameValue=if($ProfileName){$ProfileName}else{[string](Get-MmtlPlannerProperty $Config 'defaultProfile' 'default')}
    $primaryStack=Get-MmtlPlannerProperty (Get-MmtlPlannerProperty $Project 'LoaderStack') 'primaryLoader'
    $overlayStack=@(Get-MmtlPlannerProperty (Get-MmtlPlannerProperty $Project 'LoaderStack') 'overlayLoaders' @())
    $stack=@()
    if ($primaryStack) { $stack+=@([pscustomobject]@{id=[string]$primaryStack.id;version=$primaryStack.version;role='Primary'}) }
    else { $stack+=@([pscustomobject]@{id=$loader;version=$loaderVersion;role='Primary'}) }
    foreach ($overlay in $overlayStack) { $stack+=@([pscustomobject]@{id=[string]$overlay.id;version=$overlay.version;role='Overlay'}) }
    $buildSystem=Get-MmtlPlannerProperty $Project 'BuildSystem'
    $toolchain=Get-MmtlPlannerProperty $Project 'Toolchain'
    $projectModId=Get-MmtlPlannerProperty $Project 'ModId'
    $versionSource=Get-MmtlPlannerProperty $VersionMetadata 'provenance'
    $versionStatus=Get-MmtlPlannerProperty $VersionMetadata 'metadataStatus' (Get-MmtlPlannerProperty $CatalogEntry 'metadataStatus' 'Unknown')
    $jvmArgs=@(Get-MmtlPlannerProperty $Profile 'jvmArgs' @()|ForEach-Object{[string]$_})
    $gameArgs=@(Get-MmtlPlannerProperty $Profile 'gameArgs' @()|ForEach-Object{[string]$_})
    $runtimeProfiles=[ordered]@{}
    foreach ($name in @('hostCheats','clientPermissionLevel','gameMode','difficulty','worldName','seed','newWorld','resetWorld','memoryMb','hostMemoryMb','clientMemoryMb','serverMemoryMb','resolution','guiScale','windowLayout','acceptEula','port','autoBuild','cleanBuild')) { $value=Get-MmtlPlannerProperty $Profile $name; if ($null -ne $value) { $runtimeProfiles[$name]=$value } }
    $profileRecord=[ordered]@{name=$profileNameValue;mode=$mode;players=$players;hostUsername=(Get-MmtlPlannerProperty $Profile 'hostUsername' 'Dev');clientPrefix=(Get-MmtlPlannerProperty $Profile 'clientPrefix' 'Dev_');jvmArgs=$jvmArgs;gameArgs=$gameArgs}
    foreach ($name in $runtimeProfiles.Keys) { $profileRecord[$name]=$runtimeProfiles[$name] }
    $plan=[pscustomobject][ordered]@{
        schemaVersion=1;status=$planStatus;planId='pending';semanticDigest='';createdAt=[DateTimeOffset]::UtcNow.ToString('o')
        platform=[pscustomobject][ordered]@{os=[string]$Platform.os;arch=[string]$Platform.arch;isWSL=[bool](Get-MmtlPlannerProperty $Platform 'isWSL' $false);capabilities=[pscustomobject][ordered]@{Build=$buildCapability;Launch=$launchCapability}}
        repository=[pscustomobject][ordered]@{identity=$identity;root=$repositoryRoot}
        project=[pscustomobject][ordered]@{projectRoot=$projectRoot;locator=$relativeLocator;minecraftId=$minecraft;loader=[pscustomobject]@{id=$loader;version=$loaderVersion};loaderStack=@($stack);toolchain=[pscustomobject]@{id=[string](Get-MmtlPlannerProperty $toolchain 'id' 'Unknown');version=(Get-MmtlPlannerProperty $toolchain 'version')};buildSystem=[pscustomobject]@{id=[string](Get-MmtlPlannerProperty $buildSystem 'id' 'Unknown');version=(Get-MmtlPlannerProperty $buildSystem 'version')};modId=$projectModId}
        buildJava=[pscustomobject][ordered]@{requirement=$buildRequirement;resolution=$buildResolution}
        runtimeJava=[pscustomobject][ordered]@{requirement=$runtimeRequirement;resolution=$runtimeResolution;bindingMode=$binding;bindingEvidence=$bindingEvidence}
        profile=[pscustomobject]$profileRecord
        build=[pscustomobject][ordered]@{required=$buildProfileRequired;clean=$clean;task=[string](Get-MmtlPlannerProperty $Project 'BuildTask' 'build');wrapper=[IO.Path]::GetFileName([string](Get-MmtlPlannerProperty $Project 'WrapperPath' 'gradlew'));artifactExpectation='one-mod-jar'}
        runtime=[pscustomobject][ordered]@{roles=@($roleRecords);runtimeDirectories=$runtimeDirectories;memory=$memory;jvmArgs=$jvmArgs;gameArgs=$gameArgs}
        network=[pscustomobject][ordered]@{portPolicy=$portPolicy;fixedPort=$fixedPort;bindPolicy='Loopback'}
        session=[pscustomobject][ordered]@{intendedMode=$mode}
        capabilityGates=[pscustomobject][ordered]@{buildReady=$buildReady;launchReady=$launchReady;buildReasons=@($buildReasons);launchReasons=@($launchReasons)}
        blockingReasons=$blockArray;warnings=@($warnings.ToArray());launchBlockingReasons=$launchBlockingReasons;launchWarnings=$launchWarnings;provenance=[pscustomobject][ordered]@{runtimeJavaSource=$runtimeRequirement.source;metadataStatus=$versionStatus;metadataProvenance=$versionSource;runtimeJavaBindingEvidence=$bindingEvidence}
    }
    $plan.semanticDigest=Get-MmtlExecutionPlanSemanticDigest -Plan $plan
    $plan.planId='plan-'+$plan.semanticDigest.Substring(7,16)
    $validation=Test-MmtlExecutionPlan -Plan $plan
    if (-not $validation.valid) { throw ('EXECUTION_PLAN_INVALID: '+($validation.errors -join ', ')) }
    return $plan
}

Export-ModuleMember -Function New-MmtlExecutionPlan
