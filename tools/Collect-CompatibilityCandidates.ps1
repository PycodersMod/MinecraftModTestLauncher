[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Fabric', 'Quilt', 'LegacyFabric', 'OrnitheLoader')][string]$LoaderId,
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$ProxyUri
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$universePath = Join-Path $RepositoryRoot 'compatibility/universe-preview.json'
$sourceIndexPath = Join-Path $RepositoryRoot 'compatibility/source-snapshots.json'
$snapshotRoot = Join-Path $RepositoryRoot 'compatibility/snapshots'
$resultRoot = Join-Path $RepositoryRoot "compatibility/candidate-results/$LoaderId"
$catalogRoot = Join-Path $RepositoryRoot 'compatibility/candidate-catalogs'

if ($ProxyUri) {
    $proxy = $null
    $proxyIp = $null
    if (-not [Uri]::TryCreate($ProxyUri, [UriKind]::Absolute, [ref]$proxy) -or $proxy.Scheme -cne 'http' -or -not [Net.IPAddress]::TryParse($proxy.Host, [ref]$proxyIp) -or -not [Net.IPAddress]::IsLoopback($proxyIp)) {
        throw 'PROXY_INVALID: 仅接受 HTTP loopback IP 代理。'
    }
}

Import-Module (Join-Path $RepositoryRoot 'common/src/Compatibility/SourceSnapshot.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Compatibility/CompatibilityCandidateCatalog.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/Fabric.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/Quilt.psm1') -Force
Import-Module (Join-Path $RepositoryRoot 'common/src/Catalog/Providers/HistoricalProviders.psm1') -Force

function Write-MmtlAtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 40)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth $Depth), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Move($temporary, $Path, $true) } else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-MmtlCandidateResultPath {
    param([Parameter(Mandatory)][string]$TargetId)
    $bytes = [Text.Encoding]::UTF8.GetBytes($TargetId)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    Join-Path $resultRoot "$hash.json"
}

$universe = Get-Content -LiteralPath $universePath -Raw | ConvertFrom-Json -ErrorAction Stop
$sources = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'compatibility/sources.json') -Raw | ConvertFrom-Json -ErrorAction Stop
$sourceDefinition = $sources.loaders | Where-Object { [string]$_.loaderId -ceq $LoaderId } | Select-Object -First 1
if (-not $sourceDefinition) { throw "SOURCE_DEFINITION_MISSING: $LoaderId" }
$targets = @($universe.targets | Where-Object { [string]$_.loaderId -ceq $LoaderId } | Sort-Object { [string]$_.targetId })
if (-not $targets.Count) { throw "UNIVERSE_TARGETS_MISSING: $LoaderId" }
[IO.Directory]::CreateDirectory($resultRoot) | Out-Null

$temporaryRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) "mmtl-candidate-$($LoaderId.ToLowerInvariant())-$([guid]::NewGuid().ToString('N'))"))
$runtimeRoot = Join-Path $temporaryRoot 'runtime'
[IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null
$responseCapture = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$httpGet = {
    param([string]$Uri, [hashtable]$Headers, [int]$TimeoutSeconds)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    if ($ProxyUri) { $handler.UseProxy = $true; $handler.Proxy = [Net.WebProxy]::new($ProxyUri) } else { $handler.UseProxy = $false }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, [Uri]$Uri)
    $null = $request.Headers.TryAddWithoutValidation('User-Agent', 'MMTL-Compatibility-Candidate-Collector/1.0')
    foreach ($key in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation([string]$key, [string]$Headers[$key]) }
    try {
        $response = $client.Send($request)
        try {
            $bytes = [byte[]]$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $capturedHeaders = @{}
            foreach ($header in $response.Headers) { $capturedHeaders[[string]$header.Key] = [string]::Join(',', [string[]]$header.Value) }
            foreach ($header in $response.Content.Headers) { $capturedHeaders[[string]$header.Key] = [string]::Join(',', [string[]]$header.Value) }
            $record = [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Headers = $capturedHeaders; Bytes = $bytes; ResponseUri = $Uri }
            $responseCapture[$Uri] = $record
            $record
        } finally { $response.Dispose() }
    } finally { $request.Dispose(); $client.Dispose(); $handler.Dispose() }
}.GetNewClosure()

try {
    $total = $targets.Count
    $consecutiveUnknown = 0
    for ($i = 0; $i -lt $total; $i++) {
        $target = $targets[$i]
        $targetId = [string]$target.targetId
        $resultPath = Get-MmtlCandidateResultPath -TargetId $targetId
        if (Test-Path -LiteralPath $resultPath) {
            $previous = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($previous.candidateStatus -in @('Resolved', 'NoCandidatesReturned')) {
                $changed = $false
                if ($previous.PSObject.Properties['candidates']) { $previous.PSObject.Properties.Remove('candidates'); $changed = $true }
                if (-not $previous.PSObject.Properties['candidateCount']) { $previous | Add-Member -NotePropertyName candidateCount -NotePropertyValue @($previous.loaderVersions).Count; $changed = $true }
                if ($changed) {
                    Write-MmtlAtomicJson -Path $resultPath -Value $previous -Depth 20
                }
                continue
            }
        }

        $minecraftId = [string]$target.minecraftId
        $responseCapture.Clear()
        $providerResult = $null
        try {
            $providerResult = switch ($LoaderId) {
                'Fabric' { Get-MmtlFabricCandidateSet -MinecraftId $minecraftId -RuntimeRoot $runtimeRoot -ForceRefresh -HttpGet $httpGet }
                'Quilt' { Get-MmtlQuiltCandidateSet -MinecraftId $minecraftId -RuntimeRoot $runtimeRoot -ForceRefresh -HttpGet $httpGet }
                'LegacyFabric' { Get-MmtlLegacyFabricCandidateQuery -MinecraftId $minecraftId -RuntimeRoot $runtimeRoot -ForceRefresh -HttpGet $httpGet }
                'OrnitheLoader' { Get-MmtlOrnitheCandidateQuery -MinecraftId $minecraftId -RuntimeRoot $runtimeRoot -ForceRefresh -HttpGet $httpGet }
            }
            $requested = @($responseCapture.Values | Select-Object -Last 1)[0]
            $responseHash = $null
            $sourceUrl = [string]$providerResult.sourceUrl
            if ($requested -and $requested.StatusCode -ge 200 -and $requested.StatusCode -lt 300) {
                $sourceUrl = [string]$requested.ResponseUri
                $responseHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$requested.Bytes)).ToLowerInvariant()
                $record = Save-MmtlCompatibilitySourceSnapshot -ProviderId "$LoaderId`Candidates" -SourceUrl $sourceUrl -Bytes ([byte[]]$requested.Bytes) -OutputDirectory $snapshotRoot -RetrievedAt ([DateTimeOffset]::UtcNow) -SourceClass ([string]$sourceDefinition.sourceClass) -TrustClass ([string]$sourceDefinition.trustClass)
                if ($record.sha256 -cne $responseHash) { throw 'CANDIDATE_RESPONSE_HASH_MISMATCH' }
            }
            if ($sourceUrl) { $providerResult | Add-Member -NotePropertyName sourceUrl -NotePropertyValue $sourceUrl -Force }
            if ($responseHash) { $providerResult | Add-Member -NotePropertyName localHash -NotePropertyValue $responseHash -Force }
            $result = New-MmtlCompatibilityCandidateResult -LoaderId $LoaderId -MinecraftId $minecraftId -ProviderResult $providerResult
            $consecutiveUnknown = if ($result.candidateStatus -eq 'Unknown') { $consecutiveUnknown + 1 } else { 0 }
        } catch {
            $result = [pscustomobject][ordered]@{
                targetId = $targetId; loaderId = $LoaderId; minecraftId = $minecraftId
                providerStatus = 'Unavailable'; candidateStatus = 'Unknown'; loaderVersions = @()
                sourceUrl = $null; sourceHash = $null; cacheStatus = 'Unavailable'; error = $_.Exception.Message
            }
            $consecutiveUnknown++
        }

        $record = [pscustomobject][ordered]@{
            schemaVersion = 1; capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
            targetId = $result.targetId; loaderId = $result.loaderId; minecraftId = $result.minecraftId
            providerStatus = $result.providerStatus; candidateStatus = $result.candidateStatus
            loaderVersions = @($result.loaderVersions); candidateCount = @($result.loaderVersions).Count
            sourceUrl = $result.sourceUrl; sourceHash = $result.sourceHash
            sourceClass = [string]$sourceDefinition.sourceClass; trustClass = [string]$sourceDefinition.trustClass
            transportSecurity = if ($result.sourceUrl) { 'HTTPS' } else { 'Unknown' }
            cacheStatus = $result.cacheStatus; error = $result.error
        }
        Write-MmtlAtomicJson -Path $resultPath -Value $record -Depth 40
        Write-Progress -Activity "采集 $LoaderId 精确 Loader 候选" -Status "$($i + 1)/$total $minecraftId ($($result.candidateStatus))" -PercentComplete ([int](100 * ($i + 1) / $total))
        if ($consecutiveUnknown -ge 5) { break }
    }
    Write-Progress -Activity "采集 $LoaderId 精确 Loader 候选" -Completed

    $records = [Collections.Generic.List[object]]::new()
    foreach ($target in $targets) {
        $path = Get-MmtlCandidateResultPath -TargetId ([string]$target.targetId)
        if (Test-Path -LiteralPath $path) { $records.Add((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop)) }
    }
    $publicResults = @($records | Sort-Object { [string]$_.targetId } | ForEach-Object {
        [ordered]@{
            targetId = [string]$_.targetId; minecraftId = [string]$_.minecraftId
            candidateStatus = [string]$_.candidateStatus; candidateCount = [int]$_.candidateCount
            loaderVersions = @($_.loaderVersions); sourceUrl = $_.sourceUrl; sourceHash = $_.sourceHash
            sourceClass = [string]$_.sourceClass; trustClass = [string]$_.trustClass
            transportSecurity = [string]$_.transportSecurity; error = [string]$_.error
        }
    })
    $catalog = [pscustomobject][ordered]@{
        schemaVersion = 1; loaderId = $LoaderId; sourceUrl = [string]$sourceDefinition.sourceUrl
        sourceClass = [string]$sourceDefinition.sourceClass; trustClass = [string]$sourceDefinition.trustClass
        universeGeneratedAt = [string]$universe.generatedAt; universeCatalogHash = [string]$universe.catalogHash
        targetCount = $targets.Count; resultCount = $records.Count; results = $publicResults
    }
    $catalogPath = Join-Path $catalogRoot "$LoaderId.json"
    Write-MmtlAtomicJson -Path $catalogPath -Value $catalog -Depth 50

    $index = Get-Content -LiteralPath $sourceIndexPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $snapshotEntries = [Collections.Generic.List[object]]::new()
    foreach ($item in @($index.sources | Where-Object { [string]$_.providerId -notlike '*Candidates' })) { $snapshotEntries.Add($item) }
    $candidateEvidencePath = Join-Path $RepositoryRoot 'compatibility/candidate-evidence.local.json'
    $candidateEvidence = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $candidateEvidencePath) {
        $existingLocalEvidence = Get-Content -LiteralPath $candidateEvidencePath -Raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($item in @($existingLocalEvidence.sources | Where-Object { [string]$_.providerId -cne "$($LoaderId)Candidates" })) { $candidateEvidence.Add($item) }
    }
    foreach ($item in $records) {
        if ($item.sourceHash -notmatch '^[a-f0-9]{64}$' -or -not $item.sourceUrl) { continue }
        $snapshotPath = Join-Path $snapshotRoot "$($LoaderId)Candidates/$($item.sourceHash).bin"
        if (-not (Test-Path -LiteralPath $snapshotPath)) { continue }
        $key = "$($LoaderId)Candidates|$($item.sourceUrl)|$($item.sourceHash)"
        if (@($candidateEvidence | Where-Object { "$($_.providerId)|$($_.sourceUrl)|$($_.sha256)" -ceq $key }).Count) { continue }
        $candidateEvidence.Add([pscustomobject][ordered]@{
            providerId = "$($LoaderId)Candidates"; sourceUrl = [string]$item.sourceUrl
            sourceClass = [string]$item.sourceClass; trustClass = [string]$item.trustClass; transportSecurity = 'HTTPS'
            retrievedAt = [string]$item.capturedAt; relativePath = "$($LoaderId)Candidates/$($item.sourceHash).bin"
            byteLength = (Get-Item -LiteralPath $snapshotPath).Length; sha256 = [string]$item.sourceHash
        })
    }
    $index.sources = @($snapshotEntries | Sort-Object providerId, sourceUrl, sha256)
    $index.sourceCount = $index.sources.Count
    $index.auditStatus = 'IN_PROGRESS'
    Write-MmtlAtomicJson -Path $sourceIndexPath -Value $index -Depth 40
    $localCandidateEvidence = [pscustomobject][ordered]@{ schemaVersion = 1; loaderId = $LoaderId; sourceCount = $candidateEvidence.Count; sources = @($candidateEvidence | Sort-Object providerId, sourceUrl, sha256) }
    Write-MmtlAtomicJson -Path $candidateEvidencePath -Value $localCandidateEvidence -Depth 20

    foreach ($target in $universe.targets | Where-Object { [string]$_.loaderId -ceq $LoaderId }) {
        $recordPath = Get-MmtlCandidateResultPath -TargetId ([string]$target.targetId)
        if (-not (Test-Path -LiteralPath $recordPath)) { continue }
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $target.candidateStatus = [string]$record.candidateStatus
        if ($record.candidateStatus -eq 'Resolved') { $target.loaderVersionCandidates = @($record.loaderVersions) }
        elseif ($record.candidateStatus -eq 'NoCandidatesReturned') { $target.loaderVersionCandidates = @() }
        $target.candidateSourceUrl = $record.sourceUrl
        $target.candidateSourceHash = $record.sourceHash
    }
    $universe.issues = @($universe.issues | Where-Object { -not ([string]$_.loaderId -ceq $LoaderId -and [string]$_.reason -like 'LOADER_CANDIDATE_*') })
    foreach ($record in $records) {
        if ($record.candidateStatus -eq 'Unknown' -or $record.candidateStatus -eq 'Stale') {
            $universe.issues += [pscustomobject]@{ loaderId = $LoaderId; status = 'Unknown'; reason = 'LOADER_CANDIDATE_QUERY_UNRESOLVED'; sourceUrl = $record.sourceUrl; evidence = "$($record.minecraftId): $($record.error)" }
        } elseif ($record.candidateStatus -eq 'NoCandidatesReturned') {
            $universe.issues += [pscustomobject]@{ loaderId = $LoaderId; status = 'Unknown'; reason = 'LOADER_CANDIDATE_LIST_EMPTY'; sourceUrl = $record.sourceUrl; evidence = [string]$record.minecraftId }
        }
    }
    $universe.issues = @($universe.issues | Sort-Object { [string]$_.loaderId }, { [string]$_.reason }, { [string]$_.evidence })
    $candidateMaterial = @($universe.targets | Sort-Object { [string]$_.targetId } | ForEach-Object {
        [ordered]@{ targetId = [string]$_.targetId; candidateStatus = [string]$_.candidateStatus; loaderVersionCandidates = @($_.loaderVersionCandidates); candidateSourceUrl = $_.candidateSourceUrl; candidateSourceHash = $_.candidateSourceHash }
    })
    $candidateJson = ConvertTo-Json -InputObject $candidateMaterial -Depth 20 -Compress
    $universe.candidateCatalogHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($candidateJson))).ToLowerInvariant()
    Write-MmtlAtomicJson -Path $universePath -Value $universe -Depth 50

    [pscustomobject][ordered]@{
        loaderId = $LoaderId; targets = $targets.Count; results = $records.Count
        resolved = @($records | Where-Object candidateStatus -eq 'Resolved').Count
        empty = @($records | Where-Object candidateStatus -eq 'NoCandidatesReturned').Count
        stale = @($records | Where-Object candidateStatus -eq 'Stale').Count
        unknown = @($records | Where-Object candidateStatus -eq 'Unknown').Count
        sourceSnapshots = $candidateEvidence.Count; catalogPath = "compatibility/candidate-catalogs/$LoaderId.json"
        candidateCatalogHash = $universe.candidateCatalogHash
    } | ConvertTo-Json -Depth 10
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    if ($resolvedTemporaryRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTemporaryRoot) -match '^mmtl-candidate-[a-z]+-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
