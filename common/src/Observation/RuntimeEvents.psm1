Set-StrictMode -Version Latest

$script:MmtlRuntimeEventCodes = @(
    'PROCESS_STARTED','PROCESS_EXITED','PROCESS_IDENTITY_LOST','PROCESS_ORPHANED',
    'CLIENT_INIT_DETECTED','CLIENT_MAIN_MENU_DETECTED','CLIENT_LAUNCH_VERIFIED',
    'CLIENT_EXITED_BEFORE_INITIALIZATION','CLIENT_CRASH','SERVER_STARTING',
    'SERVER_READY','SERVER_LISTENING','SERVER_STOPPING','SERVER_STOPPED',
    'SERVER_CRASH','LAN_PORT_PUBLISHED','CRASH_DETECTED','FATAL_ERROR',
    'AUTH_REQUIRED','INVALID_SESSION','AUTH_FAILURE','TIMED_OUT',
    'JAVA_RUNTIME_OBSERVED','HUMAN_OBSERVATION_CONFIRMED','AGENT_WORLD_JOINED','INTEGRATED_SERVER_DETECTED',
    'LAN_PUBLISH_REQUESTED','AGENT_GUEST_CONNECTED','AGENT_ERROR','REHEARSAL_STARTED',
    'REHEARSAL_COMPLETED','REHEARSAL_FAILED','REHEARSAL_GUEST_CONNECTED','REHEARSAL_PORT_RETRY','BUILD_FAILED','PROCESS_START_FAILED'
)

function ConvertTo-MmtlSafeObservationSummary {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    $value = [string]$Text
    $value = [regex]::Replace($value, '(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,})\b', '[REDACTED_TOKEN]')
    $value = [regex]::Replace($value, '(?i)\b(token|password|client_secret|access_token|authorization)\s*([:=])\s*[^\s,;]+', '$1$2[REDACTED]')
    $value = [regex]::Replace($value, '(?i)\bBearer\s+[^\s,;]+', 'Bearer [REDACTED]')
    $value = [regex]::Replace($value, '(?i)[A-Z]:\\Users\\[^\\\s]+', '[LOCAL_PATH]')
    $value = [regex]::Replace($value, '(?i)/home/[^/\s]+', '[LOCAL_PATH]')
    $value = [regex]::Replace($value, '(?i)/Users/[^/\s]+', '[LOCAL_PATH]')
    if ($value.Length -gt 240) { $value = $value.Substring(0, 240) }
    return $value
}

function New-MmtlRuntimeEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][ValidateSet('Client','Host','Guest','Server','Build','Launcher','Process')][string]$Role,
        [Parameter(Mandatory)][ValidateRange(0,[int]::MaxValue)][int]$ProcessId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProcessIdentity,
        [Parameter(Mandatory)][ValidateSet('Process','Stdout','Stderr','RuntimeLog','CrashReport','Observer','Agent','Rehearsal','Human')][string]$SourceType,
        [Parameter(Mandatory)][string]$EventCode,
        [string]$Summary = '',
        [string]$TimestampUtc = [DateTimeOffset]::UtcNow.ToString('o'),
        [hashtable]$Metadata = @{}
    )
    if ($SessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { throw 'Runtime Event 的 Session 标识无效。' }
    if ($EventCode -cnotin $script:MmtlRuntimeEventCodes) { throw 'Runtime Event 事件码未注册。' }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($TimestampUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$timestamp)) { throw 'Runtime Event 时间戳无效。' }
    $safeMetadata = [ordered]@{}
    foreach ($key in @($Metadata.Keys | Sort-Object)) {
        if ([string]$key -notmatch '^[A-Za-z][A-Za-z0-9_]{0,39}$' -or [string]$key -match '(?i)token|password|secret|credential|raw|path|home|account|username') { continue }
        $value = $Metadata[$key]
        if ($null -eq $value) { $safeMetadata[$key] = $null }
        elseif ($value -is [string]) { $safeMetadata[$key] = ConvertTo-MmtlSafeObservationSummary $value }
        elseif ($value -is [ValueType]) { $safeMetadata[$key] = $value }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        sessionId = $SessionId
        role = $Role
        pid = $ProcessId
        processIdentity = (ConvertTo-MmtlSafeObservationSummary $ProcessIdentity)
        timestampUtc = $timestamp.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)
        sourceType = $SourceType
        eventCode = $EventCode
        summary = (ConvertTo-MmtlSafeObservationSummary $Summary)
        metadata = $safeMetadata
    }
}

function Test-MmtlRuntimeEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Event)
    $required = @('schemaVersion','sessionId','role','pid','processIdentity','timestampUtc','sourceType','eventCode','summary','metadata')
    foreach ($name in $required) { if ($null -eq $Event.PSObject.Properties[$name]) { return $false } }
    if ([int]$Event.schemaVersion -ne 1 -or [string]$Event.eventCode -cnotin $script:MmtlRuntimeEventCodes) { return $false }
    if ([string]$Event.sessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { return $false }
    if ([string]$Event.sourceType -notin @('Process','Stdout','Stderr','RuntimeLog','CrashReport','Observer','Agent','Rehearsal','Human')) { return $false }
    return $true
}

Export-ModuleMember -Function New-MmtlRuntimeEvent,Test-MmtlRuntimeEvent,ConvertTo-MmtlSafeObservationSummary
