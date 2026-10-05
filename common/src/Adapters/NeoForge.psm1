Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Test-MmtlNeoForgeProject { param($Project) return $Project.Loader -eq 'NeoForge' }
function Get-MmtlNeoForgeAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,[AllowNull()][object]$RuntimeJavaBinding) $matched=@($Evidence|Where-Object loaderId -CEQ 'NeoForge');New-MmtlAdapterProbeResult -AdapterId NeoForge -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) -RuntimeJavaBinding $RuntimeJavaBinding }
function New-MmtlNeoForgeAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if(-not(Test-MmtlNeoForgeProject $Project)){throw 'NeoForge 适配器需要 NeoForge 项目证据。'};New-MmtlAdapterBuildPlan -Project $Project }
function Get-MmtlNeoForgeClientMarkerHints { [CmdletBinding()]param([string]$MinecraftVersion) return @([pscustomobject]@{eventCode='CLIENT_INIT_DETECTED';pattern='(?i)\[(?:Render|Client) thread/INFO\]: Setting user:';description='Minecraft 客户端开始初始化'}) }
Export-ModuleMember -Function Test-MmtlNeoForgeProject,Get-MmtlNeoForgeAdapterProbe,New-MmtlNeoForgeAdapterBuildPlan,Get-MmtlNeoForgeClientMarkerHints
