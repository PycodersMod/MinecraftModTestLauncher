Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../Validation/TargetIdentity.psm1') -Force

function ConvertTo-MmtlCompatibilityCacheIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Identity)

    $targetId = [string]$Identity.targetId
    if (-not(Test-MmtlExactTargetId -TargetId $targetId)) { throw 'CACHE_IDENTITY_INVALID:targetId' }
    $normalized = [ordered]@{ targetId = $targetId }
    foreach ($name in @('universeHash', 'sourceHash', 'toolchainHash', 'targetSpecHash')) {
        $value = [string]$Identity.$name
        if ($value -notmatch '^(?i:[a-f0-9]{64})$') { throw "CACHE_IDENTITY_INVALID:$name" }
        $normalized[$name] = $value.ToLowerInvariant()
    }
    $agentHash = if ($Identity.PSObject.Properties['agentHash']) { [string]$Identity.agentHash } else { '' }
    if ($agentHash -and $agentHash -notmatch '^(?i:[a-f0-9]{64})$') { throw 'CACHE_IDENTITY_INVALID:agentHash' }
    $normalized.agentHash = if ($agentHash) { $agentHash.ToLowerInvariant() } else { $null }
    [pscustomobject]$normalized
}

function Get-MmtlCompatibilityEvidenceCacheKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Identity)
    $normalized = ConvertTo-MmtlCompatibilityCacheIdentity -Identity $Identity
    $payload = ConvertTo-Json -InputObject $normalized -Depth 5 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload))).ToLowerInvariant()
}

function Test-MmtlEvidenceStorePath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path, [switch]$MustExist)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $comparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, $comparison)) { throw 'EVIDENCE_STORE_PATH_OUTSIDE_RUNTIME_ROOT' }
    if (Test-Path -LiteralPath $fullRoot) {
        $rootAttributes = [IO.File]::GetAttributes($fullRoot)
        if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'EVIDENCE_STORE_REPARSE_RUNTIME_ROOT' }
    } elseif ($MustExist) { throw 'EVIDENCE_STORE_RUNTIME_ROOT_NOT_FOUND' }
    $current = $fullPath
    while ($current.StartsWith($prefix, $comparison)) {
        if (Test-Path -LiteralPath $current) {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'EVIDENCE_STORE_REPARSE_PATH' }
        } elseif ($MustExist) { throw 'EVIDENCE_STORE_PATH_NOT_FOUND' }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -ceq $current) { break }
        $current = $parent
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'EVIDENCE_STORE_FILE_NOT_FOUND' }
    $fullPath
}

function Test-MmtlCompatibilityCacheEvidence {
    param([Parameter(Mandatory)][object]$Evidence, [Parameter(Mandatory)][object]$Identity)
    $schemaPath = Join-Path $PSScriptRoot '../../schemas/validation-evidence.schema.json'
    $json = ConvertTo-Json -InputObject $Evidence -Depth 40
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'CACHE_EVIDENCE_INVALID:SCHEMA' }
    if ([string]$Evidence.targetId -cne [string]$Identity.targetId) { throw 'CACHE_EVIDENCE_INVALID:TARGET_MISMATCH' }
    if (-not $Evidence.PSObject.Properties['compatibilityIdentity']) { throw 'CACHE_EVIDENCE_INVALID:IDENTITY_MISSING' }
    $evidenceIdentity = ConvertTo-MmtlCompatibilityCacheIdentity -Identity $Evidence.compatibilityIdentity
    if ((ConvertTo-Json -InputObject $evidenceIdentity -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject $Identity -Depth 5 -Compress)) { throw 'CACHE_EVIDENCE_INVALID:IDENTITY_MISMATCH' }
    if ([string]$Evidence.result -cne 'PASSED' -or [string]$Evidence.failureCode -cne 'NONE') { throw 'CACHE_EVIDENCE_INVALID:NOT_SUCCESSFUL' }
    if ([string]$Evidence.validationLevel -notin @('BUILD_VERIFIED', 'SERVER_VERIFIED', 'CLIENT_LAUNCH_VERIFIED', 'INTEGRATION_VERIFIED')) {
        throw 'CACHE_EVIDENCE_INVALID:INSUFFICIENT_VALIDATION_LEVEL'
    }
    if (-not $Evidence.PSObject.Properties['source'] -or -not [bool]$Evidence.source.unchangedDuringBuild -or -not [bool]$Evidence.source.artifactFresh) {
        throw 'CACHE_EVIDENCE_INVALID:SOURCE_OR_ARTIFACT_NOT_FRESH'
    }
    if (-not $Evidence.artifact -or [string]$Evidence.artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$') {
        throw 'CACHE_EVIDENCE_INVALID:ARTIFACT_HASH_MISSING'
    }
    if ([string]$Evidence.sourceFixture.trust -notin @('TrustedOfficial', 'VerifiedHistorical')) {
        throw 'CACHE_EVIDENCE_INVALID:FIXTURE_UNTRUSTED'
    }
    $sourceUri = $null
    if (-not [Uri]::TryCreate([string]$Evidence.sourceFixture.source, [UriKind]::Absolute, [ref]$sourceUri) -or $sourceUri.Scheme -cne 'https' -or $sourceUri.UserInfo.Length -gt 0) {
        throw 'CACHE_EVIDENCE_INVALID:FIXTURE_SOURCE_UNTRUSTED'
    }
}

function Get-MmtlCompatibilityEvidenceCacheEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][object]$Identity)

    $normalized = ConvertTo-MmtlCompatibilityCacheIdentity -Identity $Identity
    $cacheKey = Get-MmtlCompatibilityEvidenceCacheKey -Identity $normalized
    $root = [IO.Path]::GetFullPath($RuntimeRoot)
    $entryPath = Join-Path (Join-Path $root 'compatibility-cache') ($cacheKey + '.json')
    if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) { return [pscustomobject]@{ status='MISS'; reason='CACHE_NOT_FOUND'; evidence=$null; cacheKey=$cacheKey } }
    try {
        $entryPath = Test-MmtlEvidenceStorePath -Root $root -Path $entryPath -MustExist
        $entryJson = [IO.File]::ReadAllText($entryPath)
        $entry = ConvertFrom-Json -InputObject $entryJson -ErrorAction Stop
        $entrySchema = Join-Path $PSScriptRoot '../../schemas/compatibility-evidence-cache-entry.schema.json'
        if (-not (Test-Json -Json $entryJson -SchemaFile $entrySchema -ErrorAction SilentlyContinue)) { throw 'CACHE_ENTRY_SCHEMA_INVALID' }
        if ([string]$entry.cacheKey -cne $cacheKey -or (ConvertTo-Json -InputObject $entry.identity -Depth 5 -Compress) -cne (ConvertTo-Json -InputObject $normalized -Depth 5 -Compress)) { throw 'CACHE_ENTRY_IDENTITY_MISMATCH' }
        $evidencePath = [IO.Path]::GetFullPath((Join-Path $root ([string]$entry.evidenceRelativePath)))
        $evidencePath = Test-MmtlEvidenceStorePath -Root $root -Path $evidencePath -MustExist
        $evidenceBytes = [IO.File]::ReadAllBytes($evidencePath)
        $evidenceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($evidenceBytes)).ToLowerInvariant()
        if ($evidenceHash -cne [string]$entry.evidenceSha256) { throw 'CACHED_EVIDENCE_HASH_MISMATCH' }
        $evidenceJson = [Text.Encoding]::UTF8.GetString($evidenceBytes)
        $evidence = ConvertFrom-Json -InputObject $evidenceJson -ErrorAction Stop
        Test-MmtlCompatibilityCacheEvidence -Evidence $evidence -Identity $normalized
        return [pscustomobject]@{ status='HIT'; reason='EXACT_CACHE_IDENTITY_MATCH'; evidence=$evidence; evidencePath=$evidencePath; cacheKey=$cacheKey }
    } catch {
        return [pscustomobject]@{ status='STALE'; reason=[string]$_.Exception.Message; evidence=$null; cacheKey=$cacheKey }
    }
}

function Add-MmtlCompatibilityEvidenceCacheEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][object]$Identity, [Parameter(Mandatory)][string]$EvidencePath)

    $normalized = ConvertTo-MmtlCompatibilityCacheIdentity -Identity $Identity
    $root = [IO.Path]::GetFullPath($RuntimeRoot)
    [void][IO.Directory]::CreateDirectory($root)
    $fullEvidencePath = Test-MmtlEvidenceStorePath -Root $root -Path $EvidencePath -MustExist
    $evidenceJson = [IO.File]::ReadAllText($fullEvidencePath)
    $evidence = ConvertFrom-Json -InputObject $evidenceJson -ErrorAction Stop
    Test-MmtlCompatibilityCacheEvidence -Evidence $evidence -Identity $normalized

    $cacheKey = Get-MmtlCompatibilityEvidenceCacheKey -Identity $normalized
    $cacheDirectory = Join-Path $root 'compatibility-cache'
    [void][IO.Directory]::CreateDirectory($cacheDirectory)
    $entryPath = Join-Path $cacheDirectory ($cacheKey + '.json')
    if (Test-Path -LiteralPath $entryPath) { throw 'CACHE_ENTRY_EXISTS:refusing to overwrite an immutable cache index' }
    $relativeEvidencePath = [IO.Path]::GetRelativePath($root, $fullEvidencePath).Replace([string][IO.Path]::DirectorySeparatorChar, '/')
    $evidenceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($fullEvidencePath))).ToLowerInvariant()
    $entry = [pscustomobject][ordered]@{
        schemaVersion=1;cacheKey=$cacheKey;identity=$normalized;evidenceRelativePath=$relativeEvidencePath;evidenceSha256=$evidenceHash
    }
    $json = ConvertTo-Json -InputObject $entry -Depth 10
    $schemaPath = Join-Path $PSScriptRoot '../../schemas/compatibility-evidence-cache-entry.schema.json'
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'CACHE_ENTRY_INVALID:SCHEMA' }
    $temporaryPath = Join-Path $cacheDirectory ('.cache-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $entryPath)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
    [pscustomobject]@{ status='STORED'; cacheKey=$cacheKey; entryPath=$entryPath; evidenceSha256=$evidenceHash }
}

Export-ModuleMember -Function ConvertTo-MmtlCompatibilityCacheIdentity,Get-MmtlCompatibilityEvidenceCacheKey,Get-MmtlCompatibilityEvidenceCacheEntry,Add-MmtlCompatibilityEvidenceCacheEntry
