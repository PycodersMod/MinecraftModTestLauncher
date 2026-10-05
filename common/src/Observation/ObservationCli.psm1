Set-StrictMode -Version Latest

function Invoke-MmtlObservationCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [scriptblock]$ProcessLookup,
        [scriptblock]$IdentityCheck
    )
    $observeIndex = [Array]::IndexOf($Arguments,'--observe-session')
    $eventsIndex = [Array]::IndexOf($Arguments,'--session-events')
    if ($observeIndex -ge 0 -and $eventsIndex -ge 0) { throw 'OBSERVATION_OPTION_CONFLICT: 只能选择 --observe-session 或 --session-events。' }
    if ($observeIndex -lt 0 -and $eventsIndex -lt 0) { return $null }
    $selectedIndex = if ($observeIndex -ge 0) { $observeIndex } else { $eventsIndex }
    if ($selectedIndex + 1 -ge $Arguments.Count) { throw 'OBSERVATION_SESSION_REQUIRED: 缺少 Session ID。' }
    $sessionId = [string]$Arguments[$selectedIndex + 1]
    if ($sessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'OBSERVATION_SESSION_INVALID: Session ID 无效。' }
    for ($index=0; $index -lt $Arguments.Count; $index++) {
        if ($index -eq $selectedIndex -or $Arguments[$index] -ceq $sessionId -or $Arguments[$index] -ceq '--json') { continue }
        if ($Arguments[$index] -ceq '--timeout-seconds' -and $observeIndex -ge 0) { continue }
        if ($Arguments[$index] -ceq '--timeout-seconds') { throw 'OBSERVATION_OPTION_INVALID: --timeout-seconds 只适用于 --observe-session。' }
        if ($Arguments[$index] -ceq '--observe-session' -or $Arguments[$index] -ceq '--session-events') { continue }
        if ($index -gt 0 -and $Arguments[$index-1] -ceq '--timeout-seconds') { continue }
        if ($Arguments[$index] -ceq '--config-file' -or $Arguments[$index] -ceq '--profile') { continue }
        if ($index -gt 0 -and $Arguments[$index-1] -in @('--config-file','--profile')) { continue }
        throw "OBSERVATION_OPTION_INVALID: 不支持的观察参数 $($Arguments[$index])。"
    }
    $timeout = 0
    $timeoutIndex = [Array]::IndexOf($Arguments,'--timeout-seconds')
    if ($timeoutIndex -ge 0) {
        if ($timeoutIndex + 1 -ge $Arguments.Count -or -not [int]::TryParse($Arguments[$timeoutIndex+1],[ref]$timeout) -or $timeout -lt 0 -or $timeout -gt 3600) { throw 'OBSERVATION_TIMEOUT_INVALID: timeout-seconds 必须为 0 至 3600。' }
    }
    $sessionsRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'sessions'))
    $sessionPath = [IO.Path]::GetFullPath((Join-Path $sessionsRoot $sessionId))
    $prefix = $sessionsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $sessionPath.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'OBSERVATION_SESSION_INVALID: Session 路径越出 Runtime Root。' }
    if (-not (Test-Path -LiteralPath $sessionPath -PathType Container)) { throw 'SESSION_NOT_FOUND: 未找到指定 Session。' }

    if ($eventsIndex -ge 0) {
        $events = @(Get-MmtlRuntimeEvents -SessionPath $sessionPath)
        return [pscustomobject][ordered]@{sessionId=$sessionId;eventCount=$events.Count;events=$events;readOnly=$true}
    }
    $observation = Invoke-MmtlProcessObserver -SessionPath $sessionPath -TimeoutSeconds $timeout -ProcessLookup $ProcessLookup -IdentityCheck $IdentityCheck
    $markerHints = @()
    $planPath = Join-Path $sessionPath 'execution-plan.json'
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $loaderId = [string]$plan.project.loader.id
        $minecraftVersion = [string]$plan.project.minecraftId
        $adapterFile = switch ($loaderId) { 'Forge' {'Forge.psm1'} 'Fabric' {'Fabric.psm1'} 'NeoForge' {'NeoForge.psm1'} 'Quilt' {'Quilt.psm1'} default {$null} }
        if ($adapterFile) {
            $adapter = Import-Module (Join-Path $PSScriptRoot "../Adapters/$adapterFile") -PassThru
            $hintCommand = "Get-Mmtl$($loaderId)ClientMarkerHints"
            if ($adapter.ExportedCommands.ContainsKey($hintCommand)) { $markerHints = @(& $adapter { param($name,$version) & $name -MinecraftVersion $version } $hintCommand $minecraftVersion) }
        }
    }
    $clientObservation = Invoke-MmtlClientObserver -SessionPath $sessionPath -MarkerHints $markerHints -ProcessLookup $ProcessLookup -IdentityCheck $IdentityCheck
    $javaObservation = Invoke-MmtlJavaRuntimeObserver -SessionPath $sessionPath -ProcessLookup $ProcessLookup -IdentityCheck $IdentityCheck
    $lanObservation = Invoke-MmtlLanObserver -SessionPath $sessionPath -ProcessLookup $ProcessLookup -IdentityCheck $IdentityCheck
    $crashObservation = Invoke-MmtlCrashObserver -SessionPath $sessionPath
    $serverObservation = [pscustomobject]@{sessionId=$sessionId;servers=@()}
    $serverEntries = @(Get-Content -LiteralPath (Join-Path $sessionPath 'pids.json') -Raw | ConvertFrom-Json -ErrorAction Stop | Where-Object { [string]$_.Role -ceq 'Server' })
    if ($serverEntries.Count -and (Test-Path -LiteralPath (Join-Path $sessionPath 'session.json') -PathType Leaf)) {
        $sessionState = Get-Content -LiteralPath (Join-Path $sessionPath 'session.json') -Raw | ConvertFrom-Json -ErrorAction Stop
        $port = [int]$sessionState.metadata.port
        if ($port -ge 1 -and $port -le 65535) { $serverObservation = Invoke-MmtlDedicatedServerObserver -SessionPath $sessionPath -Port $port -ProcessLookup $ProcessLookup -IdentityCheck $IdentityCheck }
    }
    $events = @(Get-MmtlRuntimeEvents -SessionPath $sessionPath -SkipInvalidLines)
    return [pscustomobject][ordered]@{
        sessionId=$sessionId
        processes=@($observation.processes)
        clients=@($clientObservation.clients)
        servers=@($serverObservation.servers)
        hosts=@($lanObservation.hosts)
        javaRuntimes=@($javaObservation.runtimes)
        failures=@($crashObservation.classifications)
        eventCount=$events.Count
        eventCodes=@($events | ForEach-Object eventCode)
        timedOut=[bool]$observation.timedOut
        validationCandidate=@($events | Where-Object eventCode -eq 'CLIENT_LAUNCH_VERIFIED').Count -gt 0
        validationEligible=@($clientObservation.clients | Where-Object validationEligible).Count -gt 0
        readOnly=$true
    }
}

Export-ModuleMember -Function Invoke-MmtlObservationCommand
