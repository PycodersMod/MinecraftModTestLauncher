Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Test-MmtlFabricProject { param($Project) return $Project.Loader -eq 'Fabric' }
function Get-MmtlFabricAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,[AllowNull()][object]$RuntimeJavaBinding) $matched=@($Evidence|Where-Object loaderId -CEQ 'Fabric');New-MmtlAdapterProbeResult -AdapterId Fabric -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) -RuntimeJavaBinding $RuntimeJavaBinding }
function New-MmtlFabricAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if(-not(Test-MmtlFabricProject $Project)){throw 'Fabric 适配器需要 Fabric 项目证据。'};New-MmtlAdapterBuildPlan -Project $Project }
function Get-MmtlFabricClientMarkerHints { [CmdletBinding()]param([string]$MinecraftVersion) return @([pscustomobject]@{eventCode='CLIENT_INIT_DETECTED';pattern='(?i)\[(?:Render|Client) thread/INFO\]: Setting user:';description='Minecraft 客户端开始初始化'}) }
Export-ModuleMember -Function Test-MmtlFabricProject,Get-MmtlFabricAdapterProbe,New-MmtlFabricAdapterBuildPlan,Get-MmtlFabricClientMarkerHints
