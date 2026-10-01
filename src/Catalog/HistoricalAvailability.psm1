Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Providers/HistoricalProviders.psm1') -Force

function Get-MmtlHistoricalLoaderAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[scriptblock]$HttpGet)
    $result=[Collections.Generic.List[object]]::new()
    $legacy=Get-MmtlLegacyFabricProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet
    $legacyOk=@($legacy.supportedVersions|Where-Object version -CEQ $MinecraftId).Count -gt 0
    $result.Add([pscustomobject]@{loaderId='LegacyFabric';availability=if($legacyOk){'Available'}elseif($legacy.providerStatus -in @('Available','Stale')){'Unavailable'}else{'Unknown'};providerStatus=$legacy.providerStatus;sourceClass='ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS';maintenanceState='Active';cacheStatus=$legacy.cacheStatus;source=$legacy.sourceUrl;candidateCount=if($legacyOk){@(Get-MmtlLegacyFabricCandidates -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet).Count}else{0};notes=@($legacy.error)})
    $ornithe=Get-MmtlOrnitheProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet
    $ornitheOk=@($ornithe.supportedVersions|Where-Object version -CEQ $MinecraftId).Count -gt 0
    $result.Add([pscustomobject]@{loaderId='OrnitheLoader';availability=if($ornitheOk){'Available'}elseif($ornithe.providerStatus -in @('Available','Stale')){'Unavailable'}else{'Unknown'};providerStatus=$ornithe.providerStatus;sourceClass='ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS';maintenanceState='Active';cacheStatus=$ornithe.cacheStatus;source=$ornithe.sourceUrl;candidateCount=if($ornitheOk){@(Get-MmtlOrnitheCandidates -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet).Count}else{0};notes=@($ornithe.error)})
    $lite=Get-MmtlLiteLoaderProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet
    $liteCandidates=@(Get-MmtlLiteLoaderCandidates -MinecraftId $MinecraftId -Snapshot $lite)
    $result.Add([pscustomobject]@{loaderId='LiteLoader';availability=if($liteCandidates.Count){'Available'}elseif($lite.providerStatus -in @('Available','Stale')){'Unavailable'}else{'Unknown'};providerStatus=$lite.providerStatus;sourceClass='HistoricalOfficial';trustClass='VerifiedHistorical';transportSecurity='HTTPS';maintenanceState='Archived';cacheStatus=$lite.cacheStatus;source=$lite.sourceUrl;candidateCount=$liteCandidates.Count;notes=@($lite.error)})
    foreach($loader in @('Rift','ModLoader','ModLoaderMP')){
        $items=switch($loader){'Rift'{@(Get-MmtlRiftCandidates -MinecraftId $MinecraftId)}'ModLoader'{@(Get-MmtlModLoaderArchiveCandidates -MinecraftId $MinecraftId)}'ModLoaderMP'{@(Get-MmtlModLoaderMPArchiveCandidates -MinecraftId $MinecraftId)}}
        $result.Add([pscustomobject]@{loaderId=$loader;availability=if($items.Count){'Available'}else{'Unavailable'};providerStatus=if($items.Count){'CuratedArchive'}else{'NotCatalogued'};sourceClass=if($loader -eq 'Rift'){'HistoricalOfficial'}else{'VerifiedCommunityArchive'};trustClass='VerifiedHistorical';transportSecurity=if($loader -eq 'Rift'){'ArchivedSnapshot'}else{'ArchivedSnapshot'};maintenanceState='Archived';cacheStatus='Curated';source=if($loader -eq 'Rift'){'https://github.com/DimensionalDevelopment/Rift'}else{'https://mcarchive.net/mods/'+$loader.ToLowerInvariant()};candidateCount=$items.Count;notes=@()})
    }
    $result.Add([pscustomobject]@{loaderId='JarMod';availability='Manual';providerStatus='ManualOnly';sourceClass='ManualArtifact';trustClass='UnverifiedHistorical';transportSecurity='LocalManual';maintenanceState='Unknown';cacheStatus='NotApplicable';source=$null;candidateCount=0;notes=@('Requires a user-supplied local artifact; no catalog availability is inferred.')})
    [pscustomobject][ordered]@{schemaVersion=1;minecraftId=$MinecraftId;scope='Historical';entries=@($result);generatedAt=[DateTimeOffset]::UtcNow.ToString('o')}
}
Export-ModuleMember -Function Get-MmtlHistoricalLoaderAvailability
