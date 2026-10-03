Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\LoaderMetadata.psm1') -Force

$script:MmtlFabricHost=@('meta.fabricmc.net')
$script:MmtlFabricGameUri='https://meta.fabricmc.net/v2/versions/game'

function ConvertFrom-MmtlFabricJson {
    param([Parameter(Mandatory)][string]$Content,[Parameter(Mandatory)][string]$Context)
    try{$value=ConvertFrom-Json -InputObject $Content -NoEnumerate -ErrorAction Stop;if($value -isnot [array]){throw '预期为 JSON 数组。'};return ,$value}catch{throw "FABRIC_METADATA_INVALID ($Context): $($_.Exception.Message)"}
}

function Get-MmtlFabricProviderSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $document=Get-MmtlLoaderMetadataDocument -ProviderId Fabric -CacheKey 'v2-game-versions' -Uri $script:MmtlFabricGameUri -AllowedHosts $script:MmtlFabricHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $supported=[Collections.Generic.List[object]]::new();$error=$document.error
    if($document.providerStatus -eq 'Available'){
        try{$records=ConvertFrom-MmtlFabricJson -Content $document.content -Context 'game versions';$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($record in $records){$version=Get-MmtlFabricProperty $record 'version';$stable=Get-MmtlFabricProperty $record 'stable';if([string]::IsNullOrWhiteSpace([string]$version) -or $null -eq $stable){throw '游戏版本记录缺少 version 或 stable 字段。'};if($seen.Add([string]$version)){$supported.Add([pscustomobject]@{version=[string]$version;stable=[bool]$stable})}}}catch{$error=$_.Exception.Message}
    }
    $status=if($error){'Unavailable'}else{$document.providerStatus}
    [pscustomobject]@{loaderId='Fabric';providerStatus=$status;availability=if($status -eq 'Available'){'Available'}elseif($status -eq 'Stale'){'Unknown'}else{'Unknown'};supportedVersions=@($supported);cacheStatus=$document.cacheStatus;sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;error=$error;provenance=if($status -in @('Available','Stale')){@([pscustomobject]@{sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;cacheStatus=$document.cacheStatus})}else{@()}}
}

function Get-MmtlFabricAvailability {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Snapshot)
    if($Snapshot.providerStatus -notin @('Available','Stale')){return [pscustomobject]@{availability='Unknown';source=$Snapshot.sourceUrl;lastChecked=$Snapshot.validatedAt;cacheStatus=$Snapshot.cacheStatus;notes=@($Snapshot.error)}}
    $record=$Snapshot.supportedVersions|Where-Object{$_.version -ceq $MinecraftId}|Select-Object -First 1
    [pscustomobject]@{availability=if($record){'Available'}else{'Unavailable'};gameVersionStable=if($record){$record.stable}else{$null};source=$Snapshot.sourceUrl;lastChecked=$Snapshot.validatedAt;cacheStatus=$Snapshot.cacheStatus;notes=@()}
}

function Get-MmtlFabricCandidateSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $uri="https://meta.fabricmc.net/v2/versions/loader/$([Uri]::EscapeDataString($MinecraftId))"
    $document=Get-MmtlLoaderMetadataDocument -ProviderId Fabric -CacheKey "v2-loader-$MinecraftId" -Uri $uri -AllowedHosts $script:MmtlFabricHost -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet
    $candidates=[Collections.Generic.List[object]]::new();$error=$document.error
    if($document.providerStatus -in @('Available','Stale')){
        try{
            $records=ConvertFrom-MmtlFabricJson -Content $document.content -Context "loader $MinecraftId";$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($record in $records){
                $loader=Get-MmtlFabricProperty $record 'loader';$intermediary=Get-MmtlFabricProperty $record 'intermediary'
                if(-not $loader){throw 'Loader 记录缺少元数据。'}
                $version=[string](Get-MmtlFabricProperty $loader 'version');$maven=[string](Get-MmtlFabricProperty $loader 'maven');$stable=Get-MmtlFabricProperty $loader 'stable'
                if([string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($maven) -or $null -eq $stable){throw 'Loader 元数据缺少 version、maven 或 stable 字段。'}
                if(-not $seen.Add($version)){continue}
                $intermediaryVersion=if($intermediary){[string](Get-MmtlFabricProperty $intermediary 'version')}else{$null};$intermediaryMaven=if($intermediary){[string](Get-MmtlFabricProperty $intermediary 'maven')}else{$null};$intermediaryStable=if($intermediary){Get-MmtlFabricProperty $intermediary 'stable'}else{$null}
                $candidates.Add([pscustomobject]@{loaderId='Fabric';minecraftId=$MinecraftId;loaderVersion=$version;version=$version;stable=[bool]$stable;recommended=$null;latest=$null;loader=[pscustomobject]@{version=$version;maven=$maven;stable=[bool]$stable;build=(Get-MmtlFabricProperty $loader 'build');separator=(Get-MmtlFabricProperty $loader 'separator')};intermediary=[pscustomobject]@{version=$intermediaryVersion;maven=$intermediaryMaven;stable=$intermediaryStable};artifact=[pscustomobject]@{coordinate=$maven};source=$document.sourceUrl;provenance=@([pscustomobject]@{sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;cacheStatus=$document.cacheStatus});providerStatus=$document.providerStatus;cacheStatus=$document.cacheStatus;upstreamOrder=$candidates.Count;notes=@()})
            }
        }catch{$error=$_.Exception.Message;$candidates.Clear()}
    }
    [pscustomobject]@{loaderId='Fabric';minecraftId=$MinecraftId;providerStatus=if($error){'Unavailable'}else{$document.providerStatus};availability=if($error){'Unknown'}elseif($document.providerStatus -in @('Available','Stale')){'Available'}else{'Unknown'};candidateStatus=if($error){'Malformed'}else{$document.cacheStatus};candidates=@($candidates);sourceUrl=$document.sourceUrl;fetchedAt=$document.fetchedAt;validatedAt=$document.validatedAt;localHash=$document.localHash;error=$error;provenance=$candidates|ForEach-Object{$_.provenance[0]}}
}

function Get-MmtlFabricCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    (Get-MmtlFabricCandidateSet -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet).candidates
}

function Get-MmtlFabricPreferredCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)
    $stable=$Candidates|Where-Object{$_.stable}|Select-Object -First 1
    if($stable){return [pscustomobject]@{candidate=$stable;policy='FirstStableNewestFirst';status='Preferred';reason='Fabric Meta 按版本从新到旧返回 Loader；选择第一个稳定候选项。'}}
    $newest=$Candidates|Select-Object -First 1
    if($newest){return [pscustomobject]@{candidate=$newest;policy='NewestWhenNoStable';status='NoStableCandidate';reason='没有 Fabric Loader 稳定候选项；显示最新上游候选项，但不将其称为推荐版本。'}}
    [pscustomobject]@{candidate=$null;policy='NoCandidate';status='Unavailable';reason='Fabric Meta 未返回 Loader 候选项。'}
}

function Get-MmtlFabricProperty {
    param($InputObject,[string]$Name)
    if($null -eq $InputObject){return $null};if($InputObject -is [Collections.IDictionary]){return $InputObject[$Name]};$property=$InputObject.PSObject.Properties[$Name];if($property){return $property.Value};return $null
}

Export-ModuleMember -Function Get-MmtlFabricProviderSnapshot,Get-MmtlFabricAvailability,Get-MmtlFabricCandidateSet,Get-MmtlFabricCandidates,Get-MmtlFabricPreferredCandidate
