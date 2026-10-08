Set-StrictMode -Version Latest

function Test-MmtlHistoricalMcpBackendCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)

    $errors = [Collections.Generic.List[string]]::new()
    $schemaPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'schemas/mcp-backend-catalog.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        return [pscustomobject][ordered]@{ isValid = $false; errors = @('MCP_BACKEND_CATALOG_SCHEMA_NOT_FOUND') }
    }
    $json = ConvertTo-Json -InputObject $Catalog -Depth 30 -Compress
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        return [pscustomobject][ordered]@{ isValid = $false; errors = @('MCP_BACKEND_CATALOG_SCHEMA_VALIDATION_FAILED') }
    }

    if ([int]$Catalog.schemaVersion -ne 1) { $errors.Add('MCP_BACKEND_CATALOG_SCHEMA_VERSION_INVALID') }
    if ([string]$Catalog.backendId -cne 'retromcp-java') { $errors.Add('MCP_BACKEND_CATALOG_BACKEND_ID_INVALID') }
    if ([string]$Catalog.universeHash -cnotmatch '^[a-f0-9]{64}$') { $errors.Add('MCP_BACKEND_CATALOG_UNIVERSE_HASH_INVALID') }

    $backendUri = $null
    if (-not [Uri]::TryCreate([string]$Catalog.backendSource.repositoryUrl, [UriKind]::Absolute, [ref]$backendUri) -or $backendUri.Scheme -cne 'https' -or $backendUri.Host -cne 'github.com') {
        $errors.Add('MCP_BACKEND_CATALOG_SOURCE_URL_INVALID')
    }
    if ([string]$Catalog.backendSource.commit -cnotmatch '^[a-f0-9]{40}$') { $errors.Add('MCP_BACKEND_CATALOG_SOURCE_COMMIT_INVALID') }

    $registryUri = $null
    if (-not [Uri]::TryCreate([string]$Catalog.versionRegistry.url, [UriKind]::Absolute, [ref]$registryUri) -or $registryUri.Scheme -cne 'https' -or $registryUri.Host -cne 'mcphackers.org' -or $registryUri.AbsolutePath -cne '/versionsV3/versions.json') {
        $errors.Add('MCP_BACKEND_CATALOG_REGISTRY_URL_INVALID')
    }
    if ([string]$Catalog.versionRegistry.sha256 -cnotmatch '^[a-f0-9]{64}$') { $errors.Add('MCP_BACKEND_CATALOG_REGISTRY_HASH_INVALID') }
    if ([int]$Catalog.versionRegistry.recordCount -le 0) { $errors.Add('MCP_BACKEND_CATALOG_REGISTRY_COUNT_INVALID') }
    try { $null = [DateTimeOffset]::Parse([string]$Catalog.versionRegistry.retrievedAt) }
    catch { $errors.Add('MCP_BACKEND_CATALOG_RETRIEVED_AT_INVALID') }

    if ($Catalog.executionPolicy.automaticDownloadAllowed -ne $false) { $errors.Add('MCP_BACKEND_CATALOG_DOWNLOAD_MUST_REMAIN_DENIED') }
    if ($Catalog.executionPolicy.automaticExecutionAllowed -ne $false) { $errors.Add('MCP_BACKEND_CATALOG_EXECUTION_MUST_REMAIN_DENIED') }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pair in @($Catalog.targetPairs)) {
        $loaderId = [string]$pair.loaderId
        $minecraftId = [string]$pair.minecraftId
        if ($loaderId -cnotin @('ModLoader', 'ModLoaderMP')) { $errors.Add("MCP_BACKEND_CATALOG_LOADER_INVALID:$loaderId"); continue }
        if ([string]::IsNullOrWhiteSpace($minecraftId)) { $errors.Add("MCP_BACKEND_CATALOG_MINECRAFT_ID_EMPTY:$loaderId"); continue }
        $key = "$loaderId@$minecraftId"
        if (-not $seen.Add($key)) { $errors.Add("MCP_BACKEND_CATALOG_DUPLICATE_TARGET:$key") }
        if (@($pair.evidenceRefs).Count -eq 0 -or @($pair.evidenceRefs | Where-Object { [string]$_ -match '^version-registry-id:.+' }).Count -eq 0) {
            $errors.Add("MCP_BACKEND_CATALOG_EVIDENCE_MISSING:$key")
        }
    }

    [pscustomobject][ordered]@{ isValid = ($errors.Count -eq 0); errors = @($errors.ToArray()) }
}

function Resolve-MmtlHistoricalMcpBackend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][ValidateSet('ModLoader', 'ModLoaderMP')][string]$LoaderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MinecraftId
    )

    $validation = Test-MmtlHistoricalMcpBackendCatalog -Catalog $Catalog
    $targetId = "$LoaderId@$MinecraftId"
    if (-not $validation.isValid) {
        return [pscustomobject][ordered]@{
            status = 'InvalidCatalog'; targetId = $targetId; backendId = $null; evidenceRefs = @()
            automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; errors = @($validation.errors)
        }
    }

    $match = @($Catalog.targetPairs | Where-Object { [string]$_.loaderId -ceq $LoaderId -and [string]$_.minecraftId -ceq $MinecraftId } | Select-Object -First 1)
    if (-not $match.Count) {
        return [pscustomobject][ordered]@{
            status = 'NoBackendCandidate'; targetId = $targetId; backendId = $null; evidenceRefs = @()
            automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; errors = @()
        }
    }

    $evidence = @($match[0].evidenceRefs) + @(
        "backend-source-commit:$([string]$Catalog.backendSource.commit)",
        "version-registry-sha256:$([string]$Catalog.versionRegistry.sha256)"
    )
    [pscustomobject][ordered]@{
        status = 'CataloguedOnly'; targetId = $targetId; backendId = [string]$Catalog.backendId
        backendSourceCommit = [string]$Catalog.backendSource.commit
        runtimeJavaMajor = [int]$Catalog.backendSource.runtimeJavaMajor
        evidenceRefs = $evidence
        automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; errors = @()
    }
}

Export-ModuleMember -Function Test-MmtlHistoricalMcpBackendCatalog, Resolve-MmtlHistoricalMcpBackend
