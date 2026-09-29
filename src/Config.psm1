function Read-MmtlConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "配置文件不存在：$Path" }
    try { $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "配置 JSON 无效：$($_.Exception.Message)" }
    if (-not $config.profiles) { throw '配置必须包含 profiles。' }
    if (-not $config.javaHomes) { throw '配置必须包含 javaHomes。' }
    return $config
}

function Get-MmtlProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [string]$Name)
    if (-not $Name) { $Name = [string]$Config.defaultProfile }
    if (-not $Name -or -not $Config.profiles.PSObject.Properties[$Name]) { throw "Profile 不存在：$Name" }
    return $Config.profiles.$Name
}

function Assert-MmtlProfile {
    param([Parameter(Mandatory)]$Profile)
    if (-not $Profile.project) { throw 'Profile 缺少 project。' }
    if ($Profile.mode -notin @('Single','IntegratedLAN','Dedicated')) { throw "不支持的运行模式：$($Profile.mode)" }
    if ([int]$Profile.players -lt 1) { throw 'players 必须大于 0。' }
    return $true
}

Export-ModuleMember -Function Read-MmtlConfig,Get-MmtlProfile,Assert-MmtlProfile
