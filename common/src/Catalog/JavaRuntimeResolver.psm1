Set-StrictMode -Version Latest

$script:MmtlJavaFallbackPath=Join-Path $PSScriptRoot 'data/java-runtime-fallback.json'

function Get-MmtlJavaOptionalProperty {
    param([Parameter(Mandatory)]$InputObject,[Parameter(Mandatory)][string]$Name)
    if($InputObject -is [Collections.IDictionary]){foreach($key in $InputObject.Keys){if([string]$key -ieq $Name){return $InputObject[$key]}};return $null}
    $property=$InputObject.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $null
}

function Get-MmtlJavaRuntimeFallbackRegistry {
    [CmdletBinding()]
    param([string]$Path=$script:MmtlJavaFallbackPath)
    try{$registry=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop}catch{throw "JAVA_FALLBACK_REGISTRY_INVALID: $($_.Exception.Message)"}
    if([int]$registry.schemaVersion -ne 1 -or $null -eq $registry.rules){throw 'JAVA_FALLBACK_REGISTRY_INVALID: schemaVersion 或 rules 缺失。'}
    @($registry.rules)
}

function Resolve-MmtlMinecraftRuntimeJavaRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MinecraftId,
        [Parameter(Mandatory)]$CatalogEntry,
        $VersionMetadata,
        $RuntimeOverride,
        [string]$FallbackRegistryPath=$script:MmtlJavaFallbackPath
    )
    $metadataStatus=if($VersionMetadata){[string]$VersionMetadata.metadataStatus}else{[string]$CatalogEntry.metadataStatus}
    if($RuntimeOverride){
        $major=0
        if(-not [int]::TryParse([string]$RuntimeOverride.major,[ref]$major) -or $major -le 0){throw 'RUNTIME_JAVA_OVERRIDE_INVALID: major 必须为正整数。'}
        return [pscustomobject]@{major=$major;component=(Get-MmtlJavaOptionalProperty -InputObject $RuntimeOverride -Name 'component');source='ProjectOverride';confidence='High';requirementKind='ProjectOverride';provenance=(Get-MmtlJavaOptionalProperty -InputObject $RuntimeOverride -Name 'provenance');metadataStatus=$metadataStatus}
    }
    $javaVersion=if($VersionMetadata -and $VersionMetadata.metadata){Get-MmtlJavaOptionalProperty -InputObject $VersionMetadata.metadata -Name 'javaVersion'}else{$null}
    if($javaVersion){
        $major=0
        $majorVersion=Get-MmtlJavaOptionalProperty -InputObject $javaVersion -Name 'majorVersion'
        if(-not [int]::TryParse([string]$majorVersion,[ref]$major) -or $major -le 0){throw 'METADATA_JAVA_VERSION_INVALID: javaVersion.majorVersion 必须为正整数。'}
        return [pscustomobject]@{major=$major;component=(Get-MmtlJavaOptionalProperty -InputObject $javaVersion -Name 'component');source='MojangVersionMetadata';confidence='High';requirementKind='AuthoritativeMetadata';provenance=$VersionMetadata.provenance;metadataStatus='VERIFIED'}
    }
    if($VersionMetadata -and $metadataStatus -eq 'VERIFIED'){$metadataStatus='VERIFIED_NO_JAVA_VERSION'}
    foreach($rule in (Get-MmtlJavaRuntimeFallbackRegistry -Path $FallbackRegistryPath)){
        if([string]$MinecraftId -cmatch [string]$rule.matcher){
            return [pscustomobject]@{major=[int]$rule.recommendedMajor;component=$null;source='MMTLCompatibilityFallback';confidence=[string]$rule.confidence;requirementKind='CompatibilityFallback';provenance=$rule.provenance;reason=[string]$rule.reason;metadataStatus=if($metadataStatus){$metadataStatus}else{'VERIFIED_NO_JAVA_VERSION'}}
        }
    }
    [pscustomobject]@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';provenance=$null;metadataStatus=if($metadataStatus){$metadataStatus}else{'VERIFIED_NO_JAVA_VERSION'}}
}

Export-ModuleMember -Function Get-MmtlJavaRuntimeFallbackRegistry,Resolve-MmtlMinecraftRuntimeJavaRequirement
