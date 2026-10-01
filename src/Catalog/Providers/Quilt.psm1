Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\LoaderMetadata.psm1') -Force

$script:MmtlQuiltHosts=@('meta.quiltmc.org')
$script:MmtlQuiltGameUri='https://meta.quiltmc.org/v3/versions/game'

function Get-MmtlQuiltProperty {
    param($InputObject,[string]$Name)
    if($null -eq $InputObject){return $null};if($InputObject -is [Collections.IDictionary]){return $InputObject[$Name]};$property=$InputObject.PSObject.Properties[$Name];if($property){return $property.Value};return $null
}

function ConvertFrom-MmtlQuiltJson {
    param([Parameter(Mandatory)][string]$Content,[Parameter(Mandatory)][string]$Context,[switch]$Array)
    try{$value=ConvertFrom-Json -InputObject $Content -NoEnumerate -ErrorAction Stop;if($Array -and $value -isnot [array]){throw 'Expected a JSON array.'};return ,$value}catch{throw "QUILT_METADATA_INVALID ($Context): $($_.Exception.Message)"}
}

function Get-MmtlQuiltProviderSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $doc=Get-MmtlLoaderMetadataDocument -ProviderId Quilt -CacheKey 'v3-game-versions' -Uri $script:MmtlQuiltGameUri -AllowedHosts $script:MmtlQuiltHosts -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $versions=[Collections.Generic.List[object]]::new();$error=$doc.error
    if($doc.providerStatus -in @('Available','Stale')){try{$records=ConvertFrom-MmtlQuiltJson -Content $doc.content -Context 'game versions' -Array;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($entry in $records){$version=Get-MmtlQuiltProperty $entry 'version';$stable=Get-MmtlQuiltProperty $entry 'stable';if([string]::IsNullOrWhiteSpace([string]$version) -or $null -eq $stable){throw 'Game record requires version and stable fields.'};if($seen.Add([string]$version)){$versions.Add([pscustomobject]@{version=[string]$version;stable=[bool]$stable})}}}catch{$error=$_.Exception.Message}}
    [pscustomobject]@{loaderId='Quilt';apiVersion='v3';providerStatus=if($error){'Unavailable'}else{$doc.providerStatus};supportedVersions=@($versions);sourceUrl=$doc.sourceUrl;cacheStatus=$doc.cacheStatus;fetchedAt=$doc.fetchedAt;validatedAt=$doc.validatedAt;localHash=$doc.localHash;error=$error;provenance=if(-not $error -and $doc.providerStatus -in @('Available','Stale')){@([pscustomobject]@{sourceUrl=$doc.sourceUrl;fetchedAt=$doc.fetchedAt;validatedAt=$doc.validatedAt;localHash=$doc.localHash;cacheStatus=$doc.cacheStatus})}else{@()}}
}

function Get-MmtlQuiltAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Snapshot)
    if($Snapshot.providerStatus -notin @('Available','Stale')){return [pscustomobject]@{availability='Unknown';source=$Snapshot.sourceUrl;lastChecked=$Snapshot.validatedAt;cacheStatus=$Snapshot.cacheStatus;notes=@($Snapshot.error)}}
    $game=$Snapshot.supportedVersions|Where-Object{$_.version -ceq $MinecraftId}|Select-Object -First 1
    [pscustomobject]@{availability=if($game){'Available'}else{'Unavailable'};gameVersionStable=if($game){$game.stable}else{$null};source=$Snapshot.sourceUrl;lastChecked=$Snapshot.validatedAt;cacheStatus=$Snapshot.cacheStatus;notes=@()}
}

function Get-MmtlQuiltCandidateSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $uri="https://meta.quiltmc.org/v3/versions/loader/$([Uri]::EscapeDataString($MinecraftId))"
    $doc=Get-MmtlLoaderMetadataDocument -ProviderId Quilt -CacheKey "v3-loader-$MinecraftId" -Uri $uri -AllowedHosts $script:MmtlQuiltHosts -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $items=[Collections.Generic.List[object]]::new();$error=$doc.error
    if($doc.providerStatus -in @('Available','Stale')){
        try{$records=ConvertFrom-MmtlQuiltJson -Content $doc.content -Context "loader $MinecraftId" -Array;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($record in $records){$loader=Get-MmtlQuiltProperty $record 'loader';$version=[string](Get-MmtlQuiltProperty $loader 'version');$maven=[string](Get-MmtlQuiltProperty $loader 'maven');if(-not $loader -or [string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($maven)){throw 'Loader entry requires loader.version and loader.maven.'};if(-not $seen.Add($version)){continue}
                $hashed=Get-MmtlQuiltProperty $record 'hashed';$intermediary=Get-MmtlQuiltProperty $record 'intermediary';$mappings=Get-MmtlQuiltProperty $record 'quilt-mappings';$detailUri="https://meta.quiltmc.org/v3/versions/loader/$([Uri]::EscapeDataString($MinecraftId))/$([Uri]::EscapeDataString($version))"
                $items.Add([pscustomobject]@{loaderId='Quilt';minecraftId=$MinecraftId;loaderVersion=$version;version=$version;stable=(Get-MmtlQuiltProperty $loader 'stable');recommended=(Get-MmtlQuiltProperty $loader 'recommended');latest=(Get-MmtlQuiltProperty $loader 'latest');loader=$loader;hashed=$hashed;intermediary=$intermediary;quiltMappings=$mappings;launcherMeta=(Get-MmtlQuiltProperty $record 'launcherMeta');artifact=[pscustomobject]@{coordinate=$maven};source=$doc.sourceUrl;detailUrl=$detailUri;provenance=@([pscustomobject]@{sourceUrl=$doc.sourceUrl;fetchedAt=$doc.fetchedAt;validatedAt=$doc.validatedAt;localHash=$doc.localHash;cacheStatus=$doc.cacheStatus});providerStatus=$doc.providerStatus;cacheStatus=$doc.cacheStatus;upstreamOrder=$items.Count;notes=@()})
            }
        }catch{$error=$_.Exception.Message;$items.Clear()}
    }
    [pscustomobject]@{loaderId='Quilt';minecraftId=$MinecraftId;apiVersion='v3';providerStatus=if($error){'Unavailable'}else{$doc.providerStatus};availability=if($error){'Unknown'}elseif($doc.providerStatus -in @('Available','Stale')){'Available'}else{'Unknown'};candidateStatus=if($error){'Malformed'}else{$doc.cacheStatus};candidates=@($items);sourceUrl=$doc.sourceUrl;fetchedAt=$doc.fetchedAt;validatedAt=$doc.validatedAt;localHash=$doc.localHash;error=$error;provenance=@($doc.sourceUrl)}
}

function Get-MmtlQuiltCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    (Get-MmtlQuiltCandidateSet -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet).candidates
}

function Get-MmtlQuiltVersionMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$LoaderVersion,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $uri="https://meta.quiltmc.org/v3/versions/loader/$([Uri]::EscapeDataString($MinecraftId))/$([Uri]::EscapeDataString($LoaderVersion))"
    $doc=Get-MmtlLoaderMetadataDocument -ProviderId Quilt -CacheKey "v3-loader-$MinecraftId-$LoaderVersion" -Uri $uri -AllowedHosts $script:MmtlQuiltHosts -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    if($doc.providerStatus -notin @('Available','Stale')){return [pscustomobject]@{providerStatus='Unavailable';cacheStatus=$doc.cacheStatus;metadata=$null;sourceUrl=$doc.sourceUrl;error=$doc.error}}
    try{$metadata=ConvertFrom-MmtlQuiltJson -Content $doc.content -Context 'loader detail';if([string](Get-MmtlQuiltProperty $metadata.loader 'version') -cne $LoaderVersion){throw 'detail version does not match requested loader version'};[pscustomobject]@{providerStatus=$doc.providerStatus;cacheStatus=$doc.cacheStatus;metadata=$metadata;sourceUrl=$doc.sourceUrl;fetchedAt=$doc.fetchedAt;validatedAt=$doc.validatedAt;localHash=$doc.localHash;error=$null}}catch{[pscustomobject]@{providerStatus='Unavailable';cacheStatus='Unavailable';metadata=$null;sourceUrl=$doc.sourceUrl;error=$_.Exception.Message}}
}

function Get-MmtlQuiltPreferredCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)
    $first=$Candidates|Select-Object -First 1
    if($first){return [pscustomobject]@{candidate=$first;policy='FirstUpstreamCandidate';status='DefaultCandidate';reason='Quilt Meta v3 does not provide a uniform stable/recommended/latest field for Loader entries; upstream order is retained without assigning those semantics.'}}
    [pscustomobject]@{candidate=$null;policy='NoCandidate';status='Unavailable';reason='Quilt Meta returned no Loader candidates.'}
}

Export-ModuleMember -Function Get-MmtlQuiltProviderSnapshot,Get-MmtlQuiltAvailability,Get-MmtlQuiltCandidateSet,Get-MmtlQuiltCandidates,Get-MmtlQuiltVersionMetadata,Get-MmtlQuiltPreferredCandidate
