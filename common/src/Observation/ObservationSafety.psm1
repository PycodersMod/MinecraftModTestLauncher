Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../Platform/Platform.psm1') -Force

function Test-MmtlObserverPathLink {
    param([Parameter(Mandatory)][string]$Path)
    return [bool](Test-MmtlPathLink -Path $Path)
}

function Resolve-MmtlObserverSafePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$Target,[switch]$AllowMissing)
    $session = [IO.Path]::GetFullPath($SessionPath)
    if (-not (Test-Path -LiteralPath $session -PathType Container)) { throw 'Observer Session 目录不存在。' }
    $sessionItem = Get-Item -LiteralPath $session -Force
    if (Test-MmtlObserverPathLink -Path $session) { throw 'Observer Session 不能是链接。' }
    $full = [IO.Path]::GetFullPath($Target)
    $prefix = $session.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $full.StartsWith($prefix,$comparison)) { throw 'Observer 路径越出当前 Session。' }
    $relative = [IO.Path]::GetRelativePath($session,$full); $current = $session
    foreach ($part in ($relative -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (Test-MmtlObserverPathLink -Path $current) { throw 'Observer 拒绝读取 junction 或 symlink。' }
        } elseif (-not $AllowMissing) { throw 'Observer 目标不存在。' }
    }
    return $full
}

Export-ModuleMember -Function Resolve-MmtlObserverSafePath
