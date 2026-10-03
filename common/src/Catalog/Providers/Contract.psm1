Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Forge.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Fabric.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NeoForge.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Quilt.psm1') -Force

function Get-MmtlLoaderProviderContract {
    [CmdletBinding()]
    param()
    [pscustomobject][ordered]@{contractVersion=1;loaderIds=@('Forge','Fabric','NeoForge','Quilt');operations=@('GetSupportedMinecraftVersions','GetLoaderCandidates','GetLoaderVersionMetadata','GetPreferredCandidate','GetProviderStatus');availabilityStates=@('Available','Unavailable','Unknown');cacheStates=@('Fresh','Stale','OfflineCache','Unavailable')}
}

function Get-MmtlLoaderProviderSupportedMinecraftVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Forge','Fabric','NeoForge','Quilt')][string]$LoaderId,[Parameter(Mandatory)]$Snapshot)
    switch($LoaderId){
        'Forge' { $ids=[Collections.Generic.List[string]]::new();foreach($id in $Snapshot.catalogEntries){if(@(Get-MmtlForgeCandidates -MinecraftId ([string]$id) -Snapshot $Snapshot).Count){$ids.Add([string]$id)}};return @($ids) }
        'Fabric' { return @($Snapshot.supportedVersions|ForEach-Object{[string]$_.version}) }
        'Quilt' { return @($Snapshot.supportedVersions|ForEach-Object{[string]$_.version}) }
        'NeoForge' { $ids=[Collections.Generic.List[string]]::new();foreach($id in $Snapshot.catalogEntries){if(@(Get-MmtlNeoForgeCandidates -MinecraftId ([string]$id) -Snapshot $Snapshot).Count){$ids.Add([string]$id)}};return @($ids) }
    }
}

function Get-MmtlLoaderProviderCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Forge','Fabric','NeoForge','Quilt')][string]$LoaderId,[Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[scriptblock]$HttpGet)
    switch($LoaderId){'Forge'{return @(Get-MmtlForgeCandidates -MinecraftId $MinecraftId -Snapshot $Snapshot)}'Fabric'{return @(Get-MmtlFabricCandidates -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet)}'NeoForge'{return @(Get-MmtlNeoForgeCandidates -MinecraftId $MinecraftId -Snapshot $Snapshot)}'Quilt'{return @(Get-MmtlQuiltCandidates -MinecraftId $MinecraftId -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet)}}
}

function Get-MmtlLoaderProviderVersionMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Forge','Fabric','NeoForge','Quilt')][string]$LoaderId,[Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][string]$LoaderVersion,[Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)][string]$RuntimeRoot,[switch]$Offline,[scriptblock]$HttpGet)
    if($LoaderId -eq 'Quilt'){$detail=Get-MmtlQuiltVersionMetadata -MinecraftId $MinecraftId -LoaderVersion $LoaderVersion -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet;return [pscustomobject]@{loaderId=$LoaderId;minecraftId=$MinecraftId;loaderVersion=$LoaderVersion;upstreamStatus=$detail.providerStatus;metadata=$detail.metadata;source=$detail.sourceUrl;cacheStatus=$detail.cacheStatus;provenance=@($detail.sourceUrl);notes=@($detail.error)}}
    $candidates=@(Get-MmtlLoaderProviderCandidates -LoaderId $LoaderId -MinecraftId $MinecraftId -Snapshot $Snapshot -RuntimeRoot $RuntimeRoot -Offline:$Offline -HttpGet $HttpGet);$candidate=$candidates|Where-Object{$_.loaderVersion -ceq $LoaderVersion}|Select-Object -First 1
    [pscustomobject]@{loaderId=$LoaderId;minecraftId=$MinecraftId;loaderVersion=$LoaderVersion;upstreamStatus=if($candidate){$candidate.upstreamStatus}else{'Unavailable'};metadata=$candidate;source=if($candidate){$candidate.source}else{$null};cacheStatus=if($candidate){$candidate.cacheStatus}elseif($Snapshot.cacheStatus){$Snapshot.cacheStatus}else{'Unavailable'};provenance=if($candidate){@($candidate.provenance)}else{@()};notes=@()}
}

function Get-MmtlLoaderProviderPreferredCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Forge','Fabric','NeoForge','Quilt')][string]$LoaderId,[Parameter(Mandatory)][string]$MinecraftId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)
    switch($LoaderId){'Forge'{Get-MmtlForgePreferredCandidate -MinecraftId $MinecraftId -Candidates $Candidates};'Fabric'{Get-MmtlFabricPreferredCandidate -MinecraftId $MinecraftId -Candidates $Candidates};'NeoForge'{Get-MmtlNeoForgePreferredCandidate -MinecraftId $MinecraftId -Candidates $Candidates};'Quilt'{Get-MmtlQuiltPreferredCandidate -MinecraftId $MinecraftId -Candidates $Candidates}}
}

function Get-MmtlLoaderProviderStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Forge','Fabric','NeoForge','Quilt')][string]$LoaderId,[Parameter(Mandatory)]$Snapshot)
    $cache=if($Snapshot.PSObject.Properties['cacheStatus']){[string]$Snapshot.cacheStatus}elseif($Snapshot.PSObject.Properties['versionsStatus']){[string]$Snapshot.versionsStatus.cacheStatus}elseif($Snapshot.PSObject.Properties['modern']){[string]$Snapshot.modern.cacheStatus}else{'Unavailable'}
    $source=if($Snapshot.PSObject.Properties['sourceUrl']){[string]$Snapshot.sourceUrl}elseif($Snapshot.PSObject.Properties['versionsStatus']){[string]$Snapshot.versionsStatus.sourceUrl}elseif($Snapshot.PSObject.Properties['modern']){[string]$Snapshot.modern.uri}else{$null}
    [pscustomobject][ordered]@{loaderId=$LoaderId;status=[string]$Snapshot.providerStatus;cacheStatus=$cache;source=$source;lastValidated=if($Snapshot.PSObject.Properties['validatedAt']){$Snapshot.validatedAt}else{$null};error=if($Snapshot.PSObject.Properties['error']){$Snapshot.error}else{$null};provenance=@($Snapshot.provenance)}
}

Export-ModuleMember -Function Get-MmtlLoaderProviderContract,Get-MmtlLoaderProviderSupportedMinecraftVersions,Get-MmtlLoaderProviderCandidates,Get-MmtlLoaderProviderVersionMetadata,Get-MmtlLoaderProviderPreferredCandidate,Get-MmtlLoaderProviderStatus
