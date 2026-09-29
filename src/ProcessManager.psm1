function Start-MmtlTrackedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$FilePath,[string[]]$ArgumentList=@(),[Parameter(Mandatory)][string]$WorkingDirectory,[Parameter(Mandatory)][string]$LogPath)
    if (-not (Test-MmtlInsideRoot -Root (Split-Path $SessionPath -Parent | Split-Path -Parent) -Target $SessionPath)) { throw 'Session 路径无效。' }
    if (-not (Test-MmtlInsideRoot -Root $SessionPath -Target $LogPath)) { throw '日志路径必须位于当前 Session。' }
    $proc=Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath+'.err') -PassThru
    $proc.Refresh(); $exe=$proc.Path
    $entry=[pscustomobject]@{PID=$proc.Id;Role='Process';StartTimeUtc=$proc.StartTime.ToUniversalTime().ToString('o');Executable=$exe;Command=$FilePath;Arguments=$ArgumentList;LogPath=$LogPath}
    $registry=Join-Path $SessionPath 'pids.json'; $items=@(Get-Content $registry -Raw | ConvertFrom-Json); $items += $entry
    $items | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $registry -Encoding utf8
    return $proc.Id
}
function Stop-MmtlTrackedProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][int]$ProcessId)
    $registry=Join-Path $SessionPath 'pids.json'; if (-not (Test-Path $registry)) { throw 'Session 未登记进程。' }
    $entry=@(Get-Content $registry -Raw | ConvertFrom-Json | Where-Object { [int]$_.PID -eq $ProcessId }) | Select-Object -First 1
    if (-not $entry) { throw '拒绝停止未登记进程。' }
    $proc=Get-Process -Id $ProcessId -ErrorAction Stop; $actual=$proc.StartTime.ToUniversalTime().ToString('o')
    if ($actual -ne [string]$entry.StartTimeUtc -or $proc.Path -ne [string]$entry.Executable) { throw '进程身份与登记记录不符，拒绝停止。' }
    if ($PSCmdlet.ShouldProcess("PID $ProcessId",'停止当前 Session 登记的进程')) { $proc.Kill(); return $true }
    return $false
}
Export-ModuleMember -Function Start-MmtlTrackedProcess,Stop-MmtlTrackedProcess
