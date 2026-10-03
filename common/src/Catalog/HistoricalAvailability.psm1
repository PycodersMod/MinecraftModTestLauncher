Set-StrictMode -Version Latest
$script:historicalProviderModule=Import-Module (Join-Path $PSScriptRoot 'Providers/HistoricalProviders.psm1') -Force -PassThru

function Get-MmtlHistoricalLoaderAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[scriptblock]$HttpGet)
    $result=[Collections.Generic.List[object]]::new()
    $legacy=Get-MmtlLegacyFabricProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet
    $legacyOk=@($legacy.supportedVersions|Where-Object version -CEQ $MinecraftId).Count -gt 0
    $legacyQuery=if($legacyOk){Get-MmtlLegacyFabricCandidateQuery -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet}else{$null}
    $legacyCandidateCount=if($legacyQuery){@($legacyQuery.candidates).Count}else{0}
    $legacyStatus=if($legacyQuery){[string]$legacyQuery.providerStatus}elseif($legacy.providerStatus -in @('Available','Stale','OfflineCache')){$legacy.providerStatus}else{'Unavailable'}
    $legacyQueryError=if($legacyQuery -and $legacyQuery.PSObject.Properties['error']){[string]$legacyQuery.error}else{$null}
    $legacyNotes=@(@($legacy.error,$legacyQueryError)|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
    $legacyLastChecked=if($legacyQuery){$legacyQuery.validatedAt}elseif($legacy.documents.game){$legacy.documents.game.validatedAt}else{$null}
    $legacyAvailability=if($legacyCandidateCount){'Available'}elseif($legacyStatus -in @('Available','Stale','OfflineCache')){'Unavailable'}else{'Unknown'}
    $result.Add([pscustomobject]@{loaderId='LegacyFabric';availability=$legacyAvailability;reasonCode=if($legacyCandidateCount){'LOADER_CANDIDATES_FOUND'}elseif($legacyAvailability -eq 'Unknown'){'LEGACY_FABRIC_PROVIDER_OUTAGE'}else{'LOADER_CANDIDATE_NOT_LISTED'};providerStatus=$legacyStatus;sourceClass='ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS';maintenanceState='Active';cacheStatus=if($legacyQuery){$legacyQuery.cacheStatus}else{$legacy.cacheStatus};source=$legacy.sourceUrl;candidateCount=$legacyCandidateCount;lastChecked=$legacyLastChecked;notes=$legacyNotes})
    $ornithe=Get-MmtlOrnitheProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet
    $ornitheOk=@($ornithe.supportedVersions|Where-Object version -CEQ $MinecraftId).Count -gt 0
    $ornitheQuery=if($ornitheOk){Get-MmtlOrnitheCandidateQuery -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet}else{$null}
    $ornitheCandidateCount=if($ornitheQuery){@($ornitheQuery.candidates).Count}else{0}
    $ornitheStatus=if($ornitheQuery){[string]$ornitheQuery.providerStatus}elseif($ornithe.providerStatus -in @('Available','Stale','OfflineCache')){$ornithe.providerStatus}else{'Unavailable'}
    $ornitheQueryError=if($ornitheQuery -and $ornitheQuery.PSObject.Properties['error']){[string]$ornitheQuery.error}else{$null}
    $ornitheNotes=@(@($ornithe.error,$ornitheQueryError)|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
    $ornitheLastChecked=if($ornitheQuery){$ornitheQuery.validatedAt}elseif($ornithe.documents.game){$ornithe.documents.game.validatedAt}else{$null}
    $ornitheAvailability=if($ornitheCandidateCount){'Available'}elseif($ornitheStatus -in @('Available','Stale','OfflineCache')){'Unavailable'}else{'Unknown'}
    $result.Add([pscustomobject]@{loaderId='OrnitheLoader';availability=$ornitheAvailability;reasonCode=if($ornitheCandidateCount){'LOADER_CANDIDATES_FOUND'}elseif($ornitheAvailability -eq 'Unknown'){'ORNITHE_PROVIDER_OUTAGE'}else{'GAME_VERSION_HAS_NO_ORNITHE_LOADER'};providerStatus=$ornitheStatus;sourceClass='ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS';maintenanceState='Active';cacheStatus=if($ornitheQuery){$ornitheQuery.cacheStatus}else{$ornithe.cacheStatus};source=$ornithe.sourceUrl;candidateCount=$ornitheCandidateCount;lastChecked=$ornitheLastChecked;notes=$ornitheNotes})
    $lite=Get-MmtlLiteLoaderProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet
    $liteCandidates=@(Get-MmtlLiteLoaderCandidates -MinecraftId $MinecraftId -Snapshot $lite)
    $liteNotes=@(@($lite.error)|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
    $liteAvailability=if($liteCandidates.Count){'Available'}elseif($lite.providerStatus -in @('Available','Stale','OfflineCache')){'Unavailable'}else{'Unknown'}
    $result.Add([pscustomobject]@{loaderId='LiteLoader';availability=$liteAvailability;reasonCode=if($liteCandidates.Count){'LOADER_CANDIDATES_FOUND'}elseif($liteAvailability -eq 'Unknown'){'LITELOADER_MANIFEST_UNAVAILABLE'}else{'LITELOADER_VERSION_NOT_LISTED'};providerStatus=$lite.providerStatus;sourceClass='HistoricalOfficial';trustClass='VerifiedHistorical';transportSecurity='HTTPS';maintenanceState='Archived';cacheStatus=$lite.cacheStatus;source=$lite.sourceUrl;candidateCount=$liteCandidates.Count;lastChecked=$lite.validatedAt;notes=$liteNotes})
    foreach($loader in @('Rift','ModLoader','ModLoaderMP')){
        $items=@(switch($loader){'Rift'{Get-MmtlRiftCandidates -MinecraftId $MinecraftId}'ModLoader'{Get-MmtlModLoaderArchiveCandidates -MinecraftId $MinecraftId}'ModLoaderMP'{Get-MmtlModLoaderMPArchiveCandidates -MinecraftId $MinecraftId}})
        $sourceClass=if($items.Count){[string]$items[0].sourceClass}elseif($loader -eq 'Rift'){'HistoricalOfficial'}else{'VerifiedCommunityArchive'}
        $source=if($items.Count){if($items[0].PSObject.Properties['source']){[string]$items[0].source}else{[string]$items[0].repository}}elseif($loader -eq 'Rift'){'https://github.com/DimensionalDevelopment/Rift'}else{'https://mcarchive.net/mods/'+$loader.ToLowerInvariant()}
        $archiveData=& $script:historicalProviderModule { Read-MmtlHistoricalArchiveData }
        $availability=if($items.Count){'Available'}else{'Unknown'}
        $reasonNotes=if($items.Count){@()}else{@('精选归档中没有对应记录；缺少记录不能证明不兼容。')}
        $result.Add([pscustomobject]@{loaderId=$loader;availability=$availability;reasonCode=if($items.Count){'CURATED_ARCHIVE_RECORD_FOUND'}else{'HISTORICAL_SOURCE_NO_RECORD'};providerStatus=if($items.Count){'CuratedArchive'}else{'NoCuratedRecord'};sourceClass=$sourceClass;trustClass=if($items.Count){[string]$items[0].trustClass}else{'VerifiedHistorical'};transportSecurity='ArchivedSnapshot';maintenanceState='Archived';cacheStatus='Curated';source=$source;candidateCount=$items.Count;lastChecked=$archiveData.lastReviewed;notes=@($reasonNotes)})
    }
    $result.Add([pscustomobject]@{loaderId='JarMod';availability='Manual';reasonCode='MANUAL_USER_ARTIFACT_REQUIRED';providerStatus='ManualOnly';sourceClass='ManualArtifact';trustClass='UnverifiedHistorical';transportSecurity='LocalManual';maintenanceState='Unknown';cacheStatus='NotApplicable';source=$null;candidateCount=0;notes=@('需要用户提供本地制品；不会据此推断目录中的可用性。')})
    [pscustomobject][ordered]@{schemaVersion=1;minecraftId=$MinecraftId;scope='Historical';entries=@($result);generatedAt=[DateTimeOffset]::UtcNow.ToString('o')}
}

function Get-MmtlHistoricalProviderStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LoaderId,[Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline)
    if($LoaderId -eq 'LegacyFabric'){$snapshot=Get-MmtlLegacyFabricProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline;$coverage=Get-MmtlLegacyFabricReleaseCoverage -Catalog $Catalog -Snapshot $snapshot;return [pscustomobject]@{loaderId=$LoaderId;providerStatus=$snapshot.providerStatus;cacheStatus=$snapshot.cacheStatus;sourceClass='ActiveOfficial';trustClass='TrustedOfficial';maintenanceState='Active';transportSecurity='HTTPS';releaseCoverage=$coverage;provenance=$snapshot.provenance;error=$snapshot.error}}
    if($LoaderId -eq 'OrnitheLoader'){$snapshot=Get-MmtlOrnitheProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline;$coverage=Get-MmtlOrnitheReleaseCoverage -Catalog $Catalog -Snapshot $snapshot;return [pscustomobject]@{loaderId=$LoaderId;providerStatus=$snapshot.providerStatus;cacheStatus=$snapshot.cacheStatus;sourceClass='ActiveOfficial';trustClass='TrustedOfficial';maintenanceState='Active';transportSecurity='HTTPS';releaseCoverage=$coverage;provenance=$snapshot.provenance;error=$snapshot.error}}
    if($LoaderId -eq 'LiteLoader'){$snapshot=Get-MmtlLiteLoaderProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline;$releaseIds=@($Catalog.entries|Where-Object{$_.type -eq 'release' -and $_.id -cin @($snapshot.supportedVersions)}|ForEach-Object id);return [pscustomobject]@{loaderId=$LoaderId;providerStatus=$snapshot.providerStatus;cacheStatus=$snapshot.cacheStatus;sourceClass='HistoricalOfficial';trustClass='VerifiedHistorical';maintenanceState='Archived';transportSecurity='HTTPS';releaseCoverage=[pscustomobject]@{releaseCount=$releaseIds.Count;releaseIds=$releaseIds};provenance=$snapshot.provenance;error=$snapshot.error}}
    if($LoaderId -eq 'Rift'){$items=@(Get-MmtlRiftCandidates -MinecraftId '1.13')+@(Get-MmtlRiftCandidates -MinecraftId '1.13.2');$sourceClasses=@($items|ForEach-Object sourceClass|Select-Object -Unique);$sourceClass=if($sourceClasses.Count -eq 1){$sourceClasses[0]}elseif($sourceClasses.Count -gt 1){'Mixed'}else{'UnknownHistorical'};$provenance=@($items|ForEach-Object provenance);return [pscustomobject]@{loaderId=$LoaderId;providerStatus='CuratedArchive';cacheStatus='Curated';sourceClass=$sourceClass;sourceClasses=$sourceClasses;trustClass='VerifiedHistorical';maintenanceState='Archived';transportSecurity='ArchivedSnapshot';releaseCoverage=[pscustomobject]@{releaseCount=$items.Count;releaseIds=@($items|ForEach-Object minecraftId|Select-Object -Unique)};provenance=$provenance;error=$null}}
    if($LoaderId -in @('ModLoader','ModLoaderMP')){$ids=if($LoaderId -eq 'ModLoader'){@('1.0','1.2.5','1.4.7')}else{@('1.2.5','1.3.2')};$items=@(foreach($mc in $ids){if($LoaderId -eq 'ModLoader'){Get-MmtlModLoaderArchiveCandidates -MinecraftId $mc}else{Get-MmtlModLoaderMPArchiveCandidates -MinecraftId $mc}});return [pscustomobject]@{loaderId=$LoaderId;providerStatus='CuratedArchive';cacheStatus='Curated';sourceClass='VerifiedCommunityArchive';trustClass='VerifiedHistorical';maintenanceState='Archived';transportSecurity='ArchivedSnapshot';releaseCoverage=[pscustomobject]@{releaseCount=@($items|Select-Object -ExpandProperty minecraftId -Unique).Count;releaseIds=@($items|ForEach-Object minecraftId|Select-Object -Unique)};provenance=@($items|ForEach-Object source);error=$null}}
    if($LoaderId -eq 'JarMod'){return [pscustomobject]@{loaderId=$LoaderId;providerStatus='ManualOnly';cacheStatus='NotApplicable';sourceClass='ManualArtifact';trustClass='UnverifiedHistorical';maintenanceState='Unknown';transportSecurity='LocalManual';releaseCoverage=[pscustomobject]@{releaseCount=0;releaseIds=@()};provenance=@();error='Requires user-supplied artifact.'}}
    throw "未知的历史 Provider 标识：$LoaderId"
}
Export-ModuleMember -Function Get-MmtlHistoricalLoaderAvailability,Get-MmtlHistoricalProviderStatus
