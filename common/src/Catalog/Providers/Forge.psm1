Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\LoaderMetadata.psm1') -Force

$script:MmtlForgePromotionsUri='https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json'
$script:MmtlForgeMavenUri='https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml'
$script:MmtlForgeHosts=@('files.minecraftforge.net','maven.minecraftforge.net')

function Get-MmtlForgeProviderSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $promotions=Get-MmtlLoaderMetadataDocument -ProviderId Forge -CacheKey 'promotions-slim-v1' -Uri $script:MmtlForgePromotionsUri -AllowedHosts $script:MmtlForgeHosts -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $maven=Get-MmtlLoaderMetadataDocument -ProviderId Forge -CacheKey 'forge-maven-versions-v1' -Uri $script:MmtlForgeMavenUri -AllowedHosts $script:MmtlForgeHosts -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $promotionMap=@{}
    if($promotions.providerStatus -eq 'Available'){
        try{$json=$promotions.content|ConvertFrom-Json -ErrorAction Stop;$raw=Get-MmtlForgeProperty $json 'promos';foreach($property in $raw.PSObject.Properties){$promotionMap[$property.Name]=[string]$property.Value}}catch{$promotions.providerStatus='Unavailable';$promotions.cacheStatus='Unavailable';$promotions.error="FORGE_PROMOTIONS_INVALID: $($_.Exception.Message)"}
    }
    $versions=[Collections.Generic.List[string]]::new();$mavenError=$null
    if($maven.providerStatus -eq 'Available'){
        try{
            $xml=ConvertFrom-MmtlSafeXml -Xml $maven.content
            $groupNode=$xml.SelectSingleNode('/metadata/groupId');$artifactNode=$xml.SelectSingleNode('/metadata/artifactId')
            $groupValue=if($groupNode){[string]$groupNode.InnerText}else{''};$artifactValue=if($artifactNode){[string]$artifactNode.InnerText}else{''}
            if($groupValue -cne 'net.minecraftforge' -or $artifactValue -cne 'forge'){throw "Forge Maven coordinate does not match net.minecraftforge:forge (received '$groupValue`:$artifactValue')."}
            foreach($node in $xml.SelectNodes('/metadata/versioning/versions/version')){if(-not [string]::IsNullOrWhiteSpace($node.InnerText)){$versions.Add($node.InnerText)}}
            if($versions.Count -eq 0){throw 'Forge Maven metadata contains no versions.'}
        }catch{$mavenError="FORGE_MAVEN_INVALID: $($_.Exception.Message)";$maven.providerStatus='Unavailable';$maven.cacheStatus='Unavailable';$maven.error=$mavenError}
    }
    $available=$maven.providerStatus -eq 'Available'
    $promoAvailable=$promotions.providerStatus -eq 'Available'
    $status=if($available -and $promoAvailable){'Available'}elseif($available -or $promoAvailable){'Degraded'}else{'Unavailable'}
    $uniqueVersions=[Collections.Generic.List[string]]::new();$versionIndex=@{}
    for($i=0;$i -lt $versions.Count;$i++){if(-not $versionIndex.ContainsKey($versions[$i])){$versionIndex[$versions[$i]]=$i;$uniqueVersions.Add($versions[$i])}}
    $provenance=@();foreach($document in @($promotions,$maven)){if($document.providerStatus -eq 'Available'){$provenance+= [pscustomobject]@{sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;cacheStatus=$document.cacheStatus}}}
    [pscustomobject]@{loaderId='Forge';providerStatus=$status;availability=if($available){'Available'}else{'Unknown'};catalogHash=[string]$Catalog.manifestHash;catalogEntries=@($Catalog.entries|ForEach-Object{[string]$_.id});versions=@($uniqueVersions);versionIndex=$versionIndex;promotions=$promotionMap;promotionsStatus=$promotions;versionsStatus=$maven;cacheStatus=$maven.cacheStatus;sourceUrl=$maven.sourceUrl;validatedAt=$maven.validatedAt;error=$mavenError;fetchedAt=$maven.validatedAt;provenance=$provenance}
}

function Get-MmtlForgeProperty {
    param($InputObject,[string]$Name)
    if($null -eq $InputObject){return $null};if($InputObject -is [Collections.IDictionary]){return $InputObject[$Name]};$p=$InputObject.PSObject.Properties[$Name];if($p){return $p.Value};return $null
}

function Get-MmtlForgeCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Snapshot)
    if($Snapshot.availability -ne 'Available'){return @()}
    $id=$MinecraftId
    $candidates=[Collections.Generic.List[object]]::new()
    foreach($full in $Snapshot.versions){
        $prefix="$id-"
        if(-not $full.StartsWith($prefix,[StringComparison]::Ordinal)){continue}
        $loaderVersion=$full.Substring($prefix.Length)
        if([string]::IsNullOrWhiteSpace($loaderVersion)){continue}
        $latestKey="$id-latest";$recommendedKey="$id-recommended"
        $isLatest=$Snapshot.promotions.ContainsKey($latestKey) -and $Snapshot.promotions[$latestKey] -ceq $loaderVersion
        $isRecommended=$Snapshot.promotions.ContainsKey($recommendedKey) -and $Snapshot.promotions[$recommendedKey] -ceq $loaderVersion
        $promotion=if($isLatest -and $isRecommended){'latest-and-recommended'}elseif($isRecommended){'recommended'}elseif($isLatest){'latest'}else{'none'}
        $candidates.Add([pscustomobject]@{loaderId='Forge';minecraftId=$id;version=$loaderVersion;loaderVersion=$loaderVersion;fullMavenVersion=$full;upstreamStatus='Available';stable=$null;recommended=[bool]$isRecommended;latest=[bool]$isLatest;promotionStatus=$promotion;artifact=[pscustomobject]@{group='net.minecraftforge';name='forge';version=$full;coordinate="net.minecraftforge:forge:$full"};source=$script:MmtlForgeMavenUri;provenance=@($Snapshot.provenance|Where-Object sourceUrl -eq $script:MmtlForgeMavenUri);providerStatus=$Snapshot.providerStatus;selectionPolicy='ForgeRecommendedThenLatest';notes=@()})
    }
    @($candidates)
}

function Get-MmtlForgePreferredCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)
    $recommended=$Candidates|Where-Object{$_.recommended}|Select-Object -First 1
    if($recommended){return [pscustomobject]@{candidate=$recommended;policy='ForgeRecommendedThenLatest';reason='Forge promotions_slim.json marks this version recommended.'}}
    $latest=$Candidates|Where-Object{$_.latest}|Select-Object -First 1
    if($latest){return [pscustomobject]@{candidate=$latest;policy='ForgeRecommendedThenLatest';reason='No Forge recommended promotion exists; using the explicit Forge latest promotion.'}}
    [pscustomobject]@{candidate=$null;policy='NoPromotion';reason='No Forge recommended or latest promotion is present; no default was inferred.'}
}

function Get-MmtlForgeAvailability {
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Snapshot)
    if($Snapshot.availability -ne 'Available'){return [pscustomobject]@{availability='Unknown';source=$script:MmtlForgeMavenUri;lastChecked=$Snapshot.fetchedAt;cacheStatus=$Snapshot.versionsStatus.cacheStatus;notes=@($Snapshot.versionsStatus.error)}}
    $matches=@($Snapshot.versions|Where-Object{$_.StartsWith("$MinecraftId-",[StringComparison]::Ordinal)})
    [pscustomobject]@{availability=if($matches.Count){'Available'}else{'Unavailable'};source=$script:MmtlForgeMavenUri;lastChecked=$Snapshot.versionsStatus.validatedAt;cacheStatus=$Snapshot.versionsStatus.cacheStatus;notes=@()}
}

Export-ModuleMember -Function Get-MmtlForgeProviderSnapshot,Get-MmtlForgeCandidates,Get-MmtlForgePreferredCandidate,Get-MmtlForgeAvailability
