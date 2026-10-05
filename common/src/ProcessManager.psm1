Import-Module (Join-Path $PSScriptRoot 'RuntimeManager.psm1')
Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
Import-Module (Join-Path $PSScriptRoot 'SessionLock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AtomicFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SessionLifecycle.psm1')

function Get-MmtlProcessApi {
    $provider=$global:MmtlPlatformProvider;$api=$provider.ProcessApi
    if (-not $api) { throw '当前平台未注册进程身份接口。' }
    return $api
}
function Assert-MmtlNativeProcessManagement {
    if([string]$global:MmtlPlatformProvider.ProcessManagement -ne 'Native'){throw '当前平台不支持受跟踪进程管理。'}
}
function Get-MmtlProcessRecord { param([Parameter(Mandatory)][int]$ProcessId) $api=Get-MmtlProcessApi;return & $api.GetRecord $ProcessId }
function Get-MmtlProcessSnapshot { param([Parameter(Mandatory)][int]$RootProcessId) $api=Get-MmtlProcessApi;return @(& $api.GetSnapshot $RootProcessId) }
function Write-MmtlPidRegistry {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object[]]$Entries,$Lock)
    $session=[IO.Path]::GetFullPath((Split-Path -Parent $Path));$ownsLock=$false
    if(-not $Lock){$Lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session;$ownsLock=$true}
    try{
        if([IO.Path]::GetFullPath([string]$Lock.lockPath) -cne [IO.Path]::GetFullPath((Join-Path $session '.session.lock')) -or $Lock.released){throw 'SESSION_LOCK_OWNER_MISMATCH'}
        Write-MmtlAtomicTextFile -Path $Path -Content ((@($Entries)|ConvertTo-Json -Depth 12)+"`n")
    }finally{if($ownsLock){Remove-MmtlSessionLock -Lock $Lock}}
}
function Test-MmtlProcessIdentity {
    param([Parameter(Mandatory)]$Process,[Parameter(Mandatory)]$Record)
    $api=Get-MmtlProcessApi
    return [bool](& $api.TestIdentity $Process $Record)
}
function Start-MmtlTrackedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$FilePath,[string[]]$ArgumentList=@(),[Parameter(Mandatory)][string]$WorkingDirectory,[Parameter(Mandatory)][string]$LogPath,[string]$Role='Process',[string]$Username='',[string]$RuntimeDirectory,[string]$RuntimeLinkPath,[string]$RuntimeTargetPath,[switch]$Rehearsal,[switch]$PassThru)
    $api=Get-MmtlProcessApi;Assert-MmtlNativeProcessManagement
    $session=[IO.Path]::GetFullPath($SessionPath);$runtime=[IO.Path]::GetFullPath((Split-Path (Split-Path $session -Parent) -Parent))
    if(-not(Test-MmtlInsideRoot -Root (Join-Path $runtime 'sessions') -Target $session)){throw 'Session 路径无效。'}
    if([IO.Path]::GetFullPath((Split-Path $session -Parent)) -ne [IO.Path]::GetFullPath((Join-Path $runtime 'sessions'))){throw 'Session 必须是 sessions 的直接子目录。'}
    if(-not(Test-MmtlInsideRoot -Root $session -Target $LogPath)){throw '日志路径必须位于当前 Session。'}
    if($RuntimeDirectory -and -not(Test-MmtlInsideRoot -Root $session -Target $RuntimeDirectory)){throw '进程 RuntimeDirectory 必须位于当前 Session。'}
    Assert-MmtlNoReparsePath -Path $session|Out-Null
    $registry=Join-Path $session 'pids.json';if(-not(Test-Path -LiteralPath $registry)){throw 'Session 缺少 pids.json。'}
    $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session;$proc=$null;$trackedIdentity=$null
    try{
        $manifestPath=Join-Path $session 'session.v2.json'
        if(Test-Path -LiteralPath $manifestPath -PathType Leaf){$validation=Test-MmtlSessionV2 -SessionPath $session;if(-not $validation.valid -or $validation.state -in @('Abandoned','Completed','Failed','Stopped')){throw 'SESSION_NOT_LAUNCHABLE'}}
        $proc=Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath+'.err') -PassThru
        $proc.Refresh();$current=& $api.GetRecord $proc.Id
        if(-not $current){throw '无法取得新进程的身份快照。'}
        $trackedIdentity=$current
        $entry=[pscustomobject]@{PID=$proc.Id;Role=$Role;Username=$Username;StartIdentity=[string]$current.StartIdentity;StartTimeUtc=[string]$current.StartTimeUtc;StartTimeToken=[string]$current.StartTimeToken;Executable=[string]$current.Executable;ParentPID=[int]$current.ParentPID;CommandLine=[string]$current.CommandLine;SessionID=$current.SessionID;Command=$FilePath;WorkingDirectory=$WorkingDirectory;Arguments=@($ArgumentList);LogPath=$LogPath;RuntimeDirectory=if($RuntimeDirectory){[IO.Path]::GetFullPath($RuntimeDirectory)}else{$null};StatePath=(Join-Path $session "process-$($proc.Id).exit.json");ProcessTree=@();RuntimeLinkPath=$RuntimeLinkPath;RuntimeTargetPath=$RuntimeTargetPath;Rehearsal=[bool]$Rehearsal.IsPresent}
        $items=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json);$items+= $entry;Write-MmtlPidRegistry -Path $registry -Entries $items -Lock $lock
        if($PassThru){return [pscustomobject]@{ProcessId=[int]$proc.Id;Process=$proc;StartIdentity=[string]$current.StartIdentity;StatePath=[string]$entry.StatePath;Rehearsal=[bool]$Rehearsal.IsPresent}}
        return $proc.Id
    }catch{
        if($proc -and $trackedIdentity){try{$current=& $api.GetRecord $proc.Id;if($current -and $api.TestIdentity -and (& $api.TestIdentity $current $trackedIdentity)){$proc.Kill();$null=$proc.WaitForExit(3000)}}catch{}}
        throw
    }finally{Remove-MmtlSessionLock -Lock $lock}
}
function Complete-MmtlTrackedProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][Diagnostics.Process]$Process,[Parameter(Mandatory)][string]$StartIdentity,[switch]$StopRequested)
    $session=[IO.Path]::GetFullPath($SessionPath);Assert-MmtlNoReparsePath -Path $session|Out-Null
    $processId=[int]$Process.Id;$registry=Join-Path $session 'pids.json';$expectedState=Join-Path $session "process-$processId.exit.json"
    if(-not(Test-MmtlInsideRoot -Root $session -Target $expectedState)){throw '进程退出状态路径越出 Session。'}
    Assert-MmtlNoReparsePath -Path $expectedState|Out-Null
    $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
    try{
        $entries=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json -ErrorAction Stop);$entry=$entries|Where-Object{[int]$_.PID -eq $processId}|Select-Object -First 1
        $entryIdentity=if($entry -and $entry.StartIdentity -is [DateTime]){$entry.StartIdentity.ToUniversalTime().ToString('o')}elseif($entry){[string]$entry.StartIdentity}else{''}
        if(-not $entry -or $entryIdentity -cne $StartIdentity){throw '进程退出记录与 Session 登记身份不符。'}
        if(-not $Process.HasExited){return $null}
        $state=[pscustomobject]@{PID=$processId;ExitCode=[int]$Process.ExitCode;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');Error=$(if([int]$Process.ExitCode -eq 0){$null}else{'已登记进程以非零退出码结束'});StopRequested=[bool]$StopRequested.IsPresent}
        Write-MmtlAtomicTextFile -Path $expectedState -Content (($state|ConvertTo-Json -Compress)+"`n")
        return $state
    }finally{Remove-MmtlSessionLock -Lock $lock}
}
function Stop-MmtlTrackedProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][int]$ProcessId)
    $null=Get-MmtlProcessApi;Assert-MmtlNativeProcessManagement
    $session=[IO.Path]::GetFullPath($SessionPath);Assert-MmtlNoReparsePath -Path $session|Out-Null
    $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
    try{
        $registry=Join-Path $session 'pids.json';if(-not(Test-Path -LiteralPath $registry)){throw 'Session 未登记进程。'}
        $items=@(Get-Content -LiteralPath $registry -Raw|ConvertFrom-Json);$entry=$items|Where-Object{[int]$_.PID -eq $ProcessId}|Select-Object -First 1
        if(-not $entry){throw '拒绝停止未登记进程。'}
        if($entry.StatePath -and -not(Test-MmtlInsideRoot -Root $session -Target ([string]$entry.StatePath))){throw '进程退出状态路径越出 Session，拒绝停止。'}
        $root=Get-MmtlProcessRecord -ProcessId $ProcessId;if(-not $root){return $false}
        if(-not(Test-MmtlProcessIdentity -Process $root -Record $entry)){throw '进程身份与登记记录不符，拒绝停止。'}
        $snapshot=Get-MmtlProcessSnapshot -RootProcessId $ProcessId;$tree=@($snapshot|Where-Object{[int]$_.PID -ne $ProcessId});$entry.ProcessTree=$tree;Write-MmtlPidRegistry -Path $registry -Entries $items -Lock $lock
        if(-not $PSCmdlet.ShouldProcess("PID $ProcessId 及其 $($tree.Count) 个登记子进程",'停止当前 Session 登记的进程')){return $false}
        foreach($record in @($snapshot|Sort-Object Depth -Descending)){$current=Get-MmtlProcessRecord -ProcessId ([int]$record.PID);if(-not $current -or -not(Test-MmtlProcessIdentity -Process $current -Record $record)){continue};try{$proc=Get-Process -Id ([int]$record.PID) -ErrorAction Stop;$proc.Kill();if([int]$record.PID -eq $ProcessId){$null=$proc.WaitForExit(5000)}}catch{continue}}
        $survivors=[Collections.Generic.List[int]]::new();$deadline=[DateTime]::UtcNow.AddSeconds(5)
        do{$survivors.Clear();foreach($record in $snapshot){$current=Get-MmtlProcessRecord -ProcessId ([int]$record.PID);if($current -and (Test-MmtlProcessIdentity -Process $current -Record $record)){$survivors.Add([int]$record.PID)}};if($survivors.Count){Start-Sleep -Milliseconds 100}}while($survivors.Count -and [DateTime]::UtcNow -lt $deadline)
        if($survivors.Count){throw "仍有登记进程无法停止：$($survivors -join ', ')。Session 保持活动状态。"}
        $stopped=[pscustomobject]@{PID=$ProcessId;ExitCode=$null;FinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');Error='由启动器请求停止';StopRequested=$true};Write-MmtlAtomicTextFile -Path ([string]$entry.StatePath) -Content (($stopped|ConvertTo-Json -Compress)+"`n")
        if($entry.RuntimeLinkPath -and (Get-Command Remove-MmtlFabricRuntimeLink -ErrorAction SilentlyContinue) -and $global:MmtlPlatformProvider.FabricRuntimeLink -eq 'Native'){Remove-MmtlFabricRuntimeLink -ProjectRoot $entry.WorkingDirectory -LinkPath $entry.RuntimeLinkPath -TargetPath $entry.RuntimeTargetPath}
        return $true
    }finally{Remove-MmtlSessionLock -Lock $lock}
}
Export-ModuleMember -Function Start-MmtlTrackedProcess,Complete-MmtlTrackedProcess,Stop-MmtlTrackedProcess,Write-MmtlPidRegistry,Test-MmtlProcessIdentity,Get-MmtlProcessSnapshot,Get-MmtlProcessRecord
