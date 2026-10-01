function Get-MmtlProcessSnapshot {
    param([Parameter(Mandatory)][int]$RootProcessId)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    $os=(Get-MmtlPlatformProvider).OS
    if($os -eq 'Linux'){Import-Module (Join-Path $PSScriptRoot 'Platform/Linux.Process.psm1');return @(Get-MmtlLinuxProcessSnapshot -RootProcessId $RootProcessId)}
    if($os -eq 'MacOS'){throw 'ProcessManagement is unsupported on macOS in Phase B.'}
    Import-Module (Join-Path $PSScriptRoot 'Platform/Windows.Process.psm1')
    return @(Get-MmtlWindowsProcessSnapshot -RootProcessId $RootProcessId)
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
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    $os=(Get-MmtlPlatformProvider).OS
    if($os -eq 'Linux'){Import-Module (Join-Path $PSScriptRoot 'Platform/Linux.Process.psm1');return Test-MmtlLinuxProcessIdentity -Process $Process -Record $Record}
    if($os -eq 'MacOS'){throw 'ProcessManagement is unsupported on macOS in Phase B.'}
    Import-Module (Join-Path $PSScriptRoot 'Platform/Windows.Process.psm1')
    return Test-MmtlWindowsProcessIdentity -Process $Process -Record $Record
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
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    $provider=Get-MmtlPlatformProvider
    if($provider.OS -eq 'Linux'){Import-Module (Join-Path $PSScriptRoot 'Platform/Linux.Process.psm1')}elseif($provider.OS -eq 'Windows'){Import-Module (Join-Path $PSScriptRoot 'Platform/Windows.Process.psm1')}
    if($provider.OS -eq 'MacOS'){throw 'ProcessManagement is unsupported on macOS in Phase B.'}
    $proc=Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath+'.err') -PassThru
    $proc.Refresh()
    $current=if($provider.OS -eq 'Linux'){Get-MmtlLinuxProcessRecord -ProcessId $proc.Id}else{Get-MmtlWindowsProcessRecord -ProcessId $proc.Id}
    if(-not $current){throw '无法取得新进程的身份快照。'}
    $entry=[pscustomobject]@{PID=$proc.Id;Role=$Role;Username=$Username;StartIdentity=[string]$current.StartIdentity;StartTimeUtc=[string]$current.StartTimeUtc;StartTimeToken=[string]$current.StartTimeToken;Executable=[string]$current.Executable;ParentPID=[int]$current.ParentPID;CommandLine=[string]$current.CommandLine;SessionID=$current.SessionID;Command=$FilePath;WorkingDirectory=$WorkingDirectory;Arguments=@($ArgumentList);LogPath=$LogPath;StatePath=(Join-Path $session "process-$($proc.Id).exit.json");ProcessTree=@();RuntimeLinkPath=$RuntimeLinkPath;RuntimeTargetPath=$RuntimeTargetPath}
    $items=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json);$items+= $entry
    Write-MmtlPidRegistry -Path $registry -Entries $items
    return $proc.Id
}
function Stop-MmtlTrackedProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][int]$ProcessId)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    $os=(Get-MmtlPlatformProvider).OS
    if($os -eq 'Linux'){Import-Module (Join-Path $PSScriptRoot 'Platform/Linux.Process.psm1');return Stop-MmtlLinuxTrackedProcess -SessionPath $SessionPath -ProcessId $ProcessId -WhatIf:$WhatIfPreference}
    if($os -eq 'MacOS'){throw 'ProcessManagement is unsupported on macOS in Phase B.'}
    $session=[IO.Path]::GetFullPath($SessionPath)
    Assert-MmtlNoReparsePath -Path $session|Out-Null
    $registry=Join-Path $session 'pids.json'
    if(-not(Test-Path -LiteralPath $registry)){throw 'Session 未登记进程。'}
    $items=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json)
    $entry=$items|Where-Object{[int]$_.PID -eq $ProcessId}|Select-Object -First 1
    if(-not $entry){throw '拒绝停止未登记进程。'}
    if($entry.StatePath -and -not(Test-MmtlInsideRoot -Root $session -Target ([string]$entry.StatePath))){throw '进程退出状态路径越出 Session，拒绝停止。'}
    $root=Get-MmtlWindowsProcessRecord -ProcessId $ProcessId
    if(-not $root){return $false}
    if(-not(Test-MmtlProcessIdentity -Process $root -Record $entry)){throw '进程身份与登记记录不符，拒绝停止。'}
    $snapshot=Get-MmtlProcessSnapshot -RootProcessId $ProcessId
    $tree=@($snapshot|Where-Object{[int]$_.PID -ne $ProcessId})
    $entry.ProcessTree=$tree
    Write-MmtlPidRegistry -Path $registry -Entries $items
    if(-not $PSCmdlet.ShouldProcess("PID $ProcessId 及其 $($tree.Count) 个登记子进程",'停止当前 Session 登记的进程')){return $false}
    foreach($record in @($snapshot|Sort-Object Depth -Descending)){
        $current=Get-MmtlWindowsProcessRecord -ProcessId ([int]$record.PID)
        if(-not $current -or -not(Test-MmtlProcessIdentity -Process $current -Record $record)){continue}
        try{$proc=Get-Process -Id ([int]$record.PID) -ErrorAction Stop;$proc.Kill();if([int]$record.PID -eq $ProcessId){$null=$proc.WaitForExit(5000)}}catch{continue}
    }
    $survivors=[Collections.Generic.List[int]]::new();$deadline=[DateTime]::UtcNow.AddSeconds(5)
    do{$survivors.Clear();foreach($record in $snapshot){$current=Get-MmtlWindowsProcessRecord -ProcessId ([int]$record.PID);if($current -and (Test-MmtlProcessIdentity -Process $current -Record $record)){$survivors.Add([int]$record.PID)}};if($survivors.Count){Start-Sleep -Milliseconds 100}}while($survivors.Count -and [DateTime]::UtcNow -lt $deadline)
    if($survivors.Count){throw "仍有登记进程无法停止：$($survivors -join ', ')。Session 保持活动状态。"}
    $stopped=[pscustomobject]@{PID=$ProcessId;ExitCode=$null;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');Error='Stopped by launcher request';StopRequested=$true}
    [IO.File]::WriteAllText([string]$entry.StatePath,($stopped|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if($entry.RuntimeLinkPath -and (Get-Command Remove-MmtlFabricRuntimeLink -ErrorAction SilentlyContinue)){Remove-MmtlFabricRuntimeLink -ProjectRoot $entry.WorkingDirectory -LinkPath $entry.RuntimeLinkPath -TargetPath $entry.RuntimeTargetPath}
    return $true
}
Export-ModuleMember -Function Start-MmtlTrackedProcess,Stop-MmtlTrackedProcess,Write-MmtlPidRegistry,Test-MmtlProcessIdentity,Get-MmtlProcessSnapshot
