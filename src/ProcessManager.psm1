function ConvertTo-MmtlCimUtcTime {
    param([Parameter(Mandatory)]$Value)
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime}
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Value).ToUniversalTime()
}
function Get-MmtlProcessSnapshot {
    param([Parameter(Mandatory)][int]$RootProcessId)
    $all=@(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $root=$all|Where-Object{[int]$_.ProcessId -eq $RootProcessId}|Select-Object -First 1
    if(-not $root){throw "找不到登记进程 PID $RootProcessId。"}
    $result=[Collections.Generic.List[object]]::new()
    $queue=[Collections.Generic.Queue[object]]::new()
    $seen=[Collections.Generic.HashSet[int]]::new()
    $rootRecord=[pscustomobject]@{PID=[int]$root.ProcessId;ParentPID=[int]$root.ParentProcessId;Depth=0;StartTimeUtc=(ConvertTo-MmtlCimUtcTime $root.CreationDate).ToString('o');Executable=[string]$root.ExecutablePath;CommandLine=[string]$root.CommandLine}
    $result.Add($rootRecord);$queue.Enqueue($rootRecord);[void]$seen.Add($RootProcessId)
    while($queue.Count){
        $parent=$queue.Dequeue()
        foreach($child in @($all|Where-Object{[int]$_.ParentProcessId -eq [int]$parent.PID})){
            $childId=[int]$child.ProcessId
            if(-not $seen.Add($childId)){continue}
            $record=[pscustomobject]@{PID=$childId;ParentPID=[int]$child.ParentProcessId;Depth=([int]$parent.Depth+1);StartTimeUtc=(ConvertTo-MmtlCimUtcTime $child.CreationDate).ToString('o');Executable=[string]$child.ExecutablePath;CommandLine=[string]$child.CommandLine}
            $result.Add($record);$queue.Enqueue($record)
        }
    }
    return @($result)
}
function Write-MmtlPidRegistry {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object[]]$Entries)
    $temp="$Path.$PID.tmp"
    try{
        [IO.File]::WriteAllText($temp,(@($Entries)|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Test-MmtlProcessIdentity {
    param([Parameter(Mandatory)]$Process,[Parameter(Mandatory)]$Record)
    $stored=$Record.StartTimeUtc
    $registeredTime=if($stored -is [DateTimeOffset]){$stored.UtcDateTime}elseif($stored -is [DateTime]){$stored.ToUniversalTime()}else{[DateTimeOffset]::Parse([string]$stored,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime}
    $actualTime=ConvertTo-MmtlCimUtcTime $Process.CreationDate
    if($registeredTime.Ticks -ne $actualTime.Ticks){return $false}
    if($Record.Executable -and $Process.ExecutablePath -ne [string]$Record.Executable){return $false}
    if($Record.CommandLine -and $Process.CommandLine -ne [string]$Record.CommandLine){return $false}
    if($Record.ParentPID -and [int]$Process.ParentProcessId -ne [int]$Record.ParentPID){return $false}
    return $true
}
function Start-MmtlTrackedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$FilePath,[string[]]$ArgumentList=@(),[Parameter(Mandatory)][string]$WorkingDirectory,[Parameter(Mandatory)][string]$LogPath,[string]$Role='Process',[string]$Username='',[string]$RuntimeLinkPath,[string]$RuntimeTargetPath)
    $session=[IO.Path]::GetFullPath($SessionPath)
    $runtime=[IO.Path]::GetFullPath((Split-Path (Split-Path $session -Parent) -Parent))
    if(-not(Test-MmtlInsideRoot -Root (Join-Path $runtime 'sessions') -Target $session)){throw 'Session 路径无效。'}
    if([IO.Path]::GetFullPath((Split-Path $session -Parent)) -ne [IO.Path]::GetFullPath((Join-Path $runtime 'sessions'))){throw 'Session 必须是 sessions 的直接子目录。'}
    if(-not(Test-MmtlInsideRoot -Root $session -Target $LogPath)){throw '日志路径必须位于当前 Session。'}
    Assert-MmtlNoReparsePath -Path $session|Out-Null
    $registry=Join-Path $session 'pids.json'
    if(-not(Test-Path -LiteralPath $registry)){throw 'Session 缺少 pids.json。'}
    $proc=Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath+'.err') -PassThru
    $proc.Refresh();$current=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction Stop
    if(-not $current){throw '无法取得新进程的身份快照。'}
    $entry=[pscustomobject]@{PID=$proc.Id;Role=$Role;Username=$Username;StartTimeUtc=(ConvertTo-MmtlCimUtcTime $current.CreationDate).ToString('o');Executable=[string]$current.ExecutablePath;ParentPID=[int]$current.ParentProcessId;CommandLine=[string]$current.CommandLine;Command=$FilePath;WorkingDirectory=$WorkingDirectory;Arguments=@($ArgumentList);LogPath=$LogPath;StatePath=(Join-Path $session "process-$($proc.Id).exit.json");ProcessTree=@();RuntimeLinkPath=$RuntimeLinkPath;RuntimeTargetPath=$RuntimeTargetPath}
    $items=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json);$items+= $entry
    Write-MmtlPidRegistry -Path $registry -Entries $items
    return $proc.Id
}
function Stop-MmtlTrackedProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][int]$ProcessId)
    $session=[IO.Path]::GetFullPath($SessionPath)
    Assert-MmtlNoReparsePath -Path $session|Out-Null
    $registry=Join-Path $session 'pids.json'
    if(-not(Test-Path -LiteralPath $registry)){throw 'Session 未登记进程。'}
    $items=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json)
    $entry=$items|Where-Object{[int]$_.PID -eq $ProcessId}|Select-Object -First 1
    if(-not $entry){throw '拒绝停止未登记进程。'}
    if($entry.StatePath -and -not(Test-MmtlInsideRoot -Root $session -Target ([string]$entry.StatePath))){throw '进程退出状态路径越出 Session，拒绝停止。'}
    $root=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    if(-not $root){return $false}
    if(-not(Test-MmtlProcessIdentity -Process $root -Record $entry)){throw '进程身份与登记记录不符，拒绝停止。'}
    $snapshot=Get-MmtlProcessSnapshot -RootProcessId $ProcessId
    $tree=@($snapshot|Where-Object{[int]$_.PID -ne $ProcessId})
    $entry.ProcessTree=$tree
    Write-MmtlPidRegistry -Path $registry -Entries $items
    if(-not $PSCmdlet.ShouldProcess("PID $ProcessId 及其 $($tree.Count) 个登记子进程",'停止当前 Session 登记的进程')){return $false}
    foreach($record in @($snapshot|Sort-Object Depth -Descending)){
        $current=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$([int]$record.PID)" -ErrorAction SilentlyContinue
        if(-not $current -or -not(Test-MmtlProcessIdentity -Process $current -Record $record)){continue}
        try{$proc=Get-Process -Id ([int]$record.PID) -ErrorAction Stop;$proc.Kill();if([int]$record.PID -eq $ProcessId){$null=$proc.WaitForExit(5000)}}catch{continue}
    }
    $survivors=[Collections.Generic.List[int]]::new();$deadline=[DateTime]::UtcNow.AddSeconds(5)
    do{$survivors.Clear();foreach($record in $snapshot){$current=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$([int]$record.PID)" -ErrorAction SilentlyContinue;if($current -and (Test-MmtlProcessIdentity -Process $current -Record $record)){$survivors.Add([int]$record.PID)}};if($survivors.Count){Start-Sleep -Milliseconds 100}}while($survivors.Count -and [DateTime]::UtcNow -lt $deadline)
    if($survivors.Count){throw "仍有登记进程无法停止：$($survivors -join ', ')。Session 保持活动状态。"}
    $stopped=[pscustomobject]@{PID=$ProcessId;ExitCode=$null;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');Error='Stopped by launcher request';StopRequested=$true}
    [IO.File]::WriteAllText([string]$entry.StatePath,($stopped|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if($entry.RuntimeLinkPath -and (Get-Command Remove-MmtlFabricRuntimeLink -ErrorAction SilentlyContinue)){Remove-MmtlFabricRuntimeLink -ProjectRoot $entry.WorkingDirectory -LinkPath $entry.RuntimeLinkPath -TargetPath $entry.RuntimeTargetPath}
    return $true
}
Export-ModuleMember -Function Start-MmtlTrackedProcess,Stop-MmtlTrackedProcess,Write-MmtlPidRegistry,Test-MmtlProcessIdentity,Get-MmtlProcessSnapshot
