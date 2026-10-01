function ConvertFrom-MmtlLinuxProcStat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $match=[regex]::Match($Text,'(?s)^(\d+) \((.*)\) (.*)$')
    if(-not $match.Success){throw 'Malformed /proc/PID/stat record.'}
    $fields=$match.Groups[3].Value -split '\s+'
    if($fields.Count -le 19){throw 'Truncated /proc/PID/stat record.'}
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
    if(-not $root){throw "Cannot read registered process PID $RootProcessId from /proc."}
    $all=[Collections.Generic.List[object]]::new()
    foreach($dir in Get-ChildItem /proc -Directory -ErrorAction SilentlyContinue){if($dir.Name -match '^\d+$'){$record=Get-MmtlLinuxProcessRecord -ProcessId ([int]$dir.Name);if($record){$all.Add($record)}}}
    $rootRecord=$all|Where-Object PID -eq $RootProcessId|Select-Object -First 1
    if(-not $rootRecord){throw "Cannot read registered process PID $RootProcessId from /proc."}
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
    if(-not $entry){throw 'Refusing to stop an unregistered process.'}
    $current=Get-MmtlLinuxProcessRecord -ProcessId $ProcessId
    if(-not $current){return $false}
    if(-not(Test-MmtlLinuxProcessIdentity -Process $current -Record $entry)){throw 'Process identity changed; refusing to signal PID.'}
    $snapshot=@(Get-MmtlLinuxProcessSnapshot -RootProcessId $ProcessId);$entry.ProcessTree=@($snapshot|Where-Object PID -ne $ProcessId);Write-MmtlPidRegistry -Path $registry -Entries $items
    if(-not $PSCmdlet.ShouldProcess("PID $ProcessId and registered descendants",'Send TERM then identity-checked KILL')){return $false}
    foreach($record in @($snapshot|Sort-Object Depth -Descending)){
        $again=Get-MmtlLinuxProcessRecord -ProcessId ([int]$record.PID);if(-not $again -or -not(Test-MmtlLinuxProcessIdentity -Process $again -Record $record)){continue}
        & /bin/kill -TERM -- ([string]$record.PID) 2>$null
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    do{$survivors=@($snapshot|Where-Object {$p=Get-MmtlLinuxProcessRecord -ProcessId ([int]$_.PID);$p -and (Test-MmtlLinuxProcessIdentity -Process $p -Record $_)});if($survivors.Count){Start-Sleep -Milliseconds 100}}while($survivors.Count -and [DateTime]::UtcNow -lt $deadline)
    foreach($record in @($survivors|Sort-Object Depth -Descending)){$again=Get-MmtlLinuxProcessRecord -ProcessId ([int]$record.PID);if($again -and (Test-MmtlLinuxProcessIdentity -Process $again -Record $record)){& /bin/kill -KILL -- ([string]$record.PID) 2>$null}}
    $killDeadline=[DateTime]::UtcNow.AddSeconds(2)
    do{$remaining=@($snapshot|Where-Object {$p=Get-MmtlLinuxProcessRecord -ProcessId ([int]$_.PID);$p -and (Test-MmtlLinuxProcessIdentity -Process $p -Record $_)});if($remaining.Count){Start-Sleep -Milliseconds 100}}while($remaining.Count -and [DateTime]::UtcNow -lt $killDeadline)
    if($remaining.Count){throw "Registered processes remain after KILL: $(@($remaining.PID) -join ', '); session is retained."}
    $stopped=[pscustomobject]@{PID=$ProcessId;ExitCode=$null;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');Error='Stopped by launcher request';StopRequested=$true}
    [IO.File]::WriteAllText([string]$entry.StatePath,($stopped|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));return $true
}
Export-ModuleMember -Function ConvertFrom-MmtlLinuxProcStat,Get-MmtlLinuxProcessRecord,Get-MmtlLinuxProcessSnapshot,Test-MmtlLinuxProcessIdentity,Stop-MmtlLinuxTrackedProcess
