Set-StrictMode -Version Latest

function Get-MmtlCompatibilitySha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-MmtlUniverseMinecraftVersions {
    param([Parameter(Mandatory)]$Catalog)
    if ($Catalog.PSObject.Properties['versionEntries']) { return @($Catalog.versionEntries) }
    if ($Catalog.PSObject.Properties['entries']) { return @($Catalog.entries) }
    throw 'COMPATIBILITY_CATALOG_INVALID: 缺少 versionEntries 或 entries。'
}

function Get-MmtlMinecraftVersionClassification {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId)

    $id = $MinecraftId
    $rule = 'UNCLASSIFIED_ID'
    $type = 'Unknown'
    if ($id.EndsWith('_unobfuscated', [StringComparison]::OrdinalIgnoreCase)) {
        $base = Get-MmtlMinecraftVersionClassification -MinecraftId $id.Substring(0, $id.Length - '_unobfuscated'.Length)
        if ($base.type -cne 'Unknown') {
            return [pscustomobject][ordered]@{ type = [string]$base.type; source = 'MinecraftIdSyntax'; rule = "UNOBFUSCATED_VARIANT:$([string]$base.rule)" }
        }
    }

    if ($id -match '(?i)(?:_original|_potato)$|^2point0[_-]') { $type = 'special'; $rule = 'APRIL_FOOLS_ORIGINAL_ID' }
    elseif ($id -match '(?i)_combat(?:-|$)') { $type = 'combat_test'; $rule = 'COMBAT_TEST_ID' }
    elseif ($id -match '(?i)experimental|deep_dark') { $type = 'experimental_snapshot'; $rule = 'EXPERIMENTAL_SNAPSHOT_ID' }
    elseif ($id -match '^\d{2}w\d{2}[a-z](?:-\d+)?$') { $type = 'snapshot'; $rule = 'WEEKLY_SNAPSHOT_ID' }
    elseif ($id -match '(?i)^(?:\d+(?:\.\d+)+)-(?:pre(?:-release)?)[-_ ]?\d+') { $type = 'pre'; $rule = 'NUMBERED_PRE_RELEASE_ID' }
    elseif ($id -match '(?i)^(?:\d+(?:\.\d+)+)-rc[-_ ]?\d+') { $type = 'rc'; $rule = 'NUMBERED_RELEASE_CANDIDATE_ID' }
    elseif ($id -match '^\d+(?:\.\d+){1,2}$') { $type = 'release'; $rule = 'NUMERIC_RELEASE_ID' }
    elseif ($id -match '^[bB]\d') { $type = 'old_beta'; $rule = 'BETA_ID_PREFIX' }
    elseif ($id -match '^[aA]\d|^[cC]\d|(?i)^infdev|^rd-') { $type = 'old_alpha'; $rule = 'LEGACY_PRE_RELEASE_ID_PREFIX' }

    [pscustomobject][ordered]@{ type = $type; source = if ($type -eq 'Unknown') { 'Unknown' } else { 'MinecraftIdSyntax' }; rule = $rule }
}

function New-MmtlCompatibilityUniverse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][object[]]$LoaderSnapshots,
        [Parameter(Mandatory)][DateTimeOffset]$GeneratedAt
    )

    $minecraftById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($version in (Get-MmtlUniverseMinecraftVersions -Catalog $Catalog)) {
        $id = [string]$version.id
        if ([string]::IsNullOrWhiteSpace($id) -or $minecraftById.ContainsKey($id)) {
            throw "COMPATIBILITY_CATALOG_INVALID: Minecraft ID 为空或重复：'$id'。"
        }
        $minecraftById.Add($id, $version)
    }

    $snapshotIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $loaderIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $targets = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[object]]::new()
    $manualStrategies = [Collections.Generic.List[object]]::new()
    $releaseCount = @($minecraftById.Values | Where-Object { [string]$_.type -ceq 'release' }).Count

    foreach ($snapshot in @($LoaderSnapshots | Sort-Object { [string]$_.loaderId })) {
        $loaderId = [string]$snapshot.loaderId
        $coverageModel = if ($snapshot.PSObject.Properties['coverageModel'] -and $snapshot.coverageModel) { [string]$snapshot.coverageModel } else { 'ExactAvailability' }
        if ($coverageModel -notin @('ExactAvailability', 'ManualArtifact')) { throw "COMPATIBILITY_COVERAGE_MODEL_INVALID: $loaderId/$coverageModel" }
        if ([string]::IsNullOrWhiteSpace($loaderId) -or -not $snapshotIds.Add($loaderId)) { throw "COMPATIBILITY_SNAPSHOT_INVALID: Loader/strategy ID 为空或重复：'$loaderId'。" }
        if ($coverageModel -eq 'ManualArtifact') {
            if ([string]$snapshot.providerStatus -cne 'ManualOnly' -or @($snapshot.supportedVersions).Count -gt 0) {
                throw "COMPATIBILITY_MANUAL_STRATEGY_INVALID: $loaderId must be ManualOnly and must not declare upstream version targets."
            }
            $manualStrategies.Add([pscustomobject][ordered]@{
                strategyId = $loaderId; status = 'ManualOnly'; reason = 'LOCAL_ARTIFACT_REQUIRED'
                sourceUrl = if ($snapshot.PSObject.Properties['sourceUrl'] -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.sourceUrl)) { [string]$snapshot.sourceUrl } else { $null }
                sourceClass = [string]$snapshot.sourceClass; trustClass = [string]$snapshot.trustClass
                transportSecurity = [string]$snapshot.transportSecurity; maintenanceState = [string]$snapshot.maintenanceState
                evidence = if ($snapshot.PSObject.Properties['error']) { [string]$snapshot.error } else { 'Manual compatibility strategy; no global upstream availability index.' }
            })
            continue
        }
        [void]$loaderIds.Add($loaderId)
        $status = [string]$snapshot.providerStatus
        if ($status -notin @('Available', 'Stale', 'OfflineCache', 'Degraded')) {
            $issues.Add([pscustomobject][ordered]@{
                loaderId = $loaderId; status = 'Unknown'; reason = 'AUTHORITATIVE_AVAILABILITY_UNRESOLVED'
                sourceUrl = [string]$snapshot.sourceUrl; evidence = [string]$snapshot.error
            })
            continue
        }
        if ($status -cne 'Available') {
            $issues.Add([pscustomobject][ordered]@{
                loaderId = $loaderId; status = 'Unknown'; reason = 'SOURCE_NOT_FRESH_OR_COMPLETE'
                sourceUrl = [string]$snapshot.sourceUrl; evidence = "providerStatus=$status; $([string]$snapshot.error)"
            })
        }

        $seenVersions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($candidate in @($snapshot.supportedVersions)) {
            $minecraftId = if ($candidate -is [string]) { [string]$candidate } else { [string]$candidate.version }
            if ([string]::IsNullOrWhiteSpace($minecraftId) -or -not $seenVersions.Add($minecraftId)) {
                throw "COMPATIBILITY_SNAPSHOT_INVALID: $loaderId 的 Minecraft ID 为空或重复：'$minecraftId'。"
            }
            if (-not $minecraftById.ContainsKey($minecraftId)) {
                $classification = Get-MmtlMinecraftVersionClassification -MinecraftId $minecraftId
                if ($classification.type -ceq 'Unknown') {
                    $issues.Add([pscustomobject][ordered]@{
                        loaderId = $loaderId; status = 'Unknown'; reason = 'MINECRAFT_ID_NOT_RESOLVED_IN_MOJANG_CATALOG'
                        sourceUrl = [string]$snapshot.sourceUrl; evidence = $minecraftId
                    })
                }
            } else {
                $classification = [pscustomobject][ordered]@{ type = [string]$minecraftById[$minecraftId].type; source = 'MojangManifest'; rule = 'MOJANG_MANIFEST_TYPE' }
            }

            $minecraft = if ($minecraftById.ContainsKey($minecraftId)) { $minecraftById[$minecraftId] } else { $null }
            $candidates = @()
            $candidateSourceUrl = $null
            $candidateSourceHash = $null
            if ($snapshot.PSObject.Properties['loaderCandidatesByMinecraft'] -and $snapshot.loaderCandidatesByMinecraft) {
                $property = $snapshot.loaderCandidatesByMinecraft.PSObject.Properties[$minecraftId]
                if ($property) {
                    $candidateRecord = $property.Value
                    if ($candidateRecord -and $candidateRecord.PSObject.Properties['candidates']) {
                        $candidates = @($candidateRecord.candidates)
                        $candidateSourceUrl = if ($candidateRecord.PSObject.Properties['sourceUrl']) { [string]$candidateRecord.sourceUrl } else { $null }
                        $candidateSourceHash = if ($candidateRecord.PSObject.Properties['sourceHash']) { [string]$candidateRecord.sourceHash } else { $null }
                    } else { $candidates = @($candidateRecord) }
                }
            }
            $targets.Add([pscustomobject][ordered]@{
                targetId = "$loaderId@$minecraftId"; minecraftId = $minecraftId
                minecraftType = [string]$classification.type
                minecraftTypeSource = [string]$classification.source
                minecraftTypeRule = [string]$classification.rule
                minecraftReleaseTime = if ($minecraft -and $minecraft.PSObject.Properties['releaseTime'] -and $minecraft.releaseTime) { [string]$minecraft.releaseTime } else { $null }
                loaderId = $loaderId; loaderVersionCandidates = $candidates
                candidateStatus = if ($candidates.Count) { 'Resolved' } else { 'Pending' }
                candidateSourceUrl = $candidateSourceUrl; candidateSourceHash = $candidateSourceHash
                sourceHash = if ($snapshot.PSObject.Properties['sourceHash'] -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.sourceHash)) { [string]$snapshot.sourceHash } else { $null }
                authoritativeSource = [string]$snapshot.sourceUrl
                sourceClass = [string]$snapshot.sourceClass; trustClass = [string]$snapshot.trustClass
                transportSecurity = [string]$snapshot.transportSecurity; maintenanceState = [string]$snapshot.maintenanceState
                availability = 'Available'; buildToolchainCandidates = @()
                runtimeJavaRequirement = [pscustomobject]@{ major = $null; source = 'Unknown'; confidence = 'Unknown' }
                buildJavaRequirement = [pscustomobject]@{ major = $null; source = 'Unknown'; confidence = 'Unknown' }
                agentRequirement = [pscustomobject]@{ status = 'Unknown'; source = 'Unknown' }
                status = 'Unknown'
            })
        }
    }

    $sortedTargets = @($targets | Sort-Object { [string]$_.targetId })
    $sortedManualStrategies = @($manualStrategies | Sort-Object { [string]$_.strategyId })
    $sourceMaterial = [ordered]@{
        manifestHash = if ($Catalog.PSObject.Properties['manifestHash']) { [string]$Catalog.manifestHash } else { $null }
        sources = @($LoaderSnapshots | Where-Object { -not $_.PSObject.Properties['coverageModel'] -or [string]$_.coverageModel -cne 'ManualArtifact' } | Sort-Object { [string]$_.loaderId } | ForEach-Object {
            [ordered]@{
                loaderId = [string]$_.loaderId; sourceUrl = [string]$_.sourceUrl
                sourceHash = if ($_.PSObject.Properties['sourceHash']) { [string]$_.sourceHash } else { $null }
                providerStatus = [string]$_.providerStatus
                supportedMinecraftIds = @($_.supportedVersions | ForEach-Object { if ($_ -is [string]) { [string]$_ } else { [string]$_.version } } | Sort-Object -Unique)
                loaderCandidatesByMinecraft = if ($_.PSObject.Properties['loaderCandidatesByMinecraft']) { $_.loaderCandidatesByMinecraft } else { $null }
            }
        })
        manualStrategies = $sortedManualStrategies
        targets = @($sortedTargets | ForEach-Object { [ordered]@{ targetId = $_.targetId; availability = $_.availability } })
    }
    $canonicalSourceMaterial = ConvertTo-Json -InputObject $sourceMaterial -Depth 30 -Compress
    $candidateMaterial = @($sortedTargets | ForEach-Object {
        [ordered]@{
            targetId = [string]$_.targetId; candidateStatus = [string]$_.candidateStatus
            loaderVersionCandidates = @($_.loaderVersionCandidates); candidateSourceUrl = $_.candidateSourceUrl
            candidateSourceHash = $_.candidateSourceHash
        }
    })
    $candidateJson = ConvertTo-Json -InputObject $candidateMaterial -Depth 30 -Compress
    [pscustomobject][ordered]@{
        schemaVersion = 1; auditStatus = 'IN_PROGRESS'; generatedAt = $GeneratedAt.ToUniversalTime().ToString('o')
        catalogHash = Get-MmtlCompatibilitySha256 -Text $canonicalSourceMaterial
        candidateCatalogHash = Get-MmtlCompatibilitySha256 -Text $candidateJson
        minecraftReleaseCount = $releaseCount; loaderCount = $loaderIds.Count; strategyCount = $sortedManualStrategies.Count
        targets = $sortedTargets; manualStrategies = $sortedManualStrategies
        issues = @($issues | Sort-Object { [string]$_.loaderId }, { [string]$_.reason })
    }
}

Export-ModuleMember -Function New-MmtlCompatibilityUniverse, Get-MmtlMinecraftVersionClassification
