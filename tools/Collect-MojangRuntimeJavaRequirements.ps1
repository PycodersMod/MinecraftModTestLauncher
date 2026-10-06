[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ProxyUri,
    [ValidateRange(1, 32)][int]$MaxConcurrency = 12,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$universePath = Join-Path $RepositoryRoot 'compatibility/universe-preview.json'
$sourceIndexPath = Join-Path $RepositoryRoot 'compatibility/source-snapshots.json'
$snapshotRoot = Join-Path $RepositoryRoot 'compatibility/snapshots'
$catalogPath = Join-Path $RepositoryRoot 'compatibility/runtime-java-catalog.json'
$catalogSchemaPath = Join-Path $RepositoryRoot 'common/schemas/runtime-java-catalog.schema.json'
$fallbackPath = Join-Path $RepositoryRoot 'common/src/Catalog/data/java-runtime-fallback.json'

if ($ProxyUri) {
    $proxy = $null
    $proxyIp = $null
    if (-not [Uri]::TryCreate($ProxyUri, [UriKind]::Absolute, [ref]$proxy) -or $proxy.Scheme -cne 'http' -or -not [Net.IPAddress]::TryParse($proxy.Host, [ref]$proxyIp) -or -not [Net.IPAddress]::IsLoopback($proxyIp)) {
        throw 'PROXY_INVALID: 仅接受 HTTP loopback IP 代理。'
    }
}

Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/JavaRuntimeResolver.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/MojangMetadataBatchPlanner.psm1') -Force

function Write-MmtlRuntimeJavaJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 40)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth $Depth), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Move($temporary, $Path, $true) } else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Write-MmtlRuntimeJavaSourceIndex {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Index)
    $Index.sources = @($Index.sources | Sort-Object providerId, sourceUrl, sha256)
    $Index.sourceCount = $Index.sources.Count
    Write-MmtlRuntimeJavaJson -Path $Path -Value $Index -Depth 40
}

function Save-MmtlMojangVersionSnapshot {
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)]$VersionEntry, [Parameter(Mandatory)][string]$RetrievedAt)
    $actualSha1 = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($Bytes)).ToLowerInvariant()
    if ($actualSha1 -cne ([string]$VersionEntry.sha1).ToLowerInvariant()) { throw "MOJANG_VERSION_SHA1_MISMATCH:$($VersionEntry.id)" }
    $raw = [Text.Encoding]::UTF8.GetString($Bytes)
    try { $metadata = ConvertFrom-Json -InputObject $raw -ErrorAction Stop } catch { throw "MOJANG_VERSION_JSON_INVALID:$($VersionEntry.id):$($_.Exception.Message)" }
    if ([string]$metadata.id -cne [string]$VersionEntry.id) { throw "MOJANG_VERSION_ID_MISMATCH:$($VersionEntry.id):$($metadata.id)" }
    $localSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    $relativePath = "MojangVersions/$localSha256.bin"
    $path = Join-Path $snapshotRoot $relativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existingSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingSha256 -cne $localSha256) { throw "MOJANG_VERSION_SNAPSHOT_COLLISION:$($VersionEntry.id)" }
    } else {
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        try { [IO.File]::WriteAllBytes($temporary, $Bytes); [IO.File]::Move($temporary, $path) }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    [pscustomobject][ordered]@{
        metadata = $metadata; rawJson = $raw; localSha256 = $localSha256
        snapshot = [pscustomobject][ordered]@{
            providerId = 'MojangVersion'; minecraftId = [string]$VersionEntry.id; sourceUrl = [string]$VersionEntry.url
            sourceClass = 'ActiveOfficial'; trustClass = 'TrustedOfficial'; transportSecurity = 'HTTPS'
            retrievedAt = $RetrievedAt; relativePath = $relativePath; byteLength = $Bytes.Length
            sha256 = $localSha256; manifestSha1 = $actualSha1
        }
    }
}

$universe = Get-Content -LiteralPath $universePath -Raw | ConvertFrom-Json -ErrorAction Stop
$sourceIndex = Get-Content -LiteralPath $sourceIndexPath -Raw | ConvertFrom-Json -ErrorAction Stop
$manifestRecord = @($sourceIndex.sources | Where-Object { [string]$_.providerId -ceq 'Mojang' })
if ($manifestRecord.Count -ne 1) { throw 'MOJANG_MANIFEST_SNAPSHOT_INDEX_INVALID' }
$manifestPath = Join-Path $snapshotRoot ([string]$manifestRecord[0].relativePath)
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'MOJANG_MANIFEST_SNAPSHOT_MISSING' }
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($manifestHash -cne [string]$manifestRecord[0].sha256) { throw 'MOJANG_MANIFEST_SNAPSHOT_HASH_MISMATCH' }
$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
$targetIds = @($universe.targets | ForEach-Object { [string]$_.minecraftId } | Sort-Object -Unique)
$manifestById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($entry in @($manifest.versions)) { $manifestById.Add([string]$entry.id, $entry) }
$targetEntries = [Collections.Generic.List[object]]::new()
foreach ($id in $targetIds) { if ($manifestById.ContainsKey($id)) { $targetEntries.Add($manifestById[$id]) } }

$existingVersionSources = [Collections.Generic.List[object]]::new()
foreach ($source in @($sourceIndex.sources | Where-Object { [string]$_.providerId -ceq 'MojangVersion' })) { $existingVersionSources.Add($source) }
$sourceRecordsById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($source in $existingVersionSources) {
    if (-not $source.PSObject.Properties['minecraftId'] -or -not $source.PSObject.Properties['manifestSha1']) { continue }
    if ($sourceRecordsById.ContainsKey([string]$source.minecraftId)) { throw "MOJANG_VERSION_SOURCE_DUPLICATE:$($source.minecraftId)" }
    $sourceRecordsById.Add([string]$source.minecraftId, $source)
}

$downloaded = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$missingEntries = [Collections.Generic.List[object]]::new()
foreach ($entry in $targetEntries) {
    $id = [string]$entry.id
    $sourceUri = $null
    if (-not [Uri]::TryCreate([string]$entry.url, [UriKind]::Absolute, [ref]$sourceUri) -or $sourceUri.Scheme -cne 'https' -or $sourceUri.Host -cne 'piston-meta.mojang.com' -or [string]$entry.sha1 -notmatch '^[a-f0-9]{40}$') {
        throw "MOJANG_VERSION_MANIFEST_ENTRY_INVALID:$id"
    }
    if ($sourceRecordsById.ContainsKey($id)) {
        $indexed = $sourceRecordsById[$id]
        if ([string]$indexed.manifestSha1 -cne [string]$entry.sha1 -or [string]$indexed.sourceUrl -cne [string]$entry.url) { throw "MOJANG_VERSION_SOURCE_DRIFT:$id" }
        $snapshotPath = Join-Path $snapshotRoot ([string]$indexed.relativePath)
        if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
            $bytes = [IO.File]::ReadAllBytes($snapshotPath)
            $loaded = Save-MmtlMojangVersionSnapshot -Bytes $bytes -VersionEntry $entry -RetrievedAt ([string]$indexed.retrievedAt)
            if ($loaded.localSha256 -cne [string]$indexed.sha256) { throw "MOJANG_VERSION_INDEX_HASH_MISMATCH:$id" }
            $downloaded.Add($id, $loaded)
            continue
        }
    }
    $missingEntries.Add($entry)
}

if ($Offline -and $missingEntries.Count -gt 0) { throw "MOJANG_VERSION_SNAPSHOT_OFFLINE_MISSING:$([string]$missingEntries[0].id)" }
$downloadBatches = @(Get-MmtlMojangMetadataDownloadBatches -Entries $targetEntries -AvailableIds @($downloaded.Keys) -MaxConcurrency $MaxConcurrency)
if ($downloadBatches.Count -ne 0) {
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    if ($ProxyUri) { $handler.UseProxy = $true; $handler.Proxy = [Net.WebProxy]::new($ProxyUri) } else { $handler.UseProxy = $false }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(45)
    $null = $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'MMTL-Runtime-Java-Evidence/1.0')
    try {
        foreach ($batch in $downloadBatches) {
            $requests = foreach ($entry in $batch.entries) {
                $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, [Uri][string]$entry.url)
                [pscustomobject]@{ entry = $entry; request = $request; task = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead) }
            }
            foreach ($item in $requests) {
                $record = $null
                $lastError = $null
                for ($attempt = 0; $attempt -le 2 -and -not $record; $attempt++) {
                    $response = $null
                    try {
                        if ($attempt -eq 0) { $response = $item.task.GetAwaiter().GetResult() }
                        else {
                            Start-Sleep -Milliseconds (250 * $attempt)
                            $response = $client.GetAsync([string]$item.entry.url).GetAwaiter().GetResult()
                        }
                        $responseUri = [Uri]$response.RequestMessage.RequestUri
                        if ($responseUri.Scheme -cne 'https' -or $responseUri.Host -cne 'piston-meta.mojang.com') { throw "MOJANG_VERSION_UNTRUSTED_REDIRECT:$($item.entry.id)" }
                        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) { throw "MOJANG_VERSION_HTTP_$([int]$response.StatusCode):$($item.entry.id)" }
                        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                        $record = Save-MmtlMojangVersionSnapshot -Bytes $bytes -VersionEntry $item.entry -RetrievedAt ([DateTimeOffset]::UtcNow.ToString('o'))
                    } catch { $lastError = $_.Exception.Message }
                    finally { if ($response) { $response.Dispose() } }
                }
                $item.request.Dispose()
                if (-not $record) { throw "MOJANG_VERSION_FETCH_FAILED:$($item.entry.id):$lastError" }
                $id = [string]$item.entry.id
                $downloaded.Add($id, $record)
                $sourceRecordsById[$id] = $record.snapshot
            }
            $retained = @($sourceIndex.sources | Where-Object { [string]$_.providerId -cne 'MojangVersion' })
            $indexedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($source in $existingVersionSources) { $null = $indexedIds.Add([string]$source.minecraftId) }
            $mergedVersionSources = @(@($existingVersionSources | Where-Object { -not $downloaded.ContainsKey([string]$_.minecraftId) }) + @($downloaded.Values | ForEach-Object { $_.snapshot }))
            $sourceIndex.sources = @($retained + $mergedVersionSources)
            Write-MmtlRuntimeJavaSourceIndex -Path $sourceIndexPath -Index $sourceIndex
            Write-Host "Mojang version metadata verified: $($downloaded.Count) / $($targetEntries.Count)"
        }
    } finally { $client.Dispose(); $handler.Dispose() }
}

# Reload the checkpointed index and verify every exact official metadata record before applying requirements.
$sourceIndex = Get-Content -LiteralPath $sourceIndexPath -Raw | ConvertFrom-Json -ErrorAction Stop
$versionSources = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
foreach ($source in @($sourceIndex.sources | Where-Object { [string]$_.providerId -ceq 'MojangVersion' })) {
    if (-not $source.PSObject.Properties['minecraftId'] -or $versionSources.ContainsKey([string]$source.minecraftId)) { throw "MOJANG_VERSION_SOURCE_INDEX_INVALID:$($source.minecraftId)" }
    $versionSources.Add([string]$source.minecraftId, $source)
}

$fallbackHash = (Get-FileHash -LiteralPath $fallbackPath -Algorithm SHA256).Hash.ToLowerInvariant()
$catalogEntries = [Collections.Generic.List[object]]::new()
$requirementsById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$authoritativeCount = 0
$fallbackCount = 0
$unknownCount = 0
foreach ($id in $targetIds) {
    $targetsForId = @($universe.targets | Where-Object { [string]$_.minecraftId -ceq $id })
    $minecraftType = [string]$targetsForId[0].minecraftType
    if ($manifestById.ContainsKey($id)) {
        $entry = $manifestById[$id]
        if (-not $versionSources.ContainsKey($id)) { throw "MOJANG_VERSION_SOURCE_NOT_COLLECTED:$id" }
        $source = $versionSources[$id]
        if ([string]$source.manifestSha1 -cne [string]$entry.sha1 -or [string]$source.sourceUrl -cne [string]$entry.url) { throw "MOJANG_VERSION_SOURCE_STALE:$id" }
        $snapshotPath = Join-Path $snapshotRoot ([string]$source.relativePath)
        $bytes = [IO.File]::ReadAllBytes($snapshotPath)
        $sha1 = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($sha1 -cne [string]$entry.sha1 -or $sha256 -cne [string]$source.sha256) { throw "MOJANG_VERSION_SOURCE_HASH_INVALID:$id" }
        $metadata = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
        if ([string]$metadata.id -cne $id) { throw "MOJANG_VERSION_SOURCE_ID_INVALID:$id" }
        $versionMeta = [pscustomobject]@{
            metadata = $metadata; metadataStatus = 'VERIFIED'
            provenance = [pscustomobject]@{ sourceType = 'official'; url = [string]$entry.url; hash = $sha1; snapshotSha256 = $sha256; fetchedAt = [string]$source.retrievedAt }
        }
        $observationStatus = if ($metadata.PSObject.Properties['javaVersion'] -and $metadata.javaVersion) { 'VERIFIED' } else { 'VERIFIED_NO_JAVA_VERSION' }
        $requirement = Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId $id -CatalogEntry ([pscustomobject]@{ id = $id; metadataStatus = 'VERIFIED' }) -VersionMetadata $versionMeta
        if ($requirement.requirementKind -ceq 'AuthoritativeMetadata') { $authoritativeCount++ }
        elseif ($requirement.requirementKind -ceq 'CompatibilityFallback') {
            $fallbackCount++
            $requirement.provenance | Add-Member -NotePropertyName registrySha256 -NotePropertyValue $fallbackHash -Force
        } else { $unknownCount++ }
        $metadataSource = [pscustomobject]@{ url = [string]$entry.url; manifestSha1 = [string]$entry.sha1; sourceSha1 = $sha1; snapshotSha256 = $sha256; retrievedAt = [string]$source.retrievedAt }
    } else {
        $requirement = Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId $id -CatalogEntry ([pscustomobject]@{ id = $id; metadataStatus = 'NOT_IN_MOJANG_MANIFEST' })
        $observationStatus = 'NOT_IN_MOJANG_MANIFEST'
        $metadataSource = $null
        $unknownCount++
    }
    $requirementsById.Add($id, $requirement)
    foreach ($target in $targetsForId) { $target.runtimeJavaRequirement = $requirement }
    $catalogEntries.Add([pscustomobject][ordered]@{
        minecraftId = $id; minecraftType = $minecraftType; requirement = $requirement
        metadataSource = $metadataSource; observationStatus = $observationStatus
    })
}

$catalog = [pscustomobject][ordered]@{
    schemaVersion = 1; generatedAt = [DateTimeOffset]::UtcNow.ToString('o'); universeHash = [string]$universe.catalogHash
    targetVersionCount = $targetIds.Count; officialMetadataCount = $targetEntries.Count
    authoritativeCount = $authoritativeCount; fallbackCount = $fallbackCount; unknownCount = $unknownCount
    entries = @($catalogEntries)
}
$catalogJson = ConvertTo-Json -InputObject $catalog -Depth 40
if (-not (Test-Json -Json $catalogJson -SchemaFile $catalogSchemaPath)) { throw 'RUNTIME_JAVA_CATALOG_SCHEMA_INVALID' }
Write-MmtlRuntimeJavaJson -Path $catalogPath -Value $catalog -Depth 40
Write-MmtlRuntimeJavaJson -Path $universePath -Value $universe -Depth 60
$ledgerSummary = & (Join-Path $RepositoryRoot 'tools/Generate-FullCompatibilityLedger.ps1') -UniversePath $universePath -FamilyManifestPath (Join-Path $RepositoryRoot 'compatibility/families.json') -OutputPath (Join-Path $RepositoryRoot 'compatibility/ledger-template.json')
[pscustomobject][ordered]@{
    targetVersionCount = $targetIds.Count; officialMetadataCount = $targetEntries.Count
    authoritativeCount = $authoritativeCount; fallbackCount = $fallbackCount; unknownCount = $unknownCount
    candidateUnknownTargetCount = $ledgerSummary.unknownTargetCount
    pendingImplementationDimensionCount = $ledgerSummary.pendingImplementationDimensionCount
    unassignedFamilyCount = $ledgerSummary.unassignedFamilyCount
    runtimeJavaCatalogPath = 'compatibility/runtime-java-catalog.json'
} | ConvertTo-Json -Depth 10
