Set-StrictMode -Version Latest

$script:MmtlLoaderMetadataSchemaVersion=1
$script:MmtlLoaderMetadataTtl=[TimeSpan]::FromHours(24)

function Test-MmtlAllowedMetadataUri {
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string[]]$AllowedHosts)
    $parsed=$null
    if(-not [Uri]::TryCreate($Uri,[UriKind]::Absolute,[ref]$parsed)){return $false}
    return $parsed.Scheme -ceq 'https' -and $parsed.UserInfo.Length -eq 0 -and $parsed.Host.ToLowerInvariant() -cin @($AllowedHosts|ForEach-Object{$_.ToLowerInvariant()})
}

function Invoke-MmtlMetadataHttpGet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string[]]$AllowedHosts,[hashtable]$Headers=@{},[int]$TimeoutSeconds=30,[scriptblock]$HttpGet)
    if(-not (Test-MmtlAllowedMetadataUri -Uri $Uri -AllowedHosts $AllowedHosts)){throw "METADATA_INVALID_URL: URL must be HTTPS on an allowlisted host: $Uri"}
    if($HttpGet){
        $response=& $HttpGet $Uri $Headers $TimeoutSeconds
        $responseUri=if($response.PSObject.Properties['ResponseUri'] -and $response.ResponseUri){[string]$response.ResponseUri}else{$Uri}
        if(-not (Test-MmtlAllowedMetadataUri -Uri $responseUri -AllowedHosts $AllowedHosts)){throw "METADATA_UNTRUSTED_REDIRECT: response URI is outside the provider allowlist: $responseUri"}
        return [pscustomobject]@{StatusCode=[int]$response.StatusCode;Headers=$response.Headers;Bytes=[byte[]]$response.Bytes;ResponseUri=$responseUri}
    }
    $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false
    $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds($TimeoutSeconds)
    $current=[Uri]$Uri;$redirects=0
    try {
        while($true){
            if(-not (Test-MmtlAllowedMetadataUri -Uri $current.AbsoluteUri -AllowedHosts $AllowedHosts)){throw "METADATA_UNTRUSTED_REDIRECT: redirect target is outside the provider allowlist: $current"}
            $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$current)
            foreach($key in $Headers.Keys){$null=$request.Headers.TryAddWithoutValidation([string]$key,[string]$Headers[$key])}
            $response=$client.Send($request)
            try {
                $status=[int]$response.StatusCode
                if($status -in @(301,302,303,307,308)){
                    $location=$response.Headers.Location
                    if(-not $location){throw 'METADATA_REDIRECT_INVALID: redirect has no Location header.'}
                    $redirects++
                    if($redirects -gt 5){throw 'METADATA_REDIRECT_LIMIT: more than five redirects.'}
                    $current=if($location.IsAbsoluteUri){$location}else{[Uri]::new($current,$location)}
                    continue
                }
                $responseHeaders=@{}
                foreach($header in $response.Headers){$responseHeaders[$header.Key]=$header.Value -join ', '}
                foreach($header in $response.Content.Headers){$responseHeaders[$header.Key]=$header.Value -join ', '}
                $bytes=if($status -eq 304){[byte[]]@()}else{$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()}
                return [pscustomobject]@{StatusCode=$status;Headers=$responseHeaders;Bytes=$bytes;ResponseUri=$current.AbsoluteUri}
            } finally {$response.Dispose();$request.Dispose()}
        }
    } finally {$client.Dispose();$handler.Dispose()}
}

function Get-MmtlLoaderMetadataCachePath {
    param([Parameter(Mandatory)][string]$ProviderId,[Parameter(Mandatory)][string]$CacheKey,[Parameter(Mandatory)][string]$RuntimeRoot)
    if($ProviderId -cnotin @('Forge','Fabric','NeoForge','Quilt')){throw "LOADER_PROVIDER_UNKNOWN: $ProviderId"}
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($CacheKey))).ToLowerInvariant()
    Join-Path (Join-Path (Join-Path $RuntimeRoot 'metadata/loaders') $ProviderId.ToLowerInvariant()) "$digest.json"
}

function Get-MmtlLoaderCacheEnvelope {
    param([Parameter(Mandatory)][string]$Path)
    if(-not [IO.File]::Exists($Path)){return $null}
    try {
        $envelope=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
        if([int]$envelope.providerSchemaVersion -ne $script:MmtlLoaderMetadataSchemaVersion -or [string]::IsNullOrWhiteSpace([string]$envelope.bodyBase64)){throw 'cache schema or body missing'}
        $bytes=[Convert]::FromBase64String([string]$envelope.bodyBase64)
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if($hash -cne [string]$envelope.localHash){throw 'cache body hash mismatch'}
        $envelope|Add-Member -NotePropertyName bodyBytes -NotePropertyValue $bytes -Force
        $envelope|Add-Member -NotePropertyName content -NotePropertyValue ([Text.Encoding]::UTF8.GetString($bytes)) -Force
        return $envelope
    } catch {throw "LOADER_CACHE_CORRUPT: $($_.Exception.Message)"}
}

function Write-MmtlLoaderCacheEnvelope {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)][string]$ProviderId,[Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)]$Headers,[Parameter(Mandatory)][DateTimeOffset]$FetchedAt,[Parameter(Mandatory)][DateTimeOffset]$ValidatedAt)
    $directory=Split-Path -Parent $Path;[IO.Directory]::CreateDirectory($directory)|Out-Null
    $etag=Get-MmtlLoaderOptionalProperty -InputObject $Headers -Name 'ETag'
    $lastModified=Get-MmtlLoaderOptionalProperty -InputObject $Headers -Name 'Last-Modified'
    $record=[ordered]@{providerSchemaVersion=$script:MmtlLoaderMetadataSchemaVersion;providerId=$ProviderId;sourceUrl=$Uri;fetchedAt=$FetchedAt.ToUniversalTime().ToString('o');validatedAt=$ValidatedAt.ToUniversalTime().ToString('o');localHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant();etag=[string]$etag;lastModified=[string]$lastModified;bodyBase64=[Convert]::ToBase64String($Bytes)}
    $temporary="$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try{[IO.File]::WriteAllText($temporary,($record|ConvertTo-Json -Compress),[Text.Encoding]::UTF8);if([IO.File]::Exists($Path)){[IO.File]::Move($temporary,$Path,$true)}else{[IO.File]::Move($temporary,$Path)}}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}

function Get-MmtlLoaderOptionalProperty {
    param($InputObject,[Parameter(Mandatory)][string]$Name)
    if($null -eq $InputObject){return $null}
    if($InputObject -is [Collections.IDictionary]){foreach($key in $InputObject.Keys){if([string]$key -ieq $Name){return $InputObject[$key]}};return $null}
    $property=$InputObject.PSObject.Properties[$Name];if($property){return $property.Value};return $null
}

function Get-MmtlLoaderMetadataDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Forge','Fabric','NeoForge','Quilt')][string]$ProviderId,[Parameter(Mandatory)][string]$CacheKey,[Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][string[]]$AllowedHosts,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[TimeSpan]$MaxAge=$script:MmtlLoaderMetadataTtl,[scriptblock]$HttpGet)
    if(-not (Test-MmtlAllowedMetadataUri -Uri $Uri -AllowedHosts $AllowedHosts)){return [pscustomobject]@{providerId=$ProviderId;providerStatus='Unavailable';cacheStatus='Unavailable';sourceUrl=$Uri;fetchedAt=$null;validatedAt=$null;localHash=$null;etag=$null;lastModified=$null;error='METADATA_INVALID_URL: URL is not HTTPS on an allowlisted host.';content=$null}}
    $path=Get-MmtlLoaderMetadataCachePath -ProviderId $ProviderId -CacheKey $CacheKey -RuntimeRoot $RuntimeRoot
    $cached=$null;$cacheError=$null
    try{$cached=Get-MmtlLoaderCacheEnvelope -Path $path}catch{$cacheError=$_.Exception.Message}
    $now=[DateTimeOffset]::UtcNow
    if($Offline){
        if(-not $cached){return [pscustomobject]@{providerId=$ProviderId;providerStatus='Unavailable';cacheStatus='Unavailable';sourceUrl=$Uri;fetchedAt=$null;validatedAt=$null;localHash=$null;etag=$null;lastModified=$null;error=if($cacheError){$cacheError}else{'CACHE_UNAVAILABLE: no provider metadata cache.'};content=$null}}
        return [pscustomobject]@{providerId=$ProviderId;providerStatus='Available';cacheStatus='OfflineCache';sourceUrl=[string]$cached.sourceUrl;fetchedAt=[string]$cached.fetchedAt;validatedAt=[string]$cached.validatedAt;localHash=[string]$cached.localHash;etag=[string]$cached.etag;lastModified=[string]$cached.lastModified;content=[string]$cached.content;error=$null}
    }
    if($cached -and -not $ForceRefresh -and ($now-[DateTimeOffset]::Parse([string]$cached.validatedAt)) -le $MaxAge){return [pscustomobject]@{providerId=$ProviderId;providerStatus='Available';cacheStatus='Fresh';sourceUrl=[string]$cached.sourceUrl;fetchedAt=[string]$cached.fetchedAt;validatedAt=[string]$cached.validatedAt;localHash=[string]$cached.localHash;etag=[string]$cached.etag;lastModified=[string]$cached.lastModified;content=[string]$cached.content;error=$null}}
    $headers=@{};if($cached){if($cached.etag){$headers['If-None-Match']=[string]$cached.etag};if($cached.lastModified){$headers['If-Modified-Since']=[string]$cached.lastModified}}
    try {
        $response=Invoke-MmtlMetadataHttpGet -Uri $Uri -AllowedHosts $AllowedHosts -Headers $headers -HttpGet $HttpGet
        if([int]$response.StatusCode -eq 304){
            if(-not $cached){throw 'METADATA_INVALID_RESPONSE: got HTTP 304 without a validated cache.'}
            $bytes=[byte[]]$cached.bodyBytes;$fetched=[DateTimeOffset]::Parse([string]$cached.fetchedAt)
            Write-MmtlLoaderCacheEnvelope -Path $path -Bytes $bytes -ProviderId $ProviderId -Uri $Uri -Headers $response.Headers -FetchedAt $fetched -ValidatedAt $now
        } elseif([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300){
            $bytes=[byte[]]$response.Bytes;$fetched=$now
            Write-MmtlLoaderCacheEnvelope -Path $path -Bytes $bytes -ProviderId $ProviderId -Uri $response.ResponseUri -Headers $response.Headers -FetchedAt $fetched -ValidatedAt $now
        } else {throw "METADATA_NETWORK_ERROR: HTTP $($response.StatusCode)."}
        $saved=Get-MmtlLoaderCacheEnvelope -Path $path
        return [pscustomobject]@{providerId=$ProviderId;providerStatus='Available';cacheStatus='Fresh';sourceUrl=[string]$saved.sourceUrl;fetchedAt=[string]$saved.fetchedAt;validatedAt=[string]$saved.validatedAt;localHash=[string]$saved.localHash;etag=[string]$saved.etag;lastModified=[string]$saved.lastModified;content=[string]$saved.content;error=$null}
    } catch {
        if($cached){return [pscustomobject]@{providerId=$ProviderId;providerStatus='Stale';cacheStatus='Stale';sourceUrl=[string]$cached.sourceUrl;fetchedAt=[string]$cached.fetchedAt;validatedAt=[string]$cached.validatedAt;localHash=[string]$cached.localHash;etag=[string]$cached.etag;lastModified=[string]$cached.lastModified;content=[string]$cached.content;error=$_.Exception.Message}}
        return [pscustomobject]@{providerId=$ProviderId;providerStatus='Unavailable';cacheStatus='Unavailable';sourceUrl=$Uri;fetchedAt=$null;validatedAt=$null;localHash=$null;etag=$null;lastModified=$null;content=$null;error=if($cacheError){"$cacheError; $($_.Exception.Message)"}else{$_.Exception.Message}}
    }
}

function ConvertFrom-MmtlSafeXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Xml)
    $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=16777216
    $stringReader=[IO.StringReader]::new($Xml);$reader=[Xml.XmlReader]::Create($stringReader,$settings)
    try{$document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader);return $document}catch{throw "XML_INVALID: $($_.Exception.Message)"}finally{$reader.Dispose();$stringReader.Dispose()}
}

Export-ModuleMember -Function Invoke-MmtlMetadataHttpGet,Get-MmtlLoaderMetadataDocument,Get-MmtlLoaderMetadataCachePath,ConvertFrom-MmtlSafeXml
