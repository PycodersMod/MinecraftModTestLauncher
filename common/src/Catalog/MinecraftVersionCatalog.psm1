Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'LoaderMetadata.psm1') -Force

$script:MmtlMojangManifestUrl='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
$script:MmtlMojangMetadataHosts=@('piston-meta.mojang.com')
$script:MmtlCatalogSchemaVersion=1
$script:MmtlCatalogDefaultTtl=[TimeSpan]::FromHours(24)

function Get-MmtlSha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-MmtlOptionalProperty {
    param($InputObject,[Parameter(Mandatory)][string]$Name)
    if($null -eq $InputObject){return $null}
    if($InputObject -is [Collections.IDictionary]){foreach($key in $InputObject.Keys){if([string]$key -ieq $Name){return $InputObject[$key]}};return $null}
    $property=$InputObject.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $null
}

function Write-MmtlAtomicBytes {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][byte[]]$Bytes)
    $directory=Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $temporary="$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary,$Bytes)
        if([IO.File]::Exists($Path)){[IO.File]::Move($temporary,$Path,$true)}else{[IO.File]::Move($temporary,$Path)}
    } finally { if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)} }
}

function Test-MmtlMojangMetadataUri {
    param([Parameter(Mandatory)][string]$Uri)
    $parsed=$null
    if(-not [Uri]::TryCreate($Uri,[UriKind]::Absolute,[ref]$parsed)){return $false}
    return $parsed.Scheme -eq 'https' -and $parsed.Host.ToLowerInvariant() -in $script:MmtlMojangMetadataHosts
}

function ConvertTo-MmtlMinecraftVersionCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest,[DateTimeOffset]$FetchedAt=[DateTimeOffset]::UtcNow,[string]$ManifestHash)
    $latestNode=Get-MmtlOptionalProperty -InputObject $Manifest -Name 'latest'
    $latestRelease=Get-MmtlOptionalProperty -InputObject $latestNode -Name 'release'
    $versionsNode=Get-MmtlOptionalProperty -InputObject $Manifest -Name 'versions'
    if($null -eq $latestNode -or [string]::IsNullOrWhiteSpace([string]$latestRelease) -or $null -eq $versionsNode){throw 'MANIFEST_SCHEMA_ERROR: latest.release 或 versions 缺失。'}
    $all=@($versionsNode)
    if($all.Count -eq 0){throw 'MANIFEST_SCHEMA_ERROR: versions 为空。'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $validated=[Collections.Generic.List[object]]::new()
    foreach($entry in $all){
        $entryId=Get-MmtlOptionalProperty -InputObject $entry -Name 'id'
        $entryType=Get-MmtlOptionalProperty -InputObject $entry -Name 'type'
        $entryUrl=Get-MmtlOptionalProperty -InputObject $entry -Name 'url'
        $entryTime=Get-MmtlOptionalProperty -InputObject $entry -Name 'time'
        $entryReleaseTime=Get-MmtlOptionalProperty -InputObject $entry -Name 'releaseTime'
        if([string]::IsNullOrWhiteSpace([string]$entryId) -or -not $seen.Add([string]$entryId)){throw 'MANIFEST_SCHEMA_ERROR: 规范 ID 为空或重复。'}
        if([string]::IsNullOrWhiteSpace([string]$entryType) -or -not (Test-MmtlMojangMetadataUri ([string]$entryUrl))){throw "MANIFEST_SCHEMA_ERROR: $entryId 的元数据 URL 无效或不受信任。"}
        $entrySha1=Get-MmtlOptionalProperty -InputObject $entry -Name 'sha1'
        if($entrySha1 -and [string]$entrySha1 -notmatch '^(?i:[0-9a-f]{40})$'){throw "MANIFEST_SCHEMA_ERROR: malformed SHA-1 for $entryId."}
        if([string]::IsNullOrWhiteSpace([string]$entryTime) -or [string]::IsNullOrWhiteSpace([string]$entryReleaseTime)){throw "MANIFEST_SCHEMA_ERROR: $entryId 缺少必需时间戳。"}
        try{$time=[DateTimeOffset]::Parse([string]$entryTime,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal);$releaseTime=[DateTimeOffset]::Parse([string]$entryReleaseTime,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)}catch{throw "MANIFEST_SCHEMA_ERROR: $entryId 的时间戳无效。"}
        $validated.Add([pscustomobject]@{id=[string]$entryId;type=[string]$entryType;url=[string]$entryUrl;time=$time;releaseTime=$releaseTime;sha1=if($entrySha1){([string]$entrySha1).ToLowerInvariant()}else{$null};complianceLevel=(Get-MmtlOptionalProperty -InputObject $entry -Name 'complianceLevel');original=$entry})
    }
    $anchor=$validated|Where-Object{$_.id -ceq '1.0' -and $_.type -ceq 'release'}|Select-Object -First 1
    if(-not $anchor){throw 'MINIMUM_RELEASE_NOT_FOUND: CATALOG_MINIMUM_RELEASE_ANCHOR_NOT_FOUND (1.0).'}
    $latest=$validated|Where-Object{$_.id -ceq [string]$Manifest.latest.release -and $_.type -ceq 'release'}|Select-Object -First 1
    if(-not $latest){throw "MANIFEST_SCHEMA_ERROR: latest.release '$($Manifest.latest.release)' 不是正式版本条目。"}
    if($latest.releaseTime -lt $anchor.releaseTime){throw 'MANIFEST_SCHEMA_ERROR: latest.release 早于 1.0 锚点。'}
    $entries=@($validated|Where-Object{$_.type -ceq 'release' -and $_.releaseTime -ge $anchor.releaseTime -and $_.releaseTime -le $latest.releaseTime}|ForEach-Object{
        [pscustomobject]@{
            id=$_.id;type=$_.type;time=$_.time.ToString('o');releaseTime=$_.releaseTime.ToString('o');metadataUrl=$_.url;metadataSha1=$_.sha1;complianceLevel=$_.complianceLevel
            catalogStatus='CATALOGUED';metadataStatus='NOT_FETCHED';runtimeJava=[pscustomobject]@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown'}
            provenance=@([pscustomobject]@{sourceType='official';url=$script:MmtlMojangManifestUrl;fetchedAt=$FetchedAt.ToUniversalTime().ToString('o');hash=$ManifestHash;archiveStatus='active';cacheStatus='Fresh'})
        }
    })
    $latestEntryCount=@($entries|Where-Object{$_.id -ceq [string]$Manifest.latest.release}).Count
    if($latestEntryCount -eq 0){throw "MANIFEST_SCHEMA_ERROR: CurrentStable '$($Manifest.latest.release)' 不在规范化后的 ID 中：$(@($entries.id) -join ',')。"}
    $latestSnapshot=Get-MmtlOptionalProperty -InputObject $Manifest.latest -Name 'snapshot'
    [pscustomobject]@{schemaVersion=$script:MmtlCatalogSchemaVersion;source=$script:MmtlMojangManifestUrl;fetchedAt=$FetchedAt.ToUniversalTime().ToString('o');manifestHash=$ManifestHash;latestRelease=[string]$Manifest.latest.release;latestSnapshot=if($latestSnapshot){[string]$latestSnapshot}else{$null};minimumReleaseId=$anchor.id;entries=$entries}
}

function Get-MmtlCatalogCachePaths {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $root=Join-Path $RuntimeRoot 'metadata/mojang'
    [pscustomobject]@{Root=$root;Normalized=(Join-Path $root 'normalized/version-catalog.json');Raw=(Join-Path $root 'manifest/version_manifest_v2.json');Metadata=(Join-Path $root 'manifest/cache-metadata.json')}
}

function Set-MmtlCatalogStatus {
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$Status,[Parameter(Mandatory)][string]$ProvenanceCacheStatus)
    if($Catalog.PSObject.Properties['cacheStatus']){$Catalog.cacheStatus=$Status}else{$Catalog|Add-Member -NotePropertyName cacheStatus -NotePropertyValue $Status -Force}
    foreach($entry in $Catalog.entries){foreach($source in @($entry.provenance)){if($source.PSObject.Properties['cacheStatus']){$source.cacheStatus=$ProvenanceCacheStatus}else{$source|Add-Member -NotePropertyName cacheStatus -NotePropertyValue $ProvenanceCacheStatus -Force}}}
    $Catalog
}

function Read-MmtlCachedMinecraftVersionCatalog {
    param([Parameter(Mandatory)]$Paths)
    $exists=@([IO.File]::Exists($Paths.Metadata),[IO.File]::Exists($Paths.Raw),[IO.File]::Exists($Paths.Normalized))
    if(-not ($exists -contains $true)){return $null}
    if($exists -contains $false){throw 'CACHE_CORRUPT: 目录缓存仅部分存在。'}
    try {
        $metadata=[IO.File]::ReadAllText($Paths.Metadata,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
        $rawBytes=[IO.File]::ReadAllBytes($Paths.Raw)
        $normalizedBytes=[IO.File]::ReadAllBytes($Paths.Normalized)
        $manifestHash=Get-MmtlSha256Hex -Bytes $rawBytes
        $normalizedHash=Get-MmtlSha256Hex -Bytes $normalizedBytes
        if([int]$metadata.schemaVersion -ne $script:MmtlCatalogSchemaVersion -or $manifestHash -cne [string]$metadata.manifestHash -or $normalizedHash -cne [string]$metadata.normalizedHash){throw '缓存身份信息不匹配。'}
        $manifest=[Text.Encoding]::UTF8.GetString($rawBytes)|ConvertFrom-Json -ErrorAction Stop
        $catalog=ConvertTo-MmtlMinecraftVersionCatalog -Manifest $manifest -FetchedAt ([DateTimeOffset]::Parse([string]$metadata.fetchedAt)) -ManifestHash $manifestHash
        [pscustomobject]@{Metadata=$metadata;Catalog=$catalog}
    } catch { throw "CACHE_CORRUPT: $($_.Exception.Message)" }
}

function Get-MmtlMinecraftVersionCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet,[TimeSpan]$MaxAge=$script:MmtlCatalogDefaultTtl)
    $paths=Get-MmtlCatalogCachePaths -RuntimeRoot $RuntimeRoot
    $cacheReadError=$null
    try{$cached=Read-MmtlCachedMinecraftVersionCatalog -Paths $paths}catch{if($Offline){throw};$cacheReadError=$_.Exception.Message;$cached=$null}
    $now=[DateTimeOffset]::UtcNow
    if($Offline){if(-not $cached){throw 'CACHE_UNAVAILABLE: 离线时目录缓存不存在。'};return Set-MmtlCatalogStatus -Catalog $cached.Catalog -Status 'OfflineCache' -ProvenanceCacheStatus 'OfflineCache'}
    $lastValidated=if($cached){[DateTimeOffset]::Parse([string]$cached.Metadata.validatedAt)}else{$null}
    if($cached -and -not $ForceRefresh -and ($now-$lastValidated) -le $MaxAge){return Set-MmtlCatalogStatus -Catalog $cached.Catalog -Status 'Fresh' -ProvenanceCacheStatus 'Cached'}
    $headers=@{}
    if($cached){if($cached.Metadata.etag){$headers['If-None-Match']=[string]$cached.Metadata.etag};if($cached.Metadata.lastModified){$headers['If-Modified-Since']=[string]$cached.Metadata.lastModified}}
    $manifest=$null;$catalog=$null
    try {
        try{$response=Invoke-MmtlMetadataHttpGet -Uri $script:MmtlMojangManifestUrl -AllowedHosts $script:MmtlMojangMetadataHosts -Headers $headers -TimeoutSeconds 30 -HttpGet $HttpGet}catch{throw "MANIFEST_NETWORK_ERROR: $($_.Exception.Message)"}
        if([int]$response.StatusCode -eq 304){
            if(-not $cached){throw 'MANIFEST_INVALID_RESPONSE: 没有缓存内容却收到 HTTP 304。'}
            $manifestBytes=[IO.File]::ReadAllBytes($paths.Raw);$raw=[Text.Encoding]::UTF8.GetString($manifestBytes);$fetchedAt=[DateTimeOffset]::Parse([string]$cached.Metadata.fetchedAt);$hash=[string]$cached.Metadata.manifestHash
        } elseif([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300){
            $responseUri=if($response.PSObject.Properties['ResponseUri']){[string]$response.ResponseUri}else{''}
            if($responseUri -and -not (Test-MmtlMojangMetadataUri $responseUri)){throw 'MANIFEST_UNTRUSTED_REDIRECT: 响应主机不在许可清单中。'}
            $manifestBytes=[byte[]]$response.Bytes
            $raw=[Text.Encoding]::UTF8.GetString($manifestBytes)
            try{$manifest=$raw|ConvertFrom-Json -ErrorAction Stop}catch{throw "MANIFEST_INVALID_JSON: $($_.Exception.Message)"}
            $fetchedAt=$now;$hash=Get-MmtlSha256Hex -Bytes $manifestBytes
            $catalog=ConvertTo-MmtlMinecraftVersionCatalog -Manifest $manifest -FetchedAt $fetchedAt -ManifestHash $hash
        } else {throw "MANIFEST_NETWORK_ERROR: HTTP $($response.StatusCode)."}
        if(-not $manifest){$manifest=$raw|ConvertFrom-Json -ErrorAction Stop}
        if(-not $catalog){$catalog=ConvertTo-MmtlMinecraftVersionCatalog -Manifest $manifest -FetchedAt $fetchedAt -ManifestHash $hash}
        $etag=if($response.Headers){[string](Get-MmtlOptionalProperty -InputObject $response.Headers -Name 'ETag')}else{''}
        $lastModified=if($response.Headers){[string](Get-MmtlOptionalProperty -InputObject $response.Headers -Name 'Last-Modified')}else{''}
        if([int]$response.StatusCode -eq 304){if(-not $etag){$etag=[string]$cached.Metadata.etag};if(-not $lastModified){$lastModified=[string]$cached.Metadata.lastModified}}
        $normalizedJson=$catalog|ConvertTo-Json -Depth 30 -Compress
        $normalizedBytes=[Text.Encoding]::UTF8.GetBytes($normalizedJson)
        $metadata=[ordered]@{schemaVersion=$script:MmtlCatalogSchemaVersion;source=$script:MmtlMojangManifestUrl;fetchedAt=$fetchedAt.ToUniversalTime().ToString('o');validatedAt=$now.ToString('o');manifestHash=$hash;normalizedHash=(Get-MmtlSha256Hex -Bytes $normalizedBytes);etag=$etag;lastModified=$lastModified;cacheSchemaVersion=$script:MmtlCatalogSchemaVersion}
        $metadataJson=$metadata|ConvertTo-Json -Depth 10 -Compress
        Write-MmtlAtomicBytes -Path $paths.Raw -Bytes $manifestBytes
        Write-MmtlAtomicBytes -Path $paths.Normalized -Bytes $normalizedBytes
        Write-MmtlAtomicBytes -Path $paths.Metadata -Bytes ([Text.Encoding]::UTF8.GetBytes($metadataJson))
        return Set-MmtlCatalogStatus -Catalog $catalog -Status 'Fresh' -ProvenanceCacheStatus 'Fresh'
    } catch {
        if($cached -and -not $ForceRefresh){Set-MmtlCatalogStatus -Catalog $cached.Catalog -Status 'Stale' -ProvenanceCacheStatus 'Stale'|Out-Null;$cached.Catalog|Add-Member -NotePropertyName refreshError -NotePropertyValue $_.Exception.Message -Force;return $cached.Catalog}
        if($cacheReadError){throw "CACHE_CORRUPT: $cacheReadError; refresh failed: $($_.Exception.Message)"}
        throw
    }
}

function Resolve-MmtlMinecraftVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Catalog)
    $id=if($MinecraftId -ceq 'CurrentStable'){[string]$Catalog.latestRelease}else{$MinecraftId}
    $entry=$Catalog.entries|Where-Object{$_.id -ceq $id}|Select-Object -First 1
    if(-not $entry){throw "VERSION_NOT_FOUND: Minecraft 版本 '$MinecraftId' 不在正式版本目录中。"}
    $entry
}

function Get-MmtlMinecraftVersionMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$CatalogEntry,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[scriptblock]$HttpGet)
    if(-not $CatalogEntry.metadataSha1){throw "METADATA_HASH_MISSING: $($CatalogEntry.id) 缺少预期 SHA-1。"}
    $keyText="$($CatalogEntry.id)|$($CatalogEntry.metadataSha1.ToLowerInvariant())"
    $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyText))).ToLowerInvariant()
    $path=Join-Path (Join-Path $RuntimeRoot 'metadata/mojang/versions') "$key.json"
    $raw=$null;$bytes=$null;$actual=$null;$sourceUrl=[string]$CatalogEntry.metadataUrl;$downloadedAt=$null;$wasCached=$false
    if([IO.File]::Exists($path)){
        try{$cached=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop;$bytes=[Text.Encoding]::UTF8.GetBytes([string]$cached.rawJson);$actual=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant();if([string]$cached.id -cne [string]$CatalogEntry.id -or [string]$cached.expectedSha1 -cne ([string]$CatalogEntry.metadataSha1).ToLowerInvariant() -or $actual -cne ([string]$CatalogEntry.metadataSha1).ToLowerInvariant()){throw '缓存身份信息或 SHA-1 不匹配'};$raw=[string]$cached.rawJson;$sourceUrl=[string]$cached.sourceUrl;if(-not (Test-MmtlMojangMetadataUri $sourceUrl)){throw '缓存的来源 URL 不在许可清单中'};$downloadedAt=[string]$cached.downloadedAt;$wasCached=$true}catch{throw "CACHE_CORRUPT: 逐版本元数据缓存无效: $($_.Exception.Message)"}
    } elseif($Offline){throw "CACHE_UNAVAILABLE: $($CatalogEntry.id) 的元数据缓存离线不可用。"}
    else {
        if(-not (Test-MmtlMojangMetadataUri $sourceUrl)){throw 'METADATA_INVALID_URL: 元数据 URL 不是许可清单中的 HTTPS 地址。'}
        try{$response=Invoke-MmtlMetadataHttpGet -Uri $sourceUrl -AllowedHosts $script:MmtlMojangMetadataHosts -TimeoutSeconds 30 -HttpGet $HttpGet}catch{throw "METADATA_NETWORK_ERROR: $($_.Exception.Message)"}
        if([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300){throw "METADATA_NETWORK_ERROR: HTTP $($response.StatusCode) for $($CatalogEntry.id)."}
        $responseUri=if($response.PSObject.Properties['ResponseUri']){[string]$response.ResponseUri}else{''}
        if($responseUri -and -not (Test-MmtlMojangMetadataUri $responseUri)){throw 'METADATA_UNTRUSTED_REDIRECT: 响应主机不在许可清单中。'}
        $bytes=[byte[]]$response.Bytes;$actual=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        if($actual -cne ([string]$CatalogEntry.metadataSha1).ToLowerInvariant()){throw "METADATA_HASH_MISMATCH: expected $($CatalogEntry.metadataSha1), actual $actual."}
        $raw=[Text.Encoding]::UTF8.GetString($bytes);$downloadedAt=[DateTimeOffset]::UtcNow.ToString('o')
        try{$parsed=$raw|ConvertFrom-Json -ErrorAction Stop}catch{throw "METADATA_INVALID_JSON: $($_.Exception.Message)"}
        if([string]$parsed.id -cne [string]$CatalogEntry.id){throw "METADATA_VERSION_ID_MISMATCH: expected $($CatalogEntry.id), actual $($parsed.id)."}
        $record=[ordered]@{schemaVersion=1;id=[string]$CatalogEntry.id;expectedSha1=([string]$CatalogEntry.metadataSha1).ToLowerInvariant();actualSha1=$actual;localSha256=(Get-MmtlSha256Hex -Bytes $bytes);sourceUrl=$sourceUrl;downloadedAt=$downloadedAt;rawJson=$raw}
        Write-MmtlAtomicBytes -Path $path -Bytes ([Text.Encoding]::UTF8.GetBytes(($record|ConvertTo-Json -Depth 30 -Compress)))
    }
    try{$parsed=$raw|ConvertFrom-Json -ErrorAction Stop}catch{throw "METADATA_INVALID_JSON: $($_.Exception.Message)"}
    if([string]$parsed.id -cne [string]$CatalogEntry.id){throw "METADATA_VERSION_ID_MISMATCH: expected $($CatalogEntry.id), actual $($parsed.id)."}
    [pscustomobject]@{id=[string]$CatalogEntry.id;metadata=$parsed;rawJson=$raw;metadataStatus='VERIFIED';hashStatus='SHA1_VERIFIED';expectedSha1=([string]$CatalogEntry.metadataSha1).ToLowerInvariant();actualSha1=$actual;sourceUrl=$sourceUrl;downloadedAt=$downloadedAt;provenance=[pscustomobject]@{sourceType='official';url=$sourceUrl;fetchedAt=$downloadedAt;hash=$actual;archiveStatus='active';cacheStatus=if($Offline){'OfflineCache'}elseif($wasCached){'Cached'}else{'Fresh'}}}
}

Export-ModuleMember -Function ConvertTo-MmtlMinecraftVersionCatalog,Get-MmtlMinecraftVersionCatalog,Resolve-MmtlMinecraftVersion,Get-MmtlMinecraftVersionMetadata
