Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Get-MmtlQuiltAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,[AllowNull()][object]$RuntimeJavaBinding) $matched=@($Evidence|Where-Object loaderId -CEQ 'Quilt');New-MmtlAdapterProbeResult -AdapterId Quilt -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) -RuntimeJavaBinding $RuntimeJavaBinding }
function New-MmtlQuiltAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if($Project.Loader -ne 'Quilt' -or $Project.Toolchain.id -ne 'QuiltLoom'){throw 'Quilt 适配器需要 Quilt 与 QuiltLoom 工具链。'};New-MmtlAdapterBuildPlan -Project $Project }
Export-ModuleMember -Function Get-MmtlQuiltAdapterProbe,New-MmtlQuiltAdapterBuildPlan
