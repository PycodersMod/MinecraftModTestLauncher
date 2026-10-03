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
    if(-not $homePath){throw "Required Java $Major is not configured for $($provider.OS)."}
    $java=Join-Path (Join-Path $homePath 'bin') $provider.JavaExecutable
    if(-not(Test-Path -LiteralPath $java -PathType Leaf)){throw "Required Java $Major is not available at configured path: $java"}
    $resolved=(Resolve-Path -LiteralPath $java).Path
    if(-not $SkipVersionCheck){
        try{$versionOutput=@(& $resolved -version 2>&1);$exitCode=$LASTEXITCODE}catch{throw "Configured Java could not start: $resolved ($($_.Exception.Message))"}
        if($exitCode -ne 0){throw "Configured Java failed to start (exit $exitCode): $resolved"}
        $text=$versionOutput -join "`n"
        $match=[regex]::Match($text,'(?i)version\s+"(?:1\.)?(\d+)')
        if(-not $match.Success){throw "Unable to detect Java major from: $text"}
        $actual=[int]$match.Groups[1].Value
        if($actual -ne $Major){throw "Configured Java major mismatch: expected $Major, detected $actual ($resolved)."}
    }
    return $resolved
}
Export-ModuleMember -Function Resolve-MmtlJava
