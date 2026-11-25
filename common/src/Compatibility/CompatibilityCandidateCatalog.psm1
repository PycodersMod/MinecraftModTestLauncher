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
        [Parameter(Mandatory)][ValidateSet('Fabric', 'Quilt', 'LegacyFabric', 'OrnitheLoader', 'LiteLoader')][string]$LoaderId,
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

function Join-MmtlCompatibilityCandidateCatalogs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)][object[]]$CandidateCatalogs,
        [Parameter(Mandatory)][object[]]$SourceEvidence,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$RequiredLoaderIds
    )

    $targetsById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($target in @($Universe.targets)) {
        $targetId = [string]$target.targetId
        if ([string]::IsNullOrWhiteSpace($targetId) -or $targetsById.ContainsKey($targetId)) { throw "COMPATIBILITY_CANDIDATE_TARGET_DUPLICATE: $targetId" }
        $targetsById.Add($targetId, $target)
    }

    $evidenceByKey = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $SourceEvidence) {
        $key = "$(Get-MmtlCandidateProperty $record 'providerId')|$(Get-MmtlCandidateProperty $record 'sourceUrl')|$(Get-MmtlCandidateProperty $record 'sha256')"
        if ($evidenceByKey.ContainsKey($key)) { throw "COMPATIBILITY_CANDIDATE_SOURCE_EVIDENCE_DUPLICATE: $key" }
        $evidenceByKey.Add($key, $record)
    }

    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($loaderId in $RequiredLoaderIds) {
        if ([string]::IsNullOrWhiteSpace($loaderId) -or -not $required.Add($loaderId)) { throw "COMPATIBILITY_CANDIDATE_LOADER_INVALID: $loaderId" }
    }
    $catalogByLoader = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($catalog in $CandidateCatalogs) {
        $loaderId = [string](Get-MmtlCandidateProperty $catalog 'loaderId')
        if (-not $required.Contains($loaderId)) { throw "COMPATIBILITY_CANDIDATE_LOADER_UNEXPECTED: $loaderId" }
        if ($catalogByLoader.ContainsKey($loaderId)) { throw "COMPATIBILITY_CANDIDATE_LOADER_DUPLICATE: $loaderId" }
        $catalogByLoader.Add($loaderId, $catalog)
    }

    foreach ($loaderId in $RequiredLoaderIds) {
        if (-not $catalogByLoader.ContainsKey($loaderId)) { throw "COMPATIBILITY_CANDIDATE_COVERAGE_MISSING: $loaderId catalog missing" }
        $catalog = $catalogByLoader[$loaderId]
        $expectedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($target in @($Universe.targets | Where-Object { [string]$_.loaderId -ceq $loaderId })) { [void]$expectedIds.Add([string]$target.targetId) }
        $results = @(Get-MmtlCandidateProperty $catalog 'results')
        if ([int](Get-MmtlCandidateProperty $catalog 'targetCount') -ne $expectedIds.Count -or [int](Get-MmtlCandidateProperty $catalog 'resultCount') -ne $results.Count) {
            throw "COMPATIBILITY_CANDIDATE_COVERAGE_INVALID: $loaderId catalog counts mismatch"
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($result in $results) {
            $targetId = [string](Get-MmtlCandidateProperty $result 'targetId')
            if (-not $expectedIds.Contains($targetId) -or -not $seen.Add($targetId)) { throw "COMPATIBILITY_CANDIDATE_COVERAGE_INVALID: $loaderId unexpected or duplicate target $targetId" }
            $target = $targetsById[$targetId]
            $minecraftId = [string](Get-MmtlCandidateProperty $result 'minecraftId')
            if ([string]$target.loaderId -cne $loaderId -or [string]$target.minecraftId -cne $minecraftId -or $targetId -cne "$loaderId@$minecraftId") {
                throw "COMPATIBILITY_CANDIDATE_TARGET_IDENTITY_INVALID: $targetId"
            }

            $status = [string](Get-MmtlCandidateProperty $result 'candidateStatus')
            $versions = @((Get-MmtlCandidateProperty $result 'loaderVersions') | ForEach-Object { [string]$_ })
            if ($status -notin @('Resolved', 'NoCandidatesReturned', 'Stale', 'Unknown')) { throw "COMPATIBILITY_CANDIDATE_STATUS_INVALID: $targetId/$status" }
            if (($status -eq 'Resolved' -and $versions.Count -eq 0) -or ($status -eq 'NoCandidatesReturned' -and $versions.Count -ne 0)) {
                throw "COMPATIBILITY_CANDIDATE_RESULT_INVALID: $targetId/$status"
            }

            $sourceUrl = [string](Get-MmtlCandidateProperty $result 'sourceUrl')
            $sourceHash = [string](Get-MmtlCandidateProperty $result 'sourceHash')
            if ($status -in @('Resolved', 'NoCandidatesReturned')) {
                $uri = $null
                if (-not [Uri]::TryCreate($sourceUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo.Length -gt 0 -or $sourceHash -notmatch '^[a-f0-9]{64}$') {
                    throw "COMPATIBILITY_CANDIDATE_SOURCE_EVIDENCE_INVALID: $targetId"
                }
                $key = "${loaderId}Candidates|$sourceUrl|$sourceHash"
                if (-not $evidenceByKey.ContainsKey($key)) { throw "COMPATIBILITY_CANDIDATE_SOURCE_EVIDENCE_MISSING: $targetId" }
                $evidence = $evidenceByKey[$key]
                $relativePath = [string](Get-MmtlCandidateProperty $evidence 'relativePath')
                $providerId = [string](Get-MmtlCandidateProperty $evidence 'providerId')
                $relativeMatch = [regex]::Match($relativePath, '^' + [regex]::Escape($providerId) + '/([a-f0-9]{64})\.bin$')
                if ($providerId -cne "${loaderId}Candidates" -or -not $relativeMatch.Success -or $relativeMatch.Groups[1].Value -cne $sourceHash -or [int64](Get-MmtlCandidateProperty $evidence 'byteLength') -lt 1) {
                    throw "COMPATIBILITY_CANDIDATE_SOURCE_EVIDENCE_INVALID: $targetId"
                }
                $resultTrust = [string](Get-MmtlCandidateProperty $result 'trustClass')
                $resultClass = [string](Get-MmtlCandidateProperty $result 'sourceClass')
                if ($resultTrust -and $resultTrust -cne [string](Get-MmtlCandidateProperty $evidence 'trustClass')) { throw "COMPATIBILITY_CANDIDATE_SOURCE_EVIDENCE_MISMATCH: $targetId trustClass" }
                if ($resultClass -and $resultClass -cne [string](Get-MmtlCandidateProperty $evidence 'sourceClass')) { throw "COMPATIBILITY_CANDIDATE_SOURCE_EVIDENCE_MISMATCH: $targetId sourceClass" }
            }

            $target.loaderVersionCandidates = $versions
            $target.candidateStatus = $status
            $target.candidateSourceUrl = if ($sourceUrl) { $sourceUrl } else { $null }
            $target.candidateSourceHash = if ($sourceHash) { $sourceHash } else { $null }
        }
        if ($seen.Count -ne $expectedIds.Count) { throw "COMPATIBILITY_CANDIDATE_COVERAGE_MISSING: $loaderId has $($expectedIds.Count - $seen.Count) missing targets" }
    }

    foreach ($target in $Universe.targets) {
        $status = [string]$target.candidateStatus
        if ($status -notin @('Resolved', 'NoCandidatesReturned')) { continue }
        $sourceUrl = [string]$target.candidateSourceUrl
        $sourceHash = [string]$target.candidateSourceHash
        $uri = $null
        if (-not [Uri]::TryCreate($sourceUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo.Length -gt 0 -or $sourceHash -notmatch '^[a-f0-9]{64}$') {
            throw "COMPATIBILITY_CANDIDATE_SOURCE_PROVENANCE_MISSING: $([string]$target.targetId)"
        }
        $providerId = if ($required.Contains([string]$target.loaderId)) { "$([string]$target.loaderId)Candidates" } else { [string]$target.loaderId }
        $key = "$providerId|$sourceUrl|$sourceHash"
        if (-not $evidenceByKey.ContainsKey($key)) { throw "COMPATIBILITY_CANDIDATE_SOURCE_PROVENANCE_MISSING: $([string]$target.targetId)" }
    }

    $candidateMaterial = @($Universe.targets | Sort-Object { [string]$_.targetId } | ForEach-Object {
        [ordered]@{
            targetId = [string]$_.targetId; candidateStatus = [string]$_.candidateStatus
            loaderVersionCandidates = @($_.loaderVersionCandidates); candidateSourceUrl = $_.candidateSourceUrl
            candidateSourceHash = $_.candidateSourceHash
        }
    })
    $json = ConvertTo-Json -InputObject $candidateMaterial -Depth 30 -Compress
    $Universe.candidateCatalogHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
    $Universe
}

Export-ModuleMember -Function New-MmtlCompatibilityCandidateResult,Join-MmtlCompatibilityCandidateCatalogs
