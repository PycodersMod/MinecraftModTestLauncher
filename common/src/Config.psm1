function Read-MmtlConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "配置文件不存在：$Path" }
    try { $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "配置 JSON 无效：$($_.Exception.Message)" }
    if ($null -ne $config.PSObject.Properties['configVersion'] -and [int]$config.configVersion -notin @(1, 2)) {
        throw "不支持的 Config Schema 版本：$($config.configVersion)"
    }
    if (-not $config.profiles) { throw '配置必须包含 profiles。' }
    if (-not $config.javaHomes) { throw '配置必须包含 javaHomes。' }
    foreach ($javaHome in $config.javaHomes.PSObject.Properties) {
        $major = 0
        if (-not [int]::TryParse($javaHome.Name, [ref]$major) -or $major -lt 1 -or $javaHome.Value -isnot [string]) {
            throw "javaHomes 的键必须是正整数 major 且值必须为路径字符串：$($javaHome.Name)"
        }
    }
    if ($null -ne $config.PSObject.Properties['javaHomesByPlatform']) {
        foreach ($platform in $config.javaHomesByPlatform.PSObject.Properties) {
            if ($platform.Value -isnot [pscustomobject]) { throw "javaHomesByPlatform.$($platform.Name) 必须是 major 到路径的映射。" }
            foreach ($javaHome in $platform.Value.PSObject.Properties) {
                $major = 0
                if (-not [int]::TryParse($javaHome.Name, [ref]$major) -or $major -lt 1 -or $javaHome.Value -isnot [string]) {
                    throw "javaHomesByPlatform.$($platform.Name) 包含无效 Java home：$($javaHome.Name)"
                }
            }
        }
    }
    if(-not $config.defaultProfile -or -not $config.profiles.PSObject.Properties[$config.defaultProfile]){throw 'defaultProfile 必须引用 profiles 中存在的配置。'}
    foreach($profileProperty in $config.profiles.PSObject.Properties){
        $profile=$profileProperty.Value
        if($profile.mode -notin @('Single','IntegratedLAN','Dedicated')){throw "Profile $($profileProperty.Name) 的 mode 无效。"}
        $players=0;if(-not[int]::TryParse([string]$profile.players,[ref]$players) -or $players -lt 1 -or $players -gt 8){throw "Profile $($profileProperty.Name) 的 players 必须为 1 至 8。"}
        if($null -ne $profile.PSObject.Properties['guiScale']){$guiScale=0;if([string]$profile.guiScale -ine 'Auto' -and (-not[int]::TryParse([string]$profile.guiScale,[ref]$guiScale) -or $guiScale -lt 0 -or $guiScale -gt 4)){throw "Profile $($profileProperty.Name) 的 guiScale 必须为 Auto 或 0 至 4。"}}
        if($profile.port -and [string]$profile.port -ne 'Auto'){$port=0;if(-not[int]::TryParse([string]$profile.port,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw "Profile $($profileProperty.Name) 的 port 必须是 Auto 或 1 至 65535。"}}
    }
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
    if($null -ne $Profile.PSObject.Properties['guiScale']){$guiScale=0;if([string]$Profile.guiScale -ine 'Auto' -and (-not[int]::TryParse([string]$Profile.guiScale,[ref]$guiScale) -or $guiScale -lt 0 -or $guiScale -gt 4)){throw 'guiScale 必须为 Auto 或 0 至 4。'}}
    return $true
}

Export-ModuleMember -Function Read-MmtlConfig,Get-MmtlProfile,Assert-MmtlProfile
