BeforeAll {
    $script:commonRoot=Split-Path -Parent $PSScriptRoot
    $script:platformRoot=Split-Path -Parent $script:commonRoot
    Import-Module (Join-Path $script:commonRoot 'src/Platform/Platform.psm1') -Force
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        Import-Module (Join-Path $script:platformRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
        Register-MmtlWindowsPlatform -RepositoryRoot $script:platformRoot
    }elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){
        Import-Module (Join-Path $script:platformRoot 'linux/src/LinuxPlatformProvider.psm1') -Force
        Register-MmtlLinuxPlatform -RepositoryRoot $script:platformRoot
    }else{
        Import-Module (Join-Path $script:platformRoot 'macos/src/MacOSPlatformProvider.psm1') -Force
        Register-MmtlMacOSPlatform -RepositoryRoot $script:platformRoot
    }
    Import-Module (Join-Path $script:commonRoot 'src/RunManager.psm1') -Force
}

Describe '当前 Session Dedicated 端口更新' {
    It '仅更新 Session Server 的 server-port，并保留其余属性' {
        $session=Join-Path $TestDrive 'sessions/session_port'
        $server=Join-Path $session 'Server';New-Item -ItemType Directory -Path $server -Force|Out-Null
        $properties=Join-Path $server 'server.properties'
        [IO.File]::WriteAllLines($properties,@('server-ip=127.0.0.1','server-port=25565','online-mode=false'),[Text.UTF8Encoding]::new($false))
        $changed=Set-MmtlDedicatedServerPort -SessionPath $session -Port 40123
        $changed | Should -BeTrue
        $content=[IO.File]::ReadAllLines($properties)
        $content | Should -Contain 'server-port=40123'
        $content | Should -Contain 'server-ip=127.0.0.1'
        $content | Should -Contain 'online-mode=false'
    }

    It '缺少 server-port 属性时拒绝静默追加或创建配置' {
        $session=Join-Path $TestDrive 'sessions/session_invalid'
        $server=Join-Path $session 'Server';New-Item -ItemType Directory -Path $server -Force|Out-Null
        $properties=Join-Path $server 'server.properties';'online-mode=false'|Set-Content -LiteralPath $properties
        { Set-MmtlDedicatedServerPort -SessionPath $session -Port 40123 } | Should -Throw '*server-port*'
        [IO.File]::ReadAllText($properties) | Should -BeLike '*online-mode=false*'
    }
}
