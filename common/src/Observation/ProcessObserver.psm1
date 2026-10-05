Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimeEvents.psm1')
Import-Module (Join-Path $PSScriptRoot 'RuntimeEventStore.psm1')
$script:MmtlProcessObserverSafetyModule = Import-Module (Join-Path $PSScriptRoot 'ObservationSafety.psm1') -PassThru
function Resolve-MmtlProcessObserverSafePath { param([string]$Session,[string]$Target,[switch]$AllowMissing) return & $script:MmtlProcessObserverSafetyModule {param($s,$t,$missing) Resolve-MmtlObserverSafePath -SessionPath $s -Target $t -AllowMissing:$missing} $Session $Target $AllowMissing.IsPresent }

function Get-MmtlObserverSessionId {
    param([Parameter(Mandatory)][string]$SessionPath)
    $manifest = Join-Path $SessionPath 'session.v2.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        $record = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -ErrorAction Stop
        $id = if ($record.sessionId) { [string]$record.sessionId } else { [string]$record.session.sessionId }
        if ($id) { return $id }
    }
    return [IO.Path]::GetFileName([IO.Path]::GetFullPath($SessionPath))
}

function Invoke-MmtlProcessObserver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [ValidateRange(0,3600)][int]$TimeoutSeconds = 0,
        [ValidateRange(25,5000)][int]$PollIntervalMilliseconds = 200,
        [ValidateSet('Client','Host','Guest','Server','Build','Launcher','Process')][string]$Role,
        [scriptblock]$ProcessLookup,
        [scriptblock]$IdentityCheck,
        [scriptblock]$EventWriter
    )
    $session = [IO.Path]::GetFullPath($SessionPath)
    if (-not (Test-Path -LiteralPath $session -PathType Container)) { throw 'Observer Session 目录不存在。' }
    $sessionItem = Get-Item -LiteralPath $session -Force
    if (($sessionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Observer 拒绝符号链接或 junction Session。' }
    $registryPath = Join-Path $session 'pids.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { throw 'Session 缺少登记进程表。' }
    $registryPath = Resolve-MmtlProcessObserverSafePath -Session $session -Target $registryPath
    if (-not $ProcessLookup) { $ProcessLookup = { param($processId) Get-MmtlProcessRecord -ProcessId $processId } }
    if (-not $IdentityCheck) { $IdentityCheck = { param($process,$entry) Test-MmtlProcessIdentity -Process $process -Record $entry } }
    if (-not $EventWriter) { $EventWriter = { param($path,$event) Write-MmtlRuntimeEvent -SessionPath $path -Event $event | Out-Null } }

    $sessionId = Get-MmtlObserverSessionId -SessionPath $session
    $entries = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -ErrorAction Stop)
    if ($Role) { $entries = @($entries | Where-Object { [string]$_.Role -ceq $Role }) }
    $existingEvents = @(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines)
    $results = [Collections.Generic.List[object]]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $results.Clear()
        $hasRunning = $false
        foreach ($entry in $entries) {
            $processId = [int]$entry.PID
            $identity = [string]$entry.StartIdentity
            if ($processId -le 0 -or -not $identity) { throw 'Session 登记进程缺少 PID 或启动身份。' }
            $current = & $ProcessLookup $processId
            $statePath = [string]$entry.StatePath
            $expectedStatePath = Join-Path $session "process-$processId.exit.json"
            if ($statePath -and [IO.Path]::GetFullPath($statePath) -cne [IO.Path]::GetFullPath($expectedStatePath)) { throw 'Observer 拒绝越出 Session 的退出状态路径。' }
            $expectedStatePath = Resolve-MmtlProcessObserverSafePath -Session $session -Target $expectedStatePath -AllowMissing
            if ($current) {
                if (& $IdentityCheck $current $entry) {
                    $status = 'Running'
                    $eventCode = 'PROCESS_STARTED'
                    $hasRunning = $true
                } else { $status = 'IdentityLost'; $eventCode = 'PROCESS_IDENTITY_LOST' }
                $summary = if ($status -eq 'Running') { '登记进程身份匹配。' } else { 'PID 对应的当前进程身份与 Session 登记不符。' }
            } elseif (Test-Path -LiteralPath $expectedStatePath -PathType Leaf) {
                $exit = Get-Content -LiteralPath $expectedStatePath -Raw | ConvertFrom-Json -ErrorAction Stop
                $status = 'Exited'; $eventCode = 'PROCESS_EXITED'
                $summary = "进程已退出；退出码=$([string]$exit.ExitCode)；用户停止=$([bool]$exit.StopRequested)。"
            } else {
                $status = 'Orphaned'; $eventCode = 'PROCESS_ORPHANED'
                $summary = '登记进程当前不存在且没有可信退出状态记录。'
            }
            $seen = @($existingEvents | Where-Object { [int]$_.pid -eq $processId -and [string]$_.processIdentity -ceq $identity -and [string]$_.eventCode -ceq $eventCode }).Count -gt 0
            if (-not $seen) {
                $event = New-MmtlRuntimeEvent -SessionId $sessionId -Role ([string]$entry.Role) -ProcessId $processId -ProcessIdentity $identity -SourceType Process -EventCode $eventCode -Summary $summary
                & $EventWriter $session $event
                $existingEvents += $event
            }
            $results.Add([pscustomobject]@{pid=$processId;role=[string]$entry.Role;processIdentity=$identity;status=$status;exitCode=if($status -eq 'Exited'){$exit.ExitCode}else{$null}})
        }
        if (-not $hasRunning -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    } while ($true)

    if ($hasRunning -and $TimeoutSeconds -gt 0 -and [DateTime]::UtcNow -ge $deadline) {
        foreach ($process in @($results | Where-Object status -eq 'Running')) {
            $seen = @($existingEvents | Where-Object { [int]$_.pid -eq $process.pid -and [string]$_.processIdentity -ceq $process.processIdentity -and [string]$_.eventCode -ceq 'TIMED_OUT' }).Count -gt 0
            if (-not $seen) {
                $event = New-MmtlRuntimeEvent -SessionId $sessionId -Role $process.role -ProcessId $process.pid -ProcessIdentity $process.processIdentity -SourceType Observer -EventCode TIMED_OUT -Summary 'Observer 等待超过配置时限。'
                & $EventWriter $session $event
            }
            $process.status = 'TimedOut'
        }
    }
    return [pscustomobject]@{sessionId=$sessionId;processes=@($results.ToArray());timedOut=@($results|Where-Object status -eq 'TimedOut').Count -gt 0;observedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
}

Export-ModuleMember -Function Invoke-MmtlProcessObserver
