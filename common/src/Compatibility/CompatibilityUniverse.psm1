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

    $loaderIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $targets = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[object]]::new()
    $releaseCount = @($minecraftById.Values | Where-Object { [string]$_.type -ceq 'release' }).Count

    foreach ($snapshot in @($LoaderSnapshots | Sort-Object { [string]$_.loaderId })) {
        $loaderId = [string]$snapshot.loaderId
        if ([string]::IsNullOrWhiteSpace($loaderId) -or -not $loaderIds.Add($loaderId)) {
            throw "COMPATIBILITY_SNAPSHOT_INVALID: Loader ID 为空或重复：'$loaderId'。"
        }
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
                $issues.Add([pscustomobject][ordered]@{
                    loaderId = $loaderId; status = 'Unknown'; reason = 'MINECRAFT_ID_NOT_RESOLVED_IN_MOJANG_CATALOG'
                    sourceUrl = [string]$snapshot.sourceUrl; evidence = $minecraftId
                })
                continue
            }

            $minecraft = $minecraftById[$minecraftId]
            $candidates = @()
            if ($snapshot.PSObject.Properties['loaderCandidatesByMinecraft'] -and $snapshot.loaderCandidatesByMinecraft) {
                $property = $snapshot.loaderCandidatesByMinecraft.PSObject.Properties[$minecraftId]
                if ($property) { $candidates = @($property.Value) }
            }
            $targets.Add([pscustomobject][ordered]@{
                targetId = "$loaderId@$minecraftId"; minecraftId = $minecraftId
                minecraftType = [string]$minecraft.type
                minecraftReleaseTime = if ($minecraft.PSObject.Properties['releaseTime']) { [string]$minecraft.releaseTime } else { $null }
                loaderId = $loaderId; loaderVersionCandidates = $candidates
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
    $sourceMaterial = [ordered]@{
        manifestHash = if ($Catalog.PSObject.Properties['manifestHash']) { [string]$Catalog.manifestHash } else { $null }
        sources = @($LoaderSnapshots | Sort-Object { [string]$_.loaderId } | ForEach-Object {
            [ordered]@{
                loaderId = [string]$_.loaderId; sourceUrl = [string]$_.sourceUrl
                sourceHash = if ($_.PSObject.Properties['sourceHash']) { [string]$_.sourceHash } else { $null }
                providerStatus = [string]$_.providerStatus
                supportedMinecraftIds = @($_.supportedVersions | ForEach-Object { if ($_ -is [string]) { [string]$_ } else { [string]$_.version } } | Sort-Object -Unique)
                loaderCandidatesByMinecraft = if ($_.PSObject.Properties['loaderCandidatesByMinecraft']) { $_.loaderCandidatesByMinecraft } else { $null }
            }
        })
        targets = @($sortedTargets | ForEach-Object { [ordered]@{ targetId = $_.targetId; availability = $_.availability } })
    }
    $canonicalSourceMaterial = ConvertTo-Json -InputObject $sourceMaterial -Depth 30 -Compress
    [pscustomobject][ordered]@{
        schemaVersion = 1; generatedAt = $GeneratedAt.ToUniversalTime().ToString('o')
        catalogHash = Get-MmtlCompatibilitySha256 -Text $canonicalSourceMaterial
        minecraftReleaseCount = $releaseCount; loaderCount = $loaderIds.Count
        targets = $sortedTargets; issues = @($issues | Sort-Object { [string]$_.loaderId }, { [string]$_.reason })
    }
}

Export-ModuleMember -Function New-MmtlCompatibilityUniverse
