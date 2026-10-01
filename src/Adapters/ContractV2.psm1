Set-StrictMode -Version Latest

function New-MmtlAdapterProbeResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AdapterId,[Parameter(Mandatory)][object[]]$Evidence,[Parameter(Mandatory)][ValidateSet('High','Medium','Low','Unknown')][string]$Confidence)
    [pscustomobject][ordered]@{contractVersion=2;adapterId=$AdapterId;matched=($Evidence.Count -gt 0);confidence=$Confidence;evidence=@($Evidence);conflicts=@()}
}

function Resolve-MmtlProjectStack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence)
    $ids=@($Evidence|ForEach-Object {[string]$_.loaderId}|Select-Object -Unique)
    $conflicts=@();if($ids.Count -gt 1){$conflicts=@("Conflicting loader evidence: $($ids -join ', ').")}
    $selected=if($ids.Count -eq 1){$ids[0]}else{'Unknown'}
    [pscustomobject][ordered]@{contractVersion=2;status=if($conflicts.Count){'Ambiguous'}elseif($selected -eq 'Unknown'){'Undetected'}else{'Resolved'};loaderStack=if($selected -ne 'Unknown'){[pscustomobject]@{primaryLoader=[pscustomobject]@{id=$selected;version=$null;role='Primary';provenance=@()};overlayLoaders=@()}}else{$null};loaderId=$selected;evidence=@($Evidence);conflicts=$conflicts}
}

function New-MmtlAdapterBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)
    [pscustomobject][ordered]@{contractVersion=2;projectRoot=$Project.Root;buildSystem=$Project.BuildSystem;toolchain=$Project.Toolchain;task=$Project.BuildTask;workingDirectory=$Project.Root;wrapperPath=$Project.WrapperPath;buildJavaRequirement=$Project.BuildJavaRequirement;isExecutablePlan=$false}
}

Export-ModuleMember -Function New-MmtlAdapterProbeResult,Resolve-MmtlProjectStack,New-MmtlAdapterBuildPlan
