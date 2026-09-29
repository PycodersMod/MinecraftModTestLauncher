[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$ErrorActionPreference='Stop'
if($null -eq $Arguments){$Arguments=@()}
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem (Join-Path $here 'src') -Filter '*.psm1' -Recurse | ForEach-Object { Import-Module $_.FullName -Force }
$configPath=Join-Path $here 'launcher.config.json'
$configFileIndex=[Array]::IndexOf($Arguments,'--config-file')
if($configFileIndex -ge 0){if($configFileIndex+1 -ge $Arguments.Count){throw '--config-file 缺少路径。'};$configPath=[IO.Path]::GetFullPath([string]$Arguments[$configFileIndex+1])}
$portable=$Arguments -contains '--portable'
if($Arguments -contains '--help' -or $Arguments -contains '-h'){
    Write-Host 'Minecraft Mod Test Launcher';Write-Host '用法：launcher.cmd [--validate|--dry-run|--build|--launch] [--profile NAME]';Write-Host 'Session：--list-sessions | --stop ID | --clean-session ID';Write-Host '运行目录：--portable';Write-Host '交互模式：不传参数；--config-file 仅供临时配置调用。';exit 0
}
$config=if(Test-Path $configPath){Read-MmtlConfig -Path $configPath}else{$null}
$runtimeConfigured=if($config -and $config.runtimeRoot){[string]$config.runtimeRoot}else{'%LOCALAPPDATA%/MinecraftModTestLauncher'}
$runtimeRoot=Resolve-MmtlRuntimeRoot -Path $runtimeConfigured -Portable:$portable -LauncherRoot $here
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
    $jars=@(Get-ChildItem -LiteralPath (Join-Path $Project.Root 'build\libs') -Filter '*.jar' -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -notmatch '(?i)(sources|javadoc|dev)(?:[-.]|\.jar$)'})
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
    Assert-MmtlMemoryBudget -Profile $Profile -Mode $Profile.mode|Out-Null
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
    $metadata=[pscustomobject]@{project=$Primary.Root;linkedProjects=@($linked.Root);minecraft=$Primary.MinecraftVersion;loader=$Primary.Loader;loaderVersion=$Primary.LoaderVersion;javaMajor=$Primary.JavaMajor;mode=$Profile.mode;players=$players;hostUsername=$hostName;clientPrefix=$prefix;hostCheats=[bool]$Profile.hostCheats;clientPermissionLevel=[int]$Profile.clientPermissionLevel;gameMode=$Profile.gameMode;difficulty=$Profile.difficulty;worldName=$Profile.worldName;seed=$Profile.seed;newWorld=[bool]$Profile.newWorld;resetWorld=[bool]$Profile.resetWorld;resolution=$Profile.resolution;windowLayout=$Profile.windowLayout;memoryMb=$Profile.memoryMb;port=$requestedPort;builds=@();processes=@();createdBy='MinecraftModTestLauncher'}
    $session=New-MmtlSession -RuntimeRoot $RuntimeRoot -Name $name -Metadata $metadata
    $sessionId=Split-Path $session -Leaf
    $builds=[Collections.Generic.List[object]]::new();$linkedJars=[Collections.Generic.List[string]]::new()
    try{
        Write-Host "Session: $sessionId`nMinecraft: $($Primary.MinecraftVersion)`nLoader: $($Primary.Loader) $($Primary.LoaderVersion)`nJava: $($Primary.JavaMajor)`nMode: $($Profile.mode)`nPlayers: $players`nRuntime: $session"
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
        $report=@("# Session $sessionId",'',"- Mode: $($Profile.mode)","- Project: $($Primary.Root)","- Minecraft: $($Primary.MinecraftVersion)","- Loader: $($Primary.Loader) $($Primary.LoaderVersion)","- Java: $($Primary.JavaMajor)","- Players: $($metadata.processes.username -join ', ')","- Port: $($metadata.port)","- Window layout: $($metadata.windowLayoutStatus)","- Runtime: $session",'', '## Builds')
        foreach($build in $builds){$report+=@("- Project: $($build.Project)","  - Git SHA: $($build.GitSha)","  - Jar: $($build.JarPath)","  - SHA-256: $($build.JarSha256)","  - Log: $($build.LogPath)")}
        $report+=@('','## Processes');foreach($process in $metadata.processes){$report+="- $($process.role) $($process.username) PID $($process.PID): $($process.log)"};Set-Content -LiteralPath (Join-Path $session 'report.md') -Value $report -Encoding utf8
        Write-Host "会话清单：$session`n停止命令：launcher.cmd --stop $sessionId`n清理命令：launcher.cmd --clean-session $sessionId"
    }catch{Write-Error "Session $sessionId 已保留现场和日志。检查后可用 --stop $sessionId 停止登记进程。$($_.Exception.Message)";throw}
}
if($Arguments -contains '--validate') {
    if($env:OS -ne 'Windows_NT'){throw 'MMTL v1 仅支持 Windows 10/11。'}
    if($project.Loader -eq 'Unknown'){throw '无法检测 Mod Loader。'}
    $java=if($project.JavaMajor){Resolve-MmtlJava -Config $config -Major $project.JavaMajor}else{'未能自动判断 Java 主版本'}
    $linked=@($profile.linkedProjects|Where-Object{$_}|ForEach-Object{Get-MmtlProject -Path $_})
    if($linked.Count){Assert-MmtlCompatible -Projects (@($project)+$linked)|Out-Null}
    [pscustomobject]@{Project=$project.Root;LinkedProjects=($linked.Root -join '; ');Loader=$project.Loader;Minecraft=$project.MinecraftVersion;Java=$java;Wrapper=$project.Wrapper;Mode=$profile.mode;RuntimeRoot=$runtimeRoot;Port=$profile.port} | Format-List
    exit 0
}
if($Arguments -contains '--dry-run') {
    $task=if($profile.mode -eq 'Dedicated'){'runServer'}else{'runClient'}
    $cmd=Get-MmtlGradleCommand -Project $project -Task $task
    Write-Host "模式：$($profile.mode)；项目：$($project.Root)；Loader：$($project.Loader)；Minecraft：$($project.MinecraftVersion)"
    Write-Host "命令预览：$($cmd.File) $($cmd.Arguments -join ' ')"
    Write-Host '安全说明：当前 dry-run 不执行 Gradle，也不启动 Minecraft。'
    exit 0
}
if($Arguments -contains '--launch') { Start-MmtlConfiguredRun -Primary $project -Profile $profile -Config $config -RuntimeRoot $runtimeRoot;exit 0 }
if($Arguments -contains '--build') {
    if($env:OS -ne 'Windows_NT'){throw 'MMTL v1 仅支持 Windows 10/11。'}
    if($project.Loader -eq 'Unknown' -or -not $project.Wrapper){throw '项目 Loader 或 Gradle Wrapper 无法确认。'}
    if(-not $project.JavaMajor){throw '无法确定项目所需 Java 主版本；拒绝回退到系统 Java。'}
    $java=Resolve-MmtlJava -Config $config -Major $project.JavaMajor
    $javaHome=Split-Path (Split-Path $java -Parent) -Parent
    $session=New-MmtlSession -RuntimeRoot $runtimeRoot -Name ([IO.Path]::GetFileName($project.Root)) -Metadata ([pscustomobject]@{project=$project.Root;loader=$project.Loader;minecraft=$project.MinecraftVersion;javaMajor=$project.JavaMajor;players=$profile.players;mode=$profile.mode})
    $log=New-MmtlLogPath -RuntimeRoot $runtimeRoot -SessionPath $session -Name 'gradle-build'
    $cmd=Get-MmtlGradleCommand -Project $project -Task 'build' -Clean:([bool]$profile.cleanBuild)
    $oldJavaHome=$env:JAVA_HOME;$oldPath=$env:Path
    try{$env:JAVA_HOME=$javaHome;$env:Path=(Join-Path $javaHome 'bin')+';'+$oldPath;Push-Location $cmd.WorkingDirectory;try{$cmdArgs=$cmd.Arguments;& $cmd.File @cmdArgs *> $log;$buildExit=$LASTEXITCODE}finally{Pop-Location}}
    finally{$env:JAVA_HOME=$oldJavaHome;$env:Path=$oldPath}
    $jar=Get-ChildItem (Join-Path $project.Root 'build\libs') -Filter '*.jar' -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -notmatch 'sources|javadoc'}|Sort-Object LastWriteTime -Descending|Select-Object -First 1
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
