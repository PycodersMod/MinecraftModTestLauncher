Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Contracts.psm1') -Force

function Get-MmtlHistoricalContract {
    [CmdletBinding()]
    param()
    $contract = Get-MmtlArchitectureContract
    [pscustomobject][ordered]@{
        sourceClasses = @($contract.historicalSourceClasses)
        transportSecurity = @($contract.historicalTransportSecurity)
        integrityAlgorithms = @($contract.historicalIntegrityAlgorithms)
        integrityStrengths = @($contract.historicalIntegrityStrengths)
        maintenanceStates = @($contract.historicalMaintenanceStates)
        artifactTrustClasses = @($contract.artifactTrustClasses)
        downloadPermissionStates = @($contract.artifactPermissionStates)
    }
}

function New-MmtlHistoricalSourceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ActiveOfficial','HistoricalOfficial','VerifiedCommunityArchive','VerifiedCommunitySource','ManualArtifact','UnknownHistorical')][string]$SourceClass,
        [Parameter(Mandatory)][ValidateSet('TrustedOfficial','VerifiedHistorical','UnverifiedHistorical')][string]$TrustClass,
        [Parameter(Mandatory)][ValidateSet('HTTPS','HTTPOnly','LocalManual','ArchivedSnapshot','Unknown')][string]$TransportSecurity,
        [Parameter(Mandatory)][ValidateSet('Active','Limited','Archived','Dead','Unknown')][string]$MaintenanceState,
        [string]$Url,
        [Parameter(Mandatory)][DateTimeOffset]$RetrievedAt,
        [Parameter(Mandatory)][DateTimeOffset]$LastReviewed,
        [string[]]$Notes = @()
    )
    $parsed = $null
    if ($Url -and -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed)) { throw 'HISTORICAL_SOURCE_URL_INVALID: expected an absolute URL.' }
    if ($TransportSecurity -eq 'HTTPS' -and (-not $parsed -or $parsed.Scheme -cne 'https')) { throw 'TRANSPORT_SCHEME_MISMATCH: HTTPS sources require an https URL.' }
    if ($TransportSecurity -eq 'HTTPOnly' -and (-not $parsed -or $parsed.Scheme -cne 'http')) { throw 'TRANSPORT_SCHEME_MISMATCH: HTTPOnly sources require an http URL.' }
    if ($TransportSecurity -eq 'LocalManual' -and $Url) { throw 'TRANSPORT_SCHEME_MISMATCH: LocalManual sources cannot have a remote URL.' }
    if ($TransportSecurity -eq 'ArchivedSnapshot' -and (-not $parsed -or $parsed.Scheme -notin @('https','http'))) { throw 'TRANSPORT_SCHEME_MISMATCH: ArchivedSnapshot sources require archive provenance URL.' }
    if ($SourceClass -eq 'ManualArtifact' -and $TransportSecurity -ne 'LocalManual') { throw 'MANUAL_SOURCE_TRANSPORT_INVALID: ManualArtifact must use LocalManual transport.' }
    [pscustomobject][ordered]@{
        sourceClass = $SourceClass
        trustClass = $TrustClass
        transportSecurity = $TransportSecurity
        maintenanceState = $MaintenanceState
        sourceUrl = $Url
        retrievedAt = $RetrievedAt.ToUniversalTime().ToString('o')
        lastReviewed = $LastReviewed.ToUniversalTime().ToString('o')
        notes = @($Notes)
        downloadPermission = 'RequiresConfirmation'
        executePermission = 'RequiresConfirmation'
    }
}

function Get-MmtlHistoricalIntegrityAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('SHA256','SHA1','MD5','None','Unknown')][string]$Algorithm,
        [string]$Hash
    )
    $length = switch ($Algorithm) { 'SHA256' { 64 } 'SHA1' { 40 } 'MD5' { 32 } default { 0 } }
    if ($length -and (-not $Hash -or $Hash.Length -ne $length -or $Hash -notmatch '^(?i:[0-9a-f]+)$')) { throw 'INTEGRITY_HASH_LENGTH_INVALID: hash does not match the declared algorithm.' }
    if (-not $length -and $Hash) { throw "INTEGRITY_HASH_UNEXPECTED: $Algorithm must not carry a hash value." }
    $strength = switch ($Algorithm) {
        'SHA256' { 'StrongIntegrity' }
        'SHA1' { 'LegacyIntegrity' }
        'MD5' { 'CorruptionDetectionOnly' }
        'None' { 'NoIntegrity' }
        'Unknown' { 'Unknown' }
    }
    [pscustomobject][ordered]@{
        algorithm = $Algorithm
        hash = if ($Hash) { $Hash.ToLowerInvariant() } else { $null }
        strength = $strength
        trustClass = $null
        downloadPermission = 'RequiresConfirmation'
        executePermission = 'RequiresConfirmation'
    }
}

Export-ModuleMember -Function Get-MmtlHistoricalContract,New-MmtlHistoricalSourceRecord,Get-MmtlHistoricalIntegrityAssessment
