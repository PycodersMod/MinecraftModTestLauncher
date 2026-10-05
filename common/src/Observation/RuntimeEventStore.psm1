Set-StrictMode -Version Latest

$script:MmtlRuntimeEventModule = Import-Module (Join-Path $PSScriptRoot 'RuntimeEvents.psm1') -PassThru
$script:MmtlObservationSafetyModule = Import-Module (Join-Path $PSScriptRoot 'ObservationSafety.psm1') -PassThru

function Resolve-MmtlEventSafePath {
    param([string]$Session,[string]$Target,[switch]$AllowMissing)
    return & $script:MmtlObservationSafetyModule { param($s,$t,$missing) Resolve-MmtlObserverSafePath -SessionPath $s -Target $t -AllowMissing:$missing } $Session $Target $AllowMissing.IsPresent
}

function Test-MmtlStoredRuntimeEvent {
    param([Parameter(Mandatory)]$Event)
    return [bool](& $script:MmtlRuntimeEventModule { param($candidate) Test-MmtlRuntimeEvent -Event $candidate } $Event)
}

function Assert-MmtlEventSessionPath {
    param([Parameter(Mandatory)][string]$SessionPath)
    $session = [IO.Path]::GetFullPath($SessionPath)
    if (-not (Test-Path -LiteralPath $session -PathType Container)) { throw 'Runtime Event Session 目录不存在。' }
    $null = Resolve-MmtlEventSafePath -Session $session -Target (Join-Path $session 'runtime-events.jsonl') -AllowMissing
    return $session
}

function Write-MmtlRuntimeEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$Event,[int]$LockTimeoutSeconds = 10)
    $session = Assert-MmtlEventSessionPath $SessionPath
    if (-not (Test-MmtlStoredRuntimeEvent $Event)) { throw 'Runtime Event 不符合事件契约。' }
    $manifest = Join-Path $session 'session.v2.json'
    $registeredId = [IO.Path]::GetFileName($session)
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        $sessionRecord = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -ErrorAction Stop
        $manifestId = if ($sessionRecord.sessionId) { [string]$sessionRecord.sessionId } else { [string]$sessionRecord.session.sessionId }
        if ($manifestId) { $registeredId = $manifestId }
    }
    if ($registeredId -cne [string]$Event.sessionId) { throw 'Runtime Event Session 标识与 Session 目录不匹配。' }
    $path = Join-Path $session 'runtime-events.jsonl'
    $path = Resolve-MmtlEventSafePath -Session $session -Target $path -AllowMissing
    $json = $Event | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $deadline = [DateTime]::UtcNow.AddSeconds($LockTimeoutSeconds)
    $stream = $null
    do {
        try { $stream = [IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::None) }
        catch [IO.IOException] { Start-Sleep -Milliseconds 25 }
    } while (-not $stream -and [DateTime]::UtcNow -lt $deadline)
    if (-not $stream) { throw 'Runtime Event 文件锁定超时。' }
    try { $stream.Seek(0,[IO.SeekOrigin]::End) | Out-Null; $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    return $path
}

function Get-MmtlRuntimeEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[switch]$SkipInvalidLines)
    $session = Assert-MmtlEventSessionPath $SessionPath
    $path = Join-Path $session 'runtime-events.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $path = Resolve-MmtlEventSafePath -Session $session -Target $path
    $events = [Collections.Generic.List[object]]::new()
    foreach ($line in [IO.File]::ReadAllLines($path,[Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
            if (-not (Test-MmtlStoredRuntimeEvent $event)) { throw 'Runtime Event 不符合事件契约。' }
            $events.Add($event)
        } catch { if (-not $SkipInvalidLines) { throw 'Runtime Event 文件包含无效行。' } }
    }
    return @($events.ToArray())
}

Export-ModuleMember -Function Write-MmtlRuntimeEvent,Get-MmtlRuntimeEvents
