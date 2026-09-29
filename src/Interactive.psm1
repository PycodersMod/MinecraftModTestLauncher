function Read-MmtlPromptValue {
    param([Parameter(Mandatory)][string]$Label,[AllowNull()][object]$Default)
    $shown=if($null -eq $Default){''}elseif($Default -is [array]){@($Default)-join ';'}else{[string]$Default}
    $value=Read-Host $(if($shown){"$Label [$shown]"}else{$Label})
    if([string]::IsNullOrWhiteSpace($value)){return $Default}
    return $value.Trim()
}
function ConvertTo-MmtlPromptList {
    param([AllowNull()][object]$Value)
    if($null -eq $Value){return @()}
    return @(([string]$Value -split ';'|ForEach-Object{$_.Trim()}|Where-Object{$_}) )
}
function Read-MmtlWizardProfile {
    [CmdletBinding()]
    param([AllowNull()]$Defaults)
    $value={param($name,$fallback) if($Defaults -and $null -ne $Defaults.PSObject.Properties[$name]){$Defaults.$name}else{$fallback}}
    $project=Read-MmtlPromptValue 'Mod Gradle 项目目录' (& $value 'project' '')
    if(-not $project){throw '必须填写项目目录。'}
    $project=(Get-MmtlProject -Path $project).Root
    $linkedDefault=(@(& $value 'linkedProjects' @()) -join ';')
    $linked=ConvertTo-MmtlPromptList (Read-MmtlPromptValue '联动项目目录，多个以分号分隔' $linkedDefault)
    $mode=Read-MmtlPromptValue '运行模式：Single / IntegratedLAN / Dedicated' (& $value 'mode' 'Single')
    if($mode -notin @('Single','IntegratedLAN','Dedicated')){throw '运行模式必须为 Single、IntegratedLAN 或 Dedicated。'}
    $playersDefault=if($mode -eq 'Single'){1}else{2}
    $playersText=Read-MmtlPromptValue '玩家总数（包含 Host）' (& $value 'players' $playersDefault)
    $players=0;if(-not[int]::TryParse([string]$playersText,[ref]$players) -or $players -lt 1 -or $players -gt 8){throw '玩家总数需为 1 至 8。'}
    if($mode -eq 'Single'){$players=1}
    $host=Read-MmtlPromptValue 'Host 用户名' (& $value 'hostUsername' 'Dev')
    $prefix=Read-MmtlPromptValue '客户端用户名前缀' (& $value 'clientPrefix' 'Dev_')
    $hostCheatsText=Read-MmtlPromptValue 'Host 允许作弊/命令？Y/N' $(if((& $value 'hostCheats' $true)){'Y'}else{'N'})
    $hostCheats=$hostCheatsText -match '^(?i:y|yes|true|1)$'
    $permissionText=Read-MmtlPromptValue 'Dedicated 客户端 OP 等级 0-4（0=普通玩家）' (& $value 'clientPermissionLevel' 0)
    $permission=0;if(-not[int]::TryParse([string]$permissionText,[ref]$permission) -or $permission -lt 0 -or $permission -gt 4){throw '客户端 OP 等级必须为 0 至 4。'}
    $gameMode=Read-MmtlPromptValue '世界游戏模式' (& $value 'gameMode' 'creative')
    if($gameMode -notin @('survival','creative','adventure','spectator')){throw '世界游戏模式无效。'}
    $difficulty=Read-MmtlPromptValue '世界难度' (& $value 'difficulty' 'normal')
    if($difficulty -notin @('peaceful','easy','normal','hard')){throw '世界难度无效。'}
    $world=Read-MmtlPromptValue '世界名称' (& $value 'worldName' 'MMTL-Test')
    $seed=Read-MmtlPromptValue '世界种子（可留空）' (& $value 'seed' '')
    $newWorld=(Read-MmtlPromptValue '创建新世界？Y/N' $(if((& $value 'newWorld' $true)){'Y'}else{'N'})) -match '^(?i:y|yes|true|1)$'
    $reset=(Read-MmtlPromptValue '重置本 Session 世界？Y/N' $(if((& $value 'resetWorld' $false)){'Y'}else{'N'})) -match '^(?i:y|yes|true|1)$'
    $port=Read-MmtlPromptValue 'LAN/Dedicated 端口，或 Auto' (& $value 'port' 'Auto')
    if([string]$port -ne 'Auto'){$n=0;if(-not[int]::TryParse([string]$port,[ref]$n) -or $n -lt 1 -or $n -gt 65535){throw '端口需为 Auto 或 1 至 65535。'};$port=$n}
    $autoBuild=(Read-MmtlPromptValue '自动构建项目？Y/N' $(if((& $value 'autoBuild' $true)){'Y'}else{'N'})) -match '^(?i:y|yes|true|1)$'
    $clean=(Read-MmtlPromptValue '构建前 clean？Y/N' $(if((& $value 'cleanBuild' $false)){'Y'}else{'N'})) -match '^(?i:y|yes|true|1)$'
    $extra=ConvertTo-MmtlPromptList (Read-MmtlPromptValue '额外 Mod JAR 路径，多个以分号分隔' ((@(& $value 'extraMods' @())) -join ';'))
    $memoryText=Read-MmtlPromptValue '每客户端内存 MB' (& $value 'memoryMb' 4096)
    $memory=0;if(-not[int]::TryParse([string]$memoryText,[ref]$memory) -or $memory -lt 1024 -or $memory -gt 65536){throw '内存需为 1024 至 65536 MB。'}
    $resolution=Read-MmtlPromptValue '窗口分辨率（宽x高）' (& $value 'resolution' '1280x720')
    if($resolution -notmatch '^\d{3,5}x\d{3,5}$'){throw '分辨率格式应为例如 1280x720。'}
    $layout=Read-MmtlPromptValue '窗口布局：Auto / Tile / Cascade / None' (& $value 'windowLayout' 'Auto')
    if($layout -notin @('Auto','Tile','Cascade','None')){throw '窗口布局无效。'}
    $jvm=ConvertTo-MmtlPromptList (Read-MmtlPromptValue '额外 JVM 参数，以分号分隔' ((@(& $value 'jvmArgs' @())) -join ';'))
    $game=ConvertTo-MmtlPromptList (Read-MmtlPromptValue '额外游戏参数，以分号分隔' ((@(& $value 'gameArgs' @())) -join ';'))
    $acceptEula=$false
    if($mode -eq 'Dedicated'){$acceptEula=(Read-MmtlPromptValue 'Dedicated Server EULA：输入 Y 表示你已阅读并接受；其他输入为否' $(if((& $value 'acceptEula' $false)){'Y'}else{'N'})) -match '^(?i:y|yes|true|1)$'}
    return [pscustomobject]@{project=$project;linkedProjects=@($linked);mode=$mode;players=$players;hostUsername=$host;clientPrefix=$prefix;hostCheats=$hostCheats;clientPermissionLevel=$permission;gameMode=$gameMode;difficulty=$difficulty;worldName=$world;seed=$seed;newWorld=$newWorld;resetWorld=$reset;port=$port;autoBuild=$autoBuild;cleanBuild=$clean;extraMods=@($extra);memoryMb=$memory;resolution=$resolution;windowLayout=$layout;jvmArgs=@($jvm);gameArgs=@($game);acceptEula=$acceptEula}
}
function Show-MmtlLaunchSummary {
    param([Parameter(Mandatory)]$Profile,[Parameter(Mandatory)]$Config)
    $primary=Get-MmtlProject -Path $Profile.project
    if($primary.JavaMajor){
        try{$javaPath=Resolve-MmtlJava -Config $Config -Major ([int]$primary.JavaMajor)}
        catch{$homePath=Read-Host "Required Java $($primary.JavaMajor) is not configured or unavailable. 输入该 Java 安装目录";if(-not(Test-Path -LiteralPath (Join-Path $homePath 'bin\java.exe') -PathType Leaf)){throw "Required Java $($primary.JavaMajor) is not available at configured path."};$Config.javaHomes|Add-Member -NotePropertyName ([string]$primary.JavaMajor) -NotePropertyValue $homePath -Force;$javaPath=Resolve-MmtlJava -Config $Config -Major ([int]$primary.JavaMajor)}
    }else{$javaPath='无法自动检测'}
    $linked=@($Profile.linkedProjects|Where-Object{$_}|ForEach-Object{Get-MmtlProject -Path $_})
    if($linked.Count){Assert-MmtlCompatible -Projects (@($primary)+$linked)|Out-Null}
    Write-Host '========================================';Write-Host 'Minecraft Mod Test Launcher';Write-Host '========================================'
    Write-Host "Minecraft: $($primary.MinecraftVersion)";Write-Host "Loader: $($primary.Loader) $($primary.LoaderVersion)";Write-Host "Java: $($primary.JavaMajor) ($javaPath)";Write-Host "Mode: $($Profile.mode)";Write-Host "Players: $($Profile.players)";Write-Host "Host: $($Profile.hostUsername) / $($Profile.gameMode) / Cheats=$($Profile.hostCheats)"
    if([int]$Profile.players -gt 1){Write-Host "Clients: $($Profile.clientPrefix)1 .. $($Profile.clientPrefix)$([int]$Profile.players-1); Dedicated permission level=$($Profile.clientPermissionLevel)"}
    Write-Host "Projects: $((@($primary.Root)+@($linked.Root))-join ', ')";Write-Host "Build: $($Profile.autoBuild); Clean: $($Profile.cleanBuild); Reset world: $($Profile.resetWorld)";Write-Host "Runtime: $($Profile.resolution), layout=$($Profile.windowLayout), memory=$($Profile.memoryMb) MB"
    if($Profile.mode -eq 'Dedicated' -and $Profile.acceptEula -ne $true){Write-Warning '尚未接受 EULA；Dedicated 启动会被拒绝。'}
}
function Invoke-MmtlConsoleMenu {
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$LauncherPath)
    Write-Host 'Minecraft Mod Test Launcher';Write-Host '检测到 launcher.config.json';Write-Host '[1] 使用默认配置快速启动';Write-Host '[2] 选择配置 Profile';Write-Host '[3] 查看/修改配置';Write-Host '[4] 临时配置启动';Write-Host '[Q] 退出'
    $choice=Read-Host '选择'
    if($choice -eq 'Q'){return 0}
    $temporary=$false;$profileName=[string]$Config.defaultProfile
    if($choice -eq '1'){$profile=Get-MmtlProfile -Config $Config}
    elseif($choice -eq '2'){$profileName=Read-Host ("可用 Profile: "+(($Config.profiles.PSObject.Properties.Name)-join ', '));$profile=Get-MmtlProfile -Config $Config -Name $profileName}
    elseif($choice -eq '3'){$Config|ConvertTo-Json -Depth 20|Write-Host;$profile=Get-MmtlProfile -Config $Config;$edit=Read-Host '输入 E 进入交互式配置，其他输入返回';if($edit -notmatch '^(?i:e)$'){return 0};$profile=Read-MmtlWizardProfile -Defaults $profile;$temporary=$true}
    elseif($choice -eq '4'){$profile=Read-MmtlWizardProfile -Defaults (Get-MmtlProfile -Config $Config);$temporary=$true}
    else{Write-Host '无效选择';return 2}
    while($true){
        $beforeConfig=ConvertTo-Json -InputObject $Config -Depth 30 -Compress
        Show-MmtlLaunchSummary -Profile $profile -Config $Config
        if(-not $temporary -and $beforeConfig -ne (ConvertTo-Json -InputObject $Config -Depth 30 -Compress)){ConvertTo-Json -InputObject $Config -Depth 30|Set-Content -LiteralPath $ConfigPath -Encoding utf8}
        $next=Read-Host '[Enter] 启动 [E] 修改 [S] 保存为 Profile [Q] 退出'
        if($next -eq 'Q'){return 0}
        if($next -match '^(?i:e)$'){$profile=Read-MmtlWizardProfile -Defaults $profile;$temporary=$true;continue}
        if($next -match '^(?i:s)$'){$profileName=Read-Host '输入 Profile 名称';if($profileName -notmatch '^[A-Za-z0-9_-]{1,40}$'){throw 'Profile 名称只允许字母、数字、下划线和短横线。'};$Config.profiles|Add-Member -NotePropertyName $profileName -NotePropertyValue $profile -Force;$Config.defaultProfile=$profileName;ConvertTo-Json $Config -Depth 30|Set-Content -LiteralPath $ConfigPath -Encoding utf8;$temporary=$false;continue}
        if($next -ne ''){Write-Host '请输入 Enter、E、S 或 Q。';continue}
        $configForRun=$ConfigPath
        if($temporary){$runConfig=$Config|ConvertTo-Json -Depth 30|ConvertFrom-Json;$runConfig.profiles|Add-Member -NotePropertyName '__temporary' -NotePropertyValue $profile -Force;$runConfig.defaultProfile='__temporary';$configForRun=Join-Path ([IO.Path]::GetTempPath()) ('mmtl-'+[guid]::NewGuid().ToString('N')+'.json');$runConfig|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $configForRun -Encoding utf8}
        try{$pwsh=(Get-Command pwsh -ErrorAction Stop).Source;& $pwsh -NoProfile -File $LauncherPath --config-file $configForRun --profile $(if($temporary){'__temporary'}else{$profileName}) --launch;return $LASTEXITCODE}
        finally{if($temporary -and (Test-Path -LiteralPath $configForRun)){Remove-Item -LiteralPath $configForRun -Force}}
    }
}
Export-ModuleMember -Function Read-MmtlWizardProfile,Show-MmtlLaunchSummary,Invoke-MmtlConsoleMenu
