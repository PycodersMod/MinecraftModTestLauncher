Set-StrictMode -Version Latest

function Get-MmtlCompatibilityTargetFingerprint {
    param([Parameter(Mandatory)]$Target)

    $fields = @(
        'targetId','minecraftId','minecraftType','loaderId','candidateSourceUrl','candidateSourceHash','sourceHash',
        'authoritativeSource','sourceClass','trustClass','transportSecurity','maintenanceState','availability',
        'candidateStatus','loaderVersionCandidates','buildToolchainCandidates','runtimeJavaRequirement',
        'buildJavaRequirement','agentRequirement'
    )
    $canonical = [ordered]@{}
    foreach ($field in $fields) {
        if ($Target.PSObject.Properties[$field]) {
            $canonical[$field] = $Target.$field
        } else {
            $canonical[$field] = $null
        }
    }
    $json = ConvertTo-Json -InputObject $canonical -Depth 30 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Get-MmtlCompatibilityTargetChangedFields {
    param([Parameter(Mandatory)]$Left,[Parameter(Mandatory)]$Right)
    $fields = @(
        'minecraftId','minecraftType','loaderId','candidateSourceUrl','candidateSourceHash','sourceHash',
        'authoritativeSource','sourceClass','trustClass','transportSecurity','maintenanceState','availability',
        'candidateStatus','loaderVersionCandidates','buildToolchainCandidates','runtimeJavaRequirement',
        'buildJavaRequirement','agentRequirement'
    )
    @($fields | Where-Object {
        $leftValue = if ($Left.PSObject.Properties[$_]) { ConvertTo-Json -InputObject $Left.$_ -Depth 30 -Compress } else { 'null' }
        $rightValue = if ($Right.PSObject.Properties[$_]) { ConvertTo-Json -InputObject $Right.$_ -Depth 30 -Compress } else { 'null' }
        $leftValue -cne $rightValue
    })
}

function Get-MmtlDriftTargetMap {
    param([Parameter(Mandatory)]$Universe,[Parameter(Mandatory)][string]$Name)

    if (-not $Universe.PSObject.Properties['targets'] -or $null -eq $Universe.targets) { throw "${Name}_TARGETS_REQUIRED" }
    $map = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($target in @($Universe.targets)) {
        $id = [string]$target.targetId
        if ([string]::IsNullOrWhiteSpace($id)) { throw "${Name}_TARGET_ID_REQUIRED" }
        if ($map.ContainsKey($id)) { throw "${Name}_DUPLICATE_TARGET_ID:$id" }
        $map.Add($id,[pscustomobject]@{target=$target;fingerprint=(Get-MmtlCompatibilityTargetFingerprint -Target $target)})
    }
    return ,$map
}

function Compare-MmtlCompatibilityUniverseDrift {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$FrozenUniverse,
        [Parameter(Mandatory)]$CurrentUniverse,
        [DateTimeOffset]$GeneratedAt = [DateTimeOffset]::UtcNow
    )

    if ([string]$FrozenUniverse.auditStatus -cne 'FROZEN') { throw 'FROZEN_UNIVERSE_NOT_FROZEN' }
    $frozen = Get-MmtlDriftTargetMap -Universe $FrozenUniverse -Name 'FROZEN'
    $currentStatus = [string]$CurrentUniverse.auditStatus
    if ($currentStatus -notin @('FROZEN','CANDIDATE','IN_PROGRESS')) { throw 'CURRENT_UNIVERSE_STATUS_INVALID' }
    if ($currentStatus -ceq 'IN_PROGRESS') {
        $issues = @($CurrentUniverse.issues | ForEach-Object {
            [pscustomobject][ordered]@{loaderId=[string]$_.loaderId;status=[string]$_.status;reason=[string]$_.reason}
        } | Sort-Object loaderId,reason)
        return [pscustomobject][ordered]@{
            schemaVersion=1;generatedAt=$GeneratedAt.ToUniversalTime().ToString('o');driftStatus='INDETERMINATE'
            frozenCatalogHash=[string]$FrozenUniverse.catalogHash;currentCatalogHash=[string]$CurrentUniverse.catalogHash
            frozenTargetCount=$frozen.Count;currentTargetCount=@($CurrentUniverse.targets).Count
            addedTargets=@();removedTargets=@();changedTargets=@();unresolvedIssues=$issues
        }
    }
    $current = Get-MmtlDriftTargetMap -Universe $CurrentUniverse -Name 'CURRENT'
    $added = [Collections.Generic.List[object]]::new()
    $removed = [Collections.Generic.List[object]]::new()
    $changed = [Collections.Generic.List[object]]::new()

    foreach ($id in $current.Keys) {
        $entry = $current[$id]
        if (-not $frozen.ContainsKey($id)) {
            $target = $entry.target
            $added.Add([pscustomobject][ordered]@{targetId=$id;loaderId=[string]$target.loaderId;minecraftId=[string]$target.minecraftId;status='NewUnverified';reasonCode='TARGET_NOT_IN_FROZEN_UNIVERSE';currentFingerprint=$entry.fingerprint})
        } elseif ($entry.fingerprint -cne $frozen[$id].fingerprint) {
            $target = $entry.target
            $changed.Add([pscustomobject][ordered]@{targetId=$id;loaderId=[string]$target.loaderId;minecraftId=[string]$target.minecraftId;status='ChangedInSource';reasonCode='TARGET_SOURCE_CONTRACT_CHANGED';frozenFingerprint=$frozen[$id].fingerprint;currentFingerprint=$entry.fingerprint;changedFields=(Get-MmtlCompatibilityTargetChangedFields -Left $frozen[$id].target -Right $target)})
        }
    }
    foreach ($id in $frozen.Keys) {
        if (-not $current.ContainsKey($id)) {
            $target = $frozen[$id].target
            $removed.Add([pscustomobject][ordered]@{targetId=$id;loaderId=[string]$target.loaderId;minecraftId=[string]$target.minecraftId;status='RemovedFromSource';reasonCode='TARGET_MISSING_FROM_CURRENT_UNIVERSE';frozenFingerprint=$frozen[$id].fingerprint})
        }
    }

    $hasDrift = $added.Count + $removed.Count + $changed.Count -gt 0
    [pscustomobject][ordered]@{
        schemaVersion = 1
        generatedAt = $GeneratedAt.ToUniversalTime().ToString('o')
        driftStatus = if ($hasDrift) { 'DRIFT_DETECTED' } else { 'NO_DRIFT' }
        frozenCatalogHash = [string]$FrozenUniverse.catalogHash
        currentCatalogHash = [string]$CurrentUniverse.catalogHash
        frozenTargetCount = $frozen.Count
        currentTargetCount = $current.Count
        addedTargets = @($added | Sort-Object targetId -CaseSensitive)
        removedTargets = @($removed | Sort-Object targetId -CaseSensitive)
        changedTargets = @($changed | Sort-Object targetId -CaseSensitive)
        unresolvedIssues = @()
    }
}

Export-ModuleMember -Function Compare-MmtlCompatibilityUniverseDrift
