Set-StrictMode -Version Latest

function Get-MmtlCandidateProperty {
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { if ([string]$key -ceq $Name) { return $InputObject[$key] } }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $null
}

function New-MmtlCompatibilityCandidateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Fabric', 'Quilt', 'LegacyFabric', 'OrnitheLoader')][string]$LoaderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MinecraftId,
        [Parameter(Mandatory)]$ProviderResult
    )

    $providerStatus = [string](Get-MmtlCandidateProperty -InputObject $ProviderResult -Name 'providerStatus')
    if ($providerStatus -notin @('Available', 'Stale', 'Degraded', 'Unavailable')) {
        $providerStatus = 'Unknown'
    }
    $sourceUrl = [string](Get-MmtlCandidateProperty -InputObject $ProviderResult -Name 'sourceUrl')
    $sourceHash = [string](Get-MmtlCandidateProperty -InputObject $ProviderResult -Name 'localHash')
    if (-not $sourceHash) {
        foreach ($provenance in @(Get-MmtlCandidateProperty -InputObject $ProviderResult -Name 'provenance')) {
            $sourceHash = [string](Get-MmtlCandidateProperty -InputObject $provenance -Name 'localHash')
            if ($sourceHash) { break }
        }
    }

    $candidates = @(Get-MmtlCandidateProperty -InputObject $ProviderResult -Name 'candidates')
    $versions = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in $candidates) {
        $version = if ($candidate -is [string]) { [string]$candidate } else {
            $value = Get-MmtlCandidateProperty -InputObject $candidate -Name 'loaderVersion'
            if (-not $value) { $value = Get-MmtlCandidateProperty -InputObject $candidate -Name 'version' }
            [string]$value
        }
        if ([string]::IsNullOrWhiteSpace($version)) { continue }
        if ($seen.Add($version)) { $versions.Add($version) }
    }

    $candidateStatus = if ($providerStatus -eq 'Available') {
        if ($versions.Count) { 'Resolved' } else { 'NoCandidatesReturned' }
    } elseif ($providerStatus -eq 'Stale') { 'Stale' } else { 'Unknown' }

    if ($candidateStatus -in @('Resolved', 'NoCandidatesReturned')) {
        $uri = $null
        if (-not [Uri]::TryCreate($sourceUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo.Length -gt 0) {
            throw 'COMPATIBILITY_CANDIDATE_SOURCE_INVALID: 成功的候选响应必须来自无凭据 HTTPS 来源。'
        }
        if ($sourceHash -notmatch '^[a-f0-9]{64}$') {
            throw 'COMPATIBILITY_CANDIDATE_HASH_INVALID: 成功的候选响应必须带有 SHA-256。'
        }
    }

    [pscustomobject][ordered]@{
        targetId = "$LoaderId@$MinecraftId"
        loaderId = $LoaderId
        minecraftId = $MinecraftId
        providerStatus = $providerStatus
        candidateStatus = $candidateStatus
        loaderVersions = @($versions)
        candidates = @($candidates)
        sourceUrl = if ($sourceUrl) { $sourceUrl } else { $null }
        sourceHash = if ($sourceHash) { $sourceHash } else { $null }
        cacheStatus = [string](Get-MmtlCandidateProperty -InputObject $ProviderResult -Name 'cacheStatus')
        error = [string](Get-MmtlCandidateProperty -InputObject $ProviderResult -Name 'error')
    }
}

Export-ModuleMember -Function New-MmtlCompatibilityCandidateResult
