Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\LoaderMetadata.psm1') -Force

$script:MmtlNeoForgeHost=@('maven.neoforged.net')
$script:MmtlNeoForgeVersioningDocs='https://docs.neoforged.net/docs/gettingstarted/versioning/'
$script:MmtlNeoForgeRoot='https://maven.neoforged.net/releases/net/neoforged'

function Get-MmtlNeoForgeProperty {
    param($InputObject,[string]$Name)
    if($null -eq $InputObject){return $null};if($InputObject -is [Collections.IDictionary]){return $InputObject[$Name]};$p=$InputObject.PSObject.Properties[$Name];if($p){return $p.Value};return $null
}

function Get-MmtlNeoForgeMavenVersions {
    param([Parameter(Mandatory)]$Document,[Parameter(Mandatory)][string]$Group,[Parameter(Mandatory)][string]$Artifact)
    if($Document.providerStatus -notin @('Available','Stale')){return [pscustomobject]@{status=$Document.providerStatus;versions=@();error=$Document.error}}
    try{$xml=ConvertFrom-MmtlSafeXml -Xml ([string]$Document.content);$groupNode=$xml.SelectSingleNode('/metadata/groupId');$artifactNode=$xml.SelectSingleNode('/metadata/artifactId');$groupValue=if($groupNode){[string]$groupNode.InnerText}else{''};$artifactValue=if($artifactNode){[string]$artifactNode.InnerText}else{''};if($groupValue -cne $Group -or $artifactValue -cne $Artifact){throw "Maven coordinate mismatch; expected $Group`:$Artifact."};$versions=[Collections.Generic.List[string]]::new();foreach($versionNode in $xml.SelectNodes('/metadata/versioning/versions/version')){if(-not [string]::IsNullOrWhiteSpace([string]$versionNode.InnerText)){$versions.Add([string]$versionNode.InnerText)}};if($versions.Count -eq 0){throw 'Maven metadata has no versions.'};[pscustomobject]@{status=$Document.providerStatus;versions=@($versions);error=$null}}catch{[pscustomobject]@{status='Unavailable';versions=@();error="NEOFORGE_METADATA_INVALID: $($_.Exception.Message)"}}
}

function Get-MmtlNeoForgeProviderSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $modernUri="$script:MmtlNeoForgeRoot/neoforge/maven-metadata.xml";$transitionUri="$script:MmtlNeoForgeRoot/forge/maven-metadata.xml"
    $modernDoc=Get-MmtlLoaderMetadataDocument -ProviderId NeoForge -CacheKey 'maven-neoforge-v1' -Uri $modernUri -AllowedHosts $script:MmtlNeoForgeHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $transitionDoc=Get-MmtlLoaderMetadataDocument -ProviderId NeoForge -CacheKey 'maven-transition-forge-1.20.1-v1' -Uri $transitionUri -AllowedHosts $script:MmtlNeoForgeHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $modern=Get-MmtlNeoForgeMavenVersions -Document $modernDoc -Group 'net.neoforged' -Artifact 'neoforge';$transition=Get-MmtlNeoForgeMavenVersions -Document $transitionDoc -Group 'net.neoforged' -Artifact 'forge'
    $entries=@($Catalog.entries|ForEach-Object{[string]$_.id});$entrySet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($entry in $entries){$null=$entrySet.Add($entry)}
    $status=if($modern.status -in @('Available','Stale') -and $transition.status -in @('Available','Stale')){'Available'}elseif($modern.status -in @('Available','Stale') -or $transition.status -in @('Available','Stale')){'Degraded'}else{'Unavailable'}
    $documents=@();foreach($pair in @(@{Doc=$modernDoc;Parsed=$modern;Family='NeoForge';Artifact='neoforge'},@{Doc=$transitionDoc;Parsed=$transition;Family='NeoForgedForgeTransition';Artifact='forge'})){$documents+= [pscustomobject]@{artifactFamily=$pair.Family;artifact=$pair.Artifact;uri=$pair.Doc.sourceUrl;status=$pair.Parsed.status;versions=@($pair.Parsed.versions);error=$pair.Parsed.error;cacheStatus=$pair.Doc.cacheStatus;fetchedAt=$pair.Doc.fetchedAt;validatedAt=$pair.Doc.validatedAt;localHash=$pair.Doc.localHash}}
    [pscustomobject]@{loaderId='NeoForge';providerStatus=$status;catalogHash=[string]$Catalog.manifestHash;catalogEntries=$entries;catalogEntrySet=$entrySet;modern=$documents[0];transition=$documents[1];versioningDocs=$script:MmtlNeoForgeVersioningDocs;fetchedAt=[DateTimeOffset]::UtcNow.ToString('o')}
}

function Resolve-MmtlNeoForgeVersionMapping {
    param([Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][Collections.Generic.HashSet[string]]$CatalogEntrySet,[Parameter(Mandatory)][ValidateSet('NeoForge','NeoForgedForgeTransition')][string]$ArtifactFamily)
    if($ArtifactFamily -eq 'NeoForgedForgeTransition'){
        if($Version.StartsWith('1.20.1-',[StringComparison]::Ordinal) -and $CatalogEntrySet.Contains('1.20.1')){return [pscustomobject]@{minecraftId='1.20.1';loaderVersion=$Version.Substring('1.20.1-'.Length);scheme='1.20.1-transition-forge-prefix'}}
        return $null
    }
    foreach($id in ($CatalogEntrySet|Sort-Object Length -Descending)){
        if($Version.StartsWith("$id.",[StringComparison]::Ordinal)){$suffix=$Version.Substring($id.Length+1);if($suffix){return [pscustomobject]@{minecraftId=$id;loaderVersion=$suffix;scheme='full-minecraft-prefix-26+'}}}
    }
    if($Version -match '^(?<minor>2[0-5])\.(?<patch>\d+)\.(?<remainder>.+)$'){
        $minor=[int]$Matches.minor;$patch=[int]$Matches.patch
        $canonical="1.$minor.$patch";if(-not $CatalogEntrySet.Contains($canonical) -and $patch -eq 0){$canonical="1.$minor"}
        if($CatalogEntrySet.Contains($canonical)){return [pscustomobject]@{minecraftId=$canonical;loaderVersion=$Version;scheme='stripped-leading-one-1.20-1.25'}}
    }
    $null
}

function Get-MmtlNeoForgeUnmappedVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    $unmapped=[Collections.Generic.List[object]]::new()
    foreach($family in @($Snapshot.modern,$Snapshot.transition)){
        if(-not $family -or $family.status -notin @('Available','Stale')){continue}
        foreach($version in @($family.versions)){
            $mapping=Resolve-MmtlNeoForgeVersionMapping -Version ([string]$version) -CatalogEntrySet $Snapshot.catalogEntrySet -ArtifactFamily $family.artifactFamily
            if(-not $mapping){$unmapped.Add([pscustomobject]@{artifactFamily=[string]$family.artifactFamily;upstreamVersion=[string]$version;reasonCode='UNMAPPED_UPSTREAM_VERSION'})}
        }
    }
    @($unmapped)
}

function New-MmtlNeoForgeCandidate {
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)]$Family,[Parameter(Mandatory)]$Snapshot)
    $mapping=Resolve-MmtlNeoForgeVersionMapping -Version $Version -CatalogEntrySet $Snapshot.catalogEntrySet -ArtifactFamily $Family.artifactFamily
    if(-not $mapping -or $mapping.minecraftId -cne $MinecraftId){return $null}
    $qualifier=if($Version -match '(-(?:beta|alpha|rc|pre)[A-Za-z0-9.-]*)$'){$Matches[1]}else{$null}
    $sources=@([pscustomobject]@{sourceUrl=$Family.uri;fetchedAt=$Family.fetchedAt;validatedAt=$Family.validatedAt;localHash=$Family.localHash;cacheStatus=$Family.cacheStatus},[pscustomobject]@{sourceUrl=$Snapshot.versioningDocs;sourceType='officialDocument'})
    $transition=$Family.artifactFamily -eq 'NeoForgedForgeTransition'
    $coordinate="net.neoforged:$($Family.artifact):$Version"
    [pscustomobject]@{loaderId='NeoForge';minecraftId=$MinecraftId;loaderVersion=$mapping.loaderVersion;version=$Version;fullMavenVersion=$Version;upstreamStatus='Available';artifactFamily=$Family.artifactFamily;versionScheme=$mapping.scheme;stable=($null -eq $qualifier);recommended=$null;latest=$null;rawQualifier=$qualifier;artifact=[pscustomobject]@{group='net.neoforged';name=$Family.artifact;version=$Version;coordinate=$coordinate};source=$Family.uri;provenance=$sources;providerStatus=$Snapshot.providerStatus;cacheStatus=$Family.cacheStatus;upstreamOrder=$Family.versions.IndexOf($Version);selectionPolicy='NeoForgeStableThenUpstreamOrder';recommendation=if($transition){[pscustomobject]@{id='PreferForge';source=$Snapshot.versioningDocs;reason='NeoForged documentation recommends Forge for Minecraft 1.20.1.'}}else{$null};notes=if($transition){@('Transition artifact family; keep separate from net.neoforged:neoforge.')}elseif($qualifier){@("Original prerelease qualifier retained: $qualifier")}else{@()}}
}

function Get-MmtlNeoForgeCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Snapshot)
    $family=if($MinecraftId -ceq '1.20.1'){@($Snapshot.transition)}else{@($Snapshot.modern)}
    $result=[Collections.Generic.List[object]]::new();foreach($item in $family){if($item.status -in @('Available','Stale')){foreach($version in $item.versions){$candidate=New-MmtlNeoForgeCandidate -MinecraftId $MinecraftId -Version ([string]$version) -Family $item -Snapshot $Snapshot;if($candidate){$result.Add($candidate)}}}}
    @($result)
}

function Get-MmtlNeoForgeAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Snapshot)
    $family=if($MinecraftId -ceq '1.20.1'){@($Snapshot.transition)}else{@($Snapshot.modern)}
    if(@($family|Where-Object status -in @('Available','Stale')).Count -eq 0){return [pscustomobject]@{availability='Unknown';source=$null;lastChecked=$null;cacheStatus='Unavailable';notes=@($family.error)}}
    $candidates=@(Get-MmtlNeoForgeCandidates -MinecraftId $MinecraftId -Snapshot $Snapshot)
    [pscustomobject]@{availability=if($candidates.Count){'Available'}else{'Unavailable'};source=($family|Where-Object status -in @('Available','Stale')|Select-Object -First 1).uri;lastChecked=($family|Where-Object status -in @('Available','Stale')|Select-Object -First 1).validatedAt;cacheStatus=($family|Where-Object status -in @('Available','Stale')|Select-Object -First 1).cacheStatus;notes=@()}
}

function Get-MmtlNeoForgePreferredCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)
    $stable=@($Candidates|Where-Object stable);if($stable.Count){$candidate=$stable[-1];return [pscustomobject]@{candidate=$candidate;policy='NeoForgeStableThenUpstreamOrder';status='PreferredStable';reason='Selected the last stable version in upstream Maven order; version strings were not semver-sorted.'}}
    $beta=$Candidates|Select-Object -Last 1;if($beta){return [pscustomobject]@{candidate=$beta;policy='NeoForgeStableThenUpstreamOrder';status='BetaOnly';reason='No stable candidate exists; the upstream qualifier is preserved.'}}
    [pscustomobject]@{candidate=$null;policy='NoCandidate';status='Unavailable';reason='No mapped NeoForge candidate exists.'}
}

Export-ModuleMember -Function Get-MmtlNeoForgeProviderSnapshot,Get-MmtlNeoForgeCandidates,Get-MmtlNeoForgeAvailability,Get-MmtlNeoForgePreferredCandidate,Resolve-MmtlNeoForgeVersionMapping,Get-MmtlNeoForgeUnmappedVersions
