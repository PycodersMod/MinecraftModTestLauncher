function Resolve-MmtlJava {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][int]$Major,[switch]$SkipVersionCheck)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    $provider=Get-MmtlPlatformProvider
    $homePath=$null
    if($Config.PSObject.Properties['javaHomesByPlatform']){
        $platformHomes=$Config.javaHomesByPlatform.PSObject.Properties[$provider.OS]
        if($platformHomes){$homeProperty=$platformHomes.Value.PSObject.Properties[[string]$Major];if($homeProperty){$homePath=[string]$homeProperty.Value}}
    }
    if(-not $homePath -and $Config.PSObject.Properties['javaHomes']){$homeProperty=$Config.javaHomes.PSObject.Properties[[string]$Major];if($homeProperty){$homePath=[string]$homeProperty.Value}}
    if(-not $homePath){throw "尚未为 $($provider.OS) 配置所需的 Java $Major。"}
    $java=Join-Path (Join-Path $homePath 'bin') $provider.JavaExecutable
    if(-not(Test-Path -LiteralPath $java -PathType Leaf)){throw "配置路径中没有可用的 Java $Major：$java"}
    $resolved=(Resolve-Path -LiteralPath $java).Path
    if(-not $SkipVersionCheck){
        try{$versionOutput=@(& $resolved -version 2>&1);$exitCode=$LASTEXITCODE}catch{throw "配置的 Java 无法启动：$resolved（$($_.Exception.Message)）"}
        if($exitCode -ne 0){throw "配置的 Java 启动失败（退出码 $exitCode）：$resolved"}
        $text=$versionOutput -join "`n"
        $match=[regex]::Match($text,'(?i)version\s+"(?:1\.)?(\d+)')
        if(-not $match.Success){throw "无法从以下文本识别 Java 主版本：$text"}
        $actual=[int]$match.Groups[1].Value
        if($actual -ne $Major){throw "配置的 Java 主版本不匹配：要求 $Major，检测到 $actual（$resolved）。"}
    }
    return $resolved
}
Export-ModuleMember -Function Resolve-MmtlJava
