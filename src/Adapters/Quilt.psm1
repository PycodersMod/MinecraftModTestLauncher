Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Get-MmtlQuiltAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence) $matched=@($Evidence|Where-Object loaderId -CEQ 'Quilt');New-MmtlAdapterProbeResult -AdapterId Quilt -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) }
function New-MmtlQuiltAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if($Project.Loader -ne 'Quilt' -or $Project.Toolchain.id -ne 'QuiltLoom'){throw 'Quilt adapter requires Quilt and the QuiltLoom toolchain.'};New-MmtlAdapterBuildPlan -Project $Project }
Export-ModuleMember -Function Get-MmtlQuiltAdapterProbe,New-MmtlQuiltAdapterBuildPlan
