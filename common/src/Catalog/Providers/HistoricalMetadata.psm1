Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\LoaderMetadata.psm1') -Force

$script:MmtlHistoricalMetadataTtl = [TimeSpan]::FromHours(24)

function Get-MmtlHistoricalSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Test-MmtlHistoricalAllowedMetadataUri {
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string[]]$AllowedHosts)
    $parsed = $null
    if (-not [Uri]::TryCreate($Uri,[UriKind]::Absolute,[ref]$parsed)) { return $false }
    return $parsed.Scheme -ceq 'https' -and $parsed.UserInfo.Length -eq 0 -and $parsed.Host.ToLowerInvariant() -cin @($AllowedHosts | ForEach-Object { $_.ToLowerInvariant() })
}

function Get-MmtlHistoricalMetadataCachePath {
    param([Parameter(Mandatory)][string]$ProviderId,[Parameter(Mandatory)][string]$CacheKey,[Parameter(Mandatory)][string]$RuntimeRoot)
    if ($ProviderId -notmatch '^[A-Za-z][A-Za-z0-9-]{1,31}$') { throw 'HISTORICAL_PROVIDER_ID_INVALID' }
    $hash = Get-MmtlHistoricalSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($CacheKey))
    Join-Path (Join-Path (Join-Path $RuntimeRoot 'metadata/historical') $ProviderId.ToLowerInvariant()) "$hash.json"
}

function Read-MmtlHistoricalMetadataCache {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    try {
        $record = [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $bytes = [Convert]::FromBase64String([string]$record.bodyBase64)
        $hash = Get-MmtlHistoricalSha256 -Bytes $bytes
        if ($hash -cne [string]$record.localHash) { throw '缓存正文哈希不匹配。' }
        $record | Add-Member -NotePropertyName bytes -NotePropertyValue $bytes -Force
        $record | Add-Member -NotePropertyName content -NotePropertyValue ([Text.Encoding]::UTF8.GetString($bytes)) -Force
        return $record
    } catch { throw "HISTORICAL_CACHE_CORRUPT: $($_.Exception.Message)" }
}

function Write-MmtlHistoricalMetadataCache {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ProviderId,[Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)]$Headers,[Parameter(Mandatory)][DateTimeOffset]$FetchedAt,[Parameter(Mandatory)][DateTimeOffset]$ValidatedAt)
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $etag = $null
    $lastModified = $null
    if ($Headers -is [Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]$key -ieq 'ETag') { $etag = [string]$Headers[$key] }
            if ([string]$key -ieq 'Last-Modified') { $lastModified = [string]$Headers[$key] }
        }
    }
    $record = [ordered]@{schemaVersion=1;providerId=$ProviderId;sourceUrl=$Uri;fetchedAt=$FetchedAt.ToUniversalTime().ToString('o');validatedAt=$ValidatedAt.ToUniversalTime().ToString('o');localHash=(Get-MmtlHistoricalSha256 -Bytes $Bytes);etag=$etag;lastModified=$lastModified;bodyBase64=[Convert]::ToBase64String($Bytes)}
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary,($record | ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
        if ([IO.File]::Exists($Path)) {
            $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
            try { [IO.File]::Replace($temporary,$Path,$backup,$true) }
            finally { if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) } }
        } else { [IO.File]::Move($temporary,$Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Get-MmtlHistoricalMetadataDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][string]$CacheKey,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string[]]$AllowedHosts,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [switch]$Offline,
        [switch]$ForceRefresh,
        [TimeSpan]$MaxAge = $script:MmtlHistoricalMetadataTtl,
        [ValidateRange(1,3)][int]$MaxAttempts = 3,
        [scriptblock]$HttpGet
    )
    if (-not (Test-MmtlHistoricalAllowedMetadataUri -Uri $Uri -AllowedHosts $AllowedHosts)) {
        return [pscustomobject]@{providerId=$ProviderId;providerStatus='Unavailable';cacheStatus='Unavailable';sourceUrl=$Uri;fetchedAt=$null;validatedAt=$null;localHash=$null;content=$null;error='METADATA_INVALID_URL: 历史元数据必须使用许可清单中的 HTTPS 地址。'}
    }
    $path = Get-MmtlHistoricalMetadataCachePath -ProviderId $ProviderId -CacheKey $CacheKey -RuntimeRoot $RuntimeRoot
    $cached = $null
    $cacheError = $null
    try { $cached = Read-MmtlHistoricalMetadataCache -Path $path } catch { $cacheError = $_.Exception.Message }
    $now = [DateTimeOffset]::UtcNow
    if ($Offline) {
        if (-not $cached) { return [pscustomobject]@{providerId=$ProviderId;providerStatus='Unavailable';cacheStatus='Unavailable';sourceUrl=$Uri;fetchedAt=$null;validatedAt=$null;localHash=$null;content=$null;error=if($cacheError){$cacheError}else{'CACHE_UNAVAILABLE: 没有历史元数据缓存。'}} }
        return [pscustomobject]@{providerId=$ProviderId;providerStatus='Available';cacheStatus='OfflineCache';sourceUrl=[string]$cached.sourceUrl;fetchedAt=[string]$cached.fetchedAt;validatedAt=[string]$cached.validatedAt;localHash=[string]$cached.localHash;content=[string]$cached.content;error=$null}
    }
    if ($cached -and -not $ForceRefresh -and ($now - [DateTimeOffset]::Parse([string]$cached.validatedAt)) -le $MaxAge) {
        return [pscustomobject]@{providerId=$ProviderId;providerStatus='Available';cacheStatus='Fresh';sourceUrl=[string]$cached.sourceUrl;fetchedAt=[string]$cached.fetchedAt;validatedAt=[string]$cached.validatedAt;localHash=[string]$cached.localHash;content=[string]$cached.content;error=$null}
    }
    $headers = @{}
    if ($cached) { if ($cached.etag) {$headers['If-None-Match']=[string]$cached.etag};if($cached.lastModified){$headers['If-Modified-Since']=[string]$cached.lastModified} }
    $lastError = $null
    for ($attempt=1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-MmtlMetadataHttpGet -Uri $Uri -AllowedHosts $AllowedHosts -Headers $headers -HttpGet $HttpGet
            if ([int]$response.StatusCode -eq 304) {
                if (-not $cached) { throw 'METADATA_INVALID_RESPONSE: 没有缓存时收到 HTTP 304。' }
                $bytes = [byte[]]$cached.bytes
                $fetchedAt = [DateTimeOffset]::Parse([string]$cached.fetchedAt)
                $mergedHeaders=@{};if($cached.etag){$mergedHeaders.ETag=[string]$cached.etag};if($cached.lastModified){$mergedHeaders.'Last-Modified'=[string]$cached.lastModified};if($response.Headers -is [Collections.IDictionary]){foreach($key in $response.Headers.Keys){$mergedHeaders[[string]$key]=$response.Headers[$key]}};$response.Headers=$mergedHeaders
            } elseif ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) {
                $bytes = [byte[]]$response.Bytes
                $fetchedAt = $now
            } else { throw "METADATA_NETWORK_ERROR: HTTP $($response.StatusCode)." }
            Write-MmtlHistoricalMetadataCache -Path $path -ProviderId $ProviderId -Uri $response.ResponseUri -Bytes $bytes -Headers $response.Headers -FetchedAt $fetchedAt -ValidatedAt $now
            $saved = Read-MmtlHistoricalMetadataCache -Path $path
            return [pscustomobject]@{providerId=$ProviderId;providerStatus='Available';cacheStatus='Fresh';sourceUrl=[string]$saved.sourceUrl;fetchedAt=[string]$saved.fetchedAt;validatedAt=[string]$saved.validatedAt;localHash=[string]$saved.localHash;content=[string]$saved.content;error=$null}
        } catch {
            $lastError = $_.Exception.Message
            if ($lastError -match 'METADATA_(INVALID_URL|UNTRUSTED_REDIRECT|REDIRECT_INVALID|REDIRECT_LIMIT)') { break }
        }
    }
    if ($cached) { return [pscustomobject]@{providerId=$ProviderId;providerStatus='Stale';cacheStatus='Stale';sourceUrl=[string]$cached.sourceUrl;fetchedAt=[string]$cached.fetchedAt;validatedAt=[string]$cached.validatedAt;localHash=[string]$cached.localHash;content=[string]$cached.content;error=$lastError} }
    [pscustomobject]@{providerId=$ProviderId;providerStatus='Unavailable';cacheStatus='Unavailable';sourceUrl=$Uri;fetchedAt=$null;validatedAt=$null;localHash=$null;content=$null;error=if($cacheError){"$cacheError; $lastError"}else{$lastError}}
}

Export-ModuleMember -Function Get-MmtlHistoricalMetadataDocument,Get-MmtlHistoricalMetadataCachePath
