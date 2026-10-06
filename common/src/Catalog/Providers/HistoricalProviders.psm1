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
        if ($value -isnot [array]) { throw '预期为 JSON 数组。' }
        return ,$value
    } catch { throw "HISTORICAL_METADATA_INVALID ($Context): $($_.Exception.Message)" }
}

function Get-MmtlHistoricalAggregateStatus {
    param([Parameter(Mandatory)][object[]]$Documents)
    $available = @($Documents | Where-Object { $_.providerStatus -eq 'Available' }).Count
    $stale = @($Documents | Where-Object { $_.providerStatus -eq 'Stale' }).Count
    $offline = @($Documents | Where-Object { $_.cacheStatus -eq 'OfflineCache' }).Count
    if ($offline -eq $Documents.Count) { return 'OfflineCache' }
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
    $hasGame=$parsed.Contains('game');$supported = if($hasGame){@($parsed.game | ForEach-Object { [pscustomobject]@{version=[string]$_.version;stable=[bool]$_.stable} } | Sort-Object version -Unique)}else{@()}
    [pscustomobject][ordered]@{
        providerId='LegacyFabric';loaderId='LegacyFabric';providerStatus=$status
        availability=if($status -in @('Available','OfflineCache','Stale','Degraded')){'Available'}else{'Unknown'}
        sourceClass='ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS';maintenanceState='Active'
        supportedVersions=$supported;loaderVersions=if($parsed.Contains('loader')){@($parsed.loader)}else{@()};intermediaryMappings=if($parsed.Contains('intermediary')){@($parsed.intermediary)}else{@()};yarnMappings=if($parsed.Contains('yarn')){@($parsed.yarn)}else{@()}
        cacheStatus=if($documents.Contains('game')){[string]$documents.game.cacheStatus}else{'Unavailable'};sourceUrl=$resources.game
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

function Get-MmtlLegacyFabricCandidateQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $encoded = [Uri]::EscapeDataString($MinecraftId)
    $uri = "$script:MmtlLegacyFabricBase/loader/$encoded"
    $document = Get-MmtlHistoricalMetadataDocument -ProviderId LegacyFabric -CacheKey "v2-loader-$MinecraftId" -Uri $uri -AllowedHosts $script:MmtlLegacyFabricHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    if ($document.providerStatus -notin @('Available','Stale')) { return [pscustomobject]@{providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;validatedAt=$document.validatedAt;error=$document.error;candidates=@()} }
    try { $records = ConvertFrom-MmtlHistoricalJsonArray -Content $document.content -Context "Legacy Fabric $MinecraftId 版候选项" }
    catch { return [pscustomobject]@{providerStatus='Degraded';cacheStatus=$document.cacheStatus;validatedAt=$document.validatedAt;error=$_.Exception.Message;candidates=@()} }
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
    [pscustomobject]@{providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;validatedAt=$document.validatedAt;error=$null;candidates=@($candidates)}
}

function Get-MmtlLegacyFabricCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $query=Get-MmtlLegacyFabricCandidateQuery -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    return @($query.candidates)
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
    $hasGame=$parsed.Contains('game');$hasLoader=$parsed.Contains('loader')
    [pscustomobject][ordered]@{providerId='Ornithe';loaderId='OrnitheLoader';providerStatus=$status;availability=if($hasGame){'Available'}else{'Unknown'};sourceClass='ActiveOfficial';trustClass='TrustedOfficial';maintenanceState='Active';transportSecurity='HTTPS';supportedVersions=if($hasGame){@($parsed.game|ForEach-Object{$environment=$null;if($_.PSObject.Properties['environment']){$environment=$_.environment};[pscustomobject]@{version=[string]$_.version;stable=[bool]$_.stable;environment=$environment}})}else{@()};loaderVersions=if($hasLoader){@($parsed.loader)}else{@()};cacheStatus=if($hasGame){[string]$documents.game.cacheStatus}else{'Unavailable'};sourceUrl=$uris.game;documents=[pscustomobject]$documents;provenance=@($documents.Values|Where-Object{$_.providerStatus -in @('Available','Stale')}|ForEach-Object{[pscustomobject]@{sourceUrl=$_.sourceUrl;fetchedAt=$_.fetchedAt;validatedAt=$_.validatedAt;localHash=$_.localHash;cacheStatus=$_.cacheStatus}});error=if($errors.Count){$errors -join '; '}else{$null}}
}

function Get-MmtlOrnitheReleaseCoverage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)]$Snapshot)
    $catalogEntries=@($Catalog.entries|Where-Object type -eq 'release');$supported=@($Snapshot.supportedVersions|ForEach-Object{[string]$_.version});$matched=@($catalogEntries|Where-Object{$_.id -cin $supported})
    $ordered=if($matched.Count -gt 1 -and $matched[0].PSObject.Properties['releaseTime']){@($matched|Sort-Object{[DateTimeOffset]::Parse([string]$_.releaseTime)})}else{@($matched)}
    [pscustomobject]@{providerId='Ornithe';releaseCount=$matched.Count;earliestRelease=if($ordered.Count){[string]$ordered[0].id}else{$null};latestRelease=if($ordered.Count){[string]$ordered[-1].id}else{$null};releaseIds=@($matched|ForEach-Object{[string]$_.id});catalogHash=if($Catalog.PSObject.Properties['manifestHash']){$Catalog.manifestHash}else{$null};sourceUrl=$Snapshot.sourceUrl;providerStatus=$Snapshot.providerStatus}
}

function Get-MmtlOrnitheCandidateQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $uri="$script:MmtlOrnitheBase/loader/$([Uri]::EscapeDataString($MinecraftId))"
    $document=Get-MmtlHistoricalMetadataDocument -ProviderId Ornithe -CacheKey "v2-loader-$MinecraftId" -Uri $uri -AllowedHosts $script:MmtlOrnitheHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    if($document.providerStatus -notin @('Available','Stale')){return [pscustomobject]@{providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;validatedAt=$document.validatedAt;error=$document.error;candidates=@()}}
    try{$records=ConvertFrom-MmtlHistoricalJsonArray -Content $document.content -Context "Ornithe candidates $MinecraftId"}catch{return [pscustomobject]@{providerStatus='Degraded';cacheStatus=$document.cacheStatus;validatedAt=$document.validatedAt;error=$_.Exception.Message;candidates=@()}};$candidates=[Collections.Generic.List[object]]::new()
    foreach($record in $records){if(-not $record.loader){continue};$version=[string]$record.loader.version;if(-not $version){continue};$maven=$null;if($record.loader.PSObject.Properties['maven']){$maven=[string]$record.loader.maven};$calamus=$null;if($record.PSObject.Properties['calamus']){$calamus=$record.calamus};$launcherMeta=$null;if($record.PSObject.Properties['launcherMeta']){$launcherMeta=$record.launcherMeta};$candidates.Add([pscustomobject][ordered]@{loaderId='OrnitheLoader';minecraftId=$MinecraftId;loaderVersion=$version;version=$version;stable=[bool]$record.loader.stable;artifact=[pscustomobject]@{coordinate=$maven};mappingContext=[pscustomobject]@{calamus=$calamus;feather=$null};launcherMeta=$launcherMeta;sourceClass='ActiveOfficial';trustClass='TrustedOfficial';maintenanceState='Active';transportSecurity='HTTPS';toolchain=[pscustomobject]@{id='Ploceus';version=$null;ecosystem='Ornithe'};source=$document.sourceUrl;providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;provenance=@([pscustomobject]@{sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;cacheStatus=$document.cacheStatus});downloadPermission='Granted';executePermission='RequiresConfirmation'})}
    [pscustomobject]@{providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;validatedAt=$document.validatedAt;error=$null;candidates=@($candidates)}
}

function Get-MmtlOrnitheCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $query=Get-MmtlOrnitheCandidateQuery -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    return @($query.candidates)
}

function Get-MmtlLiteLoaderProviderSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $document=Get-MmtlHistoricalMetadataDocument -ProviderId LiteLoader -CacheKey 'official-versions-json' -Uri $script:MmtlLiteLoaderManifest -AllowedHosts $script:MmtlLiteLoaderHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $records=[Collections.Generic.List[object]]::new();$error=$document.error
    if($document.providerStatus -in @('Available','Stale')){
        try{
            $manifest=ConvertFrom-Json -InputObject $document.content -ErrorAction Stop
            if(-not $manifest.versions){throw 'LiteLoader manifest 不包含版本列表。'}
            foreach($versionProperty in $manifest.versions.PSObject.Properties){
                $mcId=[string]$versionProperty.Name;$entry=$versionProperty.Value
                foreach($channelName in @('artefacts','artifacts','snapshots')){
                    $channelProperty=$entry.PSObject.Properties[$channelName];if(-not $channelProperty){continue};$channel=$channelProperty.Value;if(-not $channel){continue}
                    $artifactProperty=$channel.PSObject.Properties['com.mumfrey:liteloader'];if(-not $artifactProperty){continue}
                    foreach($build in $artifactProperty.Value.PSObject.Properties){
                        if($build.Name -eq 'latest'){continue};$detail=$build.Value;if(-not $detail.file){continue}
                        $repoUrl=if($entry.PSObject.Properties['repo'] -and $entry.repo -and $entry.repo.PSObject.Properties['url']){[string]$entry.repo.url}else{$null};$parsed=$null;$transport=if($repoUrl -and [Uri]::TryCreate($repoUrl,[UriKind]::Absolute,[ref]$parsed) -and $parsed.Scheme -eq 'http'){'HTTPOnly'}elseif($parsed -and $parsed.Scheme -eq 'https'){'HTTPS'}else{'Unknown'}
                        $dev=if($entry.PSObject.Properties['dev']){$entry.dev}else{$null};$fgVersion=if($dev -and $dev.PSObject.Properties['fgVersion']){[string]$dev.fgVersion}else{$null};$mappings=if($dev -and $dev.PSObject.Properties['mappings']){[string]$dev.mappings}else{$null};$manifestUpdated=if($manifest.PSObject.Properties['meta'] -and $manifest.meta -and $manifest.meta.PSObject.Properties['updated']){[string]$manifest.meta.updated}else{$null}
                        $integrity=Get-MmtlHistoricalIntegrityAssessment -Algorithm MD5 -Hash ([string]$detail.md5)
                        $records.Add([pscustomobject][ordered]@{loaderId='LiteLoader';minecraftId=$mcId;loaderVersion=[string]$detail.version;version=[string]$detail.version;channel=$channelName;artifact=[pscustomobject]@{filename=[string]$detail.file;repositoryUrl=$repoUrl;coordinate="com.mumfrey:liteloader:$($detail.version)"};sourceClass='HistoricalOfficial';trustClass='VerifiedHistorical';maintenanceState='Archived';metadataTransport='HTTPS';artifactTransport=$transport;integrity=$integrity;toolchain=[pscustomobject]@{id='ForgeGradle';version=$fgVersion;ecosystem='LiteLoader'};mappingContext=[pscustomobject]@{mappings=$mappings};sourceUrl=$script:MmtlLiteLoaderManifest;providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;downloadPermission='RequiresConfirmation';executePermission='Denied';provenance=@([pscustomobject]@{sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;cacheStatus=$document.cacheStatus;manifestUpdated=$manifestUpdated})})
                    }
                }
            }
        }catch{$error=$_.Exception.Message;$records.Clear()}
    }
    [pscustomobject][ordered]@{providerId='LiteLoader';loaderId='LiteLoader';providerStatus=if($error -and $document.providerStatus -eq 'Available'){'Degraded'}else{$document.providerStatus};availability=if($records.Count){'Available'}else{'Unknown'};sourceClass='HistoricalOfficial';trustClass='VerifiedHistorical';maintenanceState='Archived';metadataTransport='HTTPS';supportedVersions=@($records|ForEach-Object minecraftId|Sort-Object -Unique);candidates=@($records);sourceUrl=$script:MmtlLiteLoaderManifest;cacheStatus=$document.cacheStatus;retrievedAt=$document.fetchedAt;validatedAt=$document.validatedAt;lastReviewed='2026-10-02T00:00:00Z';error=$error;provenance=@($document.sourceUrl)}
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
    $artifactTransport = if ($Record.PSObject.Properties['artifactTransport']) { [string]$Record.artifactTransport } else { 'Unknown' }
    $downloadPermission = if ($artifactTransport -eq 'HTTPOnly') { 'Denied' } else { 'RequiresConfirmation' }
    $integrity = Get-MmtlHistoricalIntegrityAssessment -Algorithm SHA256 -Hash ([string]$Record.sha256)
    $integrity.downloadPermission = $downloadPermission
    $integrity.executePermission = 'Denied'
    [pscustomobject][ordered]@{
        providerId=[string]$Record.providerId;loaderId=[string]$Record.loaderId;minecraftId=[string]$Record.minecraftId;sourceMinecraftId=[string]$Record.sourceMinecraftId
        loaderVersion=[IO.Path]::GetFileNameWithoutExtension([string]$Record.artifactFilename);versionLabelSource='SOURCE_FILENAME'
        artifactFilename=[string]$Record.artifactFilename;artifactUrl=if($Record.PSObject.Properties['artifactUrl']){[string]$Record.artifactUrl}else{$null}
        artifactTransport=$artifactTransport;artifactFormat=if($Record.PSObject.Properties['artifactFormat']){[string]$Record.artifactFormat}else{$null}
        archiveUrl=[string]$Record.archiveUrl;sha256=[string]$Record.sha256;hashAlgorithm='SHA256'
        hashProvenance=if($Record.PSObject.Properties['hashProvenance']){[string]$Record.hashProvenance}else{'SourceDeclared'}
        hashVerifiedLocally=if($Record.PSObject.Properties['hashVerifiedLocally']){[bool]$Record.hashVerifiedLocally}else{$false}
        sourceSnapshotHash=if($Record.PSObject.Properties['sourceSnapshotHash']){[string]$Record.sourceSnapshotHash}else{$null}
        integrity=$integrity;author=[string]$Record.author;source=[string]$Record.source
        sourceClass='VerifiedCommunityArchive';trustClass=[string]$Record.trust;transportSecurity='ArchivedSnapshot';maintenanceState='Archived';artifactType=[string]$Record.artifactType
        retrievedAt=[string](Read-MmtlHistoricalArchiveData).retrievedAt;lastReviewed=[string](Read-MmtlHistoricalArchiveData).lastReviewed
        downloadPermission=$downloadPermission;executePermission='Denied'
    }
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
    if($rift.original.minecraftId -ceq $MinecraftId){$item=$rift.original;$candidates.Add([pscustomobject][ordered]@{providerId='Rift';loaderId='Rift';minecraftId=[string]$item.minecraftId;loaderVersion=[string]$item.version;version=[string]$item.version;displayName='Rift';originality='Original';repository=[string]$item.repository;commit=[string]$item.commit;license=[string]$item.license;sourceClass=[string]$item.sourceClass;trustClass=[string]$item.trust;transportSecurity=[string]$item.transportSecurity;maintenanceState=[string]$item.maintenanceState;toolchain=[pscustomobject]@{id='ForgeGradle';version='2.3-SNAPSHOT';ecosystem='Rift'};buildJavaRequirement=[pscustomobject]@{major=8;confidence='High';source='Rift 固定版本 build.gradle 的 sourceCompatibility = 1.8'};runtimeJavaRequirement=[pscustomobject]@{major=$null;confidence='Unknown';source='Minecraft 1.13 没有可用的权威逐版本 javaVersion 元数据'};providerStatus='Available';availability='Available';downloadPermission='Granted';executePermission='RequiresConfirmation';provenance=@([pscustomobject]@{sourceUrl=[string]$item.repository;commit=[string]$item.commit;license=[string]$item.license;sourceType='archivedOfficial'})})}
    foreach($item in $rift.communityPorts|Where-Object minecraftId -CEQ $MinecraftId){$candidates.Add([pscustomobject][ordered]@{providerId='Rift';loaderId='Rift';minecraftId=[string]$item.minecraftId;loaderVersion=[string]$item.version;version=[string]$item.version;displayName=[string]$item.displayName;originality='CommunityPort';repository=[string]$item.repository;commit=[string]$item.commit;license=[string]$item.license;sourceClass=[string]$item.sourceClass;trustClass=[string]$item.trust;transportSecurity=[string]$item.transportSecurity;maintenanceState=[string]$item.maintenanceState;toolchain=[pscustomobject]@{id='ForgeGradle';version=$null;ecosystem='RiftCommunityPort'};buildJavaRequirement=[pscustomobject]@{major=8;confidence='Low';source='社区源码已固定，等待检查'};runtimeJavaRequirement=[pscustomobject]@{major=$null;confidence='Unknown';source='Unverified'};providerStatus='Available';availability='Available';downloadPermission='RequiresConfirmation';executePermission='Denied';provenance=@([pscustomobject]@{sourceUrl=[string]$item.repository;commit=[string]$item.commit;license=[string]$item.license;sourceType='trustedArchive'})})}
    return @($candidates)
}

function New-MmtlJarModManualCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$ArtifactPath,[Parameter(Mandatory)][string]$PatchStrategy,[string]$Source='用户提供的本地制品')
    $resolved=Resolve-Path -LiteralPath $ArtifactPath -ErrorAction Stop
    if((Get-Item -LiteralPath $resolved.Path).PSIsContainer){throw 'JARMOD_ARTIFACT_INVALID: 预期路径为文件。'}
    $hash=(Get-FileHash -LiteralPath $resolved.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $retrievedAt=[DateTimeOffset]::new((Get-Item -LiteralPath $resolved.Path).LastWriteTimeUtc)
    [pscustomobject][ordered]@{providerId='JarMod';loaderId='JarMod';minecraftId=$MinecraftId;availability='Manual';sourceClass='ManualArtifact';trustClass='UnverifiedHistorical';transportSecurity='LocalManual';maintenanceState='Unknown';artifactPath=$resolved.Path;sha256=$hash;integrity=Get-MmtlHistoricalIntegrityAssessment -Algorithm SHA256 -Hash $hash;source=$Source;patchStrategy=$PatchStrategy;downloadPermission='Denied';executePermission='Denied';patchPermission='RequiresConfirmation';retrievedAt=$retrievedAt.ToUniversalTime().ToString('o');lastReviewed=[DateTimeOffset]::UtcNow.ToString('o');provenance=@([pscustomobject]@{sourceType='manual';path=$resolved.Path;sha256=$hash;source=$Source})}
}

Export-ModuleMember -Function Get-MmtlLegacyFabricProviderSnapshot,Get-MmtlLegacyFabricReleaseCoverage,Get-MmtlLegacyFabricCandidateQuery,Get-MmtlLegacyFabricCandidates,Get-MmtlOrnitheProviderSnapshot,Get-MmtlOrnitheReleaseCoverage,Get-MmtlOrnitheCandidateQuery,Get-MmtlOrnitheCandidates,Get-MmtlLiteLoaderProviderSnapshot,Get-MmtlLiteLoaderCandidates,Get-MmtlModLoaderArchiveCandidates,Get-MmtlModLoaderMPArchiveCandidates,Get-MmtlRiftCandidates,New-MmtlJarModManualCandidate
