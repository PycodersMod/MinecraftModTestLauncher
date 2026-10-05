BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'PortManager.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
    Import-Module (Join-Path $source 'Observation/LanObserver.psm1') -Force
}

Describe 'IntegratedLAN 当前 Session Host Observer' {
    It '只从当前 Host 的登记日志提取 LAN port' {
        $session = Join-Path $TestDrive ('session_lan_' + [guid]::NewGuid().ToString('N'))
        $runtime = Join-Path $session 'Host-Dev'; New-Item -ItemType Directory -Path (Join-Path $runtime 'logs') -Force | Out-Null
        '[Render thread/INFO]: Local game hosted on port 54321' | Set-Content (Join-Path $runtime 'logs/latest.log')
        [IO.Path]::GetFileName($session) | Set-Content (Join-Path $runtime 'mmtl-session.id') -NoNewline
        @([pscustomobject]@{PID=12;Role='Host';Username='Dev';StartIdentity='host-start';RuntimeDirectory=$runtime}) | ConvertTo-Json | Set-Content (Join-Path $session 'pids.json')
        $lookup = { param($processId) [pscustomobject]@{ProcessId=$processId;StartIdentity='host-start'} }
        $result = Invoke-MmtlLanObserver -SessionPath $session -ProcessLookup $lookup -IdentityCheck {param($process,$entry) $process.StartIdentity -ceq $entry.StartIdentity}
        $result.hosts[0].port | Should -Be 54321
        $result.hosts[0].sourceRole | Should -Be 'Host'
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'LAN_PORT_PUBLISHED'
    }

    It 'Session marker 缺失时忽略日志中的 port' {
        $session = Join-Path $TestDrive ('session_lan_' + [guid]::NewGuid().ToString('N'))
        $runtime = Join-Path $session 'Host-Dev'; New-Item -ItemType Directory -Path (Join-Path $runtime 'logs') -Force | Out-Null
        '[Render thread/INFO]: Local game hosted on port 54321' | Set-Content (Join-Path $runtime 'logs/latest.log')
        @([pscustomobject]@{PID=12;Role='Host';StartIdentity='host-start';RuntimeDirectory=$runtime}) | ConvertTo-Json | Set-Content (Join-Path $session 'pids.json')
        $lookup = { param($processId) [pscustomobject]@{ProcessId=$processId;StartIdentity='host-start'} }
        $result = Invoke-MmtlLanObserver -SessionPath $session -ProcessLookup $lookup -IdentityCheck {param($process,$entry) $process.StartIdentity -ceq $entry.StartIdentity}
        $result.hosts[0].port | Should -BeNullOrEmpty
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Not -Contain 'LAN_PORT_PUBLISHED'
    }
}
