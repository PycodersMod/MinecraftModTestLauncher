BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/GradleRunner.psm1') -Force
}

Describe 'Platform Gradle Wrapper' {
    It 'selects only the project wrapper and returns a POSIX shell invocation when needed' {
        $root = $TestDrive
        $provider = Get-MmtlPlatformProvider
        $wrapper = Join-Path $root $provider.GradleWrapper
        Set-Content -LiteralPath $wrapper -Value 'wrapper fixture'
        $project = [pscustomobject]@{Root=$root}
        $command = Get-MmtlGradleCommand -Project $project -Task build
        if ($provider.OS -eq 'Windows') { $command.File | Should -Be $wrapper }
        else { $command.File | Should -Be 'sh'; $command.Arguments[0] | Should -Be $wrapper }
        $command.Arguments | Should -Contain 'build'
    }

    It '从 Wrapper properties 识别现代 Gradle 版本以禁用启动配置缓存' {
        $root=Join-Path $TestDrive 'wrapper-modern'
        $wrapperDirectory=Join-Path $root 'gradle/wrapper'
        New-Item -ItemType Directory -Path $wrapperDirectory -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $wrapperDirectory 'gradle-wrapper.properties') -Value 'distributionUrl=https\://services.gradle.org/distributions/gradle-9.7.1-bin.zip'
        $project=[pscustomobject]@{Root=$root;BuildSystem=[pscustomobject]@{version=$null}}

        Get-MmtlGradleRunCompatibilityArguments -Project $project | Should -Contain '--no-configuration-cache'
    }

    It '从 Wrapper properties 识别旧 Gradle 且不传入不支持的参数' {
        $root=Join-Path $TestDrive 'wrapper-legacy'
        $wrapperDirectory=Join-Path $root 'gradle/wrapper'
        New-Item -ItemType Directory -Path $wrapperDirectory -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $wrapperDirectory 'gradle-wrapper.properties') -Value 'distributionUrl=https\://services.gradle.org/distributions/gradle-4.10.3-bin.zip'
        $project=[pscustomobject]@{Root=$root;BuildSystem=[pscustomobject]@{version=$null}}

        Get-MmtlGradleRunCompatibilityArguments -Project $project | Should -Not -Contain '--no-configuration-cache'
    }
}

Describe 'IntegratedLAN client routing' {
    It '仅在 Gradle 6.6 及以上的游戏启动任务禁用配置缓存' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.21.8';BuildSystem=[pscustomobject]@{id='GradleWrapper';version='9.7.1'}}
        $profile=[pscustomobject]@{gameArgs=@();jvmArgs=@();resolution='Auto';memoryMb=0;hostMemoryMb=0;clientMemoryMb=0}

        $plan=New-MmtlGradleRunPlan -Project $project -Mode Dedicated -RuntimeRoot $TestDrive -Role Server -Profile $profile

        $plan.Arguments | Should -Contain '--no-configuration-cache'
    }

    It '旧版 Gradle 不接收尚未支持的配置缓存参数' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.12.2';BuildSystem=[pscustomobject]@{id='GradleWrapper';version='4.10.3'}}
        $profile=[pscustomobject]@{gameArgs=@();jvmArgs=@();resolution='Auto';memoryMb=0;hostMemoryMb=0;clientMemoryMb=0}

        $plan=New-MmtlGradleRunPlan -Project $project -Mode Single -RuntimeRoot $TestDrive -Role Client -Username Tester -Profile $profile

        $plan.Arguments | Should -Not -Contain '--no-configuration-cache'
    }

    It 'Gradle 2.0 的运行计划不传入尚未支持的 Console 参数' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.7.10';BuildSystem=[pscustomobject]@{id='GradleWrapper';version='2.0'}}
        $profile=[pscustomobject]@{gameArgs=@();jvmArgs=@();resolution='Auto';memoryMb=0;hostMemoryMb=0;clientMemoryMb=0}

        $plan=New-MmtlGradleRunPlan -Project $project -Mode Single -RuntimeRoot $TestDrive -Role Client -Username Tester -Profile $profile

        $plan.Arguments | Should -Not -Contain '--console=plain'
    }

    It '把 Session Agent JVM binding 编入受控 Gradle 计划且不会包含 session token' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.20.1'}
        $profile=[pscustomobject]@{gameArgs=@();jvmArgs=@();resolution='Auto';memoryMb=0;hostMemoryMb=0;clientMemoryMb=0}
        $agentArgs=@('-Dmmtl.agent.role=Guest','-Dmmtl.agent.expectedLoopbackPort=25565','-Dmmtl.agent.sessionTokenFile=C:/session/agent/token.txt')
        $plan=New-MmtlGradleRunPlan -Project $project -Mode IntegratedLAN -RuntimeRoot $TestDrive -Role Client -Username Guest01 -Port 25565 -Profile $profile -AgentJvmArguments $agentArgs
        $plan.JvmArguments | Should -Contain '-Dmmtl.agent.role=Guest'
        $plan.JvmArguments | Should -Contain '-Dmmtl.agent.expectedLoopbackPort=25565'
        $plan.Arguments | Should -Contain ("-PpycodersJavaArgsB64="+(ConvertTo-MmtlArgumentPayload ($profile.jvmArgs+$agentArgs)))
        ($plan.Arguments -join ' ') | Should -Not -Match 'raw-session-token'
        {New-MmtlGradleRunPlan -Project $project -Mode IntegratedLAN -RuntimeRoot $TestDrive -Role Client -Username Guest01 -Port 25565 -Profile $profile -AgentJvmArguments @('-Dmmtl.agent.token=raw-session-token')} | Should -Throw '*AGENT_JVM_ARGUMENT_INVALID*'
    }

    It '保留受管身份名并拒绝用户游戏参数覆盖离线身份或认证字段' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.21.11';BuildSystem=[pscustomobject]@{version='9.7.1'}}
        $profile=[pscustomobject]@{gameArgs=@();jvmArgs=@();resolution='Auto';memoryMb=0;hostMemoryMb=0;clientMemoryMb=0}
        $plan=New-MmtlGradleRunPlan -Project $project -Mode Single -RuntimeRoot $TestDrive -Role Client -Username 'MMTL_Host' -Profile $profile
        $plan.Arguments | Should -Contain '-PpycodersUsername=MMTL_Host'

        foreach($reserved in @('--username','--uuid','--accessToken','--userType')){
            $profile.gameArgs=@($reserved,'user-value')
            { New-MmtlGradleRunPlan -Project $project -Mode Single -RuntimeRoot $TestDrive -Role Client -Username 'MMTL_Host' -Profile $profile } | Should -Throw '*GAME_ARGUMENT_IDENTITY_OVERRIDE_REJECTED*'
        }
    }

    It 'builds Quick Play args for the selected IPv4 loopback port only' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.20.1'}
        $profile=[pscustomobject]@{gameArgs=@();jvmArgs=@();resolution='Auto';memoryMb=0;hostMemoryMb=0;clientMemoryMb=0}
        $plan=New-MmtlGradleRunPlan -Project $project -Mode IntegratedLAN -RuntimeRoot $TestDrive -Role Client -Username Guest01 -Port 25565 -Profile $profile
        $plan.GameArguments | Should -Contain '--quickPlayMultiplayer'
        $plan.GameArguments | Should -Contain '127.0.0.1:25565'
        { New-MmtlGradleRunPlan -Project $project -Mode IntegratedLAN -RuntimeRoot $TestDrive -Role Client -Username Guest01 -Port 0 -Profile $profile } | Should -Throw '*联机客户端必须提供有效服务端口*'
        $profile.gameArgs=@('--quickPlayMultiplayer','example.invalid')
        { New-MmtlGradleRunPlan -Project $project -Mode IntegratedLAN -RuntimeRoot $TestDrive -Role Client -Username Guest01 -Port 25565 -Profile $profile } | Should -Throw '*INTEGRATED_LAN_EXTERNAL_ENDPOINT_OVERRIDE_REJECTED*'
        $profile.gameArgs=@('--server','example.invalid','--port','25565')
        { New-MmtlGradleRunPlan -Project $project -Mode IntegratedLAN -RuntimeRoot $TestDrive -Role Client -Username Guest01 -Port 25565 -Profile $profile } | Should -Throw '*INTEGRATED_LAN_EXTERNAL_ENDPOINT_OVERRIDE_REJECTED*'
    }
}
