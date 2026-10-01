function ConvertTo-MmtlWindowsProcessUtc {
    param([Parameter(Mandatory)]$Value)
    if($Value -is [DateTimeOffset]){return $Value.UtcDateTime}
    if($Value -is [DateTime]){return $Value.ToUniversalTime()}
    return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Value).ToUniversalTime()
}

function ConvertTo-MmtlWindowsProcessRecord {
    param([Parameter(Mandatory)]$Process,[int]$Depth=0)
    $start=(ConvertTo-MmtlWindowsProcessUtc $Process.CreationDate).ToString('o')
    return [pscustomobject]@{PID=[int]$Process.ProcessId;ParentPID=[int]$Process.ParentProcessId;Depth=$Depth;StartIdentity=$start;StartTimeUtc=$start;Executable=[string]$Process.ExecutablePath;CommandLine=[string]$Process.CommandLine;SessionID=[int]$Process.SessionId}
}

function Get-MmtlWindowsProcessRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $process=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if(-not $process){return $null}
    return ConvertTo-MmtlWindowsProcessRecord -Process $process
}

function Get-MmtlWindowsProcessSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$RootProcessId)
    $all=@(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $root=$all|Where-Object{[int]$_.ProcessId -eq $RootProcessId}|Select-Object -First 1
    if(-not $root){throw "找不到登记进程 PID $RootProcessId。"}
    $result=[Collections.Generic.List[object]]::new();$queue=[Collections.Generic.Queue[object]]::new();$seen=[Collections.Generic.HashSet[int]]::new()
    $rootRecord=ConvertTo-MmtlWindowsProcessRecord -Process $root -Depth 0
    $result.Add($rootRecord);$queue.Enqueue($rootRecord);[void]$seen.Add($RootProcessId)
    while($queue.Count){$parent=$queue.Dequeue();foreach($child in @($all|Where-Object{[int]$_.ParentProcessId -eq [int]$parent.PID})){$childId=[int]$child.ProcessId;if(-not $seen.Add($childId)){continue};$record=ConvertTo-MmtlWindowsProcessRecord -Process $child -Depth ([int]$parent.Depth+1);$result.Add($record);$queue.Enqueue($record)}}
    return @($result)
}

function Test-MmtlWindowsProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Process,[Parameter(Mandatory)]$Record)
    $stored=if($Record.StartIdentity){$Record.StartIdentity}else{$Record.StartTimeUtc}
    $registeredTime=if($stored -is [DateTimeOffset]){$stored.UtcDateTime}elseif($stored -is [DateTime]){$stored.ToUniversalTime()}else{[DateTimeOffset]::Parse([string]$stored,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime}
    $actualPid=if($Process.PSObject.Properties['PID']){[int]$Process.PID}else{[int]$Process.ProcessId}
    if($Record.PID -and $actualPid -ne [int]$Record.PID){return $false}
    $rawCreation=if($Process.PSObject.Properties['CreationDate']){ConvertTo-MmtlWindowsProcessUtc $Process.CreationDate}else{[DateTimeOffset]::Parse([string]$Process.StartIdentity,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime}
    if($registeredTime.Ticks -ne $rawCreation.Ticks){return $false}
    $actualExecutable=if($Process.PSObject.Properties['Executable']){[string]$Process.Executable}else{[string]$Process.ExecutablePath}
    $actualCommand=if($Process.PSObject.Properties['CommandLine']){[string]$Process.CommandLine}else{[string]$Process.CommandLine}
    $actualParent=if($Process.PSObject.Properties['ParentPID']){[int]$Process.ParentPID}else{[int]$Process.ParentProcessId}
    if($Record.Executable -and $actualExecutable -ne [string]$Record.Executable){return $false}
    if($Record.CommandLine -and $actualCommand -ne [string]$Record.CommandLine){return $false}
    if($Record.ParentPID -and $actualParent -ne [int]$Record.ParentPID){return $false}
    return $true
}

Export-ModuleMember -Function Get-MmtlWindowsProcessRecord,Get-MmtlWindowsProcessSnapshot,Test-MmtlWindowsProcessIdentity
