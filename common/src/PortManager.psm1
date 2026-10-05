function Get-MmtlPort {
    param([ValidateRange(1,65535)][int]$Port=0)
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    try { $listener.Start(); return [int]$listener.LocalEndpoint.Port }
    finally { $listener.Stop() }
}
function Invoke-MmtlPortAllocation {
    [CmdletBinding()]
    param(
        [ValidateRange(0,65535)][int]$Port=0,
        [Parameter(Mandatory)][scriptblock]$OnAllocated,
        [ValidateRange(1,16)][int]$MaximumAttempts=3,
        [scriptblock]$PortSelector
    )
    $attemptLimit=if($Port -gt 0){1}else{$MaximumAttempts}
    for($attempt=1;$attempt -le $attemptLimit;$attempt++){
        if($PortSelector){
            $candidate=[int](& $PortSelector $attempt)
            if($candidate -lt 1 -or $candidate -gt 65535){throw 'PORT_ALLOCATION_FAILED: 端口选择器必须返回 1 至 65535。'}
        }else{
            $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
            try{$listener.Start();$candidate=[int]$listener.LocalEndpoint.Port}
            catch{throw "PORT_ALLOCATION_FAILED: 无法在 loopback 分配端口 $Port。$($_.Exception.Message)"}
            finally{$listener.Stop()}
        }
        try{
            $value=& $OnAllocated $candidate $attempt
            return [pscustomobject]@{Port=$candidate;Attempts=$attempt;Value=$value}
        }catch{
            $retryable=$_.Exception.Message -match '(?i)\bPORT_BIND_CONFLICT\b'
            if($Port -eq 0 -and $retryable -and $attempt -lt $attemptLimit){continue}
            throw
        }
    }
    throw "PORT_ALLOCATION_RETRIES_EXHAUSTED: 自动端口冲突，已尝试 $attemptLimit 次。"
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
        if($ProcessId){
            try{$null=Get-Process -Id $ProcessId -ErrorAction Stop}
            catch{
                if(Test-Path -LiteralPath $Path -PathType Leaf){$finalText=(Get-Content -LiteralPath $Path -Tail 3000 -ErrorAction Stop) -join "`n";if($finalText -match '(?im)(FAILED TO BIND TO PORT|Failed to bind to port|Address already in use|java\.net\.BindException|EADDRINUSE)'){throw 'PORT_BIND_CONFLICT: Dedicated Server 退出前报告端口绑定冲突。'}}
                throw "DEDICATED_PROCESS_EXITED: Dedicated Server 在观察到就绪标记前退出（PID $ProcessId）。"
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    throw "等待 IntegratedLAN 端口超时：$Path"
}
function Wait-MmtlDedicatedReady {
    param([Parameter(Mandatory)][string]$Path,[ValidateRange(1,600)][int]$TimeoutSeconds=180,[ValidateRange(50,5000)][int]$PollMilliseconds=500,[int]$ProcessId=0)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        if(Test-Path -LiteralPath $Path -PathType Leaf){$text=(Get-Content -LiteralPath $Path -Tail 3000 -ErrorAction Stop) -join "`n";if($text -match '(?im)(FAILED TO BIND TO PORT|Failed to bind to port|Address already in use|java\.net\.BindException|EADDRINUSE)'){throw 'PORT_BIND_CONFLICT: Dedicated Server 无法绑定所选端口。'};if($text -match '(?im)(Failed to start the Minecraft server|Exception in server tick loop)'){throw "Dedicated Server 启动失败，请检查日志：$Path"};if($text -match '(?im)\bDone\s*\([^\r\n)]*\)!\s*For help, type\s+["'']help["'']'){return $true}}
        if($ProcessId){$null=Get-Process -Id $ProcessId -ErrorAction Stop}
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    throw "等待 Dedicated Server 就绪超时：$Path"
}
Export-ModuleMember -Function Get-MmtlPort,Invoke-MmtlPortAllocation,Get-MmtlLanPortFromLog,Test-MmtlDedicatedReadyLog,Wait-MmtlLanPort,Wait-MmtlDedicatedReady
