BeforeAll {
    $script:baselineRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $module = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/ForgeControl/ForgeControlConfig.psm1'
    if (Test-Path -LiteralPath $module) { Import-Module $module -Force }
}

Describe 'Forge 1.20.1 control configuration' {
    It 'defaults to one isolated offline client and does not request LAN' {
        $configPath = Join-Path $TestDrive 'single.json'
        @{
            schemaVersion = 1
            target = @{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
            javaPath = (Join-Path $TestDrive 'java.exe')
            minecraftRoot = (Join-Path $TestDrive 'game')
            versionDirectory = 'forge-test'
            runtimeRoot = (Join-Path $TestDrive 'runtime')
            clientCount = 1
            players = @('Dev')
            worldName = 'MMTL-Test'
            lanEnabled = $false
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath

        $resolved = Resolve-MmtlForgeControlConfig -ConfigPath $configPath
        $resolved.clientCount | Should -Be 1
        $resolved.players | Should -Be @('Dev')
        $resolved.lanEnabled | Should -BeFalse
        $resolved.identityMode | Should -BeExactly 'OfflineTestIdentity'
        $resolved.guestConnectionMode | Should -BeExactly 'AgentAfterMainMenu'
        $resolved.guestHandshakeDiagnostics | Should -BeFalse
    }

    It 'accepts an explicit Guest connection mode override' {
        $configPath = Join-Path $TestDrive 'guest-mode.json'
        @{
            schemaVersion = 1
            target = @{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
            javaPath = (Join-Path $TestDrive 'java.exe')
            minecraftRoot = (Join-Path $TestDrive 'game')
            versionDirectory = 'forge-test'
            runtimeRoot = (Join-Path $TestDrive 'runtime')
            clientCount = 2
            players = @('Dev','Dev_1')
            worldName = 'MMTL-Test'
            guestHandshakeDiagnostics = $true
            lanEnabled = $true
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath

        $resolved = Resolve-MmtlForgeControlConfig -ConfigPath $configPath -GuestConnectionMode AgentAfterMainMenu
        $resolved.guestConnectionMode | Should -BeExactly 'AgentAfterMainMenu'
        $resolved.guestHandshakeDiagnostics | Should -BeTrue
        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath -GuestConnectionMode 'Invalid' } | Should -Throw
    }

    It 'lets explicit client count and names override the file and turns LAN on for multi-client' {
        $configPath = Join-Path $TestDrive 'override.json'
        $file = @{
            schemaVersion = 1
            target = @{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
            javaPath = (Join-Path $TestDrive 'java.exe')
            minecraftRoot = (Join-Path $TestDrive 'game')
            versionDirectory = 'forge-test'
            runtimeRoot = (Join-Path $TestDrive 'runtime')
            clientCount = 1
            players = @('Dev')
            worldName = 'MMTL-Test'
            lanEnabled = $false
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        $resolved = Resolve-MmtlForgeControlConfig -ConfigPath $configPath -ClientCount 3 -PlayerNames @('Dev','Dev_1','Dev_2')
        $resolved.clientCount | Should -Be 3
        $resolved.players | Should -Be @('Dev','Dev_1','Dev_2')
        $resolved.lanEnabled | Should -BeTrue
    }

    It 'generates distinct default names when a command-line count overrides a profile with fewer players' {
        $configPath = Join-Path $TestDrive 'single-profile-count-override.json'
        @{
            schemaVersion = 1
            target = @{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
            javaPath = (Join-Path $TestDrive 'java.exe')
            minecraftRoot = (Join-Path $TestDrive 'game')
            versionDirectory = 'forge-test'
            runtimeRoot = (Join-Path $TestDrive 'runtime')
            clientCount = 1
            players = @('Dev')
            worldName = 'MMTL-Test'
            lanEnabled = $false
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath

        $resolved = Resolve-MmtlForgeControlConfig -ConfigPath $configPath -ClientCount 2
        $resolved.clientCount | Should -Be 2
        $resolved.players | Should -Be @('Dev','Dev_1')
        $resolved.lanEnabled | Should -BeTrue
    }

    It 'rejects unsupported target, duplicate names, and LAN for a single client' {
        $configPath = Join-Path $TestDrive 'invalid.json'
        $base = @{
            schemaVersion = 1
            target = @{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
            javaPath = (Join-Path $TestDrive 'java.exe')
            minecraftRoot = (Join-Path $TestDrive 'game')
            versionDirectory = 'forge-test'
            runtimeRoot = (Join-Path $TestDrive 'runtime')
            clientCount = 2
            players = @('Dev','Dev_1')
            worldName = 'MMTL-Test'
        }
        $base.target.loaderVersion = '47.2.0'
        $base | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath } | Should -Throw '*TARGET_UNSUPPORTED*'

        $base.target.loaderVersion = '47.4.23'
        $base.players = @('Dev','Dev')
        $base | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath } | Should -Throw '*PLAYER_NAME_DUPLICATE*'

        $base.clientCount = 1; $base.players = @('Dev'); $base.lanEnabled = $true
        $base | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath } | Should -Throw '*SINGLE_CLIENT_LAN_FORBIDDEN*'
    }

    It 'requires Java, Minecraft root, and a version folder name with specific messages' {
        $configPath = Join-Path $TestDrive 'blank-local-paths.json'
        $config = @{
            schemaVersion = 1
            target = @{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
            javaMajor = 17; javaPath = ''; minecraftRoot = ''; versionDirectory = ''
            clientCount = 1; players = @('Dev'); worldName = 'MMTL-Test'; lanEnabled = $false
        }
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath } | Should -Throw '*CONFIG_JAVA_PATH_REQUIRED*'
        $config.javaPath = Join-Path $TestDrive 'java.exe'
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath } | Should -Throw '*CONFIG_MINECRAFT_ROOT_REQUIRED*'
        $config.minecraftRoot = Join-Path $TestDrive 'game'
        $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath
        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath } | Should -Throw '*CONFIG_VERSION_DIRECTORY_REQUIRED*'
    }

    It 'resolves profile and runtime paths from the baseline root, independent of the current directory' {
        $resolved = Resolve-MmtlForgeControlConfig -ConfigPath 'config/forge-1.20.1-default.json' -RootPath $script:baselineRoot -JavaPath (Join-Path $TestDrive 'java.exe') -MinecraftRoot (Join-Path $TestDrive 'game') -VersionDirectory 'forge-test'
        $resolved.runtimeRoot | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:baselineRoot 'runtime')))
        $resolved.reportRoot | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:baselineRoot 'runtime/reports')))
        $resolved.clientCount | Should -Be 1
        $resolved.lanEnabled | Should -BeFalse
    }

    It 'keeps all published profiles valid JSON with blank machine paths and the expected client counts' {
        $profiles = @(
            @{ file = 'forge-1.20.1-default.json'; count = 1; lan = $false },
            @{ file = 'forge-1.20.1-two-client.json'; count = 2; lan = $true },
            @{ file = 'forge-1.20.1-three-client.json'; count = 3; lan = $true }
        )
        foreach ($item in $profiles) {
            $path = Join-Path $script:baselineRoot (Join-Path 'config' $item.file)
            $profile = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            $profile.javaPath | Should -BeExactly ''
            $profile.minecraftRoot | Should -BeExactly ''
            $profile.versionDirectory | Should -BeExactly ''
            $profile.clientCount | Should -Be $item.count
            $profile.lanEnabled | Should -Be $item.lan
            @($profile.players).Count | Should -Be $item.count
        }
    }
}
