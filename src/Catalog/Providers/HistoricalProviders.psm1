Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'HistoricalMetadata.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\Architecture\HistoricalContracts.psm1') -Force

$script:MmtlLegacyFabricHost = @('meta.legacyfabric.net')
$script:MmtlLegacyFabricBase = 'https://meta.legacyfabric.net/v2/versions'
$script:MmtlOrnitheHost = @('meta.ornithemc.net')
$script:MmtlOrnitheBase = 'https://meta.ornithemc.net/v2/versions'
$script:MmtlLiteLoaderHost = @('dl.liteloader.com')
$script:MmtlLiteLoaderManifest = 'https://dl.liteloader.com/versions/versions.json'

function ConvertFrom-MmtlHistoricalJsonArray {
    param([Parameter(Mandatory)][string]$Content,[Parameter(Mandatory)][string]$Context)
    try {
        $value = ConvertFrom-Json -InputObject $Content -NoEnumerate -ErrorAction Stop
        if ($value -isnot [array]) { throw 'Expected JSON array.' }
        return ,$value
    } catch { throw "HISTORICAL_METADATA_INVALID ($Context): $($_.Exception.Message)" }
}

function Get-MmtlHistoricalAggregateStatus {
    param([Parameter(Mandatory)][object[]]$Documents)
    $available = @($Documents | Where-Object { $_.providerStatus -eq 'Available' }).Count
    $stale = @($Documents | Where-Object { $_.providerStatus -eq 'Stale' }).Count
    $offline = @($Documents | Where-Object { $_.cacheStatus -eq 'OfflineCache' }).Count
    if ($available -eq $Documents.Count) { return 'Available' }
    if (($available + $stale) -eq 0) { return 'Unavailable' }
    if ($stale) { return 'Stale' }
    if ($offline -eq $Documents.Count) { return 'OfflineCache' }
    'Degraded'
}

function Get-MmtlLegacyFabricProviderSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $resources = [ordered]@{
        game = "$script:MmtlLegacyFabricBase/game"
        loader = "$script:MmtlLegacyFabricBase/loader"
        intermediary = "$script:MmtlLegacyFabricBase/intermediary"
        yarn = "$script:MmtlLegacyFabricBase/yarn"
    }
    $documents = [ordered]@{}
    $parsed = [ordered]@{}
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($key in $resources.Keys) {
        $document = Get-MmtlHistoricalMetadataDocument -ProviderId LegacyFabric -CacheKey "v2-$key" -Uri $resources[$key] -AllowedHosts $script:MmtlLegacyFabricHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
        $documents[$key] = $document
        if ($document.providerStatus -in @('Available','Stale')) {
            try { $parsed[$key] = ConvertFrom-MmtlHistoricalJsonArray -Content $document.content -Context "Legacy Fabric $key" }
            catch { $errors.Add($_.Exception.Message) }
        } else { $errors.Add([string]$document.error) }
    }
    $status = if ($errors.Count -eq 0) { Get-MmtlHistoricalAggregateStatus -Documents @($documents.Values) } elseif ($parsed.Count -gt 0) { 'Degraded' } else { 'Unavailable' }
    $supported = @($parsed.game | ForEach-Object { [pscustomobject]@{version=[string]$_.version;stable=[bool]$_.stable} } | Sort-Object version -Unique)
    [pscustomobject][ordered]@{
        providerId='LegacyFabric';loaderId='LegacyFabric';providerStatus=$status
        availability=if($status -in @('Available','OfflineCache','Stale','Degraded')){'Available'}else{'Unknown'}
        sourceClass='ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS';maintenanceState='Active'
        supportedVersions=$supported;loaderVersions=@($parsed.loader);intermediaryMappings=@($parsed.intermediary);yarnMappings=@($parsed.yarn)
        cacheStatus=if($parsed.Count){[string]$documents.game.cacheStatus}else{'Unavailable'};sourceUrl=$resources.game
        documents=[pscustomobject]$documents;provenance=@($documents.Values | Where-Object { $_.providerStatus -in @('Available','Stale') } | ForEach-Object { [pscustomobject]@{sourceUrl=$_.sourceUrl;fetchedAt=$_.fetchedAt;validatedAt=$_.validatedAt;localHash=$_.localHash;cacheStatus=$_.cacheStatus} })
        error=if($errors.Count){$errors -join '; '}else{$null}
    }
}

function Get-MmtlLegacyFabricReleaseCoverage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)]$Snapshot)
    $catalogEntries = @($Catalog.entries | Where-Object { $_.type -eq 'release' })
    $supported = @($Snapshot.supportedVersions | ForEach-Object { [string]$_.version })
    $matched = @($catalogEntries | Where-Object { $_.id -cin $supported })
    if ($matched.Count -gt 1 -and $matched[0].PSObject.Properties['releaseTime']) {
        $ordered = @($matched | Sort-Object { [DateTimeOffset]::Parse([string]$_.releaseTime) })
        $earliest = [string]$ordered[0].id; $latest = [string]$ordered[-1].id
    } else { $earliest = if($matched.Count){[string]$matched[0].id}else{$null};$latest=if($matched.Count){[string]$matched[-1].id}else{$null} }
    [pscustomobject]@{providerId='LegacyFabric';releaseCount=$matched.Count;earliestRelease=$earliest;latestRelease=$latest;releaseIds=@($matched|ForEach-Object{[string]$_.id});catalogHash=if($Catalog.PSObject.Properties['manifestHash']){$Catalog.manifestHash}else{$null};sourceUrl=if($Snapshot.PSObject.Properties['sourceUrl']){$Snapshot.sourceUrl}else{$null};providerStatus=if($Snapshot.PSObject.Properties['providerStatus']){$Snapshot.providerStatus}else{'Unknown'}}
}

function Get-MmtlLegacyFabricCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $encoded = [Uri]::EscapeDataString($MinecraftId)
    $uri = "$script:MmtlLegacyFabricBase/loader/$encoded"
    $document = Get-MmtlHistoricalMetadataDocument -ProviderId LegacyFabric -CacheKey "v2-loader-$MinecraftId" -Uri $uri -AllowedHosts $script:MmtlLegacyFabricHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    if ($document.providerStatus -notin @('Available','Stale')) { return @() }
    $records = ConvertFrom-MmtlHistoricalJsonArray -Content $document.content -Context "Legacy Fabric candidates $MinecraftId"
    $candidates = [Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        if (-not $record.loader -or -not $record.intermediary) { continue }
        $version = [string]$record.loader.version
        if (-not $version) { continue }
        $candidates.Add([pscustomobject][ordered]@{
            loaderId='LegacyFabric';minecraftId=$MinecraftId;loaderVersion=$version;version=$version;stable=[bool]$record.loader.stable
            artifact=[pscustomobject]@{coordinate=[string]$record.loader.maven}
            mappingContext=[pscustomobject]@{intermediary=$record.intermediary;yarn=$null}
            launcherMeta=$record.launcherMeta
            sourceClass='ActiveOfficial';trustClass='TrustedOfficial';maintenanceState='Active';transportSecurity='HTTPS'
            toolchain=[pscustomobject]@{id='LegacyLooming';version=$null;ecosystem='LegacyFabric'}
            source=$document.sourceUrl;providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus
            provenance=@([pscustomobject]@{sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;cacheStatus=$document.cacheStatus})
            downloadPermission='Granted';executePermission='RequiresConfirmation'
        })
    }
    return @($candidates)
}

function Get-MmtlOrnitheProviderSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $uris = [ordered]@{game="$script:MmtlOrnitheBase/game";loader="$script:MmtlOrnitheBase/loader"}
    $documents = [ordered]@{};$parsed=[ordered]@{};$errors=[Collections.Generic.List[string]]::new()
    foreach ($key in $uris.Keys) {
        $document=Get-MmtlHistoricalMetadataDocument -ProviderId Ornithe -CacheKey "v2-$key" -Uri $uris[$key] -AllowedHosts $script:MmtlOrnitheHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
        $documents[$key]=$document
        if($document.providerStatus -in @('Available','Stale')){try{$parsed[$key]=ConvertFrom-MmtlHistoricalJsonArray -Content $document.content -Context "Ornithe $key"}catch{$errors.Add($_.Exception.Message)}}else{$errors.Add([string]$document.error)}
    }
    $status=if($errors.Count -eq 0){Get-MmtlHistoricalAggregateStatus -Documents @($documents.Values)}elseif($parsed.Count){'Degraded'}else{'Unavailable'}
    [pscustomobject][ordered]@{providerId='Ornithe';loaderId='OrnitheLoader';providerStatus=$status;availability=if($parsed.game){'Available'}else{'Unknown'};sourceClass='ActiveOfficial';trustClass='TrustedOfficial';maintenanceState='Active';transportSecurity='HTTPS';supportedVersions=@($parsed.game|ForEach-Object{$environment=$null;if($_.PSObject.Properties['environment']){$environment=$_.environment};[pscustomobject]@{version=[string]$_.version;stable=[bool]$_.stable;environment=$environment}});loaderVersions=@($parsed.loader);cacheStatus=if($parsed.game){[string]$documents.game.cacheStatus}else{'Unavailable'};sourceUrl=$uris.game;documents=[pscustomobject]$documents;provenance=@($documents.Values|Where-Object{$_.providerStatus -in @('Available','Stale')}|ForEach-Object{[pscustomobject]@{sourceUrl=$_.sourceUrl;fetchedAt=$_.fetchedAt;validatedAt=$_.validatedAt;localHash=$_.localHash;cacheStatus=$_.cacheStatus}});error=if($errors.Count){$errors -join '; '}else{$null}}
}

function Get-MmtlOrnitheReleaseCoverage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)]$Snapshot)
    $catalogEntries=@($Catalog.entries|Where-Object type -eq 'release');$supported=@($Snapshot.supportedVersions|ForEach-Object{[string]$_.version});$matched=@($catalogEntries|Where-Object{$_.id -cin $supported})
    $ordered=if($matched.Count -gt 1 -and $matched[0].PSObject.Properties['releaseTime']){@($matched|Sort-Object{[DateTimeOffset]::Parse([string]$_.releaseTime)})}else{@($matched)}
    [pscustomobject]@{providerId='Ornithe';releaseCount=$matched.Count;earliestRelease=if($ordered.Count){[string]$ordered[0].id}else{$null};latestRelease=if($ordered.Count){[string]$ordered[-1].id}else{$null};releaseIds=@($matched|ForEach-Object{[string]$_.id});catalogHash=if($Catalog.PSObject.Properties['manifestHash']){$Catalog.manifestHash}else{$null};sourceUrl=$Snapshot.sourceUrl;providerStatus=$Snapshot.providerStatus}
}

function Get-MmtlOrnitheCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $uri="$script:MmtlOrnitheBase/loader/$([Uri]::EscapeDataString($MinecraftId))"
    $document=Get-MmtlHistoricalMetadataDocument -ProviderId Ornithe -CacheKey "v2-loader-$MinecraftId" -Uri $uri -AllowedHosts $script:MmtlOrnitheHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    if($document.providerStatus -notin @('Available','Stale')){return @()}
    $records=ConvertFrom-MmtlHistoricalJsonArray -Content $document.content -Context "Ornithe candidates $MinecraftId";$candidates=[Collections.Generic.List[object]]::new()
    foreach($record in $records){if(-not $record.loader){continue};$version=[string]$record.loader.version;if(-not $version){continue};$maven=$null;if($record.loader.PSObject.Properties['maven']){$maven=[string]$record.loader.maven};$calamus=$null;if($record.PSObject.Properties['calamus']){$calamus=$record.calamus};$launcherMeta=$null;if($record.PSObject.Properties['launcherMeta']){$launcherMeta=$record.launcherMeta};$candidates.Add([pscustomobject][ordered]@{loaderId='OrnitheLoader';minecraftId=$MinecraftId;loaderVersion=$version;version=$version;stable=[bool]$record.loader.stable;artifact=[pscustomobject]@{coordinate=$maven};mappingContext=[pscustomobject]@{calamus=$calamus;feather=$null};launcherMeta=$launcherMeta;sourceClass='ActiveOfficial';trustClass='TrustedOfficial';maintenanceState='Active';transportSecurity='HTTPS';toolchain=[pscustomobject]@{id='Ploceus';version=$null;ecosystem='Ornithe'};source=$document.sourceUrl;providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;provenance=@([pscustomobject]@{sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;cacheStatus=$document.cacheStatus});downloadPermission='Granted';executePermission='RequiresConfirmation'})}
    return @($candidates)
}

function Get-MmtlLiteLoaderProviderSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $document=Get-MmtlHistoricalMetadataDocument -ProviderId LiteLoader -CacheKey 'official-versions-json' -Uri $script:MmtlLiteLoaderManifest -AllowedHosts $script:MmtlLiteLoaderHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $records=[Collections.Generic.List[object]]::new();$error=$document.error
    if($document.providerStatus -in @('Available','Stale')){
        try{
            $manifest=ConvertFrom-Json -InputObject $document.content -ErrorAction Stop
            if(-not $manifest.versions){throw 'LiteLoader manifest does not contain versions.'}
            foreach($versionProperty in $manifest.versions.PSObject.Properties){
                $mcId=[string]$versionProperty.Name;$entry=$versionProperty.Value
                foreach($channelName in @('artefacts','artifacts','snapshots')){
                    $channelProperty=$entry.PSObject.Properties[$channelName];if(-not $channelProperty){continue};$channel=$channelProperty.Value;if(-not $channel){continue}
                    $artifactProperty=$channel.PSObject.Properties['com.mumfrey:liteloader'];if(-not $artifactProperty){continue}
                    foreach($build in $artifactProperty.Value.PSObject.Properties){
                        if($build.Name -eq 'latest'){continue};$detail=$build.Value;if(-not $detail.file){continue}
                        $repoUrl=[string]$entry.repo.url;$parsed=$null;$transport=if([Uri]::TryCreate($repoUrl,[UriKind]::Absolute,[ref]$parsed) -and $parsed.Scheme -eq 'http'){'HTTPOnly'}elseif($parsed -and $parsed.Scheme -eq 'https'){'HTTPS'}else{'Unknown'}
                        $integrity=Get-MmtlHistoricalIntegrityAssessment -Algorithm MD5 -Hash ([string]$detail.md5)
                        $records.Add([pscustomobject][ordered]@{loaderId='LiteLoader';minecraftId=$mcId;loaderVersion=[string]$detail.version;version=[string]$detail.version;channel=$channelName;artifact=[pscustomobject]@{filename=[string]$detail.file;repositoryUrl=$repoUrl;coordinate="com.mumfrey:liteloader:$($detail.version)"};sourceClass='HistoricalOfficial';trustClass='VerifiedHistorical';maintenanceState='Archived';metadataTransport='HTTPS';artifactTransport=$transport;integrity=$integrity;toolchain=[pscustomobject]@{id='ForgeGradle';version=[string]$entry.dev.fgVersion;ecosystem='LiteLoader'};mappingContext=[pscustomobject]@{mappings=[string]$entry.dev.mappings};sourceUrl=$script:MmtlLiteLoaderManifest;providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;downloadPermission='RequiresConfirmation';executePermission='Denied';provenance=@([pscustomobject]@{sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;cacheStatus=$document.cacheStatus;manifestUpdated=[string]$manifest.meta.updated})})
                    }
                }
            }
        }catch{$error=$_.Exception.Message;$records.Clear()}
    }
    [pscustomobject][ordered]@{providerId='LiteLoader';loaderId='LiteLoader';providerStatus=if($error -and $document.providerStatus -eq 'Available'){'Degraded'}else{$document.providerStatus};availability=if($records.Count){'Available'}else{'Unknown'};sourceClass='HistoricalOfficial';trustClass='VerifiedHistorical';maintenanceState='Archived';metadataTransport='HTTPS';supportedVersions=@($records|ForEach-Object minecraftId|Sort-Object -Unique);candidates=@($records);sourceUrl=$script:MmtlLiteLoaderManifest;cacheStatus=$document.cacheStatus;retrievedAt=$document.fetchedAt;lastReviewed='2026-10-02T00:00:00Z';error=$error;provenance=@($document.sourceUrl)}
}

function Get-MmtlLiteLoaderCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Snapshot)
    @($Snapshot.candidates | Where-Object { [string]$_.minecraftId -ceq $MinecraftId })
}

function Read-MmtlHistoricalArchiveData {
    $path=Join-Path $PSScriptRoot '..\data\historical-archive-records.json'
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
}

function ConvertTo-MmtlArchiveCandidate {
    param([Parameter(Mandatory)]$Record)
    [pscustomobject][ordered]@{providerId=[string]$Record.providerId;loaderId=[string]$Record.loaderId;minecraftId=[string]$Record.minecraftId;sourceMinecraftId=[string]$Record.sourceMinecraftId;artifactFilename=[string]$Record.artifactFilename;archiveUrl=[string]$Record.archiveUrl;sha256=[string]$Record.sha256;hashAlgorithm='SHA256';integrity=Get-MmtlHistoricalIntegrityAssessment -Algorithm SHA256 -Hash ([string]$Record.sha256);author=[string]$Record.author;source=[string]$Record.source;sourceClass='VerifiedCommunityArchive';trustClass=[string]$Record.trust;transportSecurity='ArchivedSnapshot';maintenanceState='Archived';artifactType=[string]$Record.artifactType;retrievedAt=[string](Read-MmtlHistoricalArchiveData).retrievedAt;lastReviewed=[string](Read-MmtlHistoricalArchiveData).lastReviewed;downloadPermission='RequiresConfirmation';executePermission='Denied'}
}

function Get-MmtlModLoaderArchiveCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId)
    $data=Read-MmtlHistoricalArchiveData
    @($data.records|Where-Object{$_.providerId -eq 'ModLoader' -and $_.minecraftId -ceq $MinecraftId}|ForEach-Object{ConvertTo-MmtlArchiveCandidate -Record $_})
}

function Get-MmtlModLoaderMPArchiveCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId)
    $data=Read-MmtlHistoricalArchiveData
    @($data.records|Where-Object{$_.providerId -eq 'ModLoaderMP' -and $_.minecraftId -ceq $MinecraftId}|ForEach-Object{ConvertTo-MmtlArchiveCandidate -Record $_})
}

function Get-MmtlRiftCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId)
    $rift=(Read-MmtlHistoricalArchiveData).rift
    $candidates=[Collections.Generic.List[object]]::new()
    if($rift.original.minecraftId -ceq $MinecraftId){$item=$rift.original;$candidates.Add([pscustomobject][ordered]@{providerId='Rift';loaderId='Rift';minecraftId=[string]$item.minecraftId;loaderVersion=[string]$item.version;version=[string]$item.version;displayName='Rift';originality='Original';repository=[string]$item.repository;commit=[string]$item.commit;license=[string]$item.license;sourceClass=[string]$item.sourceClass;trustClass=[string]$item.trust;transportSecurity=[string]$item.transportSecurity;maintenanceState=[string]$item.maintenanceState;toolchain=[pscustomobject]@{id='ForgeGradle';version='2.3-SNAPSHOT';ecosystem='Rift'};buildJavaRequirement=[pscustomobject]@{major=8;confidence='Medium';source='Pinned Rift sourceCompatibility/targetCompatibility'};runtimeJavaRequirement=[pscustomobject]@{major=8;confidence='Low';source='Minecraft 1.13-era historical default; requires version metadata verification'};providerStatus='Available';availability='Available';downloadPermission='Granted';executePermission='RequiresConfirmation';provenance=@([pscustomobject]@{sourceUrl=[string]$item.repository;commit=[string]$item.commit;license=[string]$item.license;sourceType='archivedOfficial'})})}
    foreach($item in $rift.communityPorts|Where-Object minecraftId -CEQ $MinecraftId){$candidates.Add([pscustomobject][ordered]@{providerId='Rift';loaderId='Rift';minecraftId=[string]$item.minecraftId;loaderVersion=[string]$item.version;version=[string]$item.version;displayName=[string]$item.displayName;originality='CommunityPort';repository=[string]$item.repository;commit=[string]$item.commit;license=[string]$item.license;sourceClass=[string]$item.sourceClass;trustClass=[string]$item.trust;transportSecurity=[string]$item.transportSecurity;maintenanceState=[string]$item.maintenanceState;toolchain=[pscustomobject]@{id='ForgeGradle';version=$null;ecosystem='RiftCommunityPort'};buildJavaRequirement=[pscustomobject]@{major=8;confidence='Low';source='Pinned community source inspection pending'};runtimeJavaRequirement=[pscustomobject]@{major=$null;confidence='Unknown';source='Unverified'};providerStatus='Available';availability='Available';downloadPermission='RequiresConfirmation';executePermission='Denied';provenance=@([pscustomobject]@{sourceUrl=[string]$item.repository;commit=[string]$item.commit;license=[string]$item.license;sourceType='trustedArchive'})})}
    return @($candidates)
}

function New-MmtlJarModManualCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$ArtifactPath,[Parameter(Mandatory)][string]$PatchStrategy,[string]$Source='User supplied local artifact')
    $resolved=Resolve-Path -LiteralPath $ArtifactPath -ErrorAction Stop
    if((Get-Item -LiteralPath $resolved.Path).PSIsContainer){throw 'JARMOD_ARTIFACT_INVALID: expected a file.'}
    $hash=(Get-FileHash -LiteralPath $resolved.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    [pscustomobject][ordered]@{providerId='JarMod';loaderId='JarMod';minecraftId=$MinecraftId;availability='Manual';sourceClass='ManualArtifact';trustClass='UnverifiedHistorical';transportSecurity='LocalManual';maintenanceState='Unknown';artifactPath=$resolved.Path;sha256=$hash;integrity=Get-MmtlHistoricalIntegrityAssessment -Algorithm SHA256 -Hash $hash;source=$Source;patchStrategy=$PatchStrategy;downloadPermission='Denied';executePermission='Denied';patchPermission='RequiresConfirmation';provenance=@([pscustomobject]@{sourceType='manual';path=$resolved.Path;sha256=$hash;source=$Source})}
}

Export-ModuleMember -Function Get-MmtlLegacyFabricProviderSnapshot,Get-MmtlLegacyFabricReleaseCoverage,Get-MmtlLegacyFabricCandidates,Get-MmtlOrnitheProviderSnapshot,Get-MmtlOrnitheReleaseCoverage,Get-MmtlOrnitheCandidates,Get-MmtlLiteLoaderProviderSnapshot,Get-MmtlLiteLoaderCandidates,Get-MmtlModLoaderArchiveCandidates,Get-MmtlModLoaderMPArchiveCandidates,Get-MmtlRiftCandidates,New-MmtlJarModManualCandidate
