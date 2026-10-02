Set-StrictMode -Version Latest

$script:MmtlCoverageLoaders=[ordered]@{
    Mainstream=@('Forge','Fabric','NeoForge','Quilt')
    Historical=@('LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP')
    Manual=@('JarMod')
}
$script:MmtlCoverageReasonCodes=@(
    'UPSTREAM_CANDIDATE_FOUND','NO_UPSTREAM_CANDIDATE','PROVIDER_UNAVAILABLE','PROVIDER_TIMEOUT',
    'OFFLINE_CACHE_MISSING','HISTORICAL_SOURCE_NO_RECORD','COMMUNITY_PORT_ONLY','MANUAL_ARTIFACT_REQUIRED',
    'HTTP_ONLY_ARTIFACT','UNMAPPED_UPSTREAM_VERSION','AMBIGUOUS_VERSION_MAPPING','PROVIDER_RECORD_MISSING',
    'AVAILABLE_WITHOUT_CANDIDATE','GAME_VERSION_SUPPORTED_CANDIDATE_NOT_PROBED','GAME_VERSION_HAS_NO_ORNITHE_LOADER',
    'LEGACY_FABRIC_PROVIDER_OUTAGE','ORNITHE_PROVIDER_OUTAGE','LITELOADER_VERSION_NOT_LISTED',
    'LITELOADER_MANIFEST_UNAVAILABLE','CURATED_ARCHIVE_RECORD_FOUND','MANUAL_USER_ARTIFACT_REQUIRED',
    'CATALOG_RELEASE_ROW_COUNT_MISMATCH','UNKNOWN_REASON_CODE','UNKNOWN_WITHOUT_REASON','AVAILABLE_WITHOUT_CANDIDATE',
    'UNKNOWN_WITHOUT_NOTES','STATE_PROVENANCE_MISSING','STATE_CHECK_TIME_MISSING','UNSAFE_TRUST_ESCALATION','ORNITHE_LOADER_CANDIDATE_NOT_PROBED',
    'COVERAGE_INCONSISTENCY','CANDIDATE_PROBE_FAILED','MOJANG_RUNTIME_METADATA_UNAVAILABLE','STATE_SOURCE_MISSING'
)

function Get-MmtlCoverageProperty {
    param($InputObject,[Parameter(Mandatory)][string]$Name)
    if($null -eq $InputObject){return $null}
    if($InputObject -is [Collections.IDictionary]){foreach($key in $InputObject.Keys){if([string]$key -ieq $Name){return $InputObject[$key]}};return $null}
    $property=$InputObject.PSObject.Properties[$Name];if($property){return $property.Value};$null
}

function ConvertTo-MmtlCoverageTimestamp {
    param($Value)
    if($null -eq $Value){return $null}
    if($Value -is [DateTimeOffset]){return $Value.ToUniversalTime().ToString('o')}
    if($Value -is [DateTime]){return ([DateTimeOffset]$Value).ToUniversalTime().ToString('o')}
    $parsed=[DateTimeOffset]::MinValue
    if([DateTimeOffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)){return $parsed.ToUniversalTime().ToString('o')}
    $null
}

function Get-MmtlCoverageInputState {
    param([Parameter(Mandatory)]$ProviderInputs,[Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$LoaderId)
    $byRelease=Get-MmtlCoverageProperty -InputObject $ProviderInputs -Name 'byRelease'
    $releaseStates=Get-MmtlCoverageProperty -InputObject $byRelease -Name $MinecraftId
    $state=Get-MmtlCoverageProperty -InputObject $releaseStates -Name $LoaderId
    if($null -ne $state){return $state}
    $providerStatuses=Get-MmtlCoverageProperty -InputObject $ProviderInputs -Name 'providerStatuses'
    $provider=Get-MmtlCoverageProperty -InputObject $providerStatuses -Name $LoaderId
    [pscustomobject]@{availability='Unknown';reasonCode='PROVIDER_RECORD_MISSING';source=Get-MmtlCoverageProperty -InputObject $provider -Name 'source';sourceClass=Get-MmtlCoverageProperty -InputObject $provider -Name 'sourceClass';cacheStatus=if(Get-MmtlCoverageProperty -InputObject $provider -Name 'cacheStatus'){Get-MmtlCoverageProperty -InputObject $provider -Name 'cacheStatus'}else{'Unavailable'};lastChecked=Get-MmtlCoverageProperty -InputObject $provider -Name 'lastChecked';notes=@("Provider input has no record for $LoaderId on Minecraft $MinecraftId.");candidateCount=0;candidates=@()}
}

function ConvertTo-MmtlCoverageState {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$LoaderId)
    $availability=[string](Get-MmtlCoverageProperty -InputObject $State -Name 'availability')
    if($availability -notin @('Available','Unavailable','Unknown','Manual','Degraded')){$availability='Unknown'}
    $reasonCode=[string](Get-MmtlCoverageProperty -InputObject $State -Name 'reasonCode')
    $notes=@(Get-MmtlCoverageProperty -InputObject $State -Name 'notes'|Where-Object{$null -ne $_}|ForEach-Object{[string]$_})
    if($availability -eq 'Unknown' -and [string]::IsNullOrWhiteSpace($reasonCode)){$reasonCode='PROVIDER_RECORD_MISSING';$notes+= 'Unknown state had no reason code.'}
    if($reasonCode -notmatch '^[A-Z][A-Z0-9_]+$'){$reasonCode='PROVIDER_RECORD_MISSING';$notes+='Invalid or missing reason code normalized during audit.'}
    [pscustomobject][ordered]@{
        availability=$availability
        reasonCode=$reasonCode
        source=Get-MmtlCoverageProperty -InputObject $State -Name 'source'
        sourceClass=if(Get-MmtlCoverageProperty -InputObject $State -Name 'sourceClass'){[string](Get-MmtlCoverageProperty -InputObject $State -Name 'sourceClass')}else{'UnknownHistorical'}
        cacheStatus=if(Get-MmtlCoverageProperty -InputObject $State -Name 'cacheStatus'){[string](Get-MmtlCoverageProperty -InputObject $State -Name 'cacheStatus')}else{'Unavailable'}
        lastChecked=ConvertTo-MmtlCoverageTimestamp (Get-MmtlCoverageProperty -InputObject $State -Name 'lastChecked')
        notes=$notes
        candidateCount=Get-MmtlCoverageProperty -InputObject $State -Name 'candidateCount'
        candidates=@(Get-MmtlCoverageProperty -InputObject $State -Name 'candidates')
        candidateProbeStatus=if(Get-MmtlCoverageProperty -InputObject $State -Name 'candidateProbeStatus'){[string](Get-MmtlCoverageProperty -InputObject $State -Name 'candidateProbeStatus')}else{'NotProbed'}
        provenance=@(Get-MmtlCoverageProperty -InputObject $State -Name 'provenance')
        trustClass=Get-MmtlCoverageProperty -InputObject $State -Name 'trustClass'
        transportSecurity=Get-MmtlCoverageProperty -InputObject $State -Name 'transportSecurity'
    }
}

function New-MmtlCoverageSourceProvenance {
    param($Source,[string]$LastChecked,[string]$CacheStatus,[string]$SourceClass)
    if([string]::IsNullOrWhiteSpace([string]$Source)){return @()}
    @([pscustomobject]@{source=[string]$Source;lastChecked=ConvertTo-MmtlCoverageTimestamp $LastChecked;cacheStatus=$CacheStatus;sourceClass=$SourceClass})
}

function Get-MmtlCoverageCandidateProvenance {
    param([object[]]$Candidates)
    $items=[Collections.Generic.List[object]]::new()
    foreach($candidate in $Candidates){
        $existing=Get-MmtlCoverageProperty -InputObject $candidate -Name 'provenance'
        if($existing){foreach($item in @($existing)){if($item -is [string]){$items.Add([pscustomobject]@{source=[string]$item})}elseif($item){$items.Add($item)}};continue}
        $source=Get-MmtlCoverageProperty -InputObject $candidate -Name 'source';if(-not $source){$source=Get-MmtlCoverageProperty -InputObject $candidate -Name 'repository'}
        $items.Add([pscustomobject]@{source=$source;sourceClass=Get-MmtlCoverageProperty -InputObject $candidate -Name 'sourceClass'})
    }
    @($items)
}

function Update-MmtlCoverageMetrics {
    param([Parameter(Mandatory)]$Audit)
    $allLoaders=@($script:MmtlCoverageLoaders.Mainstream)+@($script:MmtlCoverageLoaders.Historical)+@($script:MmtlCoverageLoaders.Manual)
    $stateCounts=[ordered]@{Available=0;Unavailable=0;Unknown=0;Manual=0;Degraded=0}
    $orderedReleases=@($Audit.releases|Sort-Object releaseTime,minecraftId)
    foreach($loaderId in $allLoaders){
        $metric=$Audit.summary.perLoader.$loaderId
        foreach($name in @('Available','Unavailable','Unknown','Manual','Degraded')){$metric.$name=0}
        $metric.candidateCount=0;$metric.candidateProbed=0;$metric.firstAvailableRelease=$null;$metric.lastAvailableRelease=$null
        $availableRanges=[Collections.Generic.List[object]]::new();$gapRanges=[Collections.Generic.List[object]]::new();$runIds=[Collections.Generic.List[string]]::new();$runState=$null;$runReason=$null
        foreach($release in $orderedReleases){
            $group=if($script:MmtlCoverageLoaders.Mainstream -contains $loaderId){$release.mainstreamLoaders}elseif($script:MmtlCoverageLoaders.Historical -contains $loaderId){$release.historicalLoaders}else{$release.manualModes}
            $state=Get-MmtlCoverageProperty -InputObject $group -Name $loaderId;$availability=[string]$state.availability;$metric.$availability++;$stateCounts[$availability]++
            if($null -ne $state.candidateCount){$metric.candidateCount+=[int]$state.candidateCount};if($state.candidateProbeStatus -in @('Passed','Failed')){$metric.candidateProbed++}
            if($availability -eq 'Available'){if(-not $metric.firstAvailableRelease){$metric.firstAvailableRelease=[string]$release.minecraftId};$metric.lastAvailableRelease=[string]$release.minecraftId}
            $rangeKey=if($availability -eq 'Available'){'Available'}else{"$availability|$($state.reasonCode)"}
            if($null -ne $runState -and $rangeKey -cne $runState){$range=[pscustomobject]@{status=($runState -split '\|')[0];reasonCode=if($runState.Contains('|')){($runState -split '\|',2)[1]}else{$null};from=$runIds[0];to=$runIds[-1];count=$runIds.Count;minecraftIds=@($runIds)};if($range.status -eq 'Available'){$availableRanges.Add($range)}else{$gapRanges.Add($range)};$runIds.Clear()}
            $runState=$rangeKey;$runIds.Add([string]$release.minecraftId)
        }
        if($runIds.Count){$range=[pscustomobject]@{status=($runState -split '\|')[0];reasonCode=if($runState.Contains('|')){($runState -split '\|',2)[1]}else{$null};from=$runIds[0];to=$runIds[-1];count=$runIds.Count;minecraftIds=@($runIds)};if($range.status -eq 'Available'){$availableRanges.Add($range)}else{$gapRanges.Add($range)}}
        $metric.continuousRanges=@($availableRanges);$metric.gaps=@($gapRanges)
    }
    $Audit.summary.stateCounts=[pscustomobject]$stateCounts
}

function New-MmtlLiveCoverageProviderInputs {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline)
    Import-Module (Join-Path $PSScriptRoot '..\Catalog\LoaderAvailability.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Catalog\HistoricalAvailability.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Catalog\Providers\HistoricalProviders.psm1') -Force
    $index=$null
    try{$index=Get-MmtlLoaderAvailabilityIndex -Catalog $Catalog -RuntimeRoot $RuntimeRoot -Offline:$Offline}catch{$index=$null}
    $neoForgeSnapshot=$null;$neoForgeUnmapped=@();$neoForgeAuditError=$null
    try{Import-Module (Join-Path $PSScriptRoot '..\Catalog\Providers\NeoForge.psm1') -Force;$neoForgeSnapshot=Get-MmtlNeoForgeProviderSnapshot -Catalog $Catalog -RuntimeRoot $RuntimeRoot -Offline:$Offline;$neoForgeUnmapped=@(Get-MmtlNeoForgeUnmappedVersions -Snapshot $neoForgeSnapshot)}catch{$neoForgeAuditError=$_.Exception.Message}
    $mainIds=@('Forge','Fabric','NeoForge','Quilt')
    $providerStatuses=[ordered]@{}
    foreach($loaderId in $mainIds){
        $status=if($index){Get-MmtlCoverageProperty -InputObject $index.providerStatuses -Name $loaderId}else{$null}
        $notes=if($status -and $status.error){@([string]$status.error)}elseif(-not $index){@('Mainstream availability index could not be loaded.')}else{@()};if($loaderId -eq 'NeoForge' -and $neoForgeUnmapped.Count){$notes+=@("Unmapped NeoForge upstream versions: $(@($neoForgeUnmapped|ForEach-Object upstreamVersion) -join ', ')")};if($loaderId -eq 'NeoForge' -and $neoForgeAuditError){$notes+=@("NeoForge unmapped-version audit failed: $neoForgeAuditError")}
        $providerStatuses[$loaderId]=[pscustomobject]@{status=if($status){$status.status}else{'Unavailable'};source=if($status){$status.source}else{$null};sourceClass='ActiveOfficial';cacheStatus=if($status){$status.cacheStatus}else{'Unavailable'};lastChecked=if($status){$status.lastChecked}else{$null};notes=$notes;unmappedVersions=if($loaderId -eq 'NeoForge'){$neoForgeUnmapped}else{@()}}
    }
    $legacy=$null;$ornithe=$null;$lite=$null
    try{$legacy=Get-MmtlLegacyFabricProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline}catch{}
    try{$ornithe=Get-MmtlOrnitheProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline}catch{}
    try{$lite=Get-MmtlLiteLoaderProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline}catch{}
    foreach($pair in @(@{Id='LegacyFabric';Snapshot=$legacy},@{Id='OrnitheLoader';Snapshot=$ornithe},@{Id='LiteLoader';Snapshot=$lite})){
        $snapshot=$pair.Snapshot
        $providerStatuses[$pair.Id]=[pscustomobject]@{status=if($snapshot){$snapshot.providerStatus}else{'Unavailable'};source=if($snapshot){$snapshot.sourceUrl}else{$null};sourceClass=if($pair.Id -eq 'LiteLoader'){'HistoricalOfficial'}else{'ActiveOfficial'};cacheStatus=if($snapshot){$snapshot.cacheStatus}else{'Unavailable'};lastChecked=if($snapshot){if($snapshot.PSObject.Properties['validatedAt']){$snapshot.validatedAt}else{$null}}else{$null};notes=if($snapshot -and $snapshot.error){@([string]$snapshot.error)}elseif(-not $snapshot){@("$($pair.Id) provider snapshot unavailable.")}else{@()}}
    }
    foreach($loaderId in @('Rift','ModLoader','ModLoaderMP','JarMod')){$providerStatuses[$loaderId]=[pscustomobject]@{status=if($loaderId -eq 'JarMod'){'ManualOnly'}else{'CuratedArchive'};source=if($loaderId -eq 'Rift'){'https://github.com/DimensionalDevelopment/Rift'}elseif($loaderId -eq 'JarMod'){$null}else{"https://mcarchive.net/mods/$($loaderId.ToLowerInvariant())"};sourceClass=if($loaderId -eq 'JarMod'){'ManualArtifact'}elseif($loaderId -eq 'Rift'){'HistoricalOfficial'}else{'VerifiedCommunityArchive'};cacheStatus=if($loaderId -eq 'JarMod'){'NotApplicable'}else{'Curated'};lastChecked='2026-10-02T00:00:00Z';notes=@()}}
    $byRelease=[ordered]@{}
    $catalogReleaseIds=@($Catalog.entries|Where-Object type -CEQ 'release'|ForEach-Object{[string]$_.id})
    foreach($entry in $Catalog.entries|Where-Object type -CEQ 'release'){
        $minecraftId=[string]$entry.id;$states=[ordered]@{}
        foreach($loaderId in $mainIds){
            $raw=$null
            if($index){$indexed=@($index.entries|Where-Object{$_.minecraftId -ceq $minecraftId}|Select-Object -First 1);if($indexed.Count){$raw=Get-MmtlCoverageProperty -InputObject $indexed[0].loaders -Name $loaderId}}
            $availability=if($raw){[string]$raw.availability}else{'Unknown'}
            $reason=if($availability -eq 'Available'){'GAME_VERSION_SUPPORTED_CANDIDATE_NOT_PROBED'}elseif($availability -eq 'Unavailable'){'NO_UPSTREAM_CANDIDATE'}else{'PROVIDER_UNAVAILABLE'}
            $source=if($raw){$raw.source}else{$providerStatuses[$loaderId].source};$cache=if($raw){$raw.cacheStatus}else{$providerStatuses[$loaderId].cacheStatus};$checked=if($raw){$raw.lastChecked}else{$providerStatuses[$loaderId].lastChecked}
            $states[$loaderId]=[pscustomobject]@{availability=$availability;reasonCode=$reason;source=$source;sourceClass='ActiveOfficial';cacheStatus=$cache;lastChecked=$checked;notes=@(if($raw){$raw.notes});candidateCount=$null;candidates=@();candidateProbeStatus='NotProbed';provenance=New-MmtlCoverageSourceProvenance -Source $source -LastChecked $checked -CacheStatus $cache -SourceClass 'ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS'}
        }
        foreach($pair in @(@{Id='LegacyFabric';Snapshot=$legacy},@{Id='OrnitheLoader';Snapshot=$ornithe})){
            $loaderId=$pair.Id;$snapshot=$pair.Snapshot;$supported=if($snapshot){@($snapshot.supportedVersions|Where-Object{$_.version -ceq $minecraftId}).Count -gt 0}else{$false};$status=if($snapshot){[string]$snapshot.providerStatus}else{'Unavailable'}
            $availability=if($loaderId -eq 'OrnitheLoader' -and $supported){'Unknown'}elseif($supported){if($status -in @('Degraded','Unavailable')){'Degraded'}else{'Available'}}elseif($status -in @('Unavailable','Degraded')){'Unknown'}else{'Unavailable'}
            $reason=if($loaderId -eq 'OrnitheLoader' -and $supported){'ORNITHE_LOADER_CANDIDATE_NOT_PROBED'}elseif($supported){'GAME_VERSION_SUPPORTED_CANDIDATE_NOT_PROBED'}elseif($availability -eq 'Unknown'){if($loaderId -eq 'LegacyFabric'){'LEGACY_FABRIC_PROVIDER_OUTAGE'}else{'ORNITHE_PROVIDER_OUTAGE'}}else{'NO_UPSTREAM_CANDIDATE'}
            $source=if($snapshot){$snapshot.sourceUrl}else{$null};$checked=if($snapshot -and $snapshot.documents.game){$snapshot.documents.game.validatedAt}else{$null};$cache=if($snapshot){$snapshot.cacheStatus}else{'Unavailable'}
            $notes=@(if($loaderId -eq 'OrnitheLoader' -and $supported){'Official game-support metadata alone does not establish an Ornithe Loader candidate.'}elseif($snapshot -and $snapshot.error){[string]$snapshot.error})
            $states[$loaderId]=[pscustomobject]@{availability=$availability;reasonCode=$reason;source=$source;sourceClass='ActiveOfficial';cacheStatus=$cache;lastChecked=$checked;notes=$notes;candidateCount=$null;candidates=@();candidateProbeStatus='NotProbed';provenance=New-MmtlCoverageSourceProvenance -Source $source -LastChecked $checked -CacheStatus $cache -SourceClass 'ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS'}
        }
        $liteHas=$lite -and @($lite.supportedVersions|Where-Object{$_ -ceq $minecraftId}).Count -gt 0;$liteStatus=if($lite){[string]$lite.providerStatus}else{'Unavailable'};$liteAvailability=if($liteHas){'Available'}elseif($liteStatus -in @('Unavailable','Degraded')){'Unknown'}else{'Unavailable'};$liteSource=if($lite){$lite.sourceUrl}else{$null};$liteChecked=if($lite){$lite.validatedAt}else{$null};$liteCache=if($lite){$lite.cacheStatus}else{'Unavailable'}
        $liteCandidates=@();if($lite){$liteCandidates=@(Get-MmtlLiteLoaderCandidates -MinecraftId $minecraftId -Snapshot $lite)}
        $states.LiteLoader=[pscustomobject]@{availability=$liteAvailability;reasonCode=if($liteHas){'UPSTREAM_CANDIDATE_FOUND'}elseif($liteAvailability -eq 'Unknown'){'LITELOADER_MANIFEST_UNAVAILABLE'}else{'LITELOADER_VERSION_NOT_LISTED'};source=$liteSource;sourceClass='HistoricalOfficial';cacheStatus=$liteCache;lastChecked=$liteChecked;notes=@(if($lite -and $lite.error){[string]$lite.error});candidateCount=$liteCandidates.Count;candidates=$liteCandidates;candidateProbeStatus='GlobalIndex';provenance=New-MmtlCoverageSourceProvenance -Source $liteSource -LastChecked $liteChecked -CacheStatus $liteCache -SourceClass 'HistoricalOfficial';trustClass='VerifiedHistorical';transportSecurity=if($liteCandidates.Count -and @($liteCandidates|Where-Object artifactTransport -eq 'HTTPOnly').Count){'HTTPOnly'}else{'HTTPS'}}
        foreach($loaderId in @('Rift','ModLoader','ModLoaderMP')){
            $candidates=@(switch($loaderId){'Rift'{Get-MmtlRiftCandidates -MinecraftId $minecraftId};'ModLoader'{Get-MmtlModLoaderArchiveCandidates -MinecraftId $minecraftId};'ModLoaderMP'{Get-MmtlModLoaderMPArchiveCandidates -MinecraftId $minecraftId}})
            $sourceClass=if($candidates.Count){[string]$candidates[0].sourceClass}else{$providerStatuses[$loaderId].sourceClass};$trust=if($candidates.Count){[string]$candidates[0].trustClass}else{'VerifiedHistorical'};$isCommunityOnly=$loaderId -eq 'Rift' -and $candidates.Count -gt 0 -and @($candidates|Where-Object originality -eq 'Original').Count -eq 0
            $archiveProvenance=if($candidates.Count){Get-MmtlCoverageCandidateProvenance -Candidates $candidates}else{@([pscustomobject]@{source=$providerStatuses[$loaderId].source;sourceClass=$sourceClass;recordStatus='NoCuratedRecord'})}
            $states[$loaderId]=[pscustomobject]@{availability=if($candidates.Count){'Available'}else{'Unknown'};reasonCode=if($candidates.Count){if($isCommunityOnly){'COMMUNITY_PORT_ONLY'}else{'CURATED_ARCHIVE_RECORD_FOUND'}}else{'HISTORICAL_SOURCE_NO_RECORD'};source=if($candidates.Count){if($candidates[0].PSObject.Properties['source']){$candidates[0].source}else{$candidates[0].repository}}else{$providerStatuses[$loaderId].source};sourceClass=$sourceClass;cacheStatus='Curated';lastChecked='2026-10-02T00:00:00Z';notes=if($candidates.Count){@()}else{@('Curated source has no record; absence does not establish incompatibility.')};candidateCount=$candidates.Count;candidates=$candidates;candidateProbeStatus='CuratedIndex';provenance=$archiveProvenance;trustClass=$trust;transportSecurity='ArchivedSnapshot'}
        }
        $states.JarMod=[pscustomobject]@{availability='Manual';reasonCode='MANUAL_ARTIFACT_REQUIRED';source=$null;sourceClass='ManualArtifact';cacheStatus='NotApplicable';lastChecked=$null;notes=@('Requires a user-supplied local artifact; no compatibility is inferred.');candidateCount=0;candidates=@();candidateProbeStatus='NotApplicable';provenance=@([pscustomobject]@{sourceClass='ManualArtifact';reason='User-supplied artifact only.'});trustClass='UnverifiedHistorical';transportSecurity='LocalManual'}
        $byRelease[$minecraftId]=$states
    }
    [pscustomobject]@{providerStatuses=[pscustomobject]$providerStatuses;byRelease=$byRelease;legacyFabricSnapshot=$legacy;ornitheSnapshot=$ornithe;liteLoaderSnapshot=$lite;neoForgeSnapshot=$neoForgeSnapshot;provenance=@(if($index){$index.providerStatuses.PSObject.Properties|ForEach-Object{$_.Value}})}
}

function New-MmtlCoverageAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)]$ProviderInputs,[object[]]$ValidationEvidence=@(),[switch]$Offline)
    $catalogEntries=@($Catalog.entries|Where-Object{$_.type -ceq 'release'})
    if(-not $catalogEntries.Count){throw 'Coverage audit requires at least one formal release.'}
    $releaseRows=[Collections.Generic.List[object]]::new()
    foreach($entry in $catalogEntries){
        $loaderGroups=[ordered]@{}
        foreach($groupName in $script:MmtlCoverageLoaders.Keys){$group=[ordered]@{};foreach($loaderId in $script:MmtlCoverageLoaders[$groupName]){$group[$loaderId]=ConvertTo-MmtlCoverageState -State (Get-MmtlCoverageInputState -ProviderInputs $ProviderInputs -MinecraftId ([string]$entry.id) -LoaderId $loaderId) -LoaderId $loaderId};$loaderGroups[$groupName]=[pscustomobject]$group}
        $evidence=@($ValidationEvidence|Where-Object{[string](Get-MmtlCoverageProperty -InputObject $_ -Name 'minecraftId') -ceq [string]$entry.id})
        $releaseRows.Add([pscustomobject][ordered]@{minecraftId=[string]$entry.id;releaseTime=[string]$entry.releaseTime;runtimeJava=if($entry.PSObject.Properties['runtimeJava']){$entry.runtimeJava}else{[pscustomobject]@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';reason='No Mojang runtime metadata recorded.'}};mainstreamLoaders=$loaderGroups.Mainstream;historicalLoaders=$loaderGroups.Historical;manualModes=$loaderGroups.Manual;validationEvidence=$evidence;coverageStatus='AUDITABLE';notes=@()})
    }
    $providerStatuses=Get-MmtlCoverageProperty -InputObject $ProviderInputs -Name 'providerStatuses'
    $providers=[Collections.Generic.List[object]]::new()
    foreach($loaderId in @($script:MmtlCoverageLoaders.Mainstream)+@($script:MmtlCoverageLoaders.Historical)+@($script:MmtlCoverageLoaders.Manual)){
        $provider=Get-MmtlCoverageProperty -InputObject $providerStatuses -Name $loaderId
        $providerNotes=@(Get-MmtlCoverageProperty -InputObject $provider -Name 'notes'|Where-Object{$null -ne $_}|ForEach-Object{[string]$_})
        $providers.Add([pscustomobject]@{loaderId=$loaderId;status=if(Get-MmtlCoverageProperty -InputObject $provider -Name 'status'){[string](Get-MmtlCoverageProperty -InputObject $provider -Name 'status')}else{'Unknown'};source=Get-MmtlCoverageProperty -InputObject $provider -Name 'source';sourceClass=Get-MmtlCoverageProperty -InputObject $provider -Name 'sourceClass';cacheStatus=if($Offline){'OfflineCache'}elseif(Get-MmtlCoverageProperty -InputObject $provider -Name 'cacheStatus'){[string](Get-MmtlCoverageProperty -InputObject $provider -Name 'cacheStatus')}else{'Unavailable'};lastChecked=ConvertTo-MmtlCoverageTimestamp (Get-MmtlCoverageProperty -InputObject $provider -Name 'lastChecked');notes=$providerNotes;unmappedVersions=@(Get-MmtlCoverageProperty -InputObject $provider -Name 'unmappedVersions')})
    }
    $counts=[ordered]@{Available=0;Unavailable=0;Unknown=0;Manual=0;Degraded=0};$perLoader=[ordered]@{}
    foreach($loaderId in @($script:MmtlCoverageLoaders.Mainstream)+@($script:MmtlCoverageLoaders.Historical)+@($script:MmtlCoverageLoaders.Manual)){$perLoader[$loaderId]=[ordered]@{Available=0;Unavailable=0;Unknown=0;Manual=0;Degraded=0;candidateCount=0;candidateProbed=0;releaseCount=$releaseRows.Count;firstAvailableRelease=$null;lastAvailableRelease=$null;continuousRanges=@();gaps=@()}}
    foreach($release in $releaseRows){foreach($groupName in $script:MmtlCoverageLoaders.Keys){$group=if($groupName -eq 'Mainstream'){$release.mainstreamLoaders}elseif($groupName -eq 'Historical'){$release.historicalLoaders}else{$release.manualModes};foreach($loaderId in $script:MmtlCoverageLoaders[$groupName]){$state=$group.$loaderId;$counts[[string]$state.availability]++;$perLoader[$loaderId][[string]$state.availability]++;if($null -ne $state.candidateCount){$perLoader[$loaderId].candidateCount+=[int]$state.candidateCount};if($state.candidateProbeStatus -in @('Passed','Failed')){$perLoader[$loaderId].candidateProbed++}}}}
    $validationLevels=[ordered]@{CATALOGUED=0;RESOLVED=0;BUILD_VERIFIED=0;SERVER_VERIFIED=0;CLIENT_LAUNCH_VERIFIED=0;INTEGRATION_VERIFIED=0}
    foreach($row in $releaseRows){foreach($evidence in $row.validationEvidence){$level=[string](Get-MmtlCoverageProperty -InputObject $evidence -Name 'level');if($validationLevels.Contains($level)){$validationLevels[$level]++}}}
    $providerStatusCounts=[ordered]@{};foreach($provider in $providers){$status=[string]$provider.status;if(-not $providerStatusCounts.Contains($status)){$providerStatusCounts[$status]=0};$providerStatusCounts[$status]++}
    $latest=[string]$Catalog.latestRelease;$minimum=[string]$Catalog.minimumReleaseId
    $catalogProvenance=@(Get-MmtlCoverageProperty -InputObject $Catalog -Name 'provenance'|Where-Object{$null -ne $_})
    if(-not $catalogProvenance.Count){foreach($entry in $catalogEntries){$catalogProvenance+=@(Get-MmtlCoverageProperty -InputObject $entry -Name 'provenance'|Where-Object{$null -ne $_})}}
    $provenance=$catalogProvenance+@(Get-MmtlCoverageProperty -InputObject $ProviderInputs -Name 'provenance'|Where-Object{$null -ne $_})
    $providerWarnings=@($providers|Where-Object{$_.status -in @('Unavailable','Degraded','Stale','Unknown')}|ForEach-Object{[pscustomobject]@{reasonCode='PROVIDER_UNAVAILABLE';loaderId=$_.loaderId;message=if(@($_.notes).Count){$_.notes -join '; '}else{"Provider status: $($_.status)"}}})
    $providerGaps=[Collections.Generic.List[object]]::new()
    foreach($providerRecord in $providers){if($providerRecord.status -notin @('Unavailable','Degraded')){continue};$unknownCount=0;foreach($releaseRow in $releaseRows){$group=if($script:MmtlCoverageLoaders.Mainstream -contains $providerRecord.loaderId){$releaseRow.mainstreamLoaders}elseif($script:MmtlCoverageLoaders.Historical -contains $providerRecord.loaderId){$releaseRow.historicalLoaders}else{$releaseRow.manualModes};$state=Get-MmtlCoverageProperty -InputObject $group -Name $providerRecord.loaderId;if($state -and $state.availability -eq 'Unknown'){$unknownCount++}};$message=if(@($providerRecord.notes).Count){$providerRecord.notes -join '; '}else{"Provider status: $($providerRecord.status)"};$providerGaps.Add([pscustomobject]@{severity='Warning';reasonCode='PROVIDER_UNAVAILABLE';minecraftId=$null;loaderId=$providerRecord.loaderId;releaseCount=$unknownCount;message=$message})}
    $audit=[pscustomobject][ordered]@{schemaVersion=1;generatedAt=[DateTimeOffset]::UtcNow.ToString('o');minecraftCatalog=[pscustomobject]@{source=[string]$Catalog.source;manifestHash=[string]$Catalog.manifestHash;minimumRelease=$minimum;currentStable=$latest;releaseCount=$releaseRows.Count;cacheStatus=if($Catalog.PSObject.Properties['cacheStatus']){[string]$Catalog.cacheStatus}else{'Unknown'}};providers=@($providers);releases=@($releaseRows);summary=[pscustomobject]@{releaseCount=$releaseRows.Count;stateCounts=[pscustomobject]$counts;perLoader=[pscustomobject]$perLoader;providerStatusCounts=[pscustomobject]$providerStatusCounts;validationLevels=[pscustomobject]$validationLevels;coverageStatus='AUDITABLE'};gaps=$providerGaps;warnings=$providerWarnings;provenance=$provenance}
    Update-MmtlCoverageMetrics -Audit $audit
    $unmappedGaps=[Collections.Generic.List[object]]::new()
    foreach($providerRecord in $providers){foreach($versionRecord in @($providerRecord.unmappedVersions)){$upstreamVersion=[string](Get-MmtlCoverageProperty -InputObject $versionRecord -Name 'upstreamVersion');$artifactFamily=[string](Get-MmtlCoverageProperty -InputObject $versionRecord -Name 'artifactFamily');if([string]::IsNullOrWhiteSpace($upstreamVersion)){continue};$unmappedGaps.Add([pscustomobject]@{severity='Error';reasonCode='UNMAPPED_UPSTREAM_VERSION';minecraftId=$null;loaderId=$providerRecord.loaderId;message="Upstream version '$upstreamVersion' in $artifactFamily has no exact Mojang release mapping."})}}
    $gaps=@($audit.gaps)+@(Test-MmtlCoverageAudit -Audit $audit)+@($unmappedGaps)
    $audit.gaps=$gaps
    $audit.summary.coverageStatus=if(@($gaps|Where-Object severity -eq 'Blocker').Count){'BLOCKED'}elseif(@($gaps|Where-Object severity -in @('Error','Warning')).Count){'AUDITABLE_WITH_GAPS'}elseif($counts.Unknown){'AUDITABLE_WITH_UNKNOWN'}else{'PASS'}
    $audit
}

function New-MmtlLiveCoverageAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$CatalogOffline,[switch]$LoaderOffline,[switch]$ForceRefresh,[object[]]$ValidationEvidence=@(),$Catalog,$ProviderInputs,[switch]$SkipCandidateProbes,[scriptblock]$CandidateProbe)
    $useCatalogOffline=$Offline -or $CatalogOffline;$useLoaderOffline=$Offline -or $LoaderOffline
    Import-Module (Join-Path $PSScriptRoot '..\Catalog\MinecraftVersionCatalog.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..\Catalog\JavaRuntimeResolver.psm1') -Force
    if(-not $Catalog){$Catalog=Get-MmtlMinecraftVersionCatalog -RuntimeRoot $RuntimeRoot -Offline:$useCatalogOffline -ForceRefresh:($ForceRefresh -and -not $useCatalogOffline)}
    $runtimeWarnings=[Collections.Generic.List[object]]::new()
    if(-not $PSBoundParameters.ContainsKey('Catalog')){foreach($entry in $Catalog.entries){
        try{$metadata=Get-MmtlMinecraftVersionMetadata -CatalogEntry $entry -RuntimeRoot $RuntimeRoot -Offline:$useCatalogOffline;$entry.runtimeJava=Resolve-MmtlMinecraftRuntimeJavaRequirement -MinecraftId ([string]$entry.id) -CatalogEntry $entry -VersionMetadata $metadata}
        catch{$entry.runtimeJava=[pscustomobject]@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';metadataStatus='UNAVAILABLE';reason=$_.Exception.Message};$runtimeWarnings.Add([pscustomobject]@{reasonCode='MOJANG_RUNTIME_METADATA_UNAVAILABLE';minecraftId=[string]$entry.id;message=$_.Exception.Message})}
    }}
    if(-not $ProviderInputs){$ProviderInputs=New-MmtlLiveCoverageProviderInputs -Catalog $Catalog -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline}
    Import-Module (Join-Path $PSScriptRoot 'ValidationEvidence.psm1') -Force
    $matrixWarnings=@()
    if(-not $ValidationEvidence.Count){$matrixSnapshot=Get-MmtlRuntimeValidationMatrices -RuntimeRoot $RuntimeRoot;$matrixWarnings=@($matrixSnapshot.warnings);$validationAudit=Get-MmtlValidationEvidenceAudit -Matrices $matrixSnapshot.matrices -CatalogReleaseIds @($Catalog.entries|Where-Object type -CEQ 'release'|ForEach-Object id);$ValidationEvidence=@($validationAudit.records);$matrixWarnings+=@($validationAudit.warnings)}
    $audit=New-MmtlCoverageAudit -Catalog $Catalog -RuntimeRoot $RuntimeRoot -ProviderInputs $ProviderInputs -ValidationEvidence $ValidationEvidence -Offline:$useLoaderOffline
    $audit.warnings=@($runtimeWarnings)+@($matrixWarnings)+@($audit.warnings)
    if($SkipCandidateProbes){return $audit}
    $probeIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in @('1.0','1.2.5','1.4.7','1.6.4','1.7.10','1.8.9','1.10.2','1.12.2','1.13','1.13.2','1.14.4','1.16.5','1.18.2','1.19.2','1.20.1','1.20.4','1.21.1',$Catalog.latestRelease)){[void]$probeIds.Add([string]$id)}
    foreach($loaderId in @($script:MmtlCoverageLoaders.Mainstream)+@($script:MmtlCoverageLoaders.Historical)){
        $available=@($audit.releases|Where-Object{$releaseGroup=if($_.mainstreamLoaders.PSObject.Properties[$loaderId]){$_.mainstreamLoaders}else{$_.historicalLoaders};$loaderState=Get-MmtlCoverageProperty -InputObject $releaseGroup -Name $loaderId;$loaderState.availability -eq 'Available'})
        if($available.Count){[void]$probeIds.Add([string]$available[0].minecraftId);[void]$probeIds.Add([string]$available[-1].minecraftId)}
    }
    $ornitheSnapshot=Get-MmtlCoverageProperty -InputObject $ProviderInputs -Name 'ornitheSnapshot'
    if($ornitheSnapshot -and $ornitheSnapshot.supportedVersions){$ornitheIds=@($Catalog.entries|Where-Object type -CEQ 'release'|Where-Object id -In @($ornitheSnapshot.supportedVersions|ForEach-Object version)|Sort-Object releaseTime);if($ornitheIds.Count){[void]$probeIds.Add([string]$ornitheIds[0].id);[void]$probeIds.Add([string]$ornitheIds[-1].id)}}
    $snapshots=@{}
    if(-not $CandidateProbe){
        Import-Module (Join-Path $PSScriptRoot '..\Catalog\Providers\Forge.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\Catalog\Providers\Fabric.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\Catalog\Providers\NeoForge.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\Catalog\Providers\Quilt.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\Catalog\Providers\HistoricalProviders.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..\Catalog\HistoricalAvailability.psm1') -Force
        foreach($loaderId in $script:MmtlCoverageLoaders.Mainstream){try{$snapshots[$loaderId]=switch($loaderId){'Forge'{Get-MmtlForgeProviderSnapshot -Catalog $Catalog -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline};'Fabric'{Get-MmtlFabricProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline};'NeoForge'{Get-MmtlNeoForgeProviderSnapshot -Catalog $Catalog -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline};'Quilt'{Get-MmtlQuiltProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline}}}catch{$snapshots[$loaderId]=$null}}
    }
    $probeWarnings=[Collections.Generic.List[object]]::new()
    foreach($minecraftId in $probeIds){
        $release=@($audit.releases|Where-Object minecraftId -CEQ $minecraftId|Select-Object -First 1);if(-not $release.Count){continue};$row=$release[0]
        foreach($loaderId in @($script:MmtlCoverageLoaders.Mainstream)+@($script:MmtlCoverageLoaders.Historical)){
            $group=if($loaderId -in $script:MmtlCoverageLoaders.Mainstream){$row.mainstreamLoaders}else{$row.historicalLoaders};$state=$group.$loaderId
            if($state.availability -ne 'Available' -and $state.reasonCode -ne 'ORNITHE_LOADER_CANDIDATE_NOT_PROBED'){continue}
            try{
                $candidates=@()
                if($CandidateProbe){$probeResult=& $CandidateProbe $minecraftId $loaderId;if($null -ne $probeResult){$candidates=@($probeResult)}}else{$candidates=@(switch($loaderId){
                    'Forge'{Get-MmtlForgeCandidates -MinecraftId $minecraftId -Snapshot $snapshots.Forge}
                    'Fabric'{Get-MmtlFabricCandidates -MinecraftId $minecraftId -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline}
                    'NeoForge'{Get-MmtlNeoForgeCandidates -MinecraftId $minecraftId -Snapshot $snapshots.NeoForge}
                    'Quilt'{Get-MmtlQuiltCandidates -MinecraftId $minecraftId -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline}
                    'LegacyFabric'{Get-MmtlLegacyFabricCandidates -MinecraftId $minecraftId -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline}
                    'OrnitheLoader'{Get-MmtlOrnitheCandidates -MinecraftId $minecraftId -RuntimeRoot $RuntimeRoot -Offline:$useLoaderOffline}
                    'LiteLoader'{Get-MmtlLiteLoaderCandidates -MinecraftId $minecraftId -Snapshot (Get-MmtlCoverageProperty -InputObject $ProviderInputs -Name 'liteLoaderSnapshot')}
                    'Rift'{Get-MmtlRiftCandidates -MinecraftId $minecraftId}
                    'ModLoader'{Get-MmtlModLoaderArchiveCandidates -MinecraftId $minecraftId}
                    'ModLoaderMP'{Get-MmtlModLoaderMPArchiveCandidates -MinecraftId $minecraftId}
                })}
                $state.candidateProbeStatus='Passed';$state.candidateCount=$candidates.Count;$state.candidates=$candidates
                if($candidates.Count -eq 0 -and $loaderId -eq 'OrnitheLoader'){$state.availability='Unavailable';$state.reasonCode='NO_UPSTREAM_CANDIDATE';$state.notes+=@('Official Ornithe game-support record has no distinct Ornithe Loader candidate for this release.')}
                elseif($candidates.Count -eq 0){$state.availability='Unknown';$state.reasonCode='COVERAGE_INCONSISTENCY';$state.notes+=@('Global availability says Available, but the sampled candidate endpoint returned zero candidates.');$audit.gaps+=@([pscustomobject]@{severity='Error';reasonCode='COVERAGE_INCONSISTENCY';minecraftId=$minecraftId;loaderId=$loaderId;message='Availability index and candidate endpoint disagree.'})}
                else{$state.availability='Available';$state.reasonCode='UPSTREAM_CANDIDATE_FOUND';$state.provenance=@($state.provenance)+@($candidates|ForEach-Object{$candidate=$_;$candidateProvenance=if($candidate -and $candidate.PSObject.Properties['provenance']){@($candidate.provenance)}else{@()};if(@($candidateProvenance).Count -gt 0){$candidateProvenance}else{[pscustomobject]@{source=if($candidate -and $candidate.PSObject.Properties['source']){$candidate.source}elseif($candidate -and $candidate.PSObject.Properties['repository']){$candidate.repository}else{$null};providerStatus=if($candidate -and $candidate.PSObject.Properties['providerStatus']){$candidate.providerStatus}else{'CuratedArchive'}}}})}
            }catch{$state.candidateProbeStatus='Failed';$state.notes+=@("Candidate endpoint probe failed: $($_.Exception.Message)");$probeWarnings.Add([pscustomobject]@{reasonCode='CANDIDATE_PROBE_FAILED';minecraftId=$minecraftId;loaderId=$loaderId;message=$_.Exception.Message})}
        }
    }
    Update-MmtlCoverageMetrics -Audit $audit
    $audit.warnings=@($audit.warnings)+@($probeWarnings)
    $probeGaps=@($audit.gaps|Where-Object reasonCode -eq 'COVERAGE_INCONSISTENCY')
    $retainedProviderGaps=@($audit.gaps|Where-Object{$null -eq $_.minecraftId})
    $audit.gaps=$retainedProviderGaps+@(Test-MmtlCoverageAudit -Audit $audit)+$probeGaps
    $audit.summary.coverageStatus=if(@($audit.gaps|Where-Object severity -eq 'Blocker').Count){'BLOCKED'}elseif(@($audit.gaps|Where-Object severity -in @('Error','Warning')).Count -or $audit.summary.stateCounts.Unknown){'AUDITABLE_WITH_GAPS'}else{'PASS'}
    $audit
}

function Get-MmtlCoverageReasonCodes {
    [CmdletBinding()]
    param()
    @($script:MmtlCoverageReasonCodes|Sort-Object -Unique)
}

function Test-MmtlCoverageAudit {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Audit)
    $gaps=[Collections.Generic.List[object]]::new()
    $requiredCount=[int]$Audit.minecraftCatalog.releaseCount
    if(@($Audit.releases).Count -ne $requiredCount){$gaps.Add([pscustomobject]@{severity='Blocker';reasonCode='CATALOG_RELEASE_ROW_COUNT_MISMATCH';minecraftId=$null;loaderId=$null;message='Audit release row count does not match the catalog.'})}
    $expected=@($script:MmtlCoverageLoaders.Mainstream)+@($script:MmtlCoverageLoaders.Historical)+@($script:MmtlCoverageLoaders.Manual)
    foreach($release in $Audit.releases){
        foreach($loaderId in $expected){
            $group=if($loaderId -in $script:MmtlCoverageLoaders.Mainstream){$release.mainstreamLoaders}elseif($loaderId -in $script:MmtlCoverageLoaders.Historical){$release.historicalLoaders}else{$release.manualModes}
            $state=Get-MmtlCoverageProperty -InputObject $group -Name $loaderId
            if($null -eq $state){$gaps.Add([pscustomobject]@{severity='Blocker';reasonCode='PROVIDER_RECORD_MISSING';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Required loader state is missing.'});continue}
            if([string]$state.reasonCode -eq 'PROVIDER_RECORD_MISSING'){$gaps.Add([pscustomobject]@{severity='Error';reasonCode='PROVIDER_RECORD_MISSING';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Provider data did not include an explicit state for this release.'})}
            if([string]$state.reasonCode -notin $script:MmtlCoverageReasonCodes){$gaps.Add([pscustomobject]@{severity='Error';reasonCode='UNKNOWN_REASON_CODE';minecraftId=$release.minecraftId;loaderId=$loaderId;message="Reason code '$($state.reasonCode)' is not registered."})}
            if([string]$state.availability -eq 'Unknown' -and [string]::IsNullOrWhiteSpace([string]$state.reasonCode)){$gaps.Add([pscustomobject]@{severity='Error';reasonCode='UNKNOWN_WITHOUT_REASON';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Unknown state has no explanation.'})}
            if([string]$state.availability -eq 'Available' -and $null -ne $state.candidateCount -and [int]$state.candidateCount -eq 0){$gaps.Add([pscustomobject]@{severity='Error';reasonCode='AVAILABLE_WITHOUT_CANDIDATE';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Provider reports Available but returned no candidate.'})}
            if([string]$state.availability -eq 'Unknown' -and @($state.notes).Count -eq 0){$gaps.Add([pscustomobject]@{severity='Error';reasonCode='UNKNOWN_WITHOUT_NOTES';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Unknown state has no diagnostic note.'})}
            if(@($state.provenance).Count -eq 0){$gaps.Add([pscustomobject]@{severity='Error';reasonCode='STATE_PROVENANCE_MISSING';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Loader state has no source provenance.'})}
            if([string]$state.availability -ne 'Manual' -and [string]::IsNullOrWhiteSpace([string]$state.source)){$gaps.Add([pscustomobject]@{severity='Error';reasonCode='STATE_SOURCE_MISSING';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Non-manual loader state has no source URL or source identifier.'})}
            if([string]$state.availability -notin @('Manual','Degraded') -and [string]$state.reasonCode -notin @('PROVIDER_UNAVAILABLE','LEGACY_FABRIC_PROVIDER_OUTAGE','ORNITHE_PROVIDER_OUTAGE','LITELOADER_MANIFEST_UNAVAILABLE') -and [string]$state.cacheStatus -notin @('Curated','NotApplicable','Unavailable') -and [string]::IsNullOrWhiteSpace([string]$state.lastChecked)){$gaps.Add([pscustomobject]@{severity='Warning';reasonCode='STATE_CHECK_TIME_MISSING';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Loader state does not record a validation time.'})}
            if([string]$state.trustClass -eq 'TrustedOfficial' -and [string]$state.sourceClass -in @('VerifiedCommunityArchive','VerifiedCommunitySource','UnknownHistorical','ManualArtifact')){$gaps.Add([pscustomobject]@{severity='Blocker';reasonCode='UNSAFE_TRUST_ESCALATION';minecraftId=$release.minecraftId;loaderId=$loaderId;message='Non-official or unknown provenance was promoted to TrustedOfficial.'})}
        }
    }
    @($gaps)
}

function Get-MmtlCoverageVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Audit,[Parameter(Mandatory)][string]$MinecraftId)
    $release=@($Audit.releases|Where-Object{$_.minecraftId -ceq $MinecraftId}|Select-Object -First 1)
    if(-not $release){throw "Minecraft version '$MinecraftId' is not a formal catalog release in this audit."}
    $release[0]
}

Export-ModuleMember -Function New-MmtlCoverageAudit,New-MmtlLiveCoverageProviderInputs,New-MmtlLiveCoverageAudit,Test-MmtlCoverageAudit,Get-MmtlCoverageVersion,Get-MmtlCoverageReasonCodes
