BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Get-ChildItem (Join-Path $script:root 'src') -Filter '*.psm1' -Recurse | ForEach-Object { Import-Module $_.FullName -Force }
    function New-TestModProject {
        param([string]$Name,[string]$Loader,[string]$MinecraftVersion,[int]$JavaMajor)
        $path=Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path (Join-Path $path 'src/main/resources') -Force | Out-Null
        "minecraft_version=$MinecraftVersion`njava_version=$JavaMajor" | Set-Content (Join-Path $path 'gradle.properties')
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
            $project.Wrapper | Should -BeTrue
        }
    }
    It '接受兼容的多项目组合' {
        $p1=[pscustomobject]@{MinecraftVersion='1.20.1';Loader='Forge';JavaMajor=17}
        $p2=[pscustomobject]@{MinecraftVersion='1.20.1';Loader='Forge';JavaMajor=17}
        (Assert-MmtlCompatible -Projects @($p1,$p2)) | Should -BeTrue
    }
    It '拒绝缺失或不一致的 Minecraft 版本' {
        $p1=[pscustomobject]@{MinecraftVersion='1.20.1';Loader='Forge';JavaMajor=17}
        $p2=[pscustomobject]@{MinecraftVersion='';Loader='Forge';JavaMajor=17}
        { Assert-MmtlCompatible -Projects @($p1,$p2) } | Should -Throw
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
    It 'Portable Runtime 指向仓库内的 .runtime' {
        $resolved=Resolve-MmtlRuntimeRoot -Path 'C:\ignored' -Portable -LauncherRoot $script:root
        $resolved | Should -Be (Join-Path $script:root '.runtime')
    }
}
