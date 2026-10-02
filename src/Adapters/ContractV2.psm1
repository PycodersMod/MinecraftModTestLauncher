Set-StrictMode -Version Latest

function New-MmtlAdapterProbeResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AdapterId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,[Parameter(Mandatory)][ValidateSet('High','Medium','Low','Unknown')][string]$Confidence)
    [pscustomobject][ordered]@{contractVersion=2;adapterId=$AdapterId;matched=($Evidence.Count -gt 0);confidence=$Confidence;evidence=@($Evidence);conflicts=@()}
}

function Resolve-MmtlProjectStack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence)
    $primaryEvidence=@($Evidence|Where-Object{-not $_.PSObject.Properties['role'] -or $_.role -ne 'Overlay'});$overlayEvidence=@($Evidence|Where-Object{$_.PSObject.Properties['role'] -and $_.role -eq 'Overlay'})
    $ids=@($primaryEvidence|ForEach-Object {[string]$_.loaderId}|Select-Object -Unique)
    $conflicts=@();if($ids.Count -gt 1){$conflicts=@("Conflicting primary loader evidence: $($ids -join ', ').")}
    $selected=if($ids.Count -eq 1){$ids[0]}else{'Unknown'}
    $stack=$null
    if($selected -ne 'Unknown' -and -not $conflicts.Count){
        $primary=$primaryEvidence|Where-Object loaderId -CEQ $selected|Select-Object -First 1
        $overlays=@($overlayEvidence|ForEach-Object{[pscustomobject]@{id=[string]$_.loaderId;version=if($_.PSObject.Properties['version']){[string]$_.version}else{$null};role='Overlay';evidence=$_}})
        $stack=[pscustomobject]@{primaryLoader=[pscustomobject]@{id=$selected;version=if($primary.PSObject.Properties['version']){[string]$primary.version}else{$null};role='Primary';evidence=$primary};overlayLoaders=$overlays}
    }
    [pscustomobject][ordered]@{contractVersion=2;status=if($conflicts.Count){'Ambiguous'}elseif($selected -eq 'Unknown'){'Undetected'}else{'Resolved'};loaderStack=$stack;loaderId=$selected;evidence=@($Evidence);conflicts=$conflicts}
}

function New-MmtlAdapterBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)
    [pscustomobject][ordered]@{contractVersion=2;projectRoot=$Project.Root;buildSystem=$Project.BuildSystem;toolchain=$Project.Toolchain;task=$Project.BuildTask;workingDirectory=$Project.Root;wrapperPath=$Project.WrapperPath;buildJavaRequirement=$Project.BuildJavaRequirement;isExecutablePlan=$false}
}

function Get-MmtlHistoricalAdapterProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LoaderId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence)
    if($LoaderId -notin @('LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){throw "Unknown historical adapter: $LoaderId"}
    $matched=@($Evidence|Where-Object loaderId -CEQ $LoaderId)
    New-MmtlAdapterProbeResult -AdapterId $LoaderId -Evidence $matched -Confidence $(if($matched.Count){[string]$matched[0].confidence}else{'Unknown'})
}

function New-MmtlHistoricalAdapterBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)
    if($Project.Loader -notin @('LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){throw 'Historical adapter requires historical loader evidence.'}
    $plan=New-MmtlAdapterBuildPlan -Project $Project
    $plan|Add-Member -NotePropertyName historical -NotePropertyValue ([pscustomobject]@{sourceClass='UnknownHistorical';trustClass='UnverifiedHistorical';automaticArtifactExecution='Denied';validationStatus='Unverified'})
    $plan|Add-Member -NotePropertyName loaderStack -NotePropertyValue $Project.LoaderStack
    return $plan
}

Export-ModuleMember -Function New-MmtlAdapterProbeResult,Resolve-MmtlProjectStack,New-MmtlAdapterBuildPlan,Get-MmtlHistoricalAdapterProbe,New-MmtlHistoricalAdapterBuildPlan
