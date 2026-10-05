BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'Observation/ObservationSafety.psm1') -Force
}

Describe 'Observer 路径安全边界' {
    It '拒绝 Session 外路径并允许 Session 内新文件' {
        $session = Join-Path $TestDrive ('session_safe_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $session -Force | Out-Null
        { Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $TestDrive 'outside.txt') } | Should -Throw
        (Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $session 'logs/latest.log') -AllowMissing) | Should -BeLike "$session*"
    }

    It '拒绝目标路径中的 junction 或 symlink' {
        $session = Join-Path $TestDrive ('session_link_' + [guid]::NewGuid().ToString('N'))
        $outside = Join-Path $TestDrive ('outside_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $session,$outside -Force | Out-Null
        $link = Join-Path $session 'linked'
        [IO.Directory]::CreateSymbolicLink($link, $outside) | Out-Null
        { Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $link 'latest.log') -AllowMissing } | Should -Throw '*symlink*'
    }
}
