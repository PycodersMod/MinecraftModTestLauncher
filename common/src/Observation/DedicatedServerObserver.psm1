Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimeEvents.psm1')
Import-Module (Join-Path $PSScriptRoot 'RuntimeEventStore.psm1')
$script:MmtlServerObserverSafetyModule = Import-Module (Join-Path $PSScriptRoot 'ObservationSafety.psm1') -PassThru
function Resolve-MmtlServerObserverSafePath { param([string]$Session,[string]$Target,[switch]$AllowMissing) return & $script:MmtlServerObserverSafetyModule {param($s,$t,$missing) Resolve-MmtlObserverSafePath -SessionPath $s -Target $t -AllowMissing:$missing} $Session $Target $AllowMissing.IsPresent }

function Test-MmtlServerLoopbackListener {
    param([ValidateRange(1,65535)][int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync([Net.IPAddress]::Loopback,$Port)
        return [bool]$task.Wait(300)
    } catch { return $false }
    finally { $client.Dispose() }
}

function Invoke-MmtlDedicatedServerObserver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,
        [ValidateRange(0,3600)][int]$TimeoutSeconds=0,
        [scriptblock]$ProcessLookup,
        [scriptblock]$IdentityCheck
    )
    $session = [IO.Path]::GetFullPath($SessionPath)
    $sessionId = [IO.Path]::GetFileName($session)
    $registryPath = Join-Path $session 'pids.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { throw 'Session 缺少登记进程表。' }
    $registryPath = Resolve-MmtlServerObserverSafePath -Session $session -Target $registryPath
    if (-not $ProcessLookup) { $ProcessLookup = { param($processId) Get-MmtlProcessRecord -ProcessId $processId } }
    if (-not $IdentityCheck) { $IdentityCheck = { param($process,$entry) Test-MmtlProcessIdentity -Process $process -Record $entry } }
    $servers = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -ErrorAction Stop | Where-Object { [string]$_.Role -ceq 'Server' })
    if (-not $servers.Count) { throw 'Session 没有登记 Dedicated Server 角色。' }
    $results = [Collections.Generic.List[object]]::new()
    $events = @(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines)
    foreach ($entry in $servers) {
        $runtimeProperty = $entry.PSObject.Properties['RuntimeDirectory']
        $runtime = if ($runtimeProperty) { [string]$runtimeProperty.Value } else { '' }
        $ready = $false; $listening = $false; $crashed = $false; $stopped = $false
        if ($runtime) {
            $runtime = Resolve-MmtlServerObserverSafePath -Session $session -Target $runtime
            $markerPath = Join-Path $runtime 'mmtl-session.id'
            $logPath = Join-Path $runtime 'logs/latest.log'
            $markerPath = Resolve-MmtlServerObserverSafePath -Session $session -Target $markerPath -AllowMissing
            $logPath = Resolve-MmtlServerObserverSafePath -Session $session -Target $logPath -AllowMissing
            $markerValid = (Test-Path -LiteralPath $markerPath -PathType Leaf) -and ((Get-Content -LiteralPath $markerPath -Raw).Trim() -ceq $sessionId)
            $logText = if (Test-Path -LiteralPath $logPath -PathType Leaf) { (Get-Content -LiteralPath $logPath -Tail 4000 -ErrorAction Stop) -join "`n" } else { '' }
            $readyMarker = [regex]::IsMatch($logText,'(?im)\bDone\s*\([0-9.]+s\)!\s*For help, type', [Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromMilliseconds(150))
            $crashDirectory = Join-Path $runtime 'crash-reports'
            if (Test-Path -LiteralPath $crashDirectory -PathType Container) { $crashDirectory = Resolve-MmtlServerObserverSafePath -Session $session -Target $crashDirectory; $crashed = @(Get-ChildItem -LiteralPath $crashDirectory -File -Filter 'crash-*.txt' -ErrorAction Stop).Count -gt 0 }
            $process = & $ProcessLookup ([int]$entry.PID)
            $identityValid = $process -and (& $IdentityCheck $process $entry)
            $ready = [bool]($identityValid -and $markerValid -and $readyMarker)
            $listening = [bool]($ready -and (Test-MmtlServerLoopbackListener -Port $Port))
            if ($ready) {
                if (-not @($events | Where-Object { [int]$_.pid -eq [int]$entry.PID -and [string]$_.eventCode -ceq 'SERVER_READY' }).Count) {
                    $event = New-MmtlRuntimeEvent -SessionId $sessionId -Role Server -ProcessId ([int]$entry.PID) -ProcessIdentity ([string]$entry.StartIdentity) -SourceType RuntimeLog -EventCode SERVER_READY -Summary '登记的 Server 进程输出 ready marker，且当前 Session marker 匹配。' -Metadata @{port=$Port}
                    Write-MmtlRuntimeEvent -SessionPath $session -Event $event | Out-Null; $events += $event
                }
            }
            if ($listening -and -not @($events | Where-Object { [int]$_.pid -eq [int]$entry.PID -and [string]$_.eventCode -ceq 'SERVER_LISTENING' }).Count) {
                $event = New-MmtlRuntimeEvent -SessionId $sessionId -Role Server -ProcessId ([int]$entry.PID) -ProcessIdentity ([string]$entry.StartIdentity) -SourceType Observer -EventCode SERVER_LISTENING -Summary 'Dedicated Server 的 localhost TCP 端口可连接。' -Metadata @{port=$Port}
                Write-MmtlRuntimeEvent -SessionPath $session -Event $event | Out-Null; $events += $event
            }
        }
        $statePath = Join-Path $session "process-$([int]$entry.PID).exit.json"
        $statePath = Resolve-MmtlServerObserverSafePath -Session $session -Target $statePath -AllowMissing
        if (-not $ready -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop
            $stopped = [bool]$state.StopRequested -and ([int]$state.ExitCode -eq 0 -or $null -eq $state.ExitCode)
            $crashed = $crashed -or (-not $stopped -and [int]$state.ExitCode -ne 0)
            $code = if ($stopped) { 'SERVER_STOPPED' } elseif ($crashed) { 'SERVER_CRASH' } else { $null }
            if ($code -and -not @($events | Where-Object { [int]$_.pid -eq [int]$entry.PID -and [string]$_.eventCode -ceq $code }).Count) {
                $event = New-MmtlRuntimeEvent -SessionId $sessionId -Role Server -ProcessId ([int]$entry.PID) -ProcessIdentity ([string]$entry.StartIdentity) -SourceType Process -EventCode $code -Summary $(if($stopped){'Dedicated Server 已安全停止。'}else{'Dedicated Server 异常退出。'})
                Write-MmtlRuntimeEvent -SessionPath $session -Event $event | Out-Null
            }
        }
        $rehearsal = if ($entry.PSObject.Properties['Rehearsal']) { [bool]$entry.Rehearsal } else { $false }
        $results.Add([pscustomobject]@{pid=[int]$entry.PID;role='Server';ready=$ready;listening=$listening;crashed=$crashed;stopped=$stopped;port=$Port;rehearsal=$rehearsal;validationEligible=$false})
    }
    return [pscustomobject]@{sessionId=$sessionId;servers=@($results.ToArray());observedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
}

Export-ModuleMember -Function Invoke-MmtlDedicatedServerObserver,Test-MmtlServerLoopbackListener
