Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimeEvents.psm1')
Import-Module (Join-Path $PSScriptRoot 'RuntimeEventStore.psm1')
$script:MmtlLanPortManagerModule=Import-Module (Join-Path $PSScriptRoot '..\PortManager.psm1') -PassThru
$script:MmtlLanObserverSafetyModule = Import-Module (Join-Path $PSScriptRoot 'ObservationSafety.psm1') -PassThru
function Resolve-MmtlLanObserverSafePath { param([string]$Session,[string]$Target,[switch]$AllowMissing) return & $script:MmtlLanObserverSafetyModule {param($s,$t,$missing) Resolve-MmtlObserverSafePath -SessionPath $s -Target $t -AllowMissing:$missing} $Session $Target $AllowMissing.IsPresent }

function Invoke-MmtlLanObserver {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[scriptblock]$ProcessLookup,[scriptblock]$IdentityCheck)
    $session = [IO.Path]::GetFullPath($SessionPath); $sessionId = [IO.Path]::GetFileName($session)
    $registryPath = Join-Path $session 'pids.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { throw 'Session 缺少登记进程表。' }
    $registryPath = Resolve-MmtlLanObserverSafePath -Session $session -Target $registryPath
    if (-not $ProcessLookup) { $ProcessLookup = { param($processId) Get-MmtlProcessRecord -ProcessId $processId } }
    if (-not $IdentityCheck) { $IdentityCheck = { param($process,$entry) Test-MmtlProcessIdentity -Process $process -Record $entry } }
    $hosts = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -ErrorAction Stop | Where-Object { [string]$_.Role -ceq 'Host' })
    $result = [Collections.Generic.List[object]]::new(); $events = @(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines)
    foreach ($entry in $hosts) {
        $runtimeProperty = $entry.PSObject.Properties['RuntimeDirectory']; $runtime = if ($runtimeProperty) { [string]$runtimeProperty.Value } else { '' }
        $port = $null
        if ($runtime) {
            $runtime = Resolve-MmtlLanObserverSafePath -Session $session -Target $runtime
            $markerPath = Join-Path $runtime 'mmtl-session.id'; $logPath = Join-Path $runtime 'logs/latest.log'
            $markerPath = Resolve-MmtlLanObserverSafePath -Session $session -Target $markerPath -AllowMissing
            $logPath = Resolve-MmtlLanObserverSafePath -Session $session -Target $logPath -AllowMissing
            $markerValid = (Test-Path -LiteralPath $markerPath -PathType Leaf) -and ((Get-Content -LiteralPath $markerPath -Raw).Trim() -ceq $sessionId)
            $process = & $ProcessLookup ([int]$entry.PID); $identityValid = $process -and (& $IdentityCheck $process $entry)
            if ($markerValid -and $identityValid -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
                $port = & $script:MmtlLanPortManagerModule {param($path) Get-MmtlLanPortFromLog -Path $path} $logPath
                if ($port -and [int]$port -ge 1 -and [int]$port -le 65535) {
                    if (-not @($events | Where-Object { [int]$_.pid -eq [int]$entry.PID -and [string]$_.processIdentity -ceq [string]$entry.StartIdentity -and [string]$_.eventCode -ceq 'LAN_PORT_PUBLISHED' }).Count) {
                        $event = New-MmtlRuntimeEvent -SessionId $sessionId -Role Host -ProcessId ([int]$entry.PID) -ProcessIdentity ([string]$entry.StartIdentity) -SourceType RuntimeLog -EventCode LAN_PORT_PUBLISHED -Summary '当前 Host Session 日志发布了 LAN 端口。' -Metadata @{port=[int]$port;sourceRole='Host'}
                        Write-MmtlRuntimeEvent -SessionPath $session -Event $event | Out-Null
                    }
                } else { $port = $null }
            } else { $port = $null }
        }
        $result.Add([pscustomobject]@{pid=[int]$entry.PID;sourceRole='Host';port=$port;sessionId=$sessionId})
    }
    return [pscustomobject]@{sessionId=$sessionId;hosts=@($result.ToArray());observedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
}

Export-ModuleMember -Function Invoke-MmtlLanObserver
