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
}

Describe 'IntegratedLAN client routing' {
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
