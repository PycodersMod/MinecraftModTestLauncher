Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimeEvents.psm1')
Import-Module (Join-Path $PSScriptRoot 'RuntimeEventStore.psm1')

function Get-MmtlAuthenticationObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][ValidateSet('Client','Host','Guest')][string]$Role,
        [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ProcessIdentity,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    $code = if ([regex]::IsMatch($Text,'(?i)(multiplayer\.authentication\.invalid_session|invalid session|failed to verify username)',[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromMilliseconds(150))) { 'INVALID_SESSION' }
        elseif ([regex]::IsMatch($Text,'(?i)(login required|not authenticated|please log in)',[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromMilliseconds(150))) { 'AUTH_REQUIRED' }
        elseif ([regex]::IsMatch($Text,'(?i)(authentication servers are down|authentication service unavailable|authentication failed)',[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromMilliseconds(150))) { 'AUTH_FAILURE' }
        else { $null }
    if ($code) {
        $events = @(Get-MmtlRuntimeEvents -SessionPath $SessionPath -SkipInvalidLines)
        if (-not @($events | Where-Object { [int]$_.pid -eq $ProcessId -and [string]$_.processIdentity -ceq $ProcessIdentity -and [string]$_.eventCode -ceq $code }).Count) {
            $event = New-MmtlRuntimeEvent -SessionId $SessionId -Role $Role -ProcessId $ProcessId -ProcessIdentity $ProcessIdentity -SourceType RuntimeLog -EventCode $code -Summary '客户端日志报告认证状态；观察器未读取凭据、认证令牌或尝试修复。'
            Write-MmtlRuntimeEvent -SessionPath $SessionPath -Event $event | Out-Null
        }
    }
    return [pscustomobject]@{code=$code;credentialsRead=$false;authenticationAttempted=$false}
}

Export-ModuleMember -Function Get-MmtlAuthenticationObservation
