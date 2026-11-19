BeforeAll {
    $module = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/ForgeControl/ForgeControlConfig.psm1'
    if (Test-Path -LiteralPath $module) { Import-Module $module -Force }
}

Describe 'Forge 1.20.1 control configuration' {
    It 'defaults to one isolated offline client and does not request LAN' {
        $configPath = Join-Path $TestDrive 'single.json'
        @{
            schemaVersion = 1
            target = @{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
            javaPath = 'C:\Java\17\bin\java.exe'
            minecraftRoot = 'C:\Game'
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
        $resolved.externalModJars | Should -Be @()
    }

    It 'resolves explicit external Mod JAR paths relative to the selected profile' {
        $profileDirectory=Join-Path $TestDrive 'profiles'
        $modDirectory=Join-Path $profileDirectory 'mods'
        New-Item -ItemType Directory -Path $modDirectory -Force | Out-Null
        $modJar=Join-Path $modDirectory 'fixture-mod.jar'
        [IO.File]::WriteAllBytes($modJar,[byte[]](0x50,0x4b,0x03,0x04))
        $configPath=Join-Path $profileDirectory 'with-mods.json'
        @{
            schemaVersion=1
            target=@{minecraftVersion='1.20.1';loader='Forge';loaderVersion='47.4.23'}
            javaPath='C:\Java\17\bin\java.exe'
            minecraftRoot='C:\Game'
            runtimeRoot=(Join-Path $TestDrive 'runtime')
            clientCount=1
            players=@('Dev')
            worldName='MMTL-Test'
            lanEnabled=$false
            externalModJars=@('mods/fixture-mod.jar')
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath

        $resolved=Resolve-MmtlForgeControlConfig -ConfigPath $configPath

        $resolved.externalModJars | Should -Be @([IO.Path]::GetFullPath($modJar))
    }

    It 'preserves explicit test JVM properties from a profile' {
        $configPath=Join-Path $TestDrive 'test-jvm-properties.json'
        @{
            schemaVersion=1
            target=@{minecraftVersion='1.20.1';loader='Forge';loaderVersion='47.4.23'}
            javaPath='C:\Java\17\bin\java.exe'
            minecraftRoot='C:\Game'
            runtimeRoot=(Join-Path $TestDrive 'runtime')
            clientCount=1
            players=@('Dev')
            worldName='MMTL-Test'
            lanEnabled=$false
            testJvmProperties=@{
                'taczintetra.dev_automation'='true'
                'taczintetra.dev_dual_hand_setup_only'='true'
                'taczintetra.dev_body_visual_family'='pistol'
            }
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath

        $resolved=Resolve-MmtlForgeControlConfig -ConfigPath $configPath

        $resolved.testJvmProperties.'taczintetra.dev_automation' | Should -BeExactly 'true'
        $resolved.testJvmProperties.'taczintetra.dev_dual_hand_setup_only' | Should -BeExactly 'true'
        $resolved.testJvmProperties.'taczintetra.dev_body_visual_family' | Should -BeExactly 'pistol'
    }

    It 'rejects malformed test JVM property names and values' {
        $configPath=Join-Path $TestDrive 'invalid-test-jvm-properties.json'
        @{
            schemaVersion=1
            target=@{minecraftVersion='1.20.1';loader='Forge';loaderVersion='47.4.23'}
            javaPath='C:\Java\17\bin\java.exe'
            minecraftRoot='C:\Game'
            runtimeRoot=(Join-Path $TestDrive 'runtime')
            clientCount=1
            players=@('Dev')
            worldName='MMTL-Test'
            lanEnabled=$false
            testJvmProperties=@{'-javaagent'='fixture.jar'}
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath

        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath } | Should -Throw '*TEST_JVM_PROPERTY_NAME_INVALID*'
    }

    It 'does not allow a profile to override MMTL Agent security properties' {
        $configPath=Join-Path $TestDrive 'reserved-test-jvm-properties.json'
        @{
            schemaVersion=1
            target=@{minecraftVersion='1.20.1';loader='Forge';loaderVersion='47.4.23'}
            javaPath='C:\Java\17\bin\java.exe'
            minecraftRoot='C:\Game'
            runtimeRoot=(Join-Path $TestDrive 'runtime')
            clientCount=1
            players=@('Dev')
            worldName='MMTL-Test'
            lanEnabled=$false
            testJvmProperties=@{'mmtl.agent.sessionTokenFile'='external.txt'}
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath

        { Resolve-MmtlForgeControlConfig -ConfigPath $configPath } | Should -Throw '*TEST_JVM_PROPERTY_RESERVED*'
    }

    It 'accepts an explicit Guest connection mode override' {
        $configPath = Join-Path $TestDrive 'guest-mode.json'
        @{
            schemaVersion = 1
            target = @{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
            javaPath = 'C:\Java\17\bin\java.exe'
            minecraftRoot = 'C:\Game'
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
            javaPath = 'C:\Java\17\bin\java.exe'
            minecraftRoot = 'C:\Game'
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
            javaPath = 'C:\Java\17\bin\java.exe'
            minecraftRoot = 'C:\Game'
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
            javaPath = 'C:\Java\17\bin\java.exe'
            minecraftRoot = 'C:\Game'
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
}
