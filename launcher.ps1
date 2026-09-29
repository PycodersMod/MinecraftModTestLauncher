[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$ErrorActionPreference='Stop'
$here=Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem (Join-Path $here 'src') -Filter '*.psm1' -Recurse | ForEach-Object { Import-Module $_.FullName -Force }
$configPath=Join-Path $here 'launcher.config.json'
$portable=$Arguments -contains '--portable'
$config=if(Test-Path $configPath){Read-MmtlConfig -Path $configPath}else{$null}
$runtimeConfigured=if($config -and $config.runtimeRoot){[string]$config.runtimeRoot}else{'%LOCALAPPDATA%/MinecraftModTestLauncher'}
$runtimeRoot=Resolve-MmtlRuntimeRoot -Path $runtimeConfigured -Portable:$portable -LauncherRoot $here
if ($Arguments -contains '--list-sessions') {
    $sessions=Join-Path $runtimeRoot 'sessions'
    if(Test-Path $sessions){Get-ChildItem $sessions -Directory | Select-Object -ExpandProperty Name}; exit 0
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
        Write-Host "已请求停止 Session $id 中的登记进程。";exit 0
    }
}
if (-not (Test-Path $configPath)) {
    Write-Host 'Minecraft Mod Test Launcher - 临时向导'
    $projectPath=Read-Host '输入 Gradle Mod 项目目录'
    if(-not $projectPath){Write-Host '未提供项目目录。'; exit 2}
    $detected=Get-MmtlProject -Path $projectPath
    $javaMajor=if($detected.JavaMajor){$detected.JavaMajor}else{Read-Host '输入所需 Java 主版本'}
    Write-Host "检测到 Loader=$($detected.Loader), Minecraft=$($detected.MinecraftVersion), Java=$javaMajor"
    Write-Host '向导模式：暂只支持安全检测和构建预览；游戏实例启动能力尚未启用。'
    exit 0
}
if($Arguments.Count -eq 0){
    Write-Host 'Minecraft Mod Test Launcher';Write-Host '检测到 launcher.config.json';Write-Host '[1] 使用默认配置快速启动';Write-Host '[2] 选择配置 Profile';Write-Host '[3] 查看配置';Write-Host '[4] 临时配置启动';Write-Host '[Q] 退出'
    $choice=Read-Host '选择'
    if($choice -eq 'Q'){exit 0}
    if($choice -eq '3'){$config|ConvertTo-Json -Depth 20|Write-Host;exit 0}
    if($choice -eq '4'){$temporaryProject=Read-Host '输入 Mod Gradle 项目目录';$temporary=Get-MmtlProject -Path $temporaryProject;Write-Host "检测到 $($temporary.Loader) / $($temporary.MinecraftVersion) / Java $($temporary.JavaMajor)";Write-Host '该临时配置目前只支持验证和预览。';exit 0}
    if($choice -eq '2'){$profileName=Read-Host ("可用 Profile: "+(($config.profiles.PSObject.Properties.Name)-join ', '));$profile=Get-MmtlProfile -Config $config -Name $profileName}
    elseif($choice -eq '1'){$profile=Get-MmtlProfile -Config $config}
    else{Write-Host '无效选择';exit 2}
    Write-Host '启动预览：实际 Minecraft 实例启动尚未实现。请使用 --dry-run 查看 Gradle 命令。';exit 3
}
$profileNameIndex=[Array]::IndexOf($Arguments,'--profile')
$profileName=if($profileNameIndex -ge 0 -and $profileNameIndex+1 -lt $Arguments.Count){[string]$Arguments[$profileNameIndex+1]}else{$null}
$profile=Get-MmtlProfile -Config $config -Name $profileName
Assert-MmtlProfile -Profile $profile | Out-Null
$project=Get-MmtlProject -Path $profile.project
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
