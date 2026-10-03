Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Providers/Forge.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Providers/Fabric.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Providers/NeoForge.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Providers/Quilt.psm1') -Force

$script:MmtlLoaderAvailabilitySchemaVersion=1

function New-MmtlUnknownLoaderAvailability {
    param([Parameter(Mandatory)][string]$Reason)
    [pscustomobject]@{availability='Unknown';source=$null;lastChecked=$null;cacheStatus='Unavailable';notes=@($Reason)}
}

function Get-MmtlAvailabilityProviderStatus {
    param([Parameter(Mandatory)][string]$Loader,[Parameter(Mandatory)]$Snapshot)
    $status=[string]$Snapshot.providerStatus
    $cacheStatus=if($Snapshot.PSObject.Properties['cacheStatus']){[string]$Snapshot.cacheStatus}elseif($Snapshot.PSObject.Properties['versionsStatus']){[string]$Snapshot.versionsStatus.cacheStatus}elseif($Snapshot.PSObject.Properties['modern']){[string]$Snapshot.modern.cacheStatus}else{'Unavailable'}
    $source=if($Snapshot.PSObject.Properties['sourceUrl']){[string]$Snapshot.sourceUrl}elseif($Loader -eq 'Forge' -and $Snapshot.PSObject.Properties['versionsStatus']){[string]$Snapshot.versionsStatus.sourceUrl}elseif($Loader -eq 'NeoForge' -and $Snapshot.PSObject.Properties['modern']){[string]$Snapshot.modern.uri}else{$null}
    $validated=if($Snapshot.PSObject.Properties['validatedAt']){[string]$Snapshot.validatedAt}elseif($Snapshot.PSObject.Properties['versionsStatus']){[string]$Snapshot.versionsStatus.validatedAt}elseif($Snapshot.PSObject.Properties['modern']){[string]$Snapshot.modern.validatedAt}else{$null}
    [pscustomobject]@{status=$status;cacheStatus=$cacheStatus;source=$source;lastChecked=$validated;error=if($Snapshot.PSObject.Properties['error']){[string]$Snapshot.error}else{$null}}
}

function Get-MmtlLoaderAvailabilityIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[switch]$ForceRefresh,[scriptblock]$HttpGet)
    $cachePath=Join-Path (Join-Path $RuntimeRoot 'metadata/loaders') 'availability-index.json'
    if(-not $ForceRefresh -and (Test-Path -LiteralPath $cachePath -PathType Leaf)){
        try{
            $cached=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json -ErrorAction Stop
            $age=[DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse([string]$cached.generatedAt)
            if([int]$cached.schemaVersion -eq $script:MmtlLoaderAvailabilitySchemaVersion -and [string]$cached.minecraftCatalogHash -ceq [string]$Catalog.manifestHash -and ($Offline -or $age -le [TimeSpan]::FromHours(24))){
                if($Offline){$cached.cacheStatus='OfflineCache';foreach($loader in @('Forge','Fabric','NeoForge','Quilt')){$cached.providerStatuses.$loader.cacheStatus='OfflineCache'};foreach($entry in $cached.entries){foreach($loader in @('Forge','Fabric','NeoForge','Quilt')){$entry.loaders.$loader.cacheStatus='OfflineCache'}}}
                return $cached
            }
        }catch{}
    }
    $snapshots=[ordered]@{}
    foreach($loader in @('Forge','Fabric','NeoForge','Quilt')){
        try{
            $snapshot=switch($loader){
                'Forge'{Get-MmtlForgeProviderSnapshot -Catalog $Catalog -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet}
                'Fabric'{Get-MmtlFabricProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet}
                'NeoForge'{Get-MmtlNeoForgeProviderSnapshot -Catalog $Catalog -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet}
                'Quilt'{Get-MmtlQuiltProviderSnapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -ForceRefresh:$ForceRefresh -HttpGet $HttpGet}
            }
            $snapshots[$loader]=$snapshot
        }catch{$snapshots[$loader]=[pscustomobject]@{loaderId=$loader;providerStatus='Unavailable';cacheStatus='Unavailable';sourceUrl=$null;validatedAt=$null;error=$_.Exception.Message}}
    }
    $providerStatuses=[ordered]@{};foreach($loader in @('Forge','Fabric','NeoForge','Quilt')){$providerStatuses[$loader]=Get-MmtlAvailabilityProviderStatus -Loader $loader -Snapshot $snapshots[$loader]}
    $entries=[Collections.Generic.List[object]]::new()
    foreach($catalogEntry in $Catalog.entries){
        $id=[string]$catalogEntry.id;$loaders=[ordered]@{}
        foreach($loader in @('Forge','Fabric','NeoForge','Quilt')){
            try{$availability=switch($loader){'Forge'{Get-MmtlForgeAvailability -MinecraftId $id -Snapshot $snapshots[$loader]};'Fabric'{Get-MmtlFabricAvailability -MinecraftId $id -Snapshot $snapshots[$loader]};'NeoForge'{Get-MmtlNeoForgeAvailability -MinecraftId $id -Snapshot $snapshots[$loader]};'Quilt'{Get-MmtlQuiltAvailability -MinecraftId $id -Snapshot $snapshots[$loader]}};if($availability.availability -notin @('Available','Unavailable','Unknown')){throw "可用性状态无效：$($availability.availability)"};$loaders[$loader]=$availability}catch{$loaders[$loader]=New-MmtlUnknownLoaderAvailability -Reason $_.Exception.Message}
        }
        $entries.Add([pscustomobject]@{minecraftId=$id;loaders=[pscustomobject]$loaders})
    }
    $providerValues=@($providerStatuses.Values);$cacheStatus=if($Offline){'OfflineCache'}elseif(@($providerValues|Where-Object status -eq 'Stale').Count){'Stale'}elseif(@($providerValues|Where-Object status -eq 'Unavailable').Count -eq 4){'Unavailable'}elseif(@($providerValues|Where-Object status -in @('Unavailable','Degraded')).Count){'Degraded'}else{'Fresh'}
    $index=[pscustomobject][ordered]@{schemaVersion=$script:MmtlLoaderAvailabilitySchemaVersion;generatedAt=[DateTimeOffset]::UtcNow.ToString('o');minecraftCatalogHash=[string]$Catalog.manifestHash;providerStatuses=[pscustomobject]$providerStatuses;entries=@($entries);cacheStatus=$cacheStatus}
    $directory=Split-Path -Parent $cachePath;[IO.Directory]::CreateDirectory($directory)|Out-Null;$temporary="$cachePath.$([guid]::NewGuid().ToString('N')).tmp"
    try{[IO.File]::WriteAllText($temporary,($index|ConvertTo-Json -Depth 30 -Compress),[Text.Encoding]::UTF8);if([IO.File]::Exists($cachePath)){[IO.File]::Move($temporary,$cachePath,$true)}else{[IO.File]::Move($temporary,$cachePath)}}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    $index
}

Export-ModuleMember -Function Get-MmtlLoaderAvailabilityIndex
