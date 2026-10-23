Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Get-MmtlQuiltAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,[AllowNull()][object]$RuntimeJavaBinding) $matched=@($Evidence|Where-Object loaderId -CEQ 'Quilt');New-MmtlAdapterProbeResult -AdapterId Quilt -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) -RuntimeJavaBinding $RuntimeJavaBinding }
function New-MmtlQuiltAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if($Project.Loader -ne 'Quilt' -or $Project.Toolchain.id -ne 'QuiltLoom'){throw 'Quilt 适配器需要 Quilt 与 QuiltLoom 工具链。'};New-MmtlAdapterBuildPlan -Project $Project }
function Resolve-MmtlQuiltAdapterTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Universe)
    if([string]$Project.Loader -cne 'Quilt'){throw 'QUILT_PROJECT_REQUIRED'}
    $universeHash=[string]$Universe.catalogHash
    if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
    $minecraftId=[string]$Project.MinecraftVersion
    if([string]::IsNullOrWhiteSpace($minecraftId)){return [pscustomobject][ordered]@{status='Unresolved';reasonCode='MINECRAFT_VERSION_UNRESOLVED';targetId=$null;minecraftId=$null;loaderVersion=[string]$Project.LoaderVersion;evidence=@()}}
    $target=@($Universe.targets|Where-Object{$_.loaderId -ceq 'Quilt' -and $_.minecraftId -ceq $minecraftId -and $_.availability -ceq 'Available'}|Select-Object -First 1)
    if(-not $target){return [pscustomobject][ordered]@{status='Unresolved';reasonCode='TARGET_NOT_IN_FROZEN_UNIVERSE';targetId=$null;minecraftId=$minecraftId;loaderVersion=[string]$Project.LoaderVersion;evidence=@("universe-sha256:$universeHash")}}
    $loaderVersion=[string]$Project.LoaderVersion
    if([string]::IsNullOrWhiteSpace($loaderVersion)){return [pscustomobject][ordered]@{status='Unresolved';reasonCode='LOADER_VERSION_UNRESOLVED';targetId=$null;minecraftId=$minecraftId;loaderVersion=$null;evidence=@("universe-sha256:$universeHash")}}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates|Where-Object{[string]$_ -ceq $loaderVersion}).Count -eq 0){return [pscustomobject][ordered]@{status='Unresolved';reasonCode='LOADER_VERSION_NOT_IN_FROZEN_CANDIDATES';targetId=$null;minecraftId=$minecraftId;loaderVersion=$loaderVersion;evidence=@("universe-sha256:$universeHash")}}
    $evidence=@("universe-sha256:$universeHash")
    if(-not [string]::IsNullOrWhiteSpace([string]$target.sourceHash)){$evidence+="source-sha256:$([string]$target.sourceHash)"}
    if(-not [string]::IsNullOrWhiteSpace([string]$target.candidateSourceHash)){$evidence+="candidate-source-sha256:$([string]$target.candidateSourceHash)"}
    [pscustomobject][ordered]@{status='Resolved';reasonCode=$null;targetId=[string]$target.targetId;minecraftId=$minecraftId;loaderVersion=$loaderVersion;evidence=$evidence}
}
function New-MmtlQuiltAdapterPlans {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Universe)
    if([string]$Project.Loader -cne 'Quilt'){throw 'QUILT_PROJECT_REQUIRED'}
    if(-not $Project.Toolchain -or [string]$Project.Toolchain.id -cne 'QuiltLoom'){throw 'QUILT_LOOM_REQUIRED'}
    if(-not $Project.BuildSystem -or [string]$Project.BuildSystem.id -cne 'GradleWrapper' -or [string]::IsNullOrWhiteSpace([string]$Project.WrapperPath)){throw 'QUILT_GRADLE_WRAPPER_REQUIRED'}
    $resolution=Resolve-MmtlQuiltAdapterTarget -Project $Project -Universe $Universe
    if($resolution.status -cne 'Resolved'){throw "QUILT_TARGET_UNRESOLVED:$($resolution.reasonCode)"}
    $target=@($Universe.targets|Where-Object{[string]$_.targetId -ceq [string]$resolution.targetId}|Select-Object -First 1)
    if(-not $target){throw 'QUILT_TARGET_MISSING_AFTER_RESOLUTION'}
    $build=[pscustomobject][ordered]@{contractVersion=2;adapterId='Quilt';targetId=[string]$resolution.targetId;projectRoot=[string]$Project.Root;buildSystem=$Project.BuildSystem;toolchain=$Project.Toolchain;task='build';workingDirectoryPolicy='MMTLManagedSessionCopy';wrapperPath=[string]$Project.WrapperPath;buildJavaRequirement=$Project.BuildJavaRequirement;isExecutablePlan=$false;executionGate='TRUSTED_VALIDATION_RUNNER_REQUIRED';evidence=@($resolution.evidence)}
    $launch=[pscustomobject][ordered]@{contractVersion=2;adapterId='Quilt';targetId=[string]$resolution.targetId;projectRoot=[string]$Project.Root;mode='Single';role='Client';task='runClient';workingDirectoryPolicy='MMTLManagedSessionCopy';wrapperPath=[string]$Project.WrapperPath;runtimeJavaRequirement=$target.runtimeJavaRequirement;sideEffectScope='MMTLManagedSession';isExecutablePlan=$false;executionGate='TRUSTED_VALIDATION_RUNNER_REQUIRED';launchCheckStatus='Unverified';evidenceScope='ExactUniverseTargetAndQuiltLoomProjectContract';evidence=@($resolution.evidence)}
    [pscustomobject][ordered]@{status='Resolved';targetId=[string]$resolution.targetId;evidence=@($resolution.evidence);buildPlan=$build;launchPlan=$launch}
}
function Get-MmtlQuiltClientMarkerHints { [CmdletBinding()]param([string]$MinecraftVersion) return @([pscustomobject]@{eventCode='CLIENT_INIT_DETECTED';pattern='(?i)\[(?:Render|Client) thread/INFO\]: Setting user:';description='Minecraft 客户端开始初始化'}) }
Export-ModuleMember -Function Get-MmtlQuiltAdapterProbe,New-MmtlQuiltAdapterBuildPlan,Resolve-MmtlQuiltAdapterTarget,New-MmtlQuiltAdapterPlans,Get-MmtlQuiltClientMarkerHints
