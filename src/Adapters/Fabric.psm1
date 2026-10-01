Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Test-MmtlFabricProject { param($Project) return $Project.Loader -eq 'Fabric' }
function Get-MmtlFabricAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence) $matched=@($Evidence|Where-Object loaderId -CEQ 'Fabric');New-MmtlAdapterProbeResult -AdapterId Fabric -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) }
function New-MmtlFabricAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if(-not(Test-MmtlFabricProject $Project)){throw 'Fabric adapter requires Fabric project evidence.'};New-MmtlAdapterBuildPlan -Project $Project }
Export-ModuleMember -Function Test-MmtlFabricProject,Get-MmtlFabricAdapterProbe,New-MmtlFabricAdapterBuildPlan
