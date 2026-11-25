Set-StrictMode -Version Latest

$script:MmtlJavaFallbackPath=Join-Path $PSScriptRoot 'data/java-runtime-fallback.json'

function Get-MmtlJavaOptionalProperty {
    param([Parameter(Mandatory)]$InputObject,[Parameter(Mandatory)][string]$Name,$Default=$null)
    if($InputObject -is [Collections.IDictionary]){foreach($key in $InputObject.Keys){if([string]$key -ieq $Name){return $InputObject[$key]}};return $Default}
    $property=$InputObject.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $Default
}

function Get-MmtlJavaRuntimeFallbackRegistry {
    [CmdletBinding()]
    param([string]$Path=$script:MmtlJavaFallbackPath)
    try{$registry=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop}catch{throw "JAVA_FALLBACK_REGISTRY_INVALID: $($_.Exception.Message)"}
    if([int]$registry.schemaVersion -ne 1 -or $null -eq $registry.rules){throw 'JAVA_FALLBACK_REGISTRY_INVALID: schemaVersion 或 rules 缺失。'}
    @($registry.rules)
}

function Resolve-MmtlMinecraftRuntimeJavaRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MinecraftId,
        [Parameter(Mandatory)]$CatalogEntry,
        $VersionMetadata,
        $RuntimeOverride,
        [string]$FallbackRegistryPath=$script:MmtlJavaFallbackPath
    )
    $metadataStatus=if($VersionMetadata){[string]$VersionMetadata.metadataStatus}else{[string]$CatalogEntry.metadataStatus}
    if($RuntimeOverride){
        $major=0
        if(-not [int]::TryParse([string]$RuntimeOverride.major,[ref]$major) -or $major -le 0){throw 'RUNTIME_JAVA_OVERRIDE_INVALID: major 必须为正整数。'}
        return [pscustomobject]@{major=$major;component=(Get-MmtlJavaOptionalProperty -InputObject $RuntimeOverride -Name 'component');source='ProjectOverride';confidence='High';requirementKind='ProjectOverride';provenance=(Get-MmtlJavaOptionalProperty -InputObject $RuntimeOverride -Name 'provenance');metadataStatus=$metadataStatus}
    }
    $javaVersion=if($VersionMetadata -and $VersionMetadata.metadata){Get-MmtlJavaOptionalProperty -InputObject $VersionMetadata.metadata -Name 'javaVersion'}else{$null}
    if($javaVersion){
        $major=0
        $majorVersion=Get-MmtlJavaOptionalProperty -InputObject $javaVersion -Name 'majorVersion'
        if(-not [int]::TryParse([string]$majorVersion,[ref]$major) -or $major -le 0){throw 'METADATA_JAVA_VERSION_INVALID: javaVersion.majorVersion 必须为正整数。'}
        return [pscustomobject]@{major=$major;component=(Get-MmtlJavaOptionalProperty -InputObject $javaVersion -Name 'component');source='MojangVersionMetadata';confidence='High';requirementKind='AuthoritativeMetadata';provenance=$VersionMetadata.provenance;metadataStatus='VERIFIED'}
    }
    if($VersionMetadata -and $metadataStatus -eq 'VERIFIED'){$metadataStatus='VERIFIED_NO_JAVA_VERSION'}
    foreach($rule in (Get-MmtlJavaRuntimeFallbackRegistry -Path $FallbackRegistryPath)){
        if([string]$MinecraftId -cmatch [string]$rule.matcher){
            return [pscustomobject]@{major=[int]$rule.recommendedMajor;component=$null;source='MMTLCompatibilityFallback';confidence=[string]$rule.confidence;requirementKind='CompatibilityFallback';provenance=$rule.provenance;reason=[string]$rule.reason;metadataStatus=if($metadataStatus){$metadataStatus}else{'VERIFIED_NO_JAVA_VERSION'}}
        }
    }
    [pscustomobject]@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';provenance=$null;metadataStatus=if($metadataStatus){$metadataStatus}else{'VERIFIED_NO_JAVA_VERSION'}}
}

function Resolve-MmtlFrozenRuntimeJavaCatalogRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MinecraftId,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$UniverseHash,
        [Parameter(Mandatory)][string]$SnapshotRoot
    )
    if ([int](Get-MmtlJavaOptionalProperty $Catalog 'schemaVersion') -ne 1 -or [string](Get-MmtlJavaOptionalProperty $Catalog 'universeHash') -cne $UniverseHash) { throw 'RUNTIME_JAVA_CATALOG_UNIVERSE_MISMATCH' }
    $entries = @((Get-MmtlJavaOptionalProperty $Catalog 'entries' @()) | Where-Object { [string](Get-MmtlJavaOptionalProperty $_ 'minecraftId') -ceq $MinecraftId })
    if ($entries.Count -eq 0) { return $null }
    if ($entries.Count -ne 1) { throw 'RUNTIME_JAVA_CATALOG_TARGET_DUPLICATE' }
    $entry = $entries[0]
    $source = Get-MmtlJavaOptionalProperty $entry 'metadataSource'
    if (-not $source) { throw 'RUNTIME_JAVA_CATALOG_SOURCE_MISSING' }
    $manifestSha1 = ([string](Get-MmtlJavaOptionalProperty $source 'manifestSha1')).ToLowerInvariant()
    $sourceSha1 = ([string](Get-MmtlJavaOptionalProperty $source 'sourceSha1')).ToLowerInvariant()
    $snapshotSha256 = ([string](Get-MmtlJavaOptionalProperty $source 'snapshotSha256')).ToLowerInvariant()
    if ($manifestSha1 -notmatch '^[a-f0-9]{40}$' -or $sourceSha1 -cne $manifestSha1 -or $snapshotSha256 -notmatch '^[a-f0-9]{64}$') { throw 'RUNTIME_JAVA_CATALOG_HASH_INVALID' }
    $uri = $null
    if (-not [Uri]::TryCreate([string](Get-MmtlJavaOptionalProperty $source 'url'), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'piston-meta.mojang.com' -or $uri.UserInfo.Length -gt 0 -or $uri.Query -or $uri.Fragment) { throw 'RUNTIME_JAVA_CATALOG_URL_INVALID' }
    $pathMatch = [regex]::Match($uri.AbsolutePath, '^/v1/packages/(?<sha1>[a-f0-9]{40})/(?<id>(?:[A-Za-z0-9._-]|%[a-fA-F0-9]{2}){1,240})\.json$')
    if (-not $pathMatch.Success -or $pathMatch.Groups['sha1'].Value -cne $manifestSha1 -or [Uri]::UnescapeDataString($pathMatch.Groups['id'].Value) -cne $MinecraftId) { throw 'RUNTIME_JAVA_CATALOG_SOURCE_ID_MISMATCH' }
    $snapshotPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $SnapshotRoot 'MojangVersions') ($snapshotSha256 + '.bin')))
    if (-not [IO.File]::Exists($snapshotPath)) { throw 'MOJANG_VERSION_CATALOG_SNAPSHOT_MISSING' }
    $bytes = [IO.File]::ReadAllBytes($snapshotPath)
    $actualSha1 = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
    $actualSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($actualSha1 -cne $manifestSha1 -or $actualSha256 -cne $snapshotSha256) { throw 'MOJANG_VERSION_CATALOG_SNAPSHOT_HASH_MISMATCH' }
    try { $metadata = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop } catch { throw 'MOJANG_VERSION_CATALOG_SNAPSHOT_JSON_INVALID' }
    if ([string](Get-MmtlJavaOptionalProperty $metadata 'id') -cne $MinecraftId) { throw 'MOJANG_VERSION_METADATA_ID_MISMATCH' }
    $versionMetadata = [pscustomobject]@{metadataStatus='VERIFIED';metadata=$metadata;provenance=[pscustomobject]@{sourceType='official';url=$uri.AbsoluteUri;hash=$manifestSha1;snapshotSha256=$snapshotSha256;fetchedAt=[string](Get-MmtlJavaOptionalProperty $source 'retrievedAt')}}
    $resolved = Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId $MinecraftId -CatalogEntry ([pscustomobject]@{id=$MinecraftId;metadataStatus='VERIFIED'}) -VersionMetadata $versionMetadata
    $catalogRequirement = Get-MmtlJavaOptionalProperty $entry 'requirement'
    if ($catalogRequirement -and (Get-MmtlJavaOptionalProperty $catalogRequirement 'major') -and [int](Get-MmtlJavaOptionalProperty $catalogRequirement 'major') -ne [int]$resolved.major) { throw 'RUNTIME_JAVA_CATALOG_REQUIREMENT_MISMATCH' }
    return $resolved
}

function Resolve-MmtlFrozenMojangClientArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MinecraftId,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$UniverseHash,
        [Parameter(Mandatory)][string]$SnapshotRoot,
        [ValidateSet('client','server')][string]$ArtifactName='client'
    )
    if ([int](Get-MmtlJavaOptionalProperty $Catalog 'schemaVersion') -ne 1 -or [string](Get-MmtlJavaOptionalProperty $Catalog 'universeHash') -cne $UniverseHash) { throw 'MOJANG_CLIENT_CATALOG_UNIVERSE_MISMATCH' }
    $entries = @((Get-MmtlJavaOptionalProperty $Catalog 'entries' @()) | Where-Object { [string](Get-MmtlJavaOptionalProperty $_ 'minecraftId') -ceq $MinecraftId })
    if ($entries.Count -ne 1) { throw 'MOJANG_CLIENT_CATALOG_TARGET_MISSING_OR_DUPLICATE' }
    $source = Get-MmtlJavaOptionalProperty $entries[0] 'metadataSource'
    $sha1 = ([string](Get-MmtlJavaOptionalProperty $source 'manifestSha1')).ToLowerInvariant()
    $sha256 = ([string](Get-MmtlJavaOptionalProperty $source 'snapshotSha256')).ToLowerInvariant()
    $sourceSha1 = ([string](Get-MmtlJavaOptionalProperty $source 'sourceSha1')).ToLowerInvariant()
    if ($sha1 -notmatch '^[a-f0-9]{40}$' -or $sourceSha1 -cne $sha1 -or $sha256 -notmatch '^[a-f0-9]{64}$') { throw 'MOJANG_CLIENT_CATALOG_HASH_INVALID' }
    $metadataUrl = $null
    if (-not [Uri]::TryCreate([string](Get-MmtlJavaOptionalProperty $source 'url'),[UriKind]::Absolute,[ref]$metadataUrl) -or $metadataUrl.Scheme -cne 'https' -or $metadataUrl.Host -cne 'piston-meta.mojang.com' -or $metadataUrl.UserInfo -or $metadataUrl.Query -or $metadataUrl.Fragment) { throw 'MOJANG_CLIENT_CATALOG_URL_INVALID' }
    $metadataPath = [regex]::Match($metadataUrl.AbsolutePath,'^/v1/packages/(?<sha1>[a-f0-9]{40})/(?<id>[A-Za-z0-9._% -]{1,240})\.json$')
    if (-not $metadataPath.Success -or $metadataPath.Groups['sha1'].Value -cne $sha1 -or [Uri]::UnescapeDataString($metadataPath.Groups['id'].Value) -cne $MinecraftId) { throw 'MOJANG_CLIENT_CATALOG_ID_MISMATCH' }
    $snapshotPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $SnapshotRoot 'MojangVersions') ($sha256 + '.bin')))
    if (-not [IO.File]::Exists($snapshotPath)) { throw 'MOJANG_CLIENT_METADATA_SNAPSHOT_MISSING' }
    $bytes = [IO.File]::ReadAllBytes($snapshotPath)
    if ([Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant() -cne $sha1 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $sha256) { throw 'MOJANG_CLIENT_METADATA_SNAPSHOT_HASH_MISMATCH' }
    try { $metadata = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop } catch { throw 'MOJANG_CLIENT_METADATA_SNAPSHOT_JSON_INVALID' }
    if ([string](Get-MmtlJavaOptionalProperty $metadata 'id') -cne $MinecraftId) { throw 'MOJANG_CLIENT_METADATA_ID_MISMATCH' }
    $versionMetadataPath = [regex]::Match($metadataUrl.AbsolutePath,'^/v1/packages/[a-f0-9]{40}/')
    if (-not $versionMetadataPath.Success) { throw 'MOJANG_VERSION_METADATA_URL_NOT_CONTENT_ADDRESSED' }
    $assetIndex = Get-MmtlJavaOptionalProperty $metadata 'assetIndex'
    $assetIndexId = [string](Get-MmtlJavaOptionalProperty $assetIndex 'id')
    $assetIndexSha1 = ([string](Get-MmtlJavaOptionalProperty $assetIndex 'sha1')).ToLowerInvariant()
    $assetIndexSize = 0L
    $assetIndexUrl = $null
    if (-not $assetIndex -or $assetIndexId -cne $MinecraftId -or $assetIndexSha1 -notmatch '^[a-f0-9]{40}$' -or -not [long]::TryParse([string](Get-MmtlJavaOptionalProperty $assetIndex 'size'),[ref]$assetIndexSize) -or $assetIndexSize -le 0 -or -not [Uri]::TryCreate([string](Get-MmtlJavaOptionalProperty $assetIndex 'url'),[UriKind]::Absolute,[ref]$assetIndexUrl) -or $assetIndexUrl.Scheme -cne 'https' -or $assetIndexUrl.Host -cne 'launchermeta.mojang.com' -or $assetIndexUrl.Port -ne 443 -or $assetIndexUrl.UserInfo -or $assetIndexUrl.Query -or $assetIndexUrl.Fragment) { throw 'MOJANG_ASSET_INDEX_PIN_INVALID' }
    $assetIndexPath = [regex]::Match($assetIndexUrl.AbsolutePath,'^/v1/packages/(?<sha1>[a-f0-9]{40})/(?<id>[A-Za-z0-9._% -]{1,240})\.json$')
    if (-not $assetIndexPath.Success -or $assetIndexPath.Groups['sha1'].Value -cne $assetIndexSha1 -or [Uri]::UnescapeDataString($assetIndexPath.Groups['id'].Value) -cne $MinecraftId) { throw 'MOJANG_ASSET_INDEX_URL_HASH_MISMATCH' }
    $verifiedVersionMetadata = [pscustomobject][ordered]@{url=$metadataUrl.AbsoluteUri;sha1=$sha1;bytes=$bytes.LongLength;sha256=$sha256}
    $verifiedAssetIndex = [pscustomobject][ordered]@{url=$assetIndexUrl.AbsoluteUri;sha1=$assetIndexSha1;bytes=$assetIndexSize;id=$assetIndexId}
    $artifact = Get-MmtlJavaOptionalProperty (Get-MmtlJavaOptionalProperty $metadata 'downloads') $ArtifactName
    if (-not $artifact) { throw "MOJANG_$($ArtifactName.ToUpperInvariant())_ARTIFACT_MISSING" }
    $artifactSha1 = ([string](Get-MmtlJavaOptionalProperty $artifact 'sha1')).ToLowerInvariant()
    $clientSize = 0L
    if ($artifactSha1 -notmatch '^[a-f0-9]{40}$' -or -not [long]::TryParse([string](Get-MmtlJavaOptionalProperty $artifact 'size'),[ref]$clientSize) -or $clientSize -le 0) { throw "MOJANG_$($ArtifactName.ToUpperInvariant())_ARTIFACT_PIN_INVALID" }
    $artifactUrl = $null
    if (-not [Uri]::TryCreate([string](Get-MmtlJavaOptionalProperty $artifact 'url'),[UriKind]::Absolute,[ref]$artifactUrl) -or $artifactUrl.Scheme -cne 'https' -or $artifactUrl.Host -cnotin @('launcher.mojang.com','piston-data.mojang.com') -or $artifactUrl.Port -ne 443 -or $artifactUrl.UserInfo -or $artifactUrl.Query -or $artifactUrl.Fragment) { throw "MOJANG_$($ArtifactName.ToUpperInvariant())_ARTIFACT_URL_INVALID" }
    if ($artifactUrl.AbsolutePath -cnotmatch ( '^/v1/objects/' + [regex]::Escape($artifactSha1) + '/' + [regex]::Escape($ArtifactName) + '\.jar$')) { throw "MOJANG_$($ArtifactName.ToUpperInvariant())_ARTIFACT_URL_HASH_MISMATCH" }
    [pscustomobject][ordered]@{url=$artifactUrl.AbsoluteUri;sha1=$artifactSha1;bytes=$clientSize;metadataSnapshotSha256=$sha256;versionMetadata=$verifiedVersionMetadata;assetIndex=$verifiedAssetIndex}
}

Export-ModuleMember -Function Get-MmtlJavaRuntimeFallbackRegistry,Resolve-MmtlMinecraftRuntimeJavaRequirement,Resolve-MmtlFrozenRuntimeJavaCatalogRequirement,Resolve-MmtlFrozenMojangClientArtifact
