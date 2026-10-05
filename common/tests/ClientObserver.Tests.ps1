BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
    Import-Module (Join-Path $source 'Observation/AuthenticationObserver.psm1') -Force
    Import-Module (Join-Path $source 'Observation/ClientObserver.psm1') -Force
    Import-Module (Join-Path $source 'Observation/JavaRuntimeObserver.psm1') -Force
    Import-Module (Join-Path $source 'Adapters/Forge.psm1') -Force
}

Describe 'Client Runtime Log Observer' {
    BeforeEach {
        $javaPath = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { 'C:\Java\bin\java.exe' } else { '/fixture-jdk/bin/java' }
        $script:session = Join-Path $TestDrive ('session_client_' + [guid]::NewGuid().ToString('N'))
        $script:runtime = Join-Path $session 'Client-Dev'
        New-Item -ItemType Directory -Path (Join-Path $runtime 'logs') -Force | Out-Null
        [IO.Path]::GetFileName($session) | Set-Content (Join-Path $runtime 'mmtl-session.id') -NoNewline
        $log = Join-Path $runtime 'logs/latest.log'
        '[Render thread/INFO]: Setting user: Dev' | Set-Content $log
        @([pscustomobject]@{PID=11;Role='Client';Username='Dev';StartIdentity='client-start';RuntimeDirectory=$runtime;StatePath=(Join-Path $session 'process-11.exit.json')}) | ConvertTo-Json | Set-Content (Join-Path $session 'pids.json')
        [pscustomobject]@{schemaVersion=1;project=[pscustomobject]@{loader=[pscustomobject]@{id='Forge'};minecraftId='1.20.1'};runtimeJava=[pscustomobject]@{bindingMode='Direct';resolution=[pscustomobject]@{javaPath=$javaPath}};buildJava=[pscustomobject]@{resolution=[pscustomobject]@{javaPath=$javaPath}}} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $session 'execution-plan.json')
        $script:lookup = { param($processId) [pscustomobject]@{ProcessId=$processId;StartIdentity='client-start';Executable=$javaPath;CommandLine='java cpw.mods.bootstraplauncher.BootstrapLauncher'} }.GetNewClosure()
        $script:identity = { param($process,$entry) $process.StartIdentity -ceq $entry.StartIdentity }
    }

    It '身份、Session marker 和 adapter init marker 全部匹配时才记录正式候选' {
        $result = Invoke-MmtlClientObserver -SessionPath $session -MarkerHints (Get-MmtlForgeClientMarkerHints -MinecraftVersion '1.20.1') -ProcessLookup $lookup -IdentityCheck $identity
        $result.clients[0].initDetected | Should -BeTrue
        $result.clients[0].validationEligible | Should -BeTrue
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'CLIENT_LAUNCH_VERIFIED'
    }

    It '缺少当前 Session marker 时不得生成 verified 事件' {
        Remove-Item (Join-Path $runtime 'mmtl-session.id')
        $result = Invoke-MmtlClientObserver -SessionPath $session -MarkerHints (Get-MmtlForgeClientMarkerHints) -ProcessLookup $lookup -IdentityCheck $identity
        $result.clients[0].validationEligible | Should -BeFalse
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Not -Contain 'CLIENT_LAUNCH_VERIFIED'
    }

    It '独立报告主菜单标记，不把客户端初始化等同于主菜单' {
        $hints = @(
            @{eventCode='CLIENT_INIT_DETECTED';pattern='Setting user:';description='客户端初始化标记。'},
            @{eventCode='CLIENT_MAIN_MENU_DETECTED';pattern='Main menu initialized';description='主菜单标记。'}
        )
        '[Render thread/INFO]: Main menu initialized' | Add-Content (Join-Path $runtime 'logs/latest.log')
        $result = Invoke-MmtlClientObserver -SessionPath $session -MarkerHints $hints -ProcessLookup $lookup -IdentityCheck $identity
        $result.clients[0].initDetected | Should -BeTrue
        $result.clients[0].mainMenuDetected | Should -BeTrue
    }

    It 'rehearsal 标记永远不能生成正式验证事件' {
        $result = Invoke-MmtlClientObserver -SessionPath $session -MarkerHints (Get-MmtlForgeClientMarkerHints) -ProcessLookup $lookup -IdentityCheck $identity -Rehearsal
        $result.clients[0].validationEligible | Should -BeFalse
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Not -Contain 'CLIENT_LAUNCH_VERIFIED'
    }

    It '仅读当前登记 RuntimeDirectory 的日志，不跟随链接路径' {
        $outside = Join-Path $TestDrive 'outside-runtime'
        New-Item -ItemType Directory -Path (Join-Path $outside 'logs') -Force | Out-Null
        '[Render thread/INFO]: Setting user: Wrong' | Set-Content (Join-Path $outside 'logs/latest.log')
        (Get-Content (Join-Path $runtime 'logs/latest.log')) | Should -Not -BeNullOrEmpty
        $result = Invoke-MmtlClientObserver -SessionPath $session -MarkerHints (Get-MmtlForgeClientMarkerHints) -ProcessLookup $lookup -IdentityCheck $identity
        $result.clients[0].validationEligible | Should -BeTrue
    }
}
