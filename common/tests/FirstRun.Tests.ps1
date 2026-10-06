BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src/FirstRun.psm1') -Force
    Import-Module (Join-Path $root 'src/ProjectImport.psm1') -Force
    Import-Module (Join-Path $root 'src/Config.psm1') -Force
}

Describe '首次运行初始化' {
    BeforeEach {
        $script:firstRunRoot = Join-Path $TestDrive ('first-run-' + [guid]::NewGuid().ToString('N'))
        $script:runtime = Join-Path $script:firstRunRoot 'runtime'
        $script:config = Join-Path $script:firstRunRoot 'launcher.config.json'
    }

    It '创建本地 Runtime、空项目 Registry、Session 目录和三种示例 Profile' {
        $result = Initialize-MmtlFirstRun -ConfigPath $script:config -RuntimeRoot $script:runtime

        $result.status | Should -BeExactly 'Initialized'
        (Test-Path -LiteralPath (Join-Path $script:runtime 'project-registry.json')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:runtime 'sessions')) | Should -BeTrue
        $config = Read-MmtlConfig -Path $script:config
        @($config.profiles.PSObject.Properties.Name) | Should -Contain 'single-example'
        @($config.profiles.PSObject.Properties.Name) | Should -Contain 'integrated-lan-example'
        @($config.profiles.PSObject.Properties.Name) | Should -Contain 'dedicated-example'
        $config.defaultProfile | Should -BeExactly 'integrated-lan-example'
        $config.profiles.'integrated-lan-example'.mode | Should -BeExactly 'IntegratedLAN'
        $config.profiles.'integrated-lan-example'.acceptEula | Should -BeFalse
        $config.profiles.'dedicated-example'.acceptEula | Should -BeFalse
    }

    It '重复执行不覆盖已有用户配置与 Registry' {
        $null = Initialize-MmtlFirstRun -ConfigPath $script:config -RuntimeRoot $script:runtime
        $configBefore = [IO.File]::ReadAllText($script:config)
        $registry = Join-Path $script:runtime 'project-registry.json'
        [IO.File]::WriteAllText($registry, '{"schemaVersion":1,"projects":[]}')
        $registryBefore = [IO.File]::ReadAllText($registry)

        $result = Initialize-MmtlFirstRun -ConfigPath $script:config -RuntimeRoot $script:runtime

        $result.status | Should -BeExactly 'AlreadyInitialized'
        [IO.File]::ReadAllText($script:config) | Should -BeExactly $configBefore
        [IO.File]::ReadAllText($registry) | Should -BeExactly $registryBefore
    }

    It '已有损坏 Registry 时停止且不覆盖原始文件' {
        $null = Initialize-MmtlFirstRun -ConfigPath $script:config -RuntimeRoot $script:runtime
        $registry = Join-Path $script:runtime 'project-registry.json'
        [IO.File]::WriteAllText($registry, 'preserve-corrupt-registry')

        { Initialize-MmtlFirstRun -ConfigPath $script:config -RuntimeRoot $script:runtime } | Should -Throw '*PROJECT_REGISTRY_CORRUPT*'
        [IO.File]::ReadAllText($registry) | Should -BeExactly 'preserve-corrupt-registry'
    }
}
