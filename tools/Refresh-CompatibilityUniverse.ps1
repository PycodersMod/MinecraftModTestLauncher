[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$SnapshotDirectory,
    [string]$ProxyUri,
    [switch]$KeepRuntimeCache
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if (-not $SnapshotDirectory) { $SnapshotDirectory = Join-Path $RepositoryRoot 'compatibility/snapshots' }
$SnapshotDirectory = [IO.Path]::GetFullPath($SnapshotDirectory)
$sourceManifestPath = Join-Path $RepositoryRoot 'compatibility/sources.json'
$sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$priorSnapshotIndexPath = Join-Path $RepositoryRoot 'compatibility/source-snapshots.json'
$priorSnapshotIndex = if (Test-Path -LiteralPath $priorSnapshotIndexPath) { Get-Content -LiteralPath $priorSnapshotIndexPath -Raw | ConvertFrom-Json -ErrorAction Stop } else { $null }
$generatedAt = [DateTimeOffset]::UtcNow

if ($ProxyUri) {
    $proxy = $null
    $proxyIp = $null
    if (-not [Uri]::TryCreate($ProxyUri, [UriKind]::Absolute, [ref]$proxy) -or $proxy.Scheme -cne 'http' -or -not [Net.IPAddress]::TryParse($proxy.Host, [ref]$proxyIp)) {
        throw 'PROXY_INVALID: 仅接受 HTTP loopback IP 代理。'
    }
    if (-not [Net.IPAddress]::IsLoopback($proxyIp)) { throw 'PROXY_INVALID: 代理必须位于 loopback。' }
}

Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/MinecraftVersionCatalog.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/Forge.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/Fabric.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/NeoForge.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/Quilt.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/HistoricalProviders.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Compatibility/CompatibilityUniverse.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Compatibility/SourceSnapshot.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Compatibility/CompatibilityCandidateCatalog.psm1') -Force

$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) "mmtl-compat-universe-$([guid]::NewGuid().ToString('N'))"))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null

$httpGet = {
    param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSeconds)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    if ($ProxyUri) {
        $handler.UseProxy = $true
        $handler.Proxy = [Net.WebProxy]::new($ProxyUri)
    } else { $handler.UseProxy = $false }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, [Uri]$Uri)
    $null = $request.Headers.TryAddWithoutValidation('User-Agent', 'MMTL-Compatibility-Universe-Refresh/1.0')
    foreach ($key in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation([string]$key, [string]$Headers[$key]) }
    try {
        $response = $client.Send($request)
        try {
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $responseHeaders = @{}
            foreach ($header in $response.Headers) { $responseHeaders[[string]$header.Key] = [string]::Join(',', [string[]]$header.Value) }
            foreach ($header in $response.Content.Headers) { $responseHeaders[[string]$header.Key] = [string]::Join(',', [string[]]$header.Value) }
            [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Headers = $responseHeaders; Bytes = [byte[]]$bytes; ResponseUri = $Uri }
        } finally { $response.Dispose() }
    } finally { $request.Dispose(); $client.Dispose(); $handler.Dispose() }
}

function Get-SourceDefinition {
    param([string]$LoaderId)
    $sourceManifest.loaders | Where-Object { [string]$_.loaderId -ceq $LoaderId } | Select-Object -First 1
}

function Get-ProviderHash {
    param($ProviderSnapshot)
    foreach ($propertyName in @('localHash', 'versionsStatus', 'modern', 'transition')) {
        $property = $ProviderSnapshot.PSObject.Properties[$propertyName]
        if (-not $property -or $null -eq $property.Value) { continue }
        if ($propertyName -eq 'localHash' -and $property.Value) { return [string]$property.Value }
        if ($propertyName -eq 'versionsStatus' -and $property.Value.localHash) { return [string]$property.Value.localHash }
    }
    $null
}

function New-LoaderSourceSnapshot {
    param(
        [Parameter(Mandatory)][string]$LoaderId,
        [Parameter(Mandatory)][string]$ProviderStatus,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceUrl,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SupportedIds,
        [string]$SourceHash,
        [string]$ErrorText,
        [object]$CandidatesByMinecraft
    )
    $definition = Get-SourceDefinition -LoaderId $LoaderId
    if ([string]::IsNullOrWhiteSpace($SourceUrl) -and $definition) { $SourceUrl = [string]$definition.sourceUrl }
    [pscustomobject][ordered]@{
        loaderId = $LoaderId; providerStatus = $ProviderStatus; sourceUrl = $SourceUrl
        coverageModel = if ($definition -and $definition.PSObject.Properties['coverageModel']) { [string]$definition.coverageModel } else { 'ExactAvailability' }
        sourceClass = if ($definition) { [string]$definition.sourceClass } else { 'Unknown' }
        trustClass = if ($definition) { [string]$definition.trustClass } else { 'Unknown' }
        transportSecurity = if ($definition) { [string]$definition.transportSecurity } else { 'Unknown' }
        maintenanceState = if ($LoaderId -in @('Forge', 'Fabric', 'NeoForge', 'Quilt', 'LegacyFabric', 'OrnitheLoader')) { 'Active' } elseif ($LoaderId -in @('LiteLoader', 'Rift', 'ModLoader', 'ModLoaderMP')) { 'Archived' } else { 'Unknown' }
        sourceHash = if ([string]::IsNullOrWhiteSpace($SourceHash)) { $null } else { $SourceHash }; supportedVersions = @($SupportedIds | Sort-Object -Unique)
        loaderCandidatesByMinecraft = $CandidatesByMinecraft; error = $ErrorText
    }
}

try {
    $catalog = Get-MmtlMinecraftVersionCatalog -RuntimeRoot $temporaryRoot -ForceRefresh -HttpGet $httpGet
    $rawManifestPath = Join-Path $temporaryRoot 'metadata/mojang/manifest/version_manifest_v2.json'
    $rawManifestBytes = [IO.File]::ReadAllBytes($rawManifestPath)
    $manifest = [Text.Encoding]::UTF8.GetString($rawManifestBytes) | ConvertFrom-Json -ErrorAction Stop
    $versionEntries = @($manifest.versions | ForEach-Object {
        [pscustomobject][ordered]@{ id = [string]$_.id; type = [string]$_.type; releaseTime = [string]$_.releaseTime }
    })
    $universeCatalog = [pscustomobject]@{ manifestHash = [string]$catalog.manifestHash; entries = @($catalog.entries); versionEntries = $versionEntries }
    $minecraftIds = @($versionEntries | ForEach-Object { [string]$_.id })
    $runtimeCache = Join-Path $temporaryRoot 'provider-runtime'
    [IO.Directory]::CreateDirectory($runtimeCache) | Out-Null

    $providerResults = [ordered]@{}
    $providerInvocations = @(
        @{ loaderId = 'Forge'; command = 'Get-MmtlForgeProviderSnapshot'; module = 'Forge.psm1' },
        @{ loaderId = 'Fabric'; command = 'Get-MmtlFabricProviderSnapshot'; module = 'Fabric.psm1' },
        @{ loaderId = 'NeoForge'; command = 'Get-MmtlNeoForgeProviderSnapshot'; module = 'NeoForge.psm1' },
        @{ loaderId = 'Quilt'; command = 'Get-MmtlQuiltProviderSnapshot'; module = 'Quilt.psm1' }
    )
    foreach ($item in $providerInvocations) {
        try {
            $modulePath = Join-Path $RepositoryRoot "common/src/Catalog/Providers/$($item.module)"
            Import-Module $modulePath -Force
            $providerResults[$item.loaderId] = if ($item.loaderId -in @('Forge', 'NeoForge')) { & $item.command -Catalog $catalog -RuntimeRoot $runtimeCache -ForceRefresh -HttpGet $httpGet } else { & $item.command -RuntimeRoot $runtimeCache -ForceRefresh -HttpGet $httpGet }
        } catch { $providerResults[$item.loaderId] = [pscustomobject]@{ loaderId = $item.loaderId; providerStatus = 'Unavailable'; sourceUrl = ''; error = $_.Exception.Message } }
    }
    Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/HistoricalProviders.psm1') -Force
    foreach ($item in @(
        @{ loaderId = 'LegacyFabric'; command = 'Get-MmtlLegacyFabricProviderSnapshot' },
        @{ loaderId = 'OrnitheLoader'; command = 'Get-MmtlOrnitheProviderSnapshot' },
        @{ loaderId = 'LiteLoader'; command = 'Get-MmtlLiteLoaderProviderSnapshot' }
    )) {
        try { $providerResults[$item.loaderId] = & $item.command -RuntimeRoot $runtimeCache -ForceRefresh -HttpGet $httpGet }
        catch { $providerResults[$item.loaderId] = [pscustomobject]@{ loaderId = $item.loaderId; providerStatus = 'Unavailable'; sourceUrl = ''; error = $_.Exception.Message } }
    }

    $loaderSnapshots = [Collections.Generic.List[object]]::new()
    foreach ($loaderId in @('Fabric', 'Quilt', 'LegacyFabric', 'OrnitheLoader', 'LiteLoader')) {
        $provider = $providerResults[$loaderId]
        $ids = @($provider.supportedVersions | ForEach-Object { if ($_ -is [string]) { [string]$_ } else { [string]$_.version } } | Where-Object { $_ })
        $loaderSnapshots.Add((New-LoaderSourceSnapshot -LoaderId $loaderId -ProviderStatus ([string]$provider.providerStatus) -SourceUrl ([string]$provider.sourceUrl) -SupportedIds $ids -SourceHash (Get-ProviderHash $provider) -ErrorText ([string]$provider.error)))
    }

    $forge = $providerResults.Forge
    $forgeMetadata = if ($forge.PSObject.Properties['versionsStatus']) { $forge.versionsStatus } else { $null }
    $forgeIds = [Collections.Generic.List[string]]::new(); $forgeCandidates = [ordered]@{}
    if ($forgeMetadata -and $forgeMetadata.providerStatus -eq 'Available') {
        foreach ($id in $minecraftIds) {
            $matches = @($forge.versions | Where-Object { ([string]$_).StartsWith("$id-", [StringComparison]::Ordinal) })
            if ($matches.Count) {
                $forgeIds.Add($id)
                $forgeCandidates[$id] = [pscustomobject][ordered]@{ candidates = @($matches); sourceUrl = [string]$forgeMetadata.sourceUrl; sourceHash = [string]$forgeMetadata.localHash }
            }
        }
    }
    $loaderSnapshots.Add((New-LoaderSourceSnapshot -LoaderId 'Forge' -ProviderStatus $(if ($forgeMetadata) { [string]$forgeMetadata.providerStatus } else { 'Unavailable' }) -SourceUrl $(if ($forgeMetadata) { [string]$forgeMetadata.sourceUrl } else { [string]$forge.sourceUrl }) -SupportedIds @($forgeIds) -SourceHash $(if ($forgeMetadata) { [string]$forgeMetadata.localHash } else { $null }) -ErrorText ([string]$forge.error) -CandidatesByMinecraft ([pscustomobject]$forgeCandidates)))

    $neo = $providerResults.NeoForge
    $neoIds = [Collections.Generic.List[string]]::new(); $neoCandidates = [ordered]@{}
    if ($neo.providerStatus -in @('Available', 'Stale')) {
        foreach ($family in @($neo.modern, $neo.transition)) {
            foreach ($version in @($family.versions)) {
                $mapping = Resolve-MmtlNeoForgeVersionMapping -Version ([string]$version) -CatalogEntrySet $neo.catalogEntrySet -ArtifactFamily $family.artifactFamily
                if (-not $mapping) { continue }
                $id = [string]$mapping.minecraftId
                if (-not $neoCandidates.Contains($id)) {
                    $neoIds.Add($id)
                    $neoCandidates[$id] = [pscustomobject][ordered]@{
                        candidates = [Collections.Generic.List[string]]::new()
                        sourceUrl = [string]$family.uri
                        sourceHash = [string]$family.localHash
                    }
                }
                $neoCandidates[$id].candidates.Add([string]$version)
            }
        }
    }
    $neoHashMaterial = @($neo.modern.localHash, $neo.transition.localHash) -join ':'
    $neoHash = if ($neoHashMaterial -match '[a-f0-9]{64}') { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($neoHashMaterial))).ToLowerInvariant() } else { $null }
    $loaderSnapshots.Add((New-LoaderSourceSnapshot -LoaderId 'NeoForge' -ProviderStatus ([string]$neo.providerStatus) -SourceUrl ([string]$neo.sourceUrl) -SupportedIds @($neoIds) -SourceHash $neoHash -ErrorText ([string]$neo.error) -CandidatesByMinecraft ([pscustomobject]$neoCandidates)))

    $externalHistoricalEvidence = [Collections.Generic.List[object]]::new()
    foreach ($loaderId in @('Rift', 'ModLoader', 'ModLoaderMP')) {
        $definition = Get-SourceDefinition -LoaderId $loaderId
        $historyError = $null
        try {
            $record = $null
            try {
                $response = & $httpGet ([string]$definition.sourceUrl) @{} 30
                if ([int]$response.StatusCode -ne 200) { throw "HTTP_$([int]$response.StatusCode)" }
                $bytes = [byte[]]$response.Bytes
            } catch {
                if ($loaderId -cne 'Rift') { throw }
                $cachedRecord = @($priorSnapshotIndex.sources | Where-Object { [string]$_.providerId -ceq 'Rift' -and [string]$_.sourceUrl -ceq [string]$definition.sourceUrl } | Sort-Object retrievedAt -Descending | Select-Object -First 1)[0]
                if (-not $cachedRecord) { throw "RIFT_OFFICIAL_SNAPSHOT_UNAVAILABLE: $($_.Exception.Message)" }
                $bytes = Get-MmtlCompatibilitySourceSnapshotBytes -SnapshotDirectory $SnapshotDirectory -Record $cachedRecord
                $record = $cachedRecord
            }
            $sourceContent = [Text.Encoding]::UTF8.GetString($bytes)
            if (-not $record) { $record = Save-MmtlCompatibilitySourceSnapshot -ProviderId $loaderId -SourceUrl ([string]$definition.sourceUrl) -Bytes $bytes -OutputDirectory $SnapshotDirectory -RetrievedAt $generatedAt -SourceClass ([string]$definition.sourceClass) -TrustClass ([string]$definition.trustClass) }
            $externalHistoricalEvidence.Add($record)
            $ids = if ($loaderId -eq 'Rift') {
                @(Get-MmtlRiftMinecraftIdsFromMetadata -JsonContent $sourceContent)
            } else { @(Get-MmtlCompatibilityArchiveMinecraftIds -HtmlContent $sourceContent) }
            if ($ids.Count -eq 0) { throw 'HISTORICAL_AVAILABILITY_PARSE_EMPTY' }
            $candidateMap = [ordered]@{}
            foreach ($id in $ids) {
                $candidates = switch ($loaderId) {
                    'Rift' { @(Get-MmtlRiftCandidates -MinecraftId $id) }
                    'ModLoader' { @(Get-MmtlModLoaderArchiveCandidates -MinecraftId $id) }
                    'ModLoaderMP' { @(Get-MmtlModLoaderMPArchiveCandidates -MinecraftId $id) }
                }
                if ($candidates.Count) {
                    $candidateMap[$id] = [pscustomobject][ordered]@{
                        candidates = $candidates; sourceUrl = [string]$definition.sourceUrl; sourceHash = [string]$record.sha256
                    }
                }
            }
            $loaderSnapshots.Add((New-LoaderSourceSnapshot -LoaderId $loaderId -ProviderStatus 'Available' -SourceUrl ([string]$definition.sourceUrl) -SupportedIds $ids -SourceHash ([string]$record.sha256) -CandidatesByMinecraft ([pscustomobject]$candidateMap)))
        } catch {
            $historyError = $_.Exception.Message
            $loaderSnapshots.Add((New-LoaderSourceSnapshot -LoaderId $loaderId -ProviderStatus 'Unavailable' -SourceUrl ([string]$definition.sourceUrl) -SupportedIds @() -ErrorText $historyError))
        }
    }
    $jarDefinition = Get-SourceDefinition -LoaderId 'JarMod'
    $loaderSnapshots.Add((New-LoaderSourceSnapshot -LoaderId 'JarMod' -ProviderStatus 'ManualOnly' -SourceUrl ([string]$jarDefinition.sourceUrl) -SupportedIds @() -ErrorText 'USER_SUPPLIED_LOCAL_ARTIFACT_REQUIRED'))

    $evidence = [Collections.Generic.List[object]]::new()
    $mojangEvidence = Save-MmtlCompatibilitySourceSnapshot -ProviderId 'Mojang' -SourceUrl ([string]$sourceManifest.minecraftCatalog.sourceUrl) -Bytes $rawManifestBytes -OutputDirectory $SnapshotDirectory -RetrievedAt $generatedAt -SourceClass ([string]$sourceManifest.minecraftCatalog.sourceClass) -TrustClass ([string]$sourceManifest.minecraftCatalog.trustClass)
    $evidence.Add($mojangEvidence)
    foreach ($record in $externalHistoricalEvidence) { $evidence.Add($record) }
    foreach ($cacheFile in (Get-ChildItem -LiteralPath $temporaryRoot -Recurse -File -Filter '*.json')) {
        try { $envelope = Get-Content -LiteralPath $cacheFile.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $envelope.bodyBase64 -or -not $envelope.sourceUrl -or -not $envelope.providerId) { continue }
        $bytes = [Convert]::FromBase64String([string]$envelope.bodyBase64)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($hash -cne [string]$envelope.localHash) { throw "SOURCE_CACHE_HASH_MISMATCH: $($envelope.sourceUrl)" }
        $providerDefinition = $sourceManifest.loaders | Where-Object { [string]$_.providerId -ceq [string]$envelope.providerId } | Select-Object -First 1
        $providerId = ([string]$envelope.providerId -replace '[^A-Za-z0-9-]', '')
        if ($providerId.Length -lt 2) { throw 'SOURCE_PROVIDER_ID_INVALID' }
        $record = Save-MmtlCompatibilitySourceSnapshot -ProviderId $providerId -SourceUrl ([string]$envelope.sourceUrl) -Bytes $bytes -OutputDirectory $SnapshotDirectory -RetrievedAt ([DateTimeOffset]::Parse([string]$envelope.fetchedAt)) -SourceClass $(if ($providerDefinition) { [string]$providerDefinition.sourceClass } else { 'Unknown' }) -TrustClass $(if ($providerDefinition) { [string]$providerDefinition.trustClass } else { 'Unknown' })
        $evidence.Add($record)
    }

    foreach ($snapshot in $loaderSnapshots) {
        if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.sourceHash)) { continue }
        $matchingEvidence = $evidence | Where-Object { [string]$_.sourceUrl -ceq [string]$snapshot.sourceUrl } | Select-Object -First 1
        if ($matchingEvidence) { $snapshot.sourceHash = [string]$matchingEvidence.sha256 }
    }

    $universe = New-MmtlCompatibilityUniverse -Catalog $universeCatalog -LoaderSnapshots @($loaderSnapshots) -GeneratedAt $generatedAt
    $candidateEvidencePath = Join-Path $RepositoryRoot 'compatibility/candidate-evidence.local.json'
    if (-not (Test-Path -LiteralPath $candidateEvidencePath)) { throw 'CANDIDATE_EVIDENCE_INDEX_MISSING' }
    $candidateEvidenceIndex = Get-Content -LiteralPath $candidateEvidencePath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ([int]$candidateEvidenceIndex.schemaVersion -ne 1 -or [int]$candidateEvidenceIndex.sourceCount -ne @($candidateEvidenceIndex.sources).Count) { throw 'CANDIDATE_EVIDENCE_INDEX_INVALID' }
    foreach ($candidateSource in $candidateEvidenceIndex.sources) {
        $null = Get-MmtlCompatibilitySourceSnapshotBytes -SnapshotDirectory $SnapshotDirectory -Record $candidateSource
        $evidence.Add($candidateSource)
    }
    $candidateLoaders = @('Fabric', 'Quilt', 'LegacyFabric', 'OrnitheLoader', 'LiteLoader')
    $candidateCatalogs = [Collections.Generic.List[object]]::new()
    foreach ($candidateLoader in $candidateLoaders) {
        $candidateCatalogPath = Join-Path $RepositoryRoot "compatibility/candidate-catalogs/$candidateLoader.json"
        if (-not (Test-Path -LiteralPath $candidateCatalogPath)) { throw "CANDIDATE_CATALOG_MISSING: $candidateLoader" }
        $candidateCatalogs.Add((Get-Content -LiteralPath $candidateCatalogPath -Raw | ConvertFrom-Json -ErrorAction Stop))
    }
    $universe = Join-MmtlCompatibilityCandidateCatalogs -Universe $universe -CandidateCatalogs @($candidateCatalogs) -SourceEvidence @($evidence) -RequiredLoaderIds $candidateLoaders
    $index = [pscustomobject][ordered]@{
        schemaVersion = 1; auditStatus = [string]$universe.auditStatus; generatedAt = $generatedAt.ToUniversalTime().ToString('o')
        sourceCount = $evidence.Count; sources = @($evidence | Sort-Object providerId, sourceUrl, sha256)
    }
    $indexPath = Join-Path $RepositoryRoot 'compatibility/source-snapshots.json'
    $previewPath = Join-Path $RepositoryRoot 'compatibility/universe-preview.json'
    $frozenPath = Join-Path $RepositoryRoot 'compatibility/compatibility-universe.json'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $indexPath)) | Out-Null
    [IO.File]::WriteAllText($indexPath, (ConvertTo-Json -InputObject $index -Depth 40), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($previewPath, (ConvertTo-Json -InputObject $universe -Depth 50), [Text.UTF8Encoding]::new($false))
    if ($universe.auditStatus -ceq 'FROZEN') {
        $sourceManifest.auditStatus = 'FROZEN'
        $sourceManifest.generatedAt = $universe.generatedAt
        $sourceManifest.minecraftCatalog | Add-Member -NotePropertyName sourceHash -NotePropertyValue ([string]$mojangEvidence.sha256) -Force
        foreach ($definition in $sourceManifest.loaders) {
            $snapshot = $loaderSnapshots | Where-Object { [string]$_.loaderId -ceq [string]$definition.loaderId } | Select-Object -First 1
            if ([string]$definition.coverageModel -ceq 'ManualArtifact') {
                $definition.status = 'ManualOnly'
                continue
            }
            if (-not $snapshot -or [string]$snapshot.providerStatus -cne 'Available' -or [string]::IsNullOrWhiteSpace([string]$snapshot.sourceHash)) {
                throw "COMPATIBILITY_SOURCE_FREEZE_REJECTED: $([string]$definition.loaderId) 缺少 Available 状态或来源 SHA-256。"
            }
            $definition.status = 'FrozenAvailability'
            $definition | Add-Member -NotePropertyName sourceHash -NotePropertyValue ([string]$snapshot.sourceHash) -Force
        }
        [IO.File]::WriteAllText((Join-Path $RepositoryRoot 'compatibility/sources.json'), (ConvertTo-Json -InputObject $sourceManifest -Depth 30), [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($frozenPath, (ConvertTo-Json -InputObject $universe -Depth 50), [Text.UTF8Encoding]::new($false))
    }

    [pscustomobject][ordered]@{
        auditStatus = $universe.auditStatus; generatedAt = $universe.generatedAt; catalogHash = $universe.catalogHash
        minecraftVersionCount = $versionEntries.Count; minecraftReleaseCount = $universe.minecraftReleaseCount
        loaderCount = $universe.loaderCount; strategyCount = $universe.strategyCount; targetPairCount = $universe.targets.Count; unknownSourceIssues = $universe.issues.Count
        perLoader = @($loaderSnapshots | ForEach-Object { [pscustomobject]@{ loaderId = $_.loaderId; providerStatus = $_.providerStatus; targetCount = @($_.supportedVersions).Count; sourceUrl = $_.sourceUrl } })
        sourceSnapshotCount = $evidence.Count; previewPath = 'compatibility/universe-preview.json'
    } | ConvertTo-Json -Depth 12
} finally {
    if (-not $KeepRuntimeCache) {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
        if ($resolvedTemporaryRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTemporaryRoot) -match '^mmtl-compat-universe-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
