function Get-MmtlPort {
    param([ValidateRange(1,65535)][int]$Port=0)
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    try { $listener.Start(); return [int]$listener.LocalEndpoint.Port }
    finally { $listener.Stop() }
}
function Get-MmtlLanPortFromLog {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $null}
    $text=(Get-Content -LiteralPath $Path -Tail 3000 -ErrorAction Stop) -join "`n"
    $patterns=@('Local game hosted on port\s*\[?(?<port>\d{1,5})\]?','Started serving on\s+(?:[^\r\n]*?:)?(?<port>\d{1,5})\s*$')
    foreach($pattern in $patterns){$matches=[regex]::Matches($text,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Multiline);if($matches.Count){$value=[int]$matches[$matches.Count-1].Groups['port'].Value;if($value -in 1..65535){return $value}}}
    return $null
}
function Test-MmtlDedicatedReadyLog {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
    $text=(Get-Content -LiteralPath $Path -Tail 3000 -ErrorAction Stop) -join "`n"
    return $text -match '(?im)\bDone\s*\([^\r\n)]*\)!\s*For help, type\s+["'']help["'']'
}
function Wait-MmtlLanPort {
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,600)][int]$TimeoutSeconds=180,[ValidateRange(50,5000)][int]$PollMilliseconds=500,[int]$ProcessId=0)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        $port=Get-MmtlLanPortFromLog -Path $Path
        if($port){return $port}
        if($ProcessId){$null=Get-Process -Id $ProcessId -ErrorAction Stop}
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    throw "等待 IntegratedLAN 端口超时：$Path"
}
function Wait-MmtlDedicatedReady {
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,600)][int]$TimeoutSeconds=180,[ValidateRange(50,5000)][int]$PollMilliseconds=500,[int]$ProcessId=0)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        if(Test-Path -LiteralPath $Path -PathType Leaf){$text=(Get-Content -LiteralPath $Path -Tail 3000 -ErrorAction Stop) -join "`n";if($text -match '(?im)(Failed to start the Minecraft server|Failed to bind to port|Exception in server tick loop)'){throw "Dedicated Server 启动失败，请检查日志：$Path"};if($text -match '(?im)\bDone\s*\([^\r\n)]*\)!\s*For help, type\s+["'']help["'']'){return $true}}
        if($ProcessId){$null=Get-Process -Id $ProcessId -ErrorAction Stop}
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    throw "等待 Dedicated Server 就绪超时：$Path"
}
Export-ModuleMember -Function Get-MmtlPort,Get-MmtlLanPortFromLog,Test-MmtlDedicatedReadyLog,Wait-MmtlLanPort,Wait-MmtlDedicatedReady
