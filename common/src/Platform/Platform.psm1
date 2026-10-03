function Set-MmtlPlatformProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Provider)
    if ($Provider.OS -notin @('Windows','Linux','MacOS')) { throw '平台提供器的 OS 标识无效。' }
    if ($Provider.Arch -notin @('x64','ARM64')) { throw '平台提供器的 CPU 架构无效。' }
    foreach ($name in @('PathComparison','DefaultRuntimeRoot','JavaExecutable','JavacExecutable','GradleWrapper','WindowManagement','ProcessManagement','FabricRuntimeLink')) {
        if (-not $Provider.PSObject.Properties[$name]) { throw "平台提供器缺少必需字段：$name" }
    }
    $global:MmtlPlatformProvider = $Provider
}

function Get-MmtlPlatformProvider {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $global:MmtlPlatformProvider) { throw '尚未由平台入口注册平台提供器。' }
    $provider = $global:MmtlPlatformProvider
    if ($Path -and $provider.GetPathComparison) { $copy=$provider.PSObject.Copy();$copy.PathComparison=& $provider.GetPathComparison $Path;return $copy }
    return $provider
}

function Get-MmtlPlatformDisplayName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Windows','Linux','MacOS')][string]$OS)
    if ($OS -eq 'MacOS') { return 'macOS' }
    return $OS
}

function Get-MmtlCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-MmtlPathLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool](($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType)
}

function Test-MmtlPlatformPathInsideRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Target)
    $r=Get-MmtlCanonicalPath -Path $Root; $t=Get-MmtlCanonicalPath -Path $Target; $provider=Get-MmtlPlatformProvider -Path $r
    if ($t.Equals($r,[StringComparison]$provider.PathComparison)) { return $true }
    $relative=[IO.Path]::GetRelativePath($r,$t)
    if (-not ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]$provider.PathComparison) -or $relative.StartsWith('..'+[IO.Path]::AltDirectorySeparatorChar,[StringComparison]$provider.PathComparison))) { return $true }
    return $false
}

function Get-MmtlPlatformContext {
    [CmdletBinding()]
    param()
    $provider=Get-MmtlPlatformProvider
    return [pscustomobject]@{os=$provider.OS;arch=$provider.Arch;isWSL=[bool]$provider.IsWSL;shell=$PSVersionTable.PSEdition;capabilities=[pscustomobject]@{Build='Native';WindowManagement=$provider.WindowManagement;ProcessManagement=$provider.ProcessManagement;FabricRuntimeLink=$provider.FabricRuntimeLink}}
}

function Get-MmtlPhysicalMemoryMb {
    [CmdletBinding()]
    param()
    $provider=Get-MmtlPlatformProvider
    if (-not $provider.GetPhysicalMemoryMb) { return $null }
    return [long](& $provider.GetPhysicalMemoryMb)
}

Export-ModuleMember -Function Set-MmtlPlatformProvider,Get-MmtlPlatformProvider,Get-MmtlPlatformDisplayName,Get-MmtlPlatformContext,Get-MmtlCanonicalPath,Test-MmtlPathLink,Test-MmtlPlatformPathInsideRoot,Get-MmtlPhysicalMemoryMb
