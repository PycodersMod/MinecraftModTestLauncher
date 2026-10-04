Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../../common/src/Platform/Platform.psm1') -Force

function Get-MmtlMacOSPsField {
    param([Parameter(Mandatory)][int]$ProcessId,[Parameter(Mandatory)][string]$Field)
    try{$value=& /bin/ps -p ([string]$ProcessId) -o "$Field=" 2>$null;if($LASTEXITCODE -ne 0 -or -not $value){return $null};return ([string]($value -join ' ')).Trim()}catch{return $null}
}

function Get-MmtlMacOSProcessRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId,[int]$Depth=0)
    if($ProcessId -le 0){return $null}
    $pidText=Get-MmtlMacOSPsField -ProcessId $ProcessId -Field 'pid'
    if(-not $pidText -or [int]$pidText -ne $ProcessId){return $null}
    $parentText=Get-MmtlMacOSPsField -ProcessId $ProcessId -Field 'ppid';$started=Get-MmtlMacOSPsField -ProcessId $ProcessId -Field 'lstart'
    $executable=Get-MmtlMacOSPsField -ProcessId $ProcessId -Field 'comm';$command=Get-MmtlMacOSPsField -ProcessId $ProcessId -Field 'args';$sessionText=Get-MmtlMacOSPsField -ProcessId $ProcessId -Field 'sid'
    if(-not $started){return $null}
    try{$token=(Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture)}catch{return $null}
    return [pscustomobject]@{PID=$ProcessId;ParentPID=$(if($parentText){[int]$parentText}else{0});Depth=$Depth;StartIdentity=$token;StartTimeToken=$token;StartTimeUtc=$started;Executable=[string]$executable;CommandLine=[string]$command;SessionID=$(if($sessionText){[int]$sessionText}else{0})}
}

function Get-MmtlMacOSProcessSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$RootProcessId)
    $root=Get-MmtlMacOSProcessRecord -ProcessId $RootProcessId
    if(-not $root){throw "无法从 macOS ps 读取已登记的进程 PID $RootProcessId。"}
    $childrenByParent=@{}
    $lines=& /bin/ps -A -o pid= -o ppid= 2>$null
    if($LASTEXITCODE -ne 0){throw '无法读取 macOS 进程父子关系。'}
    foreach($line in $lines){$match=[regex]::Match([string]$line,'^\s*(\d+)\s+(\d+)\s*$');if(-not $match.Success){continue};$pidValue=[int]$match.Groups[1].Value;$parentValue=[int]$match.Groups[2].Value;if(-not $childrenByParent.ContainsKey($parentValue)){$childrenByParent[$parentValue]=[Collections.Generic.List[int]]::new()};$childrenByParent[$parentValue].Add($pidValue)}
    $result=[Collections.Generic.List[object]]::new();$queue=[Collections.Generic.Queue[object]]::new();$seen=[Collections.Generic.HashSet[int]]::new()
    $root.Depth=0;$result.Add($root);$queue.Enqueue($root);[void]$seen.Add($RootProcessId)
    while($queue.Count){$parent=$queue.Dequeue();if(-not $childrenByParent.ContainsKey([int]$parent.PID)){continue};foreach($childId in $childrenByParent[[int]$parent.PID]){if(-not $seen.Add([int]$childId)){continue};$child=Get-MmtlMacOSProcessRecord -ProcessId $childId -Depth ([int]$parent.Depth+1);if(-not $child){continue};$result.Add($child);$queue.Enqueue($child)}}
    return @($result.ToArray())
}

function Test-MmtlMacOSProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Process,[Parameter(Mandatory)]$Record)
    $expected=if($Record.StartIdentity){[string]$Record.StartIdentity}else{[string]$Record.StartTimeToken}
    $actual=if($Process.StartIdentity){[string]$Process.StartIdentity}else{[string]$Process.StartTimeToken}
    if(-not $expected -or [int]$Process.PID -ne [int]$Record.PID -or $actual -cne $expected){return $false}
    foreach($name in @('Executable','CommandLine')){if($Record.$name -and [string]$Record.$name -cne [string]$Process.$name){return $false}}
    if($Record.ParentPID -and [int]$Record.ParentPID -ne [int]$Process.ParentPID){return $false}
    return $true
}

Export-ModuleMember -Function Get-MmtlMacOSProcessRecord,Get-MmtlMacOSProcessSnapshot,Test-MmtlMacOSProcessIdentity
