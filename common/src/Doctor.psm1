Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'JavaDiscovery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ProjectDetector.psm1') -Force

function New-MmtlDoctorCheck {
    param([string]$Id,[string]$Category,[ValidateSet('PASS','WARN','FAIL','SKIP')][string]$Status,[ValidateSet('INFO','WARNING','ERROR')][string]$Severity,[string]$Message,$Details=$null,[string]$RemediationCode='')
    [pscustomobject][ordered]@{id=$Id;category=$Category;status=$Status;severity=$Severity;message=$Message;details=$Details;remediationCode=$(if($RemediationCode){$RemediationCode}else{$null})}
}

function Test-MmtlDoctorWritable {
    param([string]$Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Container)){return $false}
    $file=Join-Path $Path ('.mmtl-doctor-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{[IO.File]::WriteAllText($file,'probe');return $true}catch{return $false}finally{if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue}}
}

function Invoke-MmtlDoctor {
    [CmdletBinding()]
    param([AllowNull()]$Config,[AllowNull()]$Plan,[Parameter(Mandatory)][string]$RuntimeRoot,[string]$ConfigPath,[switch]$Offline)
    $checks=[Collections.Generic.List[object]]::new()
    $configLoadError=$false
    if(-not $Config -and $ConfigPath -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)){try{$Config=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{$configLoadError=$true}}
    $checks.Add((New-MmtlDoctorCheck 'POWERSHELL_VERSION' 'MMTL' $(if($PSVersionTable.PSVersion.Major -ge 7){'PASS'}else{'FAIL'}) $(if($PSVersionTable.PSVersion.Major -ge 7){'INFO'}else{'ERROR'}) "PowerShell $($PSVersionTable.PSVersion)" @{edition=$PSVersionTable.PSEdition;version=[string]$PSVersionTable.PSVersion} 'POWERSHELL_7_REQUIRED'))
    $provider=$null
    try{$provider=Get-MmtlPlatformProvider;$checks.Add((New-MmtlDoctorCheck 'PLATFORM_PROVIDER' 'Platform' 'PASS' 'INFO' '平台提供器已注册。' @{os=$provider.OS;architecture=$provider.Arch;isWSL=[bool]$provider.IsWSL}))}catch{$checks.Add((New-MmtlDoctorCheck 'PLATFORM_PROVIDER' 'Platform' 'FAIL' 'ERROR' '平台提供器未注册。' $null 'PLATFORM_PROVIDER_UNAVAILABLE'))}
    if($provider){
        $checks.Add((New-MmtlDoctorCheck 'OS_ARCH' 'Platform' 'PASS' 'INFO' "$($provider.OS) / $($provider.Arch)" @{os=$provider.OS;architecture=$provider.Arch;isWSL=[bool]$provider.IsWSL}))
        $discovery=Get-MmtlJavaDiscovery -Platform $provider
        $checks.Add((New-MmtlDoctorCheck 'JAVA_DISCOVERY' 'Java' $(if($discovery.count){'PASS'}else{'WARN'}) $(if($discovery.count){'INFO'}else{'WARNING'}) $(if($discovery.count){"发现 $($discovery.count) 个 Java 候选。"}else{'没有发现 Java 安装候选。'}) @{candidates=@($discovery.candidates);configModified=$false} 'JAVA_DISCOVERY_EMPTY'))
    }
    $repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot);$configSchema=Join-Path $repoRoot 'common/schemas/launcher-config.schema.json'
    $configValid=$false
    if($Config){try{$configJson=ConvertTo-Json -InputObject $Config -Depth 100 -Compress;$configValid=Test-Json -Json $configJson -SchemaFile $configSchema -ErrorAction SilentlyContinue}catch{}}
    $configStatus=if($configValid){'PASS'}elseif($configLoadError -or $Config){'FAIL'}else{'WARN'}
    $checks.Add((New-MmtlDoctorCheck 'CONFIG_SCHEMA' 'Config' $configStatus $(if($configStatus -eq 'PASS'){'INFO'}elseif($configStatus -eq 'FAIL'){'ERROR'}else{'WARNING'}) $(if($configStatus -eq 'PASS'){'配置符合 schema。'}elseif($configStatus -eq 'FAIL'){'配置无法读取或字段与 schema 不一致。'}else{'未加载配置。'}) @{valid=$configValid;loadError=[bool]$configLoadError} 'CONFIG_SCHEMA_INVALID'))
    $profile=$null;$projectRoot=''
    if($Config -and $Config.defaultProfile -and $Config.profiles){$profile=$Config.profiles.PSObject.Properties[[string]$Config.defaultProfile].Value;if($profile){$projectRoot=[string]$profile.project}}
    if($Plan -and $Plan.project.projectRoot){$projectRoot=[string]$Plan.project.projectRoot}
    $projectExists=$projectRoot -and (Test-Path -LiteralPath $projectRoot -PathType Container)
    $checks.Add((New-MmtlDoctorCheck 'PROJECT_EXISTS' 'Project' $(if($projectExists){'PASS'}else{'FAIL'}) $(if($projectExists){'INFO'}else{'ERROR'}) $(if($projectExists){'项目目录可访问。'}else{'项目目录不存在或不可访问。'}) @{exists=[bool]$projectExists} 'PROJECT_ROOT_UNAVAILABLE'))
    $detected=$false
    if($projectExists){try{$detected=([string](Get-MmtlProject -Path $projectRoot).DetectionStatus -ne 'Unknown')}catch{}}
    $checks.Add((New-MmtlDoctorCheck 'PROJECT_DETECTOR' 'Project' $(if($detected){'PASS'}elseif($projectExists){'WARN'}else{'SKIP'}) $(if($detected){'INFO'}else{'WARNING'}) $(if($detected){'已识别项目类型。'}elseif($projectExists){'无法识别项目类型。'}else{'没有可检测项目。'}) @{recognized=[bool]$detected} 'PROJECT_TYPE_UNRESOLVED'))
    $wrapperName=if($provider){[string]$provider.GradleWrapper}else{'gradlew'};$wrapper=if($projectRoot){Join-Path $projectRoot $wrapperName}else{''};$wrapperExists=$wrapper -and (Test-Path -LiteralPath $wrapper -PathType Leaf)
    $wrapperExecutable=$wrapperExists
    if($wrapperExists -and $provider.OS -ne 'Windows'){try{$wrapperExecutable=[bool]((Get-Item -LiteralPath $wrapper -Force).UnixFileMode -band [IO.UnixFileMode]::UserExecute)}catch{$wrapperExecutable=$false}}
    $checks.Add((New-MmtlDoctorCheck 'GRADLE_WRAPPER' 'Gradle' $(if($wrapperExecutable){'PASS'}elseif($wrapperExists){'WARN'}else{'FAIL'}) $(if($wrapperExecutable){'INFO'}else{'ERROR'}) $(if($wrapperExecutable){'Gradle Wrapper 存在且可执行。'}elseif($wrapperExists){'Gradle Wrapper 缺少执行权限。'}else{'未找到 Gradle Wrapper。'}) @{exists=[bool]$wrapperExists;executable=[bool]$wrapperExecutable} 'GRADLE_WRAPPER_UNAVAILABLE'))
    $buildResolution=if($Plan -and $Plan.PSObject.Properties['buildJava']){$Plan.buildJava.resolution}else{$null};$buildJavaReady=$buildResolution -and $buildResolution.status -eq 'Resolved' -and $buildResolution.javaPath -and (Test-Path -LiteralPath $buildResolution.javaPath -PathType Leaf)
    $checks.Add((New-MmtlDoctorCheck 'BUILD_JAVA' 'Java' $(if($buildJavaReady){'PASS'}elseif($Plan){'FAIL'}else{'SKIP'}) $(if($buildJavaReady){'INFO'}else{'ERROR'}) $(if($buildJavaReady){'Build Java 可用。'}elseif($Plan){'Build Java 未解析或不可访问。'}else{'没有 Execution Plan 可供核验。'}) @{status=$(if($buildResolution){$buildResolution.status}else{'Unavailable'});major=$(if($buildResolution){$buildResolution.actualMajor}else{$null})} 'BUILD_JAVA_UNAVAILABLE'))
    $runtimeResolution=if($Plan -and $Plan.PSObject.Properties['runtimeJava']){$Plan.runtimeJava.resolution}else{$null};$runtimeReady=$runtimeResolution -and $runtimeResolution.status -eq 'Resolved' -and $runtimeResolution.javaPath -and (Test-Path -LiteralPath $runtimeResolution.javaPath -PathType Leaf)
    $checks.Add((New-MmtlDoctorCheck 'RUNTIME_JAVA' 'Java' $(if($runtimeReady){'PASS'}elseif($Plan){'WARN'}else{'SKIP'}) $(if($runtimeReady){'INFO'}else{'WARNING'}) $(if($runtimeReady){'Runtime Java 可用。'}elseif($Plan){'Runtime Java 未解析或不可访问。'}else{'没有 Execution Plan 可供核验。'}) @{status=$(if($runtimeResolution){$runtimeResolution.status}else{'Unavailable'});major=$(if($runtimeResolution){$runtimeResolution.actualMajor}else{$null})} 'RUNTIME_JAVA_UNAVAILABLE'))
    $binding=if($Plan -and $Plan.PSObject.Properties['runtimeJava']){[string]$Plan.runtimeJava.bindingMode}else{'Unknown'}
    $checks.Add((New-MmtlDoctorCheck 'RUNTIME_BINDING' 'Runtime' $(if($binding -ne 'Unknown'){'PASS'}else{'WARN'}) $(if($binding -ne 'Unknown'){'INFO'}else{'WARNING'}) "Runtime Java binding：$binding" @{mode=$binding} 'RUNTIME_JAVA_BINDING_UNKNOWN'))
    $runtimeFull=[IO.Path]::GetFullPath($RuntimeRoot);$rootExists=Test-Path -LiteralPath $runtimeFull -PathType Container;$runtimeWritable=Test-MmtlDoctorWritable $runtimeFull
    $checks.Add((New-MmtlDoctorCheck 'RUNTIME_ROOT' 'Filesystem' $(if($runtimeWritable){'PASS'}elseif($rootExists){'FAIL'}else{'WARN'}) $(if($runtimeWritable){'INFO'}else{'WARNING'}) $(if($runtimeWritable){'Runtime Root 可写。'}elseif($rootExists){'Runtime Root 不可写。'}else{'Runtime Root 尚不存在。'}) @{exists=[bool]$rootExists;writable=[bool]$runtimeWritable} 'RUNTIME_ROOT_NOT_WRITABLE'))
    $sessionRoot=Join-Path $runtimeFull 'sessions';$sessionWritable=Test-MmtlDoctorWritable $sessionRoot
    $checks.Add((New-MmtlDoctorCheck 'SESSION_ROOT' 'Session' $(if($sessionWritable){'PASS'}elseif(Test-Path $sessionRoot){'FAIL'}else{'SKIP'}) $(if($sessionWritable){'INFO'}else{'WARNING'}) $(if($sessionWritable){'Session 根目录可写。'}elseif(Test-Path $sessionRoot){'Session 根目录不可写。'}else{'Session 根目录尚不存在。'}) @{exists=(Test-Path $sessionRoot);writable=[bool]$sessionWritable} 'SESSION_ROOT_NOT_WRITABLE'))
    $diskPath=if($rootExists){$runtimeFull}else{Split-Path -Parent $runtimeFull};$freeBytes=$null
    try{$drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($diskPath));if($drive.IsReady){$freeBytes=[long]$drive.AvailableFreeSpace}}catch{}
    $checks.Add((New-MmtlDoctorCheck 'DISK_SPACE' 'Filesystem' $(if($null -ne $freeBytes){'PASS'}else{'WARN'}) $(if($null -ne $freeBytes){'INFO'}else{'WARNING'}) $(if($null -ne $freeBytes){'已读取剩余磁盘空间。'}else{'无法读取剩余磁盘空间。'}) @{availableBytes=$freeBytes} 'DISK_SPACE_UNAVAILABLE'))
    $memoryMb=0L;try{$memoryMb=[long](Get-MmtlPhysicalMemoryMb)}catch{}
    $checks.Add((New-MmtlDoctorCheck 'MEMORY' 'Platform' $(if($memoryMb -gt 0){'PASS'}else{'WARN'}) $(if($memoryMb -gt 0){'INFO'}else{'WARNING'}) $(if($memoryMb -gt 0){'已读取物理内存容量。'}else{'无法读取物理内存容量。'}) @{physicalMemoryMb=$(if($memoryMb -gt 0){$memoryMb}else{$null})} 'MEMORY_UNAVAILABLE'))
    $directories=@();if($Plan -and $Plan.PSObject.Properties['runtime'] -and $Plan.runtime.runtimeDirectories){$directories=@($Plan.runtime.runtimeDirectories)}
    $contained=$true;foreach($directory in $directories){if(-not (Test-MmtlPlatformPathInsideRoot -Root $runtimeFull -Target ([string]$directory.path))){$contained=$false}}
    $checks.Add((New-MmtlDoctorCheck 'PATH_CONTAINMENT' 'Security' $(if($contained){'PASS'}else{'FAIL'}) $(if($contained){'INFO'}else{'ERROR'}) $(if($contained){'Plan 运行路径均位于 Runtime Root 内。'}else{'检测到 Runtime Root 外部路径。'}) @{checked=$directories.Count} 'PATH_OUTSIDE_RUNTIME_ROOT'))
    $linked=Test-MmtlPathLink -Path $runtimeFull
    $checks.Add((New-MmtlDoctorCheck 'SYMLINK_SAFETY' 'Security' $(if($linked){'WARN'}else{'PASS'}) $(if($linked){'WARNING'}else{'INFO'}) $(if($linked){'Runtime Root 是链接路径，需确认目标。'}else{'Runtime Root 本身不是链接。'}) @{isLink=[bool]$linked} 'RUNTIME_ROOT_LINK'))
    $catalogPath=Join-Path $runtimeFull 'metadata/mojang/normalized/version-catalog.json';$loaderPath=Join-Path $runtimeFull 'metadata/loaders'
    $checks.Add((New-MmtlDoctorCheck 'CATALOG_CACHE' 'Cache' $(if(Test-Path $catalogPath){'PASS'}else{'WARN'}) $(if(Test-Path $catalogPath){'INFO'}else{'WARNING'}) $(if(Test-Path $catalogPath){'本地 Minecraft catalog cache 存在。'}else{'本地 Minecraft catalog cache 不存在。'}) @{exists=(Test-Path $catalogPath)} 'CATALOG_CACHE_MISSING'))
    $checks.Add((New-MmtlDoctorCheck 'LOADER_METADATA_CACHE' 'Cache' $(if(Test-Path $loaderPath){'PASS'}else{'WARN'}) $(if(Test-Path $loaderPath){'INFO'}else{'WARNING'}) $(if(Test-Path $loaderPath){'Loader metadata cache 存在。'}else{'Loader metadata cache 不存在。'}) @{exists=(Test-Path $loaderPath)} 'LOADER_CACHE_MISSING'))
    $checks.Add((New-MmtlDoctorCheck 'NETWORK_METADATA' 'Network' 'SKIP' 'INFO' '本次 Doctor 不访问网络。' @{offline=[bool]$Offline;availability='NotChecked'} ''))
    $bindingTasks=@();if($Plan -and $Plan.PSObject.Properties['runtimeJava'] -and $Plan.runtimeJava.bindingEvidence -and $Plan.runtimeJava.bindingEvidence.evidenceDetails){$bindingTasks=@($Plan.runtimeJava.bindingEvidence.evidenceDetails|ForEach-Object task)}
    $taskStatus=if($bindingTasks -contains 'runClient'){'PASS'}elseif($Plan){'WARN'}else{'SKIP'}
    $checks.Add((New-MmtlDoctorCheck 'LAUNCH_TASKS' 'Launch' $taskStatus $(if($taskStatus -eq 'PASS'){'INFO'}else{'WARNING'}) $(if($taskStatus -eq 'PASS'){'证据包含 runClient task。'}elseif($Plan){'未找到可验证的 runClient task 证据。'}else{'没有 Execution Plan。'}) @{tasks=$bindingTasks} 'LAUNCH_TASK_UNAVAILABLE'))
    $proxyNames=@('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy');$credentialNames=@('GITHUB_TOKEN','GH_TOKEN','MINECRAFT_ACCESS_TOKEN','MSA_TOKEN')
    $proxyPresence=[ordered]@{};foreach($name in $proxyNames){$proxyPresence[$name]=[bool](Get-Item "Env:$name" -ErrorAction SilentlyContinue)}
    $credentialPresence=[ordered]@{};foreach($name in $credentialNames){$credentialPresence[$name]=[bool](Get-Item "Env:$name" -ErrorAction SilentlyContinue)}
    $checks.Add((New-MmtlDoctorCheck 'PROXY_ENVIRONMENT' 'Privacy' 'PASS' 'INFO' '仅检查代理变量是否存在，不读取或展示其值。' $proxyPresence ''))
    $checks.Add((New-MmtlDoctorCheck 'CREDENTIAL_ENVIRONMENT' 'Privacy' 'PASS' 'INFO' '仅检查凭据变量是否存在，不读取或展示其值。' $credentialPresence ''))
    [pscustomobject][ordered]@{schemaVersion=1;offline=[bool]$Offline;generatedAt=[DateTimeOffset]::UtcNow.ToString('o');checks=@($checks.ToArray());summary=[pscustomobject]@{pass=@($checks|Where-Object status -eq 'PASS').Count;warn=@($checks|Where-Object status -eq 'WARN').Count;fail=@($checks|Where-Object status -eq 'FAIL').Count;skip=@($checks|Where-Object status -eq 'SKIP').Count}}
}

Export-ModuleMember -Function Invoke-MmtlDoctor
