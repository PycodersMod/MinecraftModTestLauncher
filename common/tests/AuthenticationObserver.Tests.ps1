BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
    Import-Module (Join-Path $source 'Observation/AuthenticationObserver.psm1') -Force
}

Describe '认证状态只分类不修复' {
    It '区分登录需求和失效会话且不返回原始文本' {
        $session = Join-Path $TestDrive ('session_auth_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $session -Force | Out-Null
        $syntheticToken = 'ghp_' + ('x' * 32)
        $invalid = Get-MmtlAuthenticationObservation -SessionPath $session -SessionId ([IO.Path]::GetFileName($session)) -Role Client -ProcessId 9 -ProcessIdentity id9 -Text "multiplayer.authentication.invalid_session token=$syntheticToken"
        $required = Get-MmtlAuthenticationObservation -SessionPath $session -SessionId ([IO.Path]::GetFileName($session)) -Role Client -ProcessId 9 -ProcessIdentity id9 -Text 'login required'
        $invalid.code | Should -Be 'INVALID_SESSION'
        $required.code | Should -Be 'AUTH_REQUIRED'
        $invalid.PSObject.Properties.Name | Should -Not -Contain 'text'
        $event = Get-MmtlRuntimeEvents -SessionPath $session
        $event.summary -join ' ' | Should -Not -Match 'ghp_|token='
    }

    It '未检测到认证状态时不生成认证事件' {
        $session = Join-Path $TestDrive ('session_auth_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $session -Force | Out-Null
        $result = Get-MmtlAuthenticationObservation -SessionPath $session -SessionId ([IO.Path]::GetFileName($session)) -Role Client -ProcessId 9 -ProcessIdentity id9 -Text 'normal log line'
        $result.code | Should -BeNullOrEmpty
        (Get-MmtlRuntimeEvents -SessionPath $session).Count | Should -Be 0
    }
}
