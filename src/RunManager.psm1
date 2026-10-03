Import-Module (Join-Path $PSScriptRoot 'RuntimeManager.psm1')
Import-Module (Join-Path $PSScriptRoot 'LogManager.psm1')
Import-Module (Join-Path $PSScriptRoot 'ProcessManager.psm1')

function Invoke-MmtlGradleBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)][string]$JavaPath,[Parameter(Mandatory)][string]$SessionPath,[switch]$Clean)
    if(-not(Test-Path -LiteralPath $JavaPath -PathType Leaf)){throw "Java 不存在：$JavaPath"}
    $name=[IO.Path]::GetFileName($Project.Root)-replace '[^A-Za-z0-9_-]','_'
    $log=New-MmtlLogPath -RuntimeRoot (Split-Path (Split-Path $SessionPath -Parent) -Parent) -SessionPath $SessionPath -Name "build-$name"
    $cmd=Get-MmtlGradleCommand -Project $Project -Task build -Clean:$Clean
    $oldHome=$env:JAVA_HOME;$oldPath=$env:Path;$javaHome=Split-Path (Split-Path $JavaPath -Parent) -Parent
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1');$pathSeparator=[string](Get-MmtlPlatformProvider).PathListSeparator
    $started=[DateTimeOffset]::UtcNow
    try{
        $env:JAVA_HOME=$javaHome;$env:Path=(Join-Path $javaHome 'bin')+$pathSeparator+$oldPath
        Push-Location -LiteralPath $cmd.WorkingDirectory
        try{$args=@($cmd.Arguments)+@('--console=plain');$cmdOutputPreference=$PSNativeCommandUseErrorActionPreference;$PSNativeCommandUseErrorActionPreference=$false;& $cmd.File @args *> $log;$exitCode=$LASTEXITCODE;$PSNativeCommandUseErrorActionPreference=$cmdOutputPreference}
        finally{Pop-Location}
    }finally{$env:JAVA_HOME=$oldHome;$env:Path=$oldPath}
    if($exitCode -ne 0){throw "Gradle build 失败（exit $exitCode），日志：$log"}
    $jars=@(Get-ChildItem -LiteralPath (Join-Path $Project.Root 'build/libs') -Filter '*.jar' -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -notmatch '(?i)(sources|javadoc|dev)(?:[-.]|\.jar$)'})
    if($jars.Count -ne 1){throw "Build 结束后应找到唯一正式 JAR，实际 $($jars.Count) 个：$($Project.Root)"}
    $gitSha=(& git -C $Project.Root rev-parse HEAD 2>$null);if($LASTEXITCODE -ne 0){$gitSha=$null}
    [pscustomobject]@{Project=$Project.Root;JavaPath=$JavaPath;BuildStartedUtc=$started.ToString('o');BuildFinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');ExitCode=$exitCode;JarPath=$jars[0].FullName;JarSha256=(Get-FileHash -LiteralPath $jars[0].FullName -Algorithm SHA256).Hash;GitSha=([string]$gitSha).Trim();LogPath=$log}
}
function Get-MmtlMemoryBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile,[ValidateSet('Single','IntegratedLAN','Dedicated')][string]$Mode='Single',[long]$PhysicalMemoryMb=0)
    $players=if($Profile.players){[int]$Profile.players}else{1}
    $fallback=if($Profile.memoryMb){[int]$Profile.memoryMb}else{0}
    $hostMemory=if($Profile.hostMemoryMb){[int]$Profile.hostMemoryMb}else{$fallback}
    $clientMemory=if($Profile.clientMemoryMb){[int]$Profile.clientMemoryMb}else{$fallback}
    $serverMemory=if($Profile.serverMemoryMb){[int]$Profile.serverMemoryMb}else{$fallback}
    $requested=switch($Mode){'Single'{$hostMemory};'IntegratedLAN'{$hostMemory+[Math]::Max(0,$players-1)*$clientMemory};'Dedicated'{$serverMemory+$players*$clientMemory}}
    if($requested -le 0){return [pscustomobject]@{RequestedMb=0;LimitMb=0;ExceedsLimit=$false;PhysicalMemoryMb=$PhysicalMemoryMb;Mode=$Mode}}
    if($PhysicalMemoryMb -le 0){Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1');$PhysicalMemoryMb=Get-MmtlPhysicalMemoryMb;if(-not $PhysicalMemoryMb){throw '无法确定本机物理内存；拒绝估算多实例内存预算。'}}
    $requested=[long]$requested;$limit=[long][Math]::Floor($PhysicalMemoryMb*0.8)
    return [pscustomobject]@{RequestedMb=$requested;LimitMb=$limit;ExceedsLimit=($requested -gt $limit);PhysicalMemoryMb=$PhysicalMemoryMb;Mode=$Mode}
}
function Assert-MmtlMemoryBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile,[ValidateSet('Single','IntegratedLAN','Dedicated')][string]$Mode='Single',[long]$PhysicalMemoryMb=0)
    $budget=Get-MmtlMemoryBudget -Profile $Profile -Mode $Mode -PhysicalMemoryMb $PhysicalMemoryMb
    if($budget.ExceedsLimit){throw "实例内存预算超限：请求 $($budget.RequestedMb) MB，上限为物理内存的 80%（$($budget.LimitMb) MB；$Mode 模式按各角色内存预算汇总）。请降低实例内存或玩家数量。"}
    return $true
}
function New-MmtlFabricRuntimeLink {
    param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$TargetPath,[Parameter(Mandatory)][string]$Name)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1');if((Get-MmtlPlatformProvider).FabricRuntimeLink -ne 'Native'){throw 'Fabric Runtime link capability is unsupported on this platform; ordinary builds do not require it.'}
    $root=[IO.Path]::GetFullPath($ProjectRoot);$session=[IO.Path]::GetFullPath($SessionPath);$target=[IO.Path]::GetFullPath($TargetPath)
    $sessionId=Split-Path $session -Leaf;$safe=($Name -replace '[^A-Za-z0-9_-]','_')
    $linkRoot=Join-Path $root '.gradle'
    if(-not(Test-Path -LiteralPath $linkRoot)){New-Item -ItemType Directory -Path $linkRoot|Out-Null}
    Assert-MmtlNoReparsePath -Path $linkRoot|Out-Null
    $link=Join-Path $linkRoot "mmtl-runtime-$sessionId-$safe"
    if(-not(Test-MmtlInsideRoot -Root $root -Target $link)){throw 'Fabric Runtime junction 越出项目目录。'}
    Assert-MmtlNoReparsePath -Path $root|Out-Null
    if(Test-Path -LiteralPath $link){throw "Fabric Runtime junction 路径已存在：$link"}
    New-Item -ItemType Junction -Path $link -Target $target|Out-Null
    return $link
}
function Remove-MmtlFabricRuntimeLink {
    param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)][string]$LinkPath,[Parameter(Mandatory)][string]$TargetPath)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1');if((Get-MmtlPlatformProvider).FabricRuntimeLink -ne 'Native'){throw 'Fabric Runtime link cleanup capability is unsupported on this platform.'}
    $root=[IO.Path]::GetFullPath($ProjectRoot);$link=[IO.Path]::GetFullPath($LinkPath);$target=[IO.Path]::GetFullPath($TargetPath)
    if(-not(Test-MmtlInsideRoot -Root $root -Target $link)){throw 'Fabric Runtime junction 越出项目目录，拒绝清理。'}
    if(-not(Test-Path -LiteralPath $link)){return $false}
    $item=Get-Item -LiteralPath $link -Force
    if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -ne 'Junction'){throw '目标不是预期的 Fabric Runtime junction，拒绝清理。'}
    $linkTarget=[IO.Path]::GetFullPath([string]@($item.Target)[0])
    if($linkTarget -ne $target){throw 'Fabric Runtime junction 目标与登记信息不符，拒绝清理。'}
    Remove-Item -LiteralPath $link -Force
    return $true
}
function Set-MmtlClientGuiScale {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$RuntimeDirectory,[Parameter(Mandatory)][object]$GuiScale)
    $scale=0
    if([string]$GuiScale -ine 'Auto' -and (-not[int]::TryParse([string]$GuiScale,[ref]$scale) -or $scale -lt 0 -or $scale -gt 4)){throw 'guiScale 必须为 Auto 或 0 至 4。'}
    $session=[IO.Path]::GetFullPath($SessionPath);$runtime=[IO.Path]::GetFullPath($RuntimeDirectory)
    if(-not(Test-MmtlInsideRoot -Root $session -Target $runtime) -or $runtime -eq $session){throw '客户端 Runtime 必须位于当前 Session 内。'}
    Assert-MmtlNoReparsePath -Path $session|Out-Null;Assert-MmtlNoReparsePath -Path $runtime|Out-Null
    $options=Join-Path $runtime 'options.txt'
    if(Test-Path -LiteralPath $options){$item=Get-Item -LiteralPath $options -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'options.txt 不得是 junction 或 symlink。'};$lines=@([IO.File]::ReadAllLines($options))}else{$lines=@()}
    $updated=$false
    for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match '^guiScale:'){$lines[$i]="guiScale:$scale";$updated=$true}}
    if(-not $updated){$lines+= "guiScale:$scale"}
    [IO.File]::WriteAllLines($options,[string[]]$lines,[Text.UTF8Encoding]::new($false))
    return $true
}
function Start-MmtlGradleInstance {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$JavaPath,[Parameter(Mandatory)][string]$SessionPath,[string[]]$ModJars=@())
    $session=[IO.Path]::GetFullPath($SessionPath);$runtime=[IO.Path]::GetFullPath([string]$Plan.RuntimeDirectory)
    if(-not(Test-MmtlInsideRoot -Root $session -Target $runtime)){throw '实例 Runtime 必须位于当前 Session。'}
    Assert-MmtlNoReparsePath -Path $session|Out-Null
    New-Item -ItemType Directory -Path $runtime -Force|Out-Null
    Assert-MmtlNoReparsePath -Path $runtime|Out-Null
    $mods=Join-Path $runtime 'mods';New-Item -ItemType Directory -Path $mods -Force|Out-Null
    Assert-MmtlNoReparsePath -Path $mods|Out-Null
    if($Plan.Role -ne 'Server' -and $null -ne $Plan.GuiScale -and [string]$Plan.GuiScale -ne ''){Set-MmtlClientGuiScale -SessionPath $session -RuntimeDirectory $runtime -GuiScale $Plan.GuiScale|Out-Null}
    foreach($jar in $ModJars){
        if(-not(Test-Path -LiteralPath $jar -PathType Leaf) -or [IO.Path]::GetExtension($jar) -ne '.jar'){throw "模组文件无效：$jar"}
        $destination=Join-Path $mods ([IO.Path]::GetFileName($jar))
        if(Test-Path -LiteralPath $destination){throw "当前实例存在同名 Mod JAR：$([IO.Path]::GetFileName($jar))"}
        Copy-Item -LiteralPath $jar -Destination $destination
    }
    $logName=if($Plan.Role -eq 'Server'){'server'}else{"$($Plan.Role)-$($Plan.Username)"}
    $helper=Join-Path $PSScriptRoot 'Invoke-GradleTask.ps1'
    if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw '缺少 Gradle Session Runner。'}
    $powerShellHost=Get-Command pwsh -ErrorAction SilentlyContinue
    if(-not $powerShellHost){$powerShellHost=Get-Command powershell.exe -ErrorAction Stop}
    $runtimeLink=$null;$arguments=@($Plan.Arguments)
    if($Project.Loader -eq 'Fabric'){
        $runtimeLink=New-MmtlFabricRuntimeLink -ProjectRoot $Project.Root -SessionPath $session -TargetPath $runtime -Name $logName
        $runtimeArgumentIndex=-1
        for($i=0;$i -lt $arguments.Count;$i++){if([string]$arguments[$i] -like '-PpycodersRuntimeDir=*'){$runtimeArgumentIndex=$i;break}}
        if($runtimeArgumentIndex -lt 0){Remove-MmtlFabricRuntimeLink -ProjectRoot $Project.Root -LinkPath $runtimeLink -TargetPath $runtime|Out-Null;throw 'Gradle 计划缺少 Runtime 参数。'}
        $arguments[$runtimeArgumentIndex]="-PpycodersRuntimeDir=$runtimeLink"
    }
    $payload=[ordered]@{projectRoot=$Project.Root;sessionPath=$session;arguments=$arguments;runtimeLinkPath=$runtimeLink;runtimeTargetPath=$(if($runtimeLink){$runtime}else{$null})}|ConvertTo-Json -Depth 8 -Compress
    $payloadB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $log=New-MmtlLogPath -RuntimeRoot (Split-Path (Split-Path $session -Parent) -Parent) -SessionPath $session -Name $logName
    $oldHome=$env:JAVA_HOME;$oldPath=$env:Path;$javaHome=Split-Path (Split-Path $JavaPath -Parent) -Parent
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1');$pathSeparator=[string](Get-MmtlPlatformProvider).PathListSeparator
    try{
        $env:JAVA_HOME=$javaHome;$env:Path=(Join-Path $javaHome 'bin')+$pathSeparator+$oldPath
        $args=@('-NoProfile','-NonInteractive','-File',('"'+$helper+'"'),'-LaunchPlanB64',$payloadB64)
        $processId=Start-MmtlTrackedProcess -SessionPath $session -FilePath $powerShellHost.Source -ArgumentList $args -WorkingDirectory $Project.Root -LogPath $log -Role $Plan.Role -Username $Plan.Username -RuntimeLinkPath $runtimeLink -RuntimeTargetPath $(if($runtimeLink){$runtime}else{''})
    }catch{if($runtimeLink){Remove-MmtlFabricRuntimeLink -ProjectRoot $Project.Root -LinkPath $runtimeLink -TargetPath $runtime|Out-Null};throw
    }finally{$env:JAVA_HOME=$oldHome;$env:Path=$oldPath}
    [pscustomobject]@{ProcessId=[int]$processId;Role=$Plan.Role;Username=$Plan.Username;Project=$Project.Root;Task=$Plan.Task;RuntimeDirectory=$runtime;LogPath=$log;ErrorLogPath=($log+'.err')}
}
function Initialize-MmtlDedicatedServerRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,[Parameter(Mandatory)]$Profile)
    if($Profile.acceptEula -ne $true){throw 'Dedicated Server 需要用户在配置中明确设置 acceptEula=true。'}
    $world=if($Profile.worldName){[string]$Profile.worldName}else{'MMTL-Test'}
    if($world -notmatch '^[A-Za-z0-9._ -]{1,64}$'){throw 'Dedicated 测试世界名包含不支持的字符。'}
    $players=if($Profile.players){[int]$Profile.players}else{1}
    if($players -lt 1 -or $players -gt 64){throw 'Dedicated 玩家数量必须在 1 到 64 之间。'}
    $mode=if($Profile.gameMode){[string]$Profile.gameMode}else{'survival'}
    if($mode -notin @('survival','creative','adventure','spectator')){throw 'Dedicated 游戏模式无效。'}
    $difficulty=if($Profile.difficulty){[string]$Profile.difficulty}else{'normal'}
    if($difficulty -notin @('peaceful','easy','normal','hard')){throw 'Dedicated 难度无效。'}
    $session=[IO.Path]::GetFullPath($SessionPath);Assert-MmtlNoReparsePath -Path $session|Out-Null
    $server=Join-Path $session 'Server';if(-not(Test-MmtlInsideRoot -Root $session -Target $server)){throw 'Dedicated Runtime 越出 Session。'}
    if(Test-Path -LiteralPath $server){Assert-MmtlNoReparsePath -Path $server|Out-Null}
    New-Item -ItemType Directory -Path $server -Force|Out-Null
    $eula=Join-Path $server 'eula.txt';$properties=Join-Path $server 'server.properties'
    if((Test-Path -LiteralPath $eula) -or (Test-Path -LiteralPath $properties)){throw '拒绝覆盖已有 Dedicated Runtime 配置。'}
    $lines=@("server-ip=127.0.0.1","server-port=$Port","online-mode=false","level-name=$world","max-players=$players","gamemode=$mode","difficulty=$difficulty","motd=MMTL isolated local development session","enable-command-block=false")
    if($Profile.seed){$seedText=[string]$Profile.seed;if($seedText -notmatch '^-?\d{1,20}$'){throw 'Dedicated 世界种子必须是整数。'};$lines+="level-seed=$seedText"}
    $permission=if($null -ne $Profile.clientPermissionLevel){[int]$Profile.clientPermissionLevel}else{0}
    if($permission -lt 0 -or $permission -gt 4){throw 'Dedicated 客户端权限等级必须为 0 至 4。'}
    $ops=@()
    if($permission -gt 0){
        $host=if($Profile.hostUsername){[string]$Profile.hostUsername}else{'Dev'};$prefix=if($Profile.clientPrefix){[string]$Profile.clientPrefix}else{'Dev_'}
        if($host -notmatch '^[A-Za-z0-9_]{1,16}$' -or $prefix -notmatch '^[A-Za-z0-9_]{1,15}$'){throw 'Dedicated 测试玩家用户名或前缀无效。'}
        $names=@($host);for($i=1;$i -lt $players;$i++){$names+=($prefix+$i)}
        foreach($name in $names){$md5=[Security.Cryptography.MD5]::Create();try{$bytes=$md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("OfflinePlayer:$name"))}finally{$md5.Dispose()};$bytes[6]=($bytes[6] -band 0x0f) -bor 0x30;$bytes[8]=($bytes[8] -band 0x3f) -bor 0x80;$hex=([BitConverter]::ToString($bytes).Replace('-','')).ToLowerInvariant();$uuid=$hex.Substring(0,8)+'-'+$hex.Substring(8,4)+'-'+$hex.Substring(12,4)+'-'+$hex.Substring(16,4)+'-'+$hex.Substring(20,12);$ops+=@{uuid=$uuid;name=$name;level=$permission;bypassesPlayerLimit=$false}}
    }
    [IO.File]::WriteAllText($eula,"# 用户已通过本机 Profile 明确接受 Minecraft EULA`neula=true`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($properties,$lines,[Text.UTF8Encoding]::new($false))
    if($ops.Count){[IO.File]::WriteAllText((Join-Path $server 'ops.json'),($ops|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
    [pscustomobject]@{ServerDirectory=$server;EulaPath=$eula;PropertiesPath=$properties;Port=$Port;WorldName=$world;Players=$players;Ops=$ops}
}
Export-ModuleMember -Function Invoke-MmtlGradleBuild,Get-MmtlMemoryBudget,Assert-MmtlMemoryBudget,Start-MmtlGradleInstance,Initialize-MmtlDedicatedServerRuntime,New-MmtlFabricRuntimeLink,Remove-MmtlFabricRuntimeLink,Set-MmtlClientGuiScale
