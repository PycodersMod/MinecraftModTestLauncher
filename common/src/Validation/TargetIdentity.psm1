Set-StrictMode -Version Latest

$script:MmtlExactTargetIdPattern='^[A-Za-z0-9][A-Za-z0-9._@+() -]{1,179}$'

function Test-MmtlExactTargetId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$TargetId)
    return $TargetId -cmatch $script:MmtlExactTargetIdPattern
}

function Get-MmtlValidationTargetStorageKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetId)
    if(-not(Test-MmtlExactTargetId -TargetId $TargetId)){throw 'VALIDATION_TARGET_ID_INVALID'}
    $slug=[regex]::Replace($TargetId.ToLowerInvariant(),'[^a-z0-9]+','-').Trim('-')
    if($slug.Length -gt 48){$slug=$slug.Substring(0,48).TrimEnd('-')}
    if(-not $slug){$slug='target'}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($TargetId))).ToLowerInvariant().Substring(0,16)
    return "$slug-$hash"
}

function Get-MmtlLoaderVersionCandidateValues {
    [CmdletBinding()]
    param([AllowEmptyCollection()][AllowNull()][object[]]$Candidates=@())
    $versions=[Collections.Generic.List[string]]::new()
    foreach($candidate in $Candidates){
        if($null -eq $candidate){continue}
        if($candidate -is [string]){$value=[string]$candidate}
        elseif($candidate -is [Collections.IDictionary]){
            $value=$null
            foreach($key in $candidate.Keys){if([string]$key -ieq 'loaderVersion'){$value=[string]$candidate[$key];break}}
            if(-not $value){foreach($key in $candidate.Keys){if([string]$key -ieq 'version'){$value=[string]$candidate[$key];break}}}
        }else{
            $versionProperty=$candidate.PSObject.Properties['loaderVersion']
            if($null -eq $versionProperty){$versionProperty=$candidate.PSObject.Properties['version']}
            $value=if($versionProperty){[string]$versionProperty.Value}else{$null}
        }
        if(-not [string]::IsNullOrWhiteSpace([string]$value)){$versions.Add([string]$value)}
    }
    return [string[]]$versions.ToArray()
}

Export-ModuleMember -Function Test-MmtlExactTargetId,Get-MmtlValidationTargetStorageKey,Get-MmtlLoaderVersionCandidateValues
