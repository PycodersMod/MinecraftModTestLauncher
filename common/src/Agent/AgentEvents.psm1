Set-StrictMode -Version Latest

$script:RuntimeEventModule=Import-Module (Join-Path $PSScriptRoot '../Observation/RuntimeEvents.psm1') -PassThru
$script:AgentEventMap=@{
    CLIENT_INITIALIZED='CLIENT_INIT_DETECTED'
    MAIN_MENU_READY='CLIENT_MAIN_MENU_DETECTED'
    WORLD_JOINED='AGENT_WORLD_JOINED'
    INTEGRATED_SERVER_DETECTED='INTEGRATED_SERVER_DETECTED'
    LAN_PUBLISH_REQUESTED='LAN_PUBLISH_REQUESTED'
    LAN_PUBLISHED='LAN_PORT_PUBLISHED'
    GUEST_CONNECTED='AGENT_GUEST_CONNECTED'
    AGENT_ERROR='AGENT_ERROR'
}

function ConvertFrom-MmtlAgentEventLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Line,[Parameter(Mandatory)][string]$ExpectedSessionId,[Parameter(Mandatory)][ValidateSet('Client','Host','Guest','Server')][string]$ExpectedRole,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedNonceHash,[Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,[Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProcessIdentity)
    try{$agentEvent=$Line|ConvertFrom-Json -ErrorAction Stop}catch{throw 'AGENT_EVENT_INVALID_JSON'}
    if([int]$agentEvent.schemaVersion -ne 1 -or -not $agentEvent.eventId -or -not $agentEvent.timestampUtc -or -not $agentEvent.eventType -or -not $agentEvent.summary){throw 'AGENT_EVENT_SCHEMA_INVALID'}
    if([string]$agentEvent.sessionId -cne $ExpectedSessionId){throw 'AGENT_EVENT_SESSION_MISMATCH'}
    if([string]$agentEvent.role -cne $ExpectedRole){throw 'AGENT_EVENT_ROLE_MISMATCH'}
    if([string]$agentEvent.sessionNonceHash -cne $ExpectedNonceHash){throw 'AGENT_EVENT_NONCE_MISMATCH'}
    if(-not $script:AgentEventMap.ContainsKey([string]$agentEvent.eventType)){throw 'AGENT_EVENT_TYPE_UNSUPPORTED'}
    foreach($property in $agentEvent.PSObject.Properties.Name){if($property -match '(?i)token|password|secret|credential|raw|path|account|username'){throw 'AGENT_EVENT_SENSITIVE_FIELD_REJECTED'}}
    $metadata=@{agentEventId=[string]$agentEvent.eventId;sourceCategory=if($agentEvent.eventType -eq 'AGENT_ERROR'){'MMTL_INFRASTRUCTURE'}else{'AGENT_OBSERVATION'}}
    return & $script:RuntimeEventModule {param($sid,$role,$pidValue,$identity,$code,$summary,$time,$meta) New-MmtlRuntimeEvent -SessionId $sid -Role $role -ProcessId $pidValue -ProcessIdentity $identity -SourceType Agent -EventCode $code -Summary $summary -TimestampUtc $time -Metadata $meta} $ExpectedSessionId $ExpectedRole $ProcessId $ProcessIdentity $script:AgentEventMap[[string]$agentEvent.eventType] ([string]$agentEvent.summary) ([string]$agentEvent.timestampUtc) $metadata
}

Export-ModuleMember -Function ConvertFrom-MmtlAgentEventLine
