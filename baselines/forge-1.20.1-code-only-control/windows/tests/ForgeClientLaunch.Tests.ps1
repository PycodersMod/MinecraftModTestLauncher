BeforeAll {
    $commonRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'common'
    Import-Module (Join-Path $commonRoot 'src/Agent/AgentProvider.psm1') -Force
    $module = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'windows/src/ForgeControl/ForgeClientLaunch.psm1'
    if (Test-Path -LiteralPath $module) { Import-Module $module -Force }
}

Describe 'Forge 1.20.1 direct client launch plan' {
    BeforeEach {
        $script:fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:gameRoot = Join-Path $fixture 'game'
        $script:session = Join-Path $fixture 'runtime/sessions/20261020T000000Z_fixture'
        $script:providerRoot = Join-Path $fixture 'provider'
        $script:versionDir = Join-Path $gameRoot 'versions/forge-test'
        $script:libraryDir = Join-Path $gameRoot 'libraries'
        $script:assetsRoot = Join-Path $gameRoot 'assets'
        New-Item -ItemType Directory -Path $versionDir,$libraryDir,$assetsRoot,$session,$providerRoot -Force | Out-Null
        $libPath='fixture/test/1/test-1.jar';$libFull=Join-Path $libraryDir ($libPath -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $libFull) -Force | Out-Null
        Set-Content -LiteralPath $libFull -Value 'library'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $nativeSource=Join-Path $fixture 'native-source';New-Item -ItemType Directory -Path $nativeSource -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $nativeSource 'native-test.dll') -Value 'native'
        $nativePath='fixture/native/1/native-1-natives-windows.jar';$nativeFull=Join-Path $libraryDir ($nativePath -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $nativeFull) -Force|Out-Null
        [IO.Compression.ZipFile]::CreateFromDirectory($nativeSource,$nativeFull)
        Set-Content -LiteralPath (Join-Path $versionDir 'forge-test.jar') -Value 'client'
        $version = @{
            id='forge-test'; mainClass='example.Bootstrap'
            assetIndex=@{id='5'}
            libraries=@(
                @{name='fixture:test:1';downloads=@{artifact=@{path=$libPath}}},
                @{name='fixture:native:1:natives-windows';downloads=@{artifact=@{path=$nativePath}}}
            )
            arguments=@{
                jvm=@('-Dfixture=true')
                game=@('--fml.forgeVersion','47.4.23','--username','${auth_player_name}','--gameDir','${game_directory}','--assetsDir','${assets_root}','--assetIndex','${assets_index_name}','--uuid','${auth_uuid}','--accessToken','${auth_access_token}')
            }
        }
        $version | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $versionDir 'forge-test.json')
        Set-Content -LiteralPath (Join-Path $providerRoot 'mmtl-agent.jar') -Value 'agent jar fixture'
        $jarHash=(Get-FileHash (Join-Path $providerRoot 'mmtl-agent.jar') -Algorithm SHA256).Hash.ToLowerInvariant()
        @{schemaVersion=1;providerId='forge-1.20.1';loaderId='Forge';minecraftVersions=@('1.20.1');agentVersion='0.1';artifact='mmtl-agent.jar';sha256=$jarHash;minJavaMajor=17;roles=@('Client','Host','Guest');capabilities=@('OfflineSessionHandshake','IntegratedServerEvents','GuestJoinObservation','OfflineIntegratedLanHost','LoopbackOnlyListener')} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $providerRoot 'agent-manifest.json')
        $roles=@(
            [pscustomobject]@{role='Host';username='Dev';runtimeJavaMajor=17;runtimeJavaPath=(Join-Path $TestDrive 'java.exe');networkRole='IntegratedServerHost'},
            [pscustomobject]@{role='Guest';username='Dev_1';runtimeJavaMajor=17;runtimeJavaPath=(Join-Path $TestDrive 'java.exe');networkRole='LoopbackClient'},
            [pscustomobject]@{role='Client';username='Solo';runtimeJavaMajor=17;runtimeJavaPath=(Join-Path $TestDrive 'java.exe');networkRole='SingleplayerClient'}
        )
        Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'common/src/TestIdentity.psm1') -Force
        $identities=Initialize-MmtlTestIdentityDirectories -SessionId '20261020T000000Z_fixture' -SessionPath $session -Roles $roles
        @{sessionId='20261020T000000Z_fixture';testIdentities=$identities} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $session 'session.json')
        $script:config=[pscustomobject]@{minecraftRoot=$gameRoot;versionDirectory='forge-test';javaPath=(Join-Path $TestDrive 'java.exe');runtimeRoot=(Join-Path $fixture 'runtime');memoryMb=1024;worldName='MMTL-Test';worldGameMode='survival';worldDifficulty='normal';worldSeed='';worldAllowCommands=$false;identityMode='OfflineTestIdentity'}
    }

    It 'builds an isolated offline Host recipe with Agent and exact managed world properties' {
        $plan=New-MmtlForgeClientLaunchPlan -Config $script:config -SessionPath $script:session -Role Host -PlayerName Dev -ProviderRoot $script:providerRoot -IntegratedLanPort 39127 -SessionToken ('a'*48)
        $plan.role | Should -BeExactly 'Host'
        $plan.playerName | Should -BeExactly 'Dev'
        $plan.arguments | Should -Contain 'example.Bootstrap'
        ($plan.arguments -join ' ') | Should -Match 'mmtl\.agent\.autoCreateWorld=true'
        ($plan.arguments -join ' ') | Should -Match 'mmtl\.agent\.integratedLanPort=39127'
        (Test-Path (Join-Path $plan.gameDirectory 'mods/mmtl-agent.jar')) | Should -BeTrue
        (Test-Path (Join-Path $plan.nativesDirectory 'native-test.dll')) | Should -BeTrue
        @($plan.classpath | Where-Object { $_ -like '*native-1-natives-windows.jar' }).Count | Should -Be 0
        @((Get-ChildItem (Join-Path $plan.gameDirectory 'mods') -File).Name) | Should -Be @('mmtl-agent.jar')
    }

    It 'builds a loopback-only Guest quick-play recipe when explicitly requested' {
        $plan=New-MmtlForgeClientLaunchPlan -Config $script:config -SessionPath $script:session -Role Guest -PlayerName Dev_1 -ProviderRoot $script:providerRoot -ExpectedLoopbackPort 39127 -SessionToken ('b'*48) -GuestConnectionMode QuickPlay
        $plan.gameDirectory | Should -BeLike '*\Dev_1'
        ($plan.arguments -join ' ') | Should -Match '127\.0\.0\.1:39127'
        ($plan.arguments -join ' ') | Should -Match 'mmtl\.agent\.expectedLoopbackPort=39127'
        $plan.arguments | Should -Not -Contain '--quickPlaySingleplayer'
    }

    It 'defaults a Guest launch to Agent connection after the main menu' {
        $plan=New-MmtlForgeClientLaunchPlan -Config $script:config -SessionPath $script:session -Role Guest -PlayerName Dev_1 -ProviderRoot $script:providerRoot -ExpectedLoopbackPort 39127 -SessionToken ('b'*48)
        $plan.guestConnectionMode | Should -BeExactly 'AgentAfterMainMenu'
        $plan.arguments | Should -Not -Contain '--quickPlayMultiplayer'
        ($plan.arguments -join ' ') | Should -Match 'mmtl\.agent\.guestConnectionMode=AgentAfterMainMenu'
    }

    It 'builds an Agent-triggered Guest recipe without QuickPlay arguments' {
        $plan=New-MmtlForgeClientLaunchPlan -Config $script:config -SessionPath $script:session -Role Guest -PlayerName Dev_1 -ProviderRoot $script:providerRoot -ExpectedLoopbackPort 39127 -SessionToken ('b'*48) -GuestConnectionMode AgentAfterMainMenu
        $plan.arguments | Should -Not -Contain '--quickPlayMultiplayer'
        ($plan.arguments -join ' ') | Should -Match 'mmtl\.agent\.guestConnectionMode=AgentAfterMainMenu'
    }

    It 'enables detailed handshake diagnostics only for an explicitly configured Guest' {
        $diagnosticConfig = $script:config.PSObject.Copy()
        $diagnosticConfig | Add-Member -NotePropertyName guestHandshakeDiagnostics -NotePropertyValue $true
        $plan = New-MmtlForgeClientLaunchPlan -Config $diagnosticConfig -SessionPath $script:session -Role Guest -PlayerName Dev_1 -ProviderRoot $script:providerRoot -ExpectedLoopbackPort 39127 -SessionToken ('b'*48) -GuestConnectionMode QuickPlay
        ($plan.arguments -join ' ') | Should -Match 'mmtl\.agent\.guestHandshakeDiagnostics=true'
        $hostPlan = New-MmtlForgeClientLaunchPlan -Config $diagnosticConfig -SessionPath $script:session -Role Host -PlayerName Dev -ProviderRoot $script:providerRoot -IntegratedLanPort 39127 -SessionToken ('b'*48)
        ($hostPlan.arguments -join ' ') | Should -Not -Match 'guestHandshakeDiagnostics'
    }

    It 'rejects native archive entries that escape the isolated Session' {
        $nativePath=Join-Path $script:libraryDir 'fixture/native/1/native-1-natives-windows.jar'
        Remove-Item -LiteralPath $nativePath -Force
        $badZip=[IO.Compression.ZipFile]::Open($nativePath,[IO.Compression.ZipArchiveMode]::Create)
        try{$entry=$badZip.CreateEntry('../outside.dll');$writer=[IO.StreamWriter]::new($entry.Open());$writer.Write('unsafe');$writer.Dispose()}finally{$badZip.Dispose()}
        { New-MmtlForgeClientLaunchPlan -Config $script:config -SessionPath $script:session -Role Host -PlayerName Dev -ProviderRoot $script:providerRoot -IntegratedLanPort 39127 -SessionToken ('a'*48) } | Should -Throw '*FORGE_NATIVE_PATH_ESCAPE*'
    }
}
