Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../Validation/TargetIdentity.psm1') -Force

function Get-MmtlAdapterV3Operation {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Dimension
    )

    $claim = $null
    if ($Target.dimensions -and $Target.dimensions.PSObject.Properties[$Dimension]) {
        $claim = $Target.dimensions.$Dimension
    }
    if (-not $claim) {
        return [pscustomobject][ordered]@{ status = 'PendingImplementation'; evidenceRefs = @() }
    }
    return [pscustomobject][ordered]@{
        status = [string]$claim.status
        evidenceRefs = @($claim.evidenceRefs | ForEach-Object { [string]$_ })
    }
}

function Get-MmtlAdapterV3BuildJavaEvidence {
    param(
        [Parameter(Mandatory)]$EvidenceIndex,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$TargetSpecHash,
        [Parameter(Mandatory)][string]$UniverseHash
    )

    if ([string]$EvidenceIndex.universeHash -cne $UniverseHash) { throw 'ADAPTER_V3_BUILD_EVIDENCE_UNIVERSE_MISMATCH' }
    $matches = @($EvidenceIndex.entries | Where-Object { [string]$_.targetId -ceq $TargetId -and [string]$_.dimension -ceq 'BuildVerified' })
    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -ne 1) { throw 'ADAPTER_V3_BUILD_EVIDENCE_MISSING_OR_DUPLICATE' }
    $entry = $matches[0]
    if ([string]$entry.targetSpecHash -cne $TargetSpecHash) { throw 'ADAPTER_V3_BUILD_EVIDENCE_TARGET_SPEC_MISMATCH' }
    $relativePath = [string]$entry.evidencePath
    if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw 'ADAPTER_V3_BUILD_EVIDENCE_PATH_INVALID'
    }
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $path = [IO.Path]::GetFullPath((Join-Path $root $relativePath))
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'ADAPTER_V3_BUILD_EVIDENCE_PATH_INVALID' }
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    $rootIsLink = $rootItem.PSObject.Properties['LinkType'] -and -not [string]::IsNullOrWhiteSpace([string]$rootItem.LinkType)
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $rootIsLink) { throw 'ADAPTER_V3_BUILD_EVIDENCE_PATH_INVALID' }
    $cursor = $root
    $relativeFromRoot = $path.Substring($prefix.Length)
    foreach ($part in ($relativeFromRoot -split '[\\/]')) {
        $cursor = Join-Path $cursor $part
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            $isLink = $item.PSObject.Properties['LinkType'] -and -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $isLink) { throw 'ADAPTER_V3_BUILD_EVIDENCE_PATH_INVALID' }
        }
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'ADAPTER_V3_BUILD_EVIDENCE_FILE_MISSING' }

    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne [string]$entry.evidenceSha256) { throw 'ADAPTER_V3_BUILD_EVIDENCE_HASH_MISMATCH' }
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $schemaPath = Join-Path $root 'common/schemas/validation-evidence.schema.json'
    if (-not (Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'ADAPTER_V3_BUILD_EVIDENCE_SCHEMA_INVALID' }
    $evidence = $raw | ConvertFrom-Json -ErrorAction Stop
    if ([string]$evidence.targetId -cne $TargetId -or [string]$evidence.result -cne 'PASSED' -or [string]$evidence.validationLevel -cne 'BUILD_VERIFIED') {
        throw 'ADAPTER_V3_BUILD_EVIDENCE_CLAIM_INVALID'
    }
    $requirement = $evidence.java.buildRequirement
    $observed = $evidence.java.observedBuildJava
    $major = 0
    $observedMajor = 0
    if (-not [int]::TryParse([string]$requirement.major, [ref]$major) -or $major -le 0 -or -not [int]::TryParse([string]$observed.major, [ref]$observedMajor) -or $observedMajor -ne $major) {
        throw 'ADAPTER_V3_BUILD_JAVA_EVIDENCE_INVALID'
    }
    return [pscustomobject][ordered]@{
        status = 'Supported'
        strategy = 'PinnedBuildEvidence'
        major = $major
        observedMajor = $observedMajor
        minimumMajor = $null
        maximumMajor = $null
        preferredMajor = $null
        requirementKind = [string]$requirement.kind
        source = [string]$requirement.source
        evidenceRefs = @(
            "target-runner-evidence-sha256:$actualHash",
            "target-evidence-index-sha256:$([string]$entry.evidenceSha256)",
            "target-spec-sha256:$([string]$entry.targetSpecHash)",
            "target-runner-evidence-path:$relativePath"
        )
    }
}

function Resolve-MmtlAdapterV3 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)]$FamilyManifest,
        [Parameter(Mandatory)]$Ledger,
        [Parameter(Mandatory)]$RuntimeJavaCatalog,
        [AllowNull()]$TargetEvidenceIndex,
        [string]$EvidenceRoot
    )

    if ([string]$FamilyManifest.universeHash -cne [string]$Universe.catalogHash -or [string]$Ledger.universeHash -cne [string]$Universe.catalogHash -or [string]$RuntimeJavaCatalog.universeHash -cne [string]$Universe.catalogHash) {
        throw 'ADAPTER_V3_UNIVERSE_HASH_MISMATCH'
    }

    $universeTargets = @($Universe.targets | Where-Object { [string]$_.targetId -ceq $TargetId })
    if ($universeTargets.Count -ne 1 -or [string]$universeTargets[0].availability -cne 'Available') {
        throw 'ADAPTER_V3_TARGET_NOT_EXACT'
    }
    $universeTarget = $universeTargets[0]

    $ledgerTargets = @($Ledger.targets | Where-Object { [string]$_.targetId -ceq $TargetId })
    if ($ledgerTargets.Count -ne 1) { throw 'ADAPTER_V3_LEDGER_TARGET_MISSING_OR_DUPLICATE' }
    $ledgerTarget = $ledgerTargets[0]

    $javaEntries = @($RuntimeJavaCatalog.entries | Where-Object { [string]$_.minecraftId -ceq [string]$universeTarget.minecraftId })
    if ($javaEntries.Count -ne 1) { throw 'ADAPTER_V3_RUNTIME_JAVA_TARGET_MISSING_OR_DUPLICATE' }
    $javaEntry = $javaEntries[0]
    $javaRequirement = $javaEntry.requirement
    $javaEvidence = @()
    if ($javaEntry.metadataSource) {
        if ($javaEntry.metadataSource.url) { $javaEvidence += "runtime-java-source-url:$([string]$javaEntry.metadataSource.url)" }
        if ($javaEntry.metadataSource.sourceSha1) { $javaEvidence += "runtime-java-sha1:$([string]$javaEntry.metadataSource.sourceSha1)" }
        if ($javaEntry.metadataSource.snapshotSha256) { $javaEvidence += "runtime-java-snapshot-sha256:$([string]$javaEntry.metadataSource.snapshotSha256)" }
    }
    $javaMajor = if ($null -ne $javaRequirement.major) { [int]$javaRequirement.major } else { $null }
    $runtimeJavaStatus = if ($javaMajor -gt 0 -and [string]$javaEntry.observationStatus -ceq 'VERIFIED' -and $javaEvidence.Count -gt 0) { 'Supported' } else { 'Unknown' }

    $families = @($FamilyManifest.families | Where-Object { [string]$_.familyId -ceq [string]$ledgerTarget.familyId })
    if ($families.Count -eq 0) {
        $matchingFamily = @($FamilyManifest.families | Where-Object { [string]$_.loaderId -ceq [string]$universeTarget.loaderId -and [string]$universeTarget.minecraftId -cin @($_.minecraftIds | ForEach-Object { [string]$_ }) })
        if ($matchingFamily.Count -eq 1) { throw 'ADAPTER_V3_LEDGER_FAMILY_MISMATCH' }
        throw 'ADAPTER_V3_FAMILY_MISSING_OR_DUPLICATE'
    }
    if ($families.Count -ne 1) { throw 'ADAPTER_V3_FAMILY_MISSING_OR_DUPLICATE' }
    $family = $families[0]
    if ([string]$family.loaderId -cne [string]$universeTarget.loaderId -or [string]$ledgerTarget.loaderId -cne [string]$universeTarget.loaderId -or [string]$universeTarget.minecraftId -cnotin @($family.minecraftIds | ForEach-Object { [string]$_ })) {
        throw 'ADAPTER_V3_FAMILY_TARGET_MISMATCH'
    }
    if (-not $family.buildJava) { throw 'ADAPTER_V3_BUILD_JAVA_POLICY_MISSING' }
    $familyBuildJavaStatus = if ($family.buildJava.PSObject.Properties['status']) { [string]$family.buildJava.status } else { 'FamilyBuildJavaPolicy' }
    if ([string]::IsNullOrWhiteSpace($familyBuildJavaStatus)) { throw 'ADAPTER_V3_BUILD_JAVA_POLICY_MISSING' }

    $buildJavaClaim = if ($ledgerTarget.dimensions -and $ledgerTarget.dimensions.PSObject.Properties['BuildJava']) { $ledgerTarget.dimensions.BuildJava } else { $null }
    $buildJavaEvidence = @()
    if ($buildJavaClaim) { $buildJavaEvidence += @($buildJavaClaim.evidenceRefs | ForEach-Object { [string]$_ }) }
    if ($family.buildJava.PSObject.Properties['evidenceRef'] -and -not [string]::IsNullOrWhiteSpace([string]$family.buildJava.evidenceRef)) { $buildJavaEvidence += [string]$family.buildJava.evidenceRef }
    if ($family.capabilities -and $family.capabilities.BuildJava) { $buildJavaEvidence += @($family.capabilities.BuildJava.evidenceRefs | ForEach-Object { [string]$_ }) }
    $buildJavaMajor = $null
    if ($family.buildJava.PSObject.Properties['major'] -and $null -ne $family.buildJava.major) { $buildJavaMajor = [int]$family.buildJava.major }
    elseif ($buildJavaClaim -and $buildJavaClaim.PSObject.Properties['major'] -and $null -ne $buildJavaClaim.major) { $buildJavaMajor = [int]$buildJavaClaim.major }
    $buildJavaObservedMajor = $null
    $buildJavaMinimumMajor = if ($family.buildJava.PSObject.Properties['minimumMajor'] -and $null -ne $family.buildJava.minimumMajor) { [int]$family.buildJava.minimumMajor } else { $null }
    $buildJavaMaximumMajor = if ($family.buildJava.PSObject.Properties['maximumMajor'] -and $null -ne $family.buildJava.maximumMajor) { [int]$family.buildJava.maximumMajor } else { $null }
    $buildJavaPreferredMajor = if ($family.buildJava.PSObject.Properties['preferredMajor'] -and $null -ne $family.buildJava.preferredMajor) { [int]$family.buildJava.preferredMajor } else { $null }
    $buildJavaRequirementKind = 'Unknown'
    $buildJavaSource = 'Unknown'
    if ($buildJavaMajor -and $buildJavaClaim) {
        if ($buildJavaClaim.PSObject.Properties['requirementKind']) { $buildJavaRequirementKind = [string]$buildJavaClaim.requirementKind }
        if ($buildJavaClaim.PSObject.Properties['source']) { $buildJavaSource = [string]$buildJavaClaim.source }
    }
    $claimStatus = if ($buildJavaClaim) { [string]$buildJavaClaim.status } else { 'PendingImplementation' }
    if ($claimStatus -ceq 'Supported' -and $buildJavaClaim) {
        $majorRefs = @($buildJavaEvidence | Where-Object { $_ -cmatch '^build-java-major:(\d+)$' } | ForEach-Object { [int]($_ -replace '^build-java-major:', '') } | Select-Object -Unique)
        $observedRefs = @($buildJavaEvidence | Where-Object { $_ -cmatch '^build-java-observed-major:(\d+)$' } | ForEach-Object { [int]($_ -replace '^build-java-observed-major:', '') } | Select-Object -Unique)
        $kindRefs = @($buildJavaEvidence | Where-Object { $_ -cmatch '^build-java-requirement-kind:([A-Za-z]+)$' } | ForEach-Object { $_ -replace '^build-java-requirement-kind:', '' } | Select-Object -Unique)
        $sourceRefs = @($buildJavaEvidence | Where-Object { $_ -cmatch '^build-java-requirement-source:.+$' } | ForEach-Object { $_ -replace '^build-java-requirement-source:', '' } | Select-Object -Unique)
        if ($majorRefs.Count -gt 1 -or $observedRefs.Count -gt 1 -or $kindRefs.Count -gt 1 -or $sourceRefs.Count -gt 1) { throw 'ADAPTER_V3_BUILD_JAVA_CLAIM_INVALID' }
        if ($majorRefs.Count -eq 1) {
            if ($observedRefs.Count -ne 1 -or $observedRefs[0] -ne $majorRefs[0] -or $kindRefs.Count -ne 1 -or $sourceRefs.Count -ne 1) { throw 'ADAPTER_V3_BUILD_JAVA_CLAIM_INVALID' }
            $buildJavaMajor = $majorRefs[0]
            $buildJavaObservedMajor = $observedRefs[0]
            $buildJavaRequirementKind = [string]$kindRefs[0]
            $buildJavaSource = [string]$sourceRefs[0]
        } elseif ($buildJavaMinimumMajor -and $buildJavaMaximumMajor) {
            if ($buildJavaMinimumMajor -gt $buildJavaMaximumMajor -or ($buildJavaPreferredMajor -and ($buildJavaPreferredMajor -lt $buildJavaMinimumMajor -or $buildJavaPreferredMajor -gt $buildJavaMaximumMajor))) { throw 'ADAPTER_V3_BUILD_JAVA_CLAIM_INVALID' }
            $buildJavaRequirementKind = 'Range'
            $buildJavaSource = 'FamilyBuildJavaPolicy'
        } else {
            throw 'ADAPTER_V3_BUILD_JAVA_CLAIM_INVALID'
        }
    }

    $historicalLoaders = @('LegacyFabric', 'OrnitheLoader', 'LiteLoader', 'Rift', 'ModLoader', 'ModLoaderMP')
    $historicalSafety = if ([string]$universeTarget.loaderId -cin $historicalLoaders) {
        [pscustomobject][ordered]@{ status = 'PendingImplementation'; evidenceRefs = @(); reasonCode = 'HISTORICAL_SAFETY_REVIEW_REQUIRED' }
    } else {
        [pscustomobject][ordered]@{ status = 'NotApplicable'; evidenceRefs = @() }
    }

    $operations = [pscustomobject][ordered]@{
        detect = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'ProjectDetection'
        resolve = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'LoaderResolved'
        build = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'BuildPlan'
        launchPlan = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'LaunchPlan'
        launch = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'LaunchCheck'
        agent = [pscustomobject][ordered]@{
            build = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'AgentBuild'
            inject = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'AgentInjection'
        }
        single = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'SingleCapability'
        offlineLan = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'IntegratedLANCapability'
        dedicated = Get-MmtlAdapterV3Operation -Target $ledgerTarget -Dimension 'DedicatedCapability'
        historicalSafety = $historicalSafety
    }

    $buildJava = [pscustomobject][ordered]@{
        status = $claimStatus
        strategy = if ($buildJavaObservedMajor) { 'PinnedBuildEvidence' } elseif ($buildJavaMinimumMajor -and $buildJavaMaximumMajor) { 'FamilyBuildJavaPolicy' } else { $familyBuildJavaStatus }
        major = $buildJavaMajor
        observedMajor = $buildJavaObservedMajor
        minimumMajor = $buildJavaMinimumMajor
        maximumMajor = $buildJavaMaximumMajor
        preferredMajor = $buildJavaPreferredMajor
        requirementKind = $buildJavaRequirementKind
        source = $buildJavaSource
        evidenceRefs = @($buildJavaEvidence | Select-Object -Unique)
    }
    if ($null -ne $TargetEvidenceIndex) {
        if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { throw 'ADAPTER_V3_BUILD_EVIDENCE_ROOT_REQUIRED' }
        $indexedBuildJava = Get-MmtlAdapterV3BuildJavaEvidence -EvidenceIndex $TargetEvidenceIndex -EvidenceRoot $EvidenceRoot -TargetId $TargetId -TargetSpecHash ([string]$ledgerTarget.targetSpecHash) -UniverseHash ([string]$Universe.catalogHash)
        if ($indexedBuildJava) { $buildJava = $indexedBuildJava }
    }

    return [pscustomobject][ordered]@{
        contractVersion = 3
        adapterId = [string]$family.familyId
        loaderId = [string]$universeTarget.loaderId
        targetId = [string]$universeTarget.targetId
        minecraftId = [string]$universeTarget.minecraftId
        familyId = [string]$family.familyId
        targetSpecHash = [string]$ledgerTarget.targetSpecHash
        sourceHash = [string]$ledgerTarget.sourceHash
        toolchainHash = [string]$ledgerTarget.toolchainHash
        buildJava = $buildJava
        runtimeJava = [pscustomobject][ordered]@{
            status = $runtimeJavaStatus
            major = $javaMajor
            component = [string]$javaRequirement.component
            source = [string]$javaRequirement.source
            confidence = [string]$javaRequirement.confidence
            requirementKind = [string]$javaRequirement.requirementKind
            metadataStatus = [string]$javaEntry.observationStatus
            evidenceRefs = @($javaEvidence)
        }
        operations = $operations
        isExecutablePlan = $false
    }
}

function Resolve-MmtlAdapterV3Project {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)]$FamilyManifest,
        [Parameter(Mandatory)]$Ledger,
        [Parameter(Mandatory)]$RuntimeJavaCatalog
    )

    $adapter = Resolve-MmtlAdapterV3 -TargetId $TargetId -Universe $Universe -FamilyManifest $FamilyManifest -Ledger $Ledger -RuntimeJavaCatalog $RuntimeJavaCatalog
    $candidate = @($Universe.targets | Where-Object { [string]$_.targetId -ceq $TargetId })[0]
    $loaderVersion = if ($Project.PSObject.Properties['LoaderVersion']) { [string]$Project.LoaderVersion } elseif ($Project.PSObject.Properties['loaderVersion']) { [string]$Project.loaderVersion } else { '' }
    $projectLoader = if ($Project.PSObject.Properties['Loader']) { [string]$Project.Loader } elseif ($Project.PSObject.Properties['loaderId']) { [string]$Project.loaderId } else { '' }
    $projectMinecraft = if ($Project.PSObject.Properties['MinecraftVersion']) { [string]$Project.MinecraftVersion } elseif ($Project.PSObject.Properties['minecraftId']) { [string]$Project.minecraftId } else { '' }
    if ($projectLoader -cne [string]$candidate.loaderId -or $projectMinecraft -cne [string]$candidate.minecraftId -or $loaderVersion -cnotin @(Get-MmtlLoaderVersionCandidateValues -Candidates $candidate.loaderVersionCandidates)) {
        throw 'ADAPTER_V3_PROJECT_TARGET_MISMATCH'
    }

    $legacyVersion = if ($Project.PSObject.Properties['contractVersion']) { [int]$Project.contractVersion } else { 2 }
    if ($legacyVersion -ne 2) { throw 'ADAPTER_V3_LEGACY_CONTRACT_UNSUPPORTED' }
    return [pscustomobject][ordered]@{
        contractVersion = 3
        targetId = $adapter.targetId
        loaderId = $adapter.loaderId
        adapter = $adapter
        project = $Project
        legacyContractVersion = $legacyVersion
        isExecutablePlan = $false
    }
}

Export-ModuleMember -Function Resolve-MmtlAdapterV3, Resolve-MmtlAdapterV3Project
