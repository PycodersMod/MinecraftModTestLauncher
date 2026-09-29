BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Get-ChildItem (Join-Path $script:root 'src') -Filter '*.psm1' -Recurse | ForEach-Object { Import-Module $_.FullName -Force }
    function New-TestModProject {
        param([string]$Name,[string]$Loader,[string]$MinecraftVersion,[int]$JavaMajor)
        $path=Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path (Join-Path $path 'src/main/resources') -Force | Out-Null
        $loaderVersion=if($Loader -eq 'Forge'){'47.2.0'}elseif($Loader -eq 'NeoForge'){'21.1.238'}else{'0.16.14'}
        $loaderKey=if($Loader -eq 'Forge'){'forge_version'}elseif($Loader -eq 'NeoForge'){'neo_version'}else{'loader_version'}
        "minecraft_version=$MinecraftVersion`njava_version=$JavaMajor`n$loaderKey=$loaderVersion`nmod_id=${Name}_mod" | Set-Content (Join-Path $path 'gradle.properties')
        'plugins {}' | Set-Content (Join-Path $path 'build.gradle')
        New-Item -ItemType File -Path (Join-Path $path 'gradlew.bat') | Out-Null
        $metadata=switch($Loader){
            'Fabric' {'fabric.mod.json'}
            'NeoForge' {'META-INF/neoforge.mods.toml'}
            'Forge' {'META-INF/mods.toml'}
        }
        $metadataPath=Join-Path (Join-Path $path 'src/main/resources') $metadata
        New-Item -ItemType Directory -Path (Split-Path $metadataPath -Parent) -Force | Out-Null
        '{}' | Set-Content $metadataPath
        return $path
    }
}
Describe 'MMTL 安全与项目检测' {
    It '拒绝 Runtime Root 外的删除目标' {
        { Remove-MmtlSession -RuntimeRoot 'C:\mmtl' -SessionPath (Join-Path $TestDrive 'outside-session') } | Should -Throw
    }
    It 'Session 子目录中出现 junction 时拒绝递归删除' {
        $runtime=Join-Path $TestDrive 'junction-runtime';$outside=Join-Path $TestDrive 'junction-outside'
        $session=New-MmtlSession -RuntimeRoot $runtime -Name 'junction-protected' -Metadata ([pscustomobject]@{players=1})
        New-Item -ItemType Directory -Path $outside|Out-Null;Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'safe'
        $link=Join-Path $session 'linked-data';New-Item -ItemType Junction -Path $link -Target $outside|Out-Null
        try{
            {Remove-MmtlSession -RuntimeRoot $runtime -SessionPath $session}|Should -Throw '*junction/symlink*'
            (Get-Content (Join-Path $outside 'keep.txt') -Raw).Trim()|Should -Be 'safe'
            Test-Path -LiteralPath $session|Should -BeTrue
        }finally{Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue}
    }
    It '识别当前 Carpet Fabric 项目并拒绝未知类型' {
        $repo=New-TestModProject -Name 'carpet-fixture' -Loader Fabric -MinecraftVersion '1.21.6' -JavaMajor 21
        $project=Get-MmtlProject -Path $repo
        $project.Loader | Should -Be 'Fabric'
        $project.MinecraftVersion | Should -Not -BeNullOrEmpty
    }
    It '拒绝不兼容 Loader' {
        $p1=[pscustomobject]@{MinecraftVersion='1.21.1';Loader='Forge';JavaMajor=21}
        $p2=[pscustomobject]@{MinecraftVersion='1.21.1';Loader='Fabric';JavaMajor=21}
        { Assert-MmtlCompatible -Projects @($p1,$p2) } | Should -Throw
    }
    It 'Java 未配置时明确失败' {
        { Resolve-MmtlJava -Config ([pscustomobject]@{javaHomes=@{}}) -Major 19 } | Should -Throw '*Required Java 19 is not configured*'
    }
    It 'Runtime Root 内创建 Session 和隔离日志目录' {
        $runtime=Join-Path $TestDrive 'runtime'
        $session=New-MmtlSession -RuntimeRoot $runtime -Name 'safe_test' -Metadata ([pscustomobject]@{players=2})
        (Test-MmtlInsideRoot -Root $runtime -Target $session) | Should -BeTrue
        (Test-Path (Join-Path $session 'logs')) | Should -BeTrue
        (Test-Path (Join-Path $session 'Dev_1')) | Should -BeTrue
    }
    It '同名 Session 在短时间内创建时仍使用独立目录' {
        $runtime=Join-Path $TestDrive 'unique-runtime'
        $metadata=[pscustomobject]@{players=1}
        $first=New-MmtlSession -RuntimeRoot $runtime -Name 'same_name' -Metadata $metadata
        $second=New-MmtlSession -RuntimeRoot $runtime -Name 'same_name' -Metadata $metadata
        $second | Should -Not -Be $first
        (Test-Path $first) | Should -BeTrue
        (Test-Path $second) | Should -BeTrue
    }
    It '拒绝 Session 名称路径穿越' {
        { New-MmtlSession -RuntimeRoot $TestDrive -Name '..\escape' -Metadata ([pscustomobject]@{players=1}) } | Should -Throw
    }
    It '日志必须留在当前 Session' {
        $runtime=Join-Path $TestDrive 'runtime2'; $session=New-MmtlSession -RuntimeRoot $runtime -Name 'logs_test' -Metadata ([pscustomobject]@{players=1})
        { New-MmtlLogPath -RuntimeRoot $runtime -SessionPath (Split-Path $session -Parent) -Name 'client' } | Should -Throw
        (New-MmtlLogPath -RuntimeRoot $runtime -SessionPath $session -Name 'client') | Should -BeLike "$session*"
    }
    It '自动端口可绑定且位于有效范围' {
        $port=Get-MmtlPort
        $port | Should -BeGreaterThan 0
        $port | Should -BeLessThan 65536
    }
    It '从 IntegratedLAN 启动日志检测端口并等待 Dedicated 就绪标记' {
        $log=Join-Path $TestDrive 'minecraft-startup.log'
        '[Server thread/INFO]: Started serving on 25566' | Set-Content $log
        (Get-MmtlLanPortFromLog -Path $log) | Should -Be 25566
        '[Server thread/INFO]: Done (2.5s)! For help, type "help"' | Add-Content $log
        (Test-MmtlDedicatedReadyLog -Path $log) | Should -BeTrue
        '[Server thread/INFO]: Failed to start the Minecraft server' | Add-Content $log
        { Wait-MmtlDedicatedReady -Path $log -TimeoutSeconds 1 -PollMilliseconds 50 } | Should -Throw '*启动失败*'
    }
    It 'Dedicated 仅在配置明确接受 EULA 后写入 Session 服务端目录' {
        $runtime=Join-Path $TestDrive 'dedicated-runtime'
        $session=New-MmtlSession -RuntimeRoot $runtime -Name 'dedicated' -Metadata ([pscustomobject]@{players=2})
        $profile=[pscustomobject]@{acceptEula=$false;worldName='MMTL-Test';players=2;gameMode='creative';difficulty='normal';seed='-12345';hostUsername='Dev';clientPrefix='Dev_';clientPermissionLevel=2}
        {Initialize-MmtlDedicatedServerRuntime -SessionPath $session -Port 25567 -Profile $profile}|Should -Throw '*EULA*'
        (Test-Path (Join-Path $session 'Server\eula.txt')) | Should -BeFalse
        $profile.acceptEula=$true
        $profile.seed='bad-seed'
        {Initialize-MmtlDedicatedServerRuntime -SessionPath $session -Port 25567 -Profile $profile}|Should -Throw '*种子*'
        (Test-Path (Join-Path $session 'Server\eula.txt')) | Should -BeFalse
        $profile.seed='-12345'
        $result=Initialize-MmtlDedicatedServerRuntime -SessionPath $session -Port 25567 -Profile $profile
        (Test-MmtlInsideRoot -Root $session -Target $result.ServerDirectory) | Should -BeTrue
        (Get-Content (Join-Path $result.ServerDirectory 'eula.txt') -Raw) | Should -Match 'eula=true'
        $properties=Get-Content (Join-Path $result.ServerDirectory 'server.properties') -Raw
        $properties | Should -Match 'server-port=25567'
        $properties | Should -Match 'server-ip=127\.0\.0\.1'
        $properties | Should -Match 'online-mode=false'
        $properties | Should -Match 'level-seed=-12345'
        $ops=Get-Content (Join-Path $result.ServerDirectory 'ops.json') -Raw|ConvertFrom-Json
        @($ops).Count | Should -Be 2
        @($ops|Where-Object level -ne 2).Count | Should -Be 0
    }
    It 'Session 报告汇总退出码和 Crash Report 路径' {
        $runtime=Join-Path $TestDrive 'report-runtime'
        $session=New-MmtlSession -RuntimeRoot $runtime -Name 'report' -Metadata ([pscustomobject]@{players=1})
        $testProcessId=2147480000
        $entry=[pscustomobject]@{PID=$testProcessId;Role='Client';Username='Dev';StartTimeUtc='2000-01-01T00:00:00.0000000Z';Executable='C:\fake\pwsh.exe';ParentPID=0;CommandLine='';LogPath=(Join-Path $session 'logs\client.log');ProcessTree=@()}
        $entry|ConvertTo-Json|Set-Content (Join-Path $session 'pids.json')
        [pscustomobject]@{PID=$testProcessId;ExitCode=-1;FinishedUtc='2026-09-29T00:00:00Z';Error='runClient crashed'}|ConvertTo-Json|Set-Content (Join-Path $session "process-$testProcessId.exit.json")
        $crashDir=Join-Path $session 'Dev\crash-reports';New-Item -ItemType Directory -Path $crashDir -Force|Out-Null
        New-Item -ItemType File -Path (Join-Path $crashDir 'crash-test-client.txt')|Out-Null
        $status=Update-MmtlSessionReport -SessionPath $session
        $status.Status | Should -Be 'Failed'
        $report=Get-Content (Join-Path $session 'report.md') -Raw
        $report | Should -Match 'exit=-1'
        $report | Should -Match 'crash-test-client\.txt'
    }
    It '拒绝清理仍有登记进程的 Session' {
        $runtime=Join-Path $TestDrive 'active-clean-runtime'
        $session=New-MmtlSession -RuntimeRoot $runtime -Name 'active' -Metadata ([pscustomobject]@{players=1})
        $pwsh=(Get-Command pwsh).Source
        $log=New-MmtlLogPath -RuntimeRoot $runtime -SessionPath $session -Name 'active-process'
        $processId=Start-MmtlTrackedProcess -SessionPath $session -FilePath $pwsh -ArgumentList @('-NoProfile','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'))) -WorkingDirectory $TestDrive -LogPath $log
        try {
            {Remove-MmtlSession -RuntimeRoot $runtime -SessionPath $session}|Should -Throw '*仍有启动器登记进程*'
            (Test-Path $session) | Should -BeTrue
        } finally {Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $processId -Confirm:$false|Out-Null}
    }
    It '窗口平铺不可用时安全降级' {
        (Get-MmtlWindowLayout -Mode Tile) | Should -Be 'UnavailableFallbackNone'
    }
    It '分别识别 Forge、NeoForge、Fabric 及其 Java 主版本' {
        $cases=@(
            @{name='forge-fixture';loader='Forge';version='1.20.1';java=17},
            @{name='neoforge-fixture';loader='NeoForge';version='1.21.1';java=21},
            @{name='fabric-fixture';loader='Fabric';version='1.21.6';java=21}
        )
        foreach($case in $cases){
            $fixture=New-TestModProject -Name $case.name -Loader $case.loader -MinecraftVersion $case.version -JavaMajor $case.java
            $project=Get-MmtlProject $fixture
            $project.Loader | Should -Be $case.loader
            $project.JavaMajor | Should -Be $case.java
            $project.LoaderVersion | Should -Not -BeNullOrEmpty
            $project.ModId | Should -Be ($case.name+'_mod')
            $project.Wrapper | Should -BeTrue
        }
    }
    It '为 Single、IntegratedLAN 和 Dedicated 生成隔离的 Loader 启动计划' {
        $projectPath=New-TestModProject -Name 'run-plan-fixture' -Loader Forge -MinecraftVersion '1.20.1' -JavaMajor 17
        $project=Get-MmtlProject $projectPath
        $session=Join-Path $TestDrive 'run-plan-session'
        New-Item -ItemType Directory $session|Out-Null
        $profile=[pscustomobject]@{gameArgs=@('--demo');jvmArgs=@('-Dfixture=true');memoryMb=2048;resolution='1280x720'}
        $single=New-MmtlGradleRunPlan -Project $project -Mode Single -RuntimeRoot $session -Role Client -Username 'Dev' -Profile $profile
        $single.Task | Should -Be 'runClient'
        $single.RuntimeDirectory | Should -BeLike "$session*"
        $single.Arguments | Should -Contain '-PpycodersUsername=Dev'
        $single.GameArguments | Should -Contain '--width'
        $single.GameArguments | Should -Contain '1280'
        $single.GameArguments | Should -Contain '--height'
        $single.GameArguments | Should -Contain '720'
        $lanHostPlan=New-MmtlGradleRunPlan -Project $project -Mode IntegratedLAN -RuntimeRoot $session -Role Host -Username 'Dev' -Profile $profile
        $client=New-MmtlGradleRunPlan -Project $project -Mode IntegratedLAN -RuntimeRoot $session -Role Client -Username 'Dev_1' -Port 25566 -Profile $profile
        $lanHostPlan.Task | Should -Be 'runClient'
        $client.RuntimeDirectory | Should -Not -Be $lanHostPlan.RuntimeDirectory
        $client.GameArguments | Should -Contain '--server'
        $client.GameArguments | Should -Contain '127.0.0.1'
        $client.GameArguments | Should -Contain '--port'
        $client.GameArguments | Should -Contain '25566'
        $server=New-MmtlGradleRunPlan -Project $project -Mode Dedicated -RuntimeRoot $session -Role Server -Username '' -Profile $profile
        $server.Task | Should -Be 'runServer'
        @($server.Arguments|Where-Object{$_ -like '-PpycodersRuntimeDir=*'}).Count | Should -Be 1
    }
    It '按玩家进程数拒绝超出物理内存预算的配置' {
        $profile=[pscustomobject]@{players=4;memoryMb=4096}
        {Assert-MmtlMemoryBudget -Profile $profile -Mode IntegratedLAN -PhysicalMemoryMb 16384}|Should -Throw '*内存预算超限*'
        (Assert-MmtlMemoryBudget -Profile $profile -Mode Single -PhysicalMemoryMb 16384)|Should -BeTrue
        {Assert-MmtlMemoryBudget -Profile $profile -Mode Dedicated -PhysicalMemoryMb 16384}|Should -Throw '*内存预算超限*'
    }
    It '把 Gradle 实例日志和进程登记限制在 Session 内' {
        $projectPath=New-TestModProject -Name 'fake-gradle-project' -Loader Forge -MinecraftVersion '1.20.1' -JavaMajor 17
        $wrapper=Join-Path $projectPath 'gradlew.bat'
        "@echo off`necho fake-gradle-start`ntimeout /t 30 /nobreak >nul`n" | Set-Content -LiteralPath $wrapper
        $project=Get-MmtlProject $projectPath
        $runtime=Join-Path $TestDrive 'run-runtime'
        $session=New-MmtlSession -RuntimeRoot $runtime -Name 'fake_run' -Metadata ([pscustomobject]@{players=1})
        $profile=[pscustomobject]@{gameArgs=@();jvmArgs=@();memoryMb=1024}
        $plan=New-MmtlGradleRunPlan -Project $project -Mode Single -RuntimeRoot $session -Role Client -Username 'Dev' -Profile $profile
        $java=Join-Path $TestDrive 'jdk/bin/java.exe';New-Item -ItemType File -Path $java -Force|Out-Null
        $javaHome=Split-Path (Split-Path $java -Parent) -Parent
        $started=Start-MmtlGradleInstance -Project $project -Plan $plan -JavaPath $java -SessionPath $session
        try {
            $deadline=(Get-Date).AddSeconds(8)
            while(-not (Select-String -Path $started.LogPath -Pattern 'fake-gradle-start' -Quiet -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
            (Select-String -Path $started.LogPath -Pattern 'fake-gradle-start' -Quiet) | Should -BeTrue
            (Test-MmtlInsideRoot -Root $session -Target $started.LogPath) | Should -BeTrue
            $entry=Get-Content (Join-Path $session 'pids.json') -Raw|ConvertFrom-Json|Where-Object PID -eq $started.ProcessId
            $entry.Role | Should -Be 'Client'
            $entry.Username | Should -Be 'Dev'
        } finally {Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $started.ProcessId -Confirm:$false|Out-Null}
    }
    It '接受兼容的多项目组合' {
        $p1=[pscustomobject]@{MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';JavaMajor=17}
        $p2=[pscustomobject]@{MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';JavaMajor=17}
        (Assert-MmtlCompatible -Projects @($p1,$p2)) | Should -BeTrue
    }
    It '拒绝缺失或不一致的 Minecraft 版本' {
        $p1=[pscustomobject]@{MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';JavaMajor=17}
        $p2=[pscustomobject]@{MinecraftVersion='';Loader='Forge';LoaderVersion='47.2.0';JavaMajor=17}
        { Assert-MmtlCompatible -Projects @($p1,$p2) } | Should -Throw
    }
    It 'Loader 版本缺失或不同则拒绝多项目组合' {
        $p1=[pscustomobject]@{MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';JavaMajor=17}
        $p2=[pscustomobject]@{MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.4.20';JavaMajor=17}
        {Assert-MmtlCompatible -Projects @($p1,$p2)}|Should -Throw '*Loader 版本*'
        $p2.LoaderVersion=$null
        {Assert-MmtlCompatible -Projects @($p1,$p2)}|Should -Throw '*无法确认*'
    }
    It '配置读取后选择命名 Profile' {
        $file=Join-Path $TestDrive 'config.json'
        '{"defaultProfile":"a","javaHomes":{"17":"C:/jdk"},"profiles":{"a":{"project":"demo","mode":"Single","players":1},"b":{"project":"other","mode":"Dedicated","players":1}}}' | Set-Content $file
        $config=Read-MmtlConfig -Path $file
        (Get-MmtlProfile -Config $config -Name 'b').project | Should -Be 'other'
        (Assert-MmtlProfile -Profile (Get-MmtlProfile -Config $config -Name 'b')) | Should -BeTrue
    }
    It '拒绝畸形配置 JSON' {
        $file=Join-Path $TestDrive 'broken.json'; '{broken' | Set-Content $file
        { Read-MmtlConfig -Path $file } | Should -Throw
    }
    It '拒绝未登记的进程 PID' {
        $session=Join-Path $TestDrive 'pid-session'; New-Item -ItemType Directory -Path $session | Out-Null
        '[]' | Set-Content (Join-Path $session 'pids.json')
        { Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $PID -Confirm:$false } | Should -Throw '*未登记*'
    }
    It '登记进程已退出时停止命令安全返回而不触碰复用 PID' {
        $session=Join-Path $TestDrive 'exited-process-session';New-Item -ItemType Directory $session|Out-Null
        $record=[pscustomobject]@{PID=2147480000;Role='Client';Username='Dev';StartTimeUtc='2000-01-01T00:00:00.0000000Z';Executable='C:\fake\pwsh.exe';ParentPID=0;CommandLine='';ProcessTree=@()}
        $record|ConvertTo-Json|Set-Content (Join-Path $session 'pids.json')
        (Stop-MmtlTrackedProcess -SessionPath $session -ProcessId 2147480000 -Confirm:$false) | Should -BeFalse
    }
    It '停止登记的启动器进程时只结束它的进程树' {
        $runtime=Join-Path $TestDrive 'process-runtime'
        $session=New-MmtlSession -RuntimeRoot $runtime -Name 'process_tree' -Metadata ([pscustomobject]@{players=1})
        $pwsh=(Get-Command pwsh).Source
        $childPidFile=Join-Path $TestDrive 'child.pid'
        $runner=Join-Path $TestDrive 'process-tree-runner.ps1'
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 60'))
        @"
`$child=Start-Process -FilePath '$pwsh' -ArgumentList @('-NoProfile','-EncodedCommand','$encoded') -PassThru
Set-Content -LiteralPath '$childPidFile' -Value `$child.Id
Start-Sleep -Seconds 60
"@ | Set-Content -LiteralPath $runner
        $log=New-MmtlLogPath -RuntimeRoot $runtime -SessionPath $session -Name 'process-tree'
        $rootPid=Start-MmtlTrackedProcess -SessionPath $session -FilePath $pwsh -ArgumentList @('-NoProfile','-File',$runner) -WorkingDirectory $TestDrive -LogPath $log -Role 'Client' -Username 'Dev_1'
        try {
            $deadline=(Get-Date).AddSeconds(8)
            while(-not (Test-Path $childPidFile) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
            (Test-Path $childPidFile) | Should -BeTrue
            $childPid=[int](Get-Content $childPidFile -Raw)
            (Stop-MmtlTrackedProcess -SessionPath $session -ProcessId $rootPid -Confirm:$false) | Should -BeTrue
            $record=Get-Content (Join-Path $session 'pids.json') -Raw | ConvertFrom-Json | Where-Object PID -eq $rootPid
            @($record.ProcessTree | Where-Object PID -eq $childPid).Count | Should -Be 1
            $deadline=(Get-Date).AddSeconds(5)
            while((Get-Process -Id $childPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 100}
            (Get-Process -Id $childPid -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
            $record.Role | Should -Be 'Client'
            $record.Username | Should -Be 'Dev_1'
            (Get-Content $record.StatePath -Raw | ConvertFrom-Json).StopRequested | Should -BeTrue
        } finally {
            $childText=Get-Content $childPidFile -Raw -ErrorAction SilentlyContinue
            if($childText -match '^\d+$'){Stop-Process -Id ([int]$childText) -Force -ErrorAction SilentlyContinue}
            Stop-Process -Id $rootPid -Force -ErrorAction SilentlyContinue
        }
    }
    It 'Portable Runtime 指向仓库内的 .runtime' {
        $resolved=Resolve-MmtlRuntimeRoot -Path 'C:\ignored' -Portable -LauncherRoot $script:root
        $resolved | Should -Be (Join-Path $script:root '.runtime')
    }
    It 'Fabric Loom 跨盘 Runtime 使用受控目录联接且只删除联接本身' {
        $project=Join-Path $TestDrive 'fabric-project';$target=Join-Path $TestDrive 'runtime-target';$session=Join-Path $target 'session'
        New-Item -ItemType Directory -Path $project,$target|Out-Null
        Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'preserve'
        $link=New-MmtlFabricRuntimeLink -ProjectRoot $project -SessionPath $session -TargetPath $target -Name 'Client Dev'
        try {
            $item=Get-Item -LiteralPath $link -Force
            $item.LinkType | Should -Be 'Junction'
            [IO.Path]::GetFullPath([string]@($item.Target)[0]) | Should -Be ([IO.Path]::GetFullPath($target))
            (Remove-MmtlFabricRuntimeLink -ProjectRoot $project -LinkPath $link -TargetPath $target) | Should -BeTrue
            Test-Path -LiteralPath $link | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $target 'keep.txt') -Raw).Trim() | Should -Be 'preserve'
        } finally { if(Test-Path -LiteralPath $link){Remove-MmtlFabricRuntimeLink -ProjectRoot $project -LinkPath $link -TargetPath $target|Out-Null} }
    }
    It '交互向导识别项目并生成完整 Single Profile 默认值' {
        $project=New-TestModProject -Name 'wizard-fixture' -Loader Fabric -MinecraftVersion '1.21.6' -JavaMajor 21
        $global:MmtlWizardAnswers=[Collections.Generic.Queue[string]]::new();$global:MmtlWizardAnswers.Enqueue($project);1..22|ForEach-Object{$global:MmtlWizardAnswers.Enqueue('')}
        Set-Item Function:\global:Read-Host {param([string]$Prompt)$global:MmtlWizardAnswers.Dequeue()}
        try{
            $profile=Read-MmtlWizardProfile -Defaults $null
            $profile.project | Should -Be $project
            $profile.mode | Should -Be 'Single'
            $profile.players | Should -Be 1
            $profile.acceptEula | Should -BeFalse
            $profile.clientPermissionLevel | Should -Be 0
            $profile.resolution | Should -Be '1280x720'
            $profile.autoBuild | Should -BeTrue
        }finally{Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue;Remove-Variable MmtlWizardAnswers -Scope Global -ErrorAction SilentlyContinue}
    }
}
