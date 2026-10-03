function ConvertFrom-MmtlLinuxProcStat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $match=[regex]::Match($Text,'(?s)^(\d+) \((.*)\) (.*)$')
    if(-not $match.Success){throw '/proc/PID/stat 记录格式无效。'}
    $fields=$match.Groups[3].Value -split '\s+'
    if($fields.Count -le 19){throw '/proc/PID/stat 记录不完整。'}
    return [pscustomobject]@{PID=[int]$match.Groups[1].Value;Comm=$match.Groups[2].Value;State=$fields[0];ParentPID=[int]$fields[1];SessionID=[int]$fields[3];StartTimeToken=$fields[19]}
}
function Get-MmtlLinuxProcessRecord {
    param([Parameter(Mandatory)][int]$ProcessId,[int]$Depth=0)
    $base="/proc/$ProcessId"
    if(-not(Test-Path -LiteralPath "$base/stat")){return $null}
    try{
        $stat=ConvertFrom-MmtlLinuxProcStat -Text ([IO.File]::ReadAllText("$base/stat"));$exe=(Get-Item -LiteralPath "$base/exe" -Force -ErrorAction Stop).Target
        $raw=[IO.File]::ReadAllBytes("$base/cmdline");$command=[Text.Encoding]::UTF8.GetString($raw).Replace([char]0,' ').Trim()
        return [pscustomobject]@{PID=$stat.PID;ParentPID=$stat.ParentPID;Depth=$Depth;StartIdentity=[string]$stat.StartTimeToken;StartTimeToken=[string]$stat.StartTimeToken;Executable=[string]$exe;CommandLine=$command;SessionID=$stat.SessionID}
    }catch{return $null}
}
function Get-MmtlLinuxProcessSnapshot {
    param([Parameter(Mandatory)][int]$RootProcessId)
    $root=Get-MmtlLinuxProcessRecord -ProcessId $RootProcessId
    if(-not $root){throw "无法从 /proc 读取已登记的进程 PID $RootProcessId。"}
    $all=[Collections.Generic.List[object]]::new()
    foreach($dir in Get-ChildItem /proc -Directory -ErrorAction SilentlyContinue){if($dir.Name -match '^\d+$'){$record=Get-MmtlLinuxProcessRecord -ProcessId ([int]$dir.Name);if($record){$all.Add($record)}}}
    $rootRecord=$all|Where-Object PID -eq $RootProcessId|Select-Object -First 1
    if(-not $rootRecord){throw "无法从 /proc 读取已登记的进程 PID $RootProcessId。"}
    $result=[Collections.Generic.List[object]]::new();$queue=[Collections.Generic.Queue[object]]::new();$seen=[Collections.Generic.HashSet[int]]::new()
    $rootRecord.Depth=0;$result.Add($rootRecord);$queue.Enqueue($rootRecord);[void]$seen.Add($RootProcessId)
    while($queue.Count){$parent=$queue.Dequeue();foreach($child in @($all|Where-Object ParentPID -eq $parent.PID)){if(-not $seen.Add([int]$child.PID)){continue};$child.Depth=[int]$parent.Depth+1;$result.Add($child);$queue.Enqueue($child)}}
    return @($result)
}
function Test-MmtlLinuxProcessIdentity {
    param([Parameter(Mandatory)]$Process,[Parameter(Mandatory)]$Record)
    $token=if($Record.StartIdentity){[string]$Record.StartIdentity}else{[string]$Record.StartTimeToken}
    if(-not $token -or [int]$Process.PID -ne [int]$Record.PID -or [string]$Process.StartIdentity -ne $token){return $false}
    if($Record.Executable -and [string]$Process.Executable -ne [string]$Record.Executable){return $false}
    if($Record.CommandLine -and [string]$Process.CommandLine -ne [string]$Record.CommandLine){return $false}
    return $true
}
function Stop-MmtlLinuxTrackedProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][int]$ProcessId)
    $registry=Join-Path $SessionPath 'pids.json';$items=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json);$entry=$items|Where-Object {[int]$_.PID -eq $ProcessId}|Select-Object -First 1
    if(-not $entry){throw '拒绝停止未登记的进程。'}
    $current=Get-MmtlLinuxProcessRecord -ProcessId $ProcessId
    if(-not $current){return $false}
    if(-not(Test-MmtlLinuxProcessIdentity -Process $current -Record $entry)){throw '进程身份已改变；拒绝向该 PID 发送信号。'}
    $snapshot=@(Get-MmtlLinuxProcessSnapshot -RootProcessId $ProcessId);$entry.ProcessTree=@($snapshot|Where-Object PID -ne $ProcessId);Write-MmtlPidRegistry -Path $registry -Entries $items
    if(-not $PSCmdlet.ShouldProcess("PID $ProcessId 及其已登记的子进程",'先发送 TERM，随后按进程身份核验后发送 KILL')){return $false}
    foreach($record in @($snapshot|Sort-Object Depth -Descending)){
        $again=Get-MmtlLinuxProcessRecord -ProcessId ([int]$record.PID);if(-not $again -or -not(Test-MmtlLinuxProcessIdentity -Process $again -Record $record)){continue}
        & /bin/kill -TERM -- ([string]$record.PID) 2>$null
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    do{$survivors=@($snapshot|Where-Object {$p=Get-MmtlLinuxProcessRecord -ProcessId ([int]$_.PID);$p -and (Test-MmtlLinuxProcessIdentity -Process $p -Record $_)});if($survivors.Count){Start-Sleep -Milliseconds 100}}while($survivors.Count -and [DateTime]::UtcNow -lt $deadline)
    foreach($record in @($survivors|Sort-Object Depth -Descending)){$again=Get-MmtlLinuxProcessRecord -ProcessId ([int]$record.PID);if($again -and (Test-MmtlLinuxProcessIdentity -Process $again -Record $record)){& /bin/kill -KILL -- ([string]$record.PID) 2>$null}}
    $killDeadline=[DateTime]::UtcNow.AddSeconds(2)
    do{$remaining=@($snapshot|Where-Object {$p=Get-MmtlLinuxProcessRecord -ProcessId ([int]$_.PID);$p -and (Test-MmtlLinuxProcessIdentity -Process $p -Record $_)});if($remaining.Count){Start-Sleep -Milliseconds 100}}while($remaining.Count -and [DateTime]::UtcNow -lt $killDeadline)
    if($remaining.Count){throw "发送 KILL 后仍有已登记进程存活：$(@($remaining.PID) -join ', ')；保留此 Session。"}
    $stopped=[pscustomobject]@{PID=$ProcessId;ExitCode=$null;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');Error='已按启动器请求停止';StopRequested=$true}
    [IO.File]::WriteAllText([string]$entry.StatePath,($stopped|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));return $true
}
Export-ModuleMember -Function ConvertFrom-MmtlLinuxProcStat,Get-MmtlLinuxProcessRecord,Get-MmtlLinuxProcessSnapshot,Test-MmtlLinuxProcessIdentity,Stop-MmtlLinuxTrackedProcess
