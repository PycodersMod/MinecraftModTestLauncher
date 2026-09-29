function Resolve-MmtlJava {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config,[Parameter(Mandatory)][int]$Major)
    $homePath = [string]$Config.javaHomes."$Major"
    if (-not $homePath) { throw "Required Java $Major is not configured." }
    $java = Join-Path $homePath 'bin\java.exe'
    if (-not (Test-Path -LiteralPath $java -PathType Leaf)) { throw "Required Java $Major is not available at configured path." }
    return (Resolve-Path -LiteralPath $java).Path
}
Export-ModuleMember -Function Resolve-MmtlJava
