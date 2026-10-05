BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Observation/RuntimeEvents.psm1'
    Import-Module $modulePath -Force
}

Describe 'Runtime Event 契约' {
    It '生成包含 Session、角色、进程身份、时间、来源和稳定事件码的事件' {
        $event = New-MmtlRuntimeEvent -SessionId 'session_01' -Role 'Client' -ProcessId 42 -ProcessIdentity 'start-42' -SourceType 'RuntimeLog' -EventCode 'CLIENT_INIT_DETECTED'
        $event.schemaVersion | Should -Be 1
        $event.sessionId | Should -Be 'session_01'
        $event.role | Should -Be 'Client'
        $event.pid | Should -Be 42
        $event.processIdentity | Should -Be 'start-42'
        $event.timestampUtc | Should -Match 'Z$'
        $event.sourceType | Should -Be 'RuntimeLog'
        $event.eventCode | Should -Be 'CLIENT_INIT_DETECTED'
    }

    It '拒绝未知事件码、非法 Session 标识与负 PID' {
        { New-MmtlRuntimeEvent -SessionId '../outside' -Role Client -ProcessId 1 -ProcessIdentity p1 -SourceType Observer -EventCode CLIENT_INIT_DETECTED } | Should -Throw
        { New-MmtlRuntimeEvent -SessionId session_01 -Role Client -ProcessId -1 -ProcessIdentity p1 -SourceType Observer -EventCode CLIENT_INIT_DETECTED } | Should -Throw
        { New-MmtlRuntimeEvent -SessionId session_01 -Role Client -ProcessId 1 -ProcessIdentity p1 -SourceType Observer -EventCode MADE_UP } | Should -Throw
    }

    It '接受 Dedicated 演练中已握手的 synthetic guest 事件码' {
        $event = New-MmtlRuntimeEvent -SessionId session_01 -Role Client -ProcessId 1 -ProcessIdentity p1 -SourceType Rehearsal -EventCode REHEARSAL_GUEST_CONNECTED
        $event.eventCode | Should -Be 'REHEARSAL_GUEST_CONNECTED'
    }

    It '接受自动端口冲突后继续重试的演练事件码' {
        (New-MmtlRuntimeEvent -SessionId session_01 -Role Launcher -ProcessId 1 -ProcessIdentity p1 -SourceType Rehearsal -EventCode REHEARSAL_PORT_RETRY).eventCode | Should -Be 'REHEARSAL_PORT_RETRY'
    }

    It '只允许安全摘要字段并剔除凭据与本机路径' {
        $syntheticToken = 'ghp_' + ('x' * 32)
        $separator = [string][char]92
        $syntheticPath = 'C:' + $separator + 'Users' + $separator + 'Alice' + $separator + 'latest.log'
        $event = New-MmtlRuntimeEvent -SessionId session_01 -Role Client -ProcessId 1 -ProcessIdentity p1 -SourceType Observer -EventCode AUTH_REQUIRED -Summary "token=$syntheticToken at $syntheticPath"
        $event.summary | Should -Not -Match 'ghp_|C:\\Users\\Alice'
        $event.PSObject.Properties.Name | Should -Not -Contain 'rawLog'
    }
}
