Set-StrictMode -Version Latest

$script:LedgerDimensions = @(
    'Catalogued', 'LoaderResolved', 'ProjectDetection', 'BuildPlan', 'BuildJava',
    'RuntimeJava', 'RuntimeBinding', 'BuildVerified', 'LaunchPlan', 'LaunchCheck',
    'AgentBuild', 'AgentInjection', 'SingleCapability', 'IntegratedLANCapability',
    'DedicatedCapability', 'LogObservation', 'EvidenceLevel'
)
$script:LedgerStatuses = @('Supported', 'PartiallySupported', 'NotApplicable', 'ExternallyBlocked', 'Unsupported', 'Unknown', 'PendingImplementation')

function Get-MmtlLedgerSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-MmtlCanonicalJson {
    param([Parameter(Mandatory)]$Value)
    ConvertTo-Json -InputObject $Value -Depth 50 -Compress
}

function Get-MmtlTargetSpecHash {
    param([Parameter(Mandatory)]$Target)
    $spec = [ordered]@{
        targetId = [string]$Target.targetId
        loaderId = [string]$Target.loaderId
        minecraftId = [string]$Target.minecraftId
        minecraftType = [string]$Target.minecraftType
        availability = [string]$Target.availability
        loaderVersionCandidates = @($Target.loaderVersionCandidates)
        candidateStatus = [string]$Target.candidateStatus
        candidateSourceHash = if ($Target.PSObject.Properties['candidateSourceHash']) { $Target.candidateSourceHash } else { $null }
        sourceHash = if ($Target.PSObject.Properties['sourceHash']) { $Target.sourceHash } else { $null }
        authoritativeSource = if ($Target.PSObject.Properties['authoritativeSource']) { $Target.authoritativeSource } else { $null }
        buildToolchainCandidates = if ($Target.PSObject.Properties['buildToolchainCandidates']) { @($Target.buildToolchainCandidates) } else { @() }
        buildJavaRequirement = if ($Target.PSObject.Properties['buildJavaRequirement']) { $Target.buildJavaRequirement } else { $null }
        runtimeJavaRequirement = if ($Target.PSObject.Properties['runtimeJavaRequirement']) { $Target.runtimeJavaRequirement } else { $null }
        agentRequirement = if ($Target.PSObject.Properties['agentRequirement']) { $Target.agentRequirement } else { $null }
    }
    Get-MmtlLedgerSha256 -Text (Get-MmtlCanonicalJson -Value $spec)
}

function New-MmtlLedgerDimension {
    param([Parameter(Mandatory)][string]$Status, [string[]]$EvidenceRefs = @())
    [pscustomobject][ordered]@{ status = $Status; evidenceRefs = @($EvidenceRefs) }
}

function Get-MmtlCompatibilityFamilyMap {
    param([Parameter(Mandatory)]$Universe, $FamilyManifest)
    $map = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    if (-not $FamilyManifest) { return ,$map }
    if ([string]$FamilyManifest.universeHash -cne [string]$Universe.catalogHash) { throw 'FAMILY_MANIFEST_UNIVERSE_HASH_MISMATCH' }
    $familyIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $universeIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($target in @($Universe.targets | Where-Object { $_.availability -ceq 'Available' })) { [void]$universeIds.Add([string]$target.targetId) }
    foreach ($family in @($FamilyManifest.families)) {
        $familyId = [string]$family.familyId
        if ([string]::IsNullOrWhiteSpace($familyId) -or -not $familyIds.Add($familyId)) { throw "FAMILY_MANIFEST_INVALID:DUPLICATE_OR_EMPTY_FAMILY:$familyId" }
        foreach ($field in @('loaderId','minecraftIds','toolchain','buildJava','runtimeJava','projectDetectionStrategy','launchStrategy','agentBridge','evidence')) {
            if (-not $family.PSObject.Properties[$field]) { throw "FAMILY_MANIFEST_INVALID:MISSING_FIELD:${familyId}:$field" }
        }
        if (@($family.minecraftIds).Count -eq 0 -or @($family.evidence).Count -eq 0) { throw "FAMILY_MANIFEST_INVALID:MISSING_EXACT_SCOPE_OR_EVIDENCE:$familyId" }
        foreach ($minecraftId in @($family.minecraftIds)) {
            $targetId = "$([string]$family.loaderId)@$([string]$minecraftId)"
            if (-not $universeIds.Contains($targetId)) { throw "FAMILY_TARGET_NOT_IN_UNIVERSE:${familyId}:$targetId" }
            if ($map.ContainsKey($targetId)) { throw "FAMILY_TARGET_OVERLAP:$targetId" }
            $map.Add($targetId, $familyId)
        }
    }
    return ,$map
}

function Get-MmtlTargetLedgerStatus {
    param([Parameter(Mandatory)]$Dimensions)
    $statuses = @($script:LedgerDimensions | ForEach-Object { [string]$Dimensions.$_.status })
    if ($statuses -contains 'Unknown') { return 'Unknown' }
    if ($statuses -contains 'ExternallyBlocked') { return 'ExternallyBlocked' }
    if ($statuses -contains 'PendingImplementation') { return 'PendingImplementation' }
    if ($statuses -contains 'Unsupported') { return 'Unsupported' }
    if ($statuses -contains 'PartiallySupported') { return 'PartiallySupported' }
    'Supported'
}

function New-MmtlFullCompatibilityLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)][DateTimeOffset]$GeneratedAt,
        $FamilyManifest
    )

    $familyMap = Get-MmtlCompatibilityFamilyMap -Universe $Universe -FamilyManifest $FamilyManifest
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($target in @($Universe.targets | Sort-Object { [string]$_.targetId })) {
        if ([string]$target.availability -cne 'Available') { continue }
        $candidateResolved = ([string]$target.candidateStatus -ceq 'Resolved' -and @($target.loaderVersionCandidates).Count -gt 0)
        $dimensions = [ordered]@{}
        foreach ($name in $script:LedgerDimensions) {
            $status = switch ($name) {
                'Catalogued' { 'Supported' }
                'LoaderResolved' { if ($candidateResolved) { 'Supported' } else { 'Unknown' } }
                default { 'PendingImplementation' }
            }
            $evidenceRefs = @()
            if ($status -ceq 'Supported') {
                $evidenceRefs += "universe-sha256:$([string]$Universe.catalogHash)"
                if (-not [string]::IsNullOrWhiteSpace([string]$target.sourceHash)) { $evidenceRefs += "source-sha256:$([string]$target.sourceHash)" }
                if (-not [string]::IsNullOrWhiteSpace([string]$target.authoritativeSource)) { $evidenceRefs += "source-url:$([string]$target.authoritativeSource)" }
            }
            $dimensions[$name] = New-MmtlLedgerDimension -Status $status -EvidenceRefs $evidenceRefs
        }
        $targets.Add([pscustomobject][ordered]@{
            targetId = [string]$target.targetId
            loaderId = [string]$target.loaderId
            minecraftId = [string]$target.minecraftId
            familyId = if ($familyMap.ContainsKey([string]$target.targetId)) { $familyMap[[string]$target.targetId] } else { $null }
            dimensions = [pscustomobject]$dimensions
            status = Get-MmtlTargetLedgerStatus -Dimensions ([pscustomobject]$dimensions)
            sourceHash = if ($target.PSObject.Properties['sourceHash']) { $target.sourceHash } else { $null }
            toolchainHash = $null
            targetSpecHash = Get-MmtlTargetSpecHash -Target $target
        })
    }

    $records = @($targets.ToArray())
    [pscustomobject][ordered]@{
        schemaVersion = 1
        auditStatus = 'IN_PROGRESS'
        generatedAt = $GeneratedAt.ToUniversalTime().ToString('o')
        universeHash = [string]$Universe.catalogHash
        candidateCatalogHash = if ($Universe.PSObject.Properties['candidateCatalogHash']) { $Universe.candidateCatalogHash } else { $null }
        targets = $records
        summary = Get-MmtlFullCompatibilityLedgerSummary -Targets $records
    }
}

function Get-MmtlFullCompatibilityLedgerSummary {
    param([Parameter(Mandatory)][object[]]$Targets)
    $unknown = @($Targets | Where-Object { $_.status -ceq 'Unknown' }).Count
    $pendingCount = 0
    foreach ($target in $Targets) {
        foreach ($name in $script:LedgerDimensions) {
            if ([string]$target.dimensions.$name.status -ceq 'PendingImplementation') { $pendingCount++ }
        }
    }
    [pscustomobject][ordered]@{
        targetCount = $Targets.Count
        unknownTargetCount = $unknown
        pendingImplementationDimensionCount = $pendingCount
        unassignedFamilyCount = @($Targets | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.familyId) }).Count
    }
}

function Test-MmtlFullCompatibilityLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Ledger, [Parameter(Mandatory)]$Universe, $FamilyManifest, [switch]$RequireFamilies)

    $errors = [Collections.Generic.List[string]]::new()
    $familyMap = $null
    try { $familyMap = Get-MmtlCompatibilityFamilyMap -Universe $Universe -FamilyManifest $FamilyManifest }
    catch { $errors.Add($_.Exception.Message) }
    $universeById = @{}
    foreach ($universeTarget in @($Universe.targets | Where-Object { $_.availability -ceq 'Available' })) { $universeById[[string]$universeTarget.targetId] = $universeTarget }
    $expected = @($Universe.targets | Where-Object { [string]$_.availability -ceq 'Available' } | ForEach-Object { [string]$_.targetId } | Sort-Object -Unique)
    $actualRows = @($Ledger.targets)
    $actual = @($actualRows | ForEach-Object { [string]$_.targetId } | Sort-Object -Unique)
    if (($expected -join "`n") -cne ($actual -join "`n") -or $actualRows.Count -ne $actual.Count) { $errors.Add('LEDGER_TARGET_SET_MISMATCH') }

    foreach ($group in @($actualRows | Group-Object { [string]$_.targetId } | Where-Object Count -gt 1)) {
        $errors.Add("LEDGER_DUPLICATE_TARGET:$($group.Name)")
    }
    foreach ($row in $actualRows) {
        $targetId = [string]$row.targetId
        if ($universeById.ContainsKey($targetId)) {
            $sourceTarget = $universeById[$targetId]
            if ([string]$row.loaderId -cne [string]$sourceTarget.loaderId -or [string]$row.minecraftId -cne [string]$sourceTarget.minecraftId) { $errors.Add("LEDGER_TARGET_IDENTITY_MISMATCH:$targetId") }
            if ([string]$row.targetSpecHash -cne (Get-MmtlTargetSpecHash -Target $sourceTarget)) { $errors.Add("LEDGER_TARGET_SPEC_HASH_MISMATCH:$targetId") }
            if ([string]$row.sourceHash -cne [string]$sourceTarget.sourceHash) { $errors.Add("LEDGER_SOURCE_HASH_MISMATCH:$targetId") }
            $expectedFamily = if ($familyMap -and $familyMap.ContainsKey($targetId)) { $familyMap[$targetId] } else { $null }
            if ([string]$row.familyId -cne [string]$expectedFamily) { $errors.Add("LEDGER_FAMILY_ASSIGNMENT_MISMATCH:$targetId") }
        }
        foreach ($name in $script:LedgerDimensions) {
            if (-not $row.dimensions -or -not $row.dimensions.PSObject.Properties[$name]) {
                $errors.Add("LEDGER_DIMENSION_MISSING:$($row.targetId):$name")
                continue
            }
            $dimension = $row.dimensions.$name
            if ([string]$dimension.status -cnotin $script:LedgerStatuses) { $errors.Add("LEDGER_STATUS_INVALID:$($row.targetId):$name") }
            if ([string]$dimension.status -cin @('Supported', 'PartiallySupported') -and @($dimension.evidenceRefs).Count -eq 0) { $errors.Add("LEDGER_CAPABILITY_EVIDENCE_MISSING:$($row.targetId):$name") }
            if ([string]$dimension.status -ceq 'ExternallyBlocked') {
                foreach ($field in @('reasonCode','source','evidence','attemptedRemediation')) {
                    if (-not $dimension.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$dimension.$field)) {
                        $errors.Add("EXTERNAL_BLOCKER_EVIDENCE_MISSING:$($row.targetId):$name")
                        break
                    }
                }
            }
        }
        if ($row.dimensions -and @($script:LedgerDimensions | Where-Object { -not $row.dimensions.PSObject.Properties[$_] }).Count -eq 0) {
            $calculatedStatus = Get-MmtlTargetLedgerStatus -Dimensions $row.dimensions
            if ([string]$row.status -cne $calculatedStatus) { $errors.Add("LEDGER_TARGET_STATUS_MISMATCH:$targetId") }
        }
        if ($RequireFamilies -and [string]::IsNullOrWhiteSpace([string]$row.familyId)) { $errors.Add("LEDGER_FAMILY_UNASSIGNED:$targetId") }
    }

    $summary = Get-MmtlFullCompatibilityLedgerSummary -Targets $actualRows
    foreach ($field in @('targetCount','unknownTargetCount','pendingImplementationDimensionCount','unassignedFamilyCount')) {
        if (-not $Ledger.summary -or [int]$Ledger.summary.$field -ne [int]$summary.$field) { $errors.Add("LEDGER_SUMMARY_MISMATCH:$field") }
    }
    [pscustomobject][ordered]@{ isValid = ($errors.Count -eq 0); errors = @($errors.ToArray() | Sort-Object -Unique); summary = $summary }
}

Export-ModuleMember -Function New-MmtlFullCompatibilityLedger, Test-MmtlFullCompatibilityLedger, Get-MmtlFullCompatibilityLedgerSummary
