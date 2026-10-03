Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Test-MmtlForgeProject { param($Project) return $Project.Loader -eq 'Forge' }
function Get-MmtlForgeAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence) $matched=@($Evidence|Where-Object loaderId -CEQ 'Forge');New-MmtlAdapterProbeResult -AdapterId Forge -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) }
function New-MmtlForgeAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if(-not(Test-MmtlForgeProject $Project)){throw 'Forge adapter requires Forge project evidence.'};New-MmtlAdapterBuildPlan -Project $Project }
Export-ModuleMember -Function Test-MmtlForgeProject,Get-MmtlForgeAdapterProbe,New-MmtlForgeAdapterBuildPlan
