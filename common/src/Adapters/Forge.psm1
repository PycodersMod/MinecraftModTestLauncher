Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Test-MmtlForgeProject { param($Project) return $Project.Loader -eq 'Forge' }
function Get-MmtlForgeAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,[AllowNull()][object]$RuntimeJavaBinding) $matched=@($Evidence|Where-Object loaderId -CEQ 'Forge');New-MmtlAdapterProbeResult -AdapterId Forge -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) -RuntimeJavaBinding $RuntimeJavaBinding }
function New-MmtlForgeAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if(-not(Test-MmtlForgeProject $Project)){throw 'Forge 适配器需要 Forge 项目证据。'};New-MmtlAdapterBuildPlan -Project $Project }
function Resolve-MmtlForgeAdapterTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Universe)
    if(-not(Test-MmtlForgeProject $Project)){throw 'FORGE_PROJECT_REQUIRED'}
    $universeHash=[string]$Universe.catalogHash
    if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
    $minecraftId=[string]$Project.MinecraftVersion
    if([string]::IsNullOrWhiteSpace($minecraftId)){return [pscustomobject][ordered]@{status='Unresolved';reasonCode='MINECRAFT_VERSION_UNRESOLVED';targetId=$null;minecraftId=$null;loaderVersion=[string]$Project.LoaderVersion;evidence=@()}}
    $target=@($Universe.targets|Where-Object{$_.loaderId -ceq 'Forge' -and $_.minecraftId -ceq $minecraftId -and $_.availability -ceq 'Available'}|Select-Object -First 1)
    if(-not $target){return [pscustomobject][ordered]@{status='Unresolved';reasonCode='TARGET_NOT_IN_FROZEN_UNIVERSE';targetId=$null;minecraftId=$minecraftId;loaderVersion=[string]$Project.LoaderVersion;evidence=@("universe-sha256:$universeHash")}}
    $loaderVersion=[string]$Project.LoaderVersion
    if([string]::IsNullOrWhiteSpace($loaderVersion)){return [pscustomobject][ordered]@{status='Unresolved';reasonCode='LOADER_VERSION_UNRESOLVED';targetId=$null;minecraftId=$minecraftId;loaderVersion=$null;evidence=@("universe-sha256:$universeHash")}}
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates|Where-Object{[string]$_ -ceq $loaderVersion}).Count -eq 0){return [pscustomobject][ordered]@{status='Unresolved';reasonCode='LOADER_VERSION_NOT_IN_FROZEN_CANDIDATES';targetId=$null;minecraftId=$minecraftId;loaderVersion=$loaderVersion;evidence=@("universe-sha256:$universeHash")}}
    $evidence=@("universe-sha256:$universeHash")
    if(-not [string]::IsNullOrWhiteSpace([string]$target.sourceHash)){$evidence+="source-sha256:$([string]$target.sourceHash)"}
    if(-not [string]::IsNullOrWhiteSpace([string]$target.candidateSourceHash)){$evidence+="candidate-source-sha256:$([string]$target.candidateSourceHash)"}
    [pscustomobject][ordered]@{status='Resolved';reasonCode=$null;targetId=[string]$target.targetId;minecraftId=$minecraftId;loaderVersion=$loaderVersion;evidence=$evidence}
}
function New-MmtlForgeAdapterPlans {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Universe)
    if(-not(Test-MmtlForgeProject $Project)){throw 'FORGE_PROJECT_REQUIRED'}
    if(-not $Project.Toolchain -or [string]$Project.Toolchain.id -cne 'ForgeGradle'){throw 'FORGE_GRADLE_TOOLCHAIN_REQUIRED'}
    if(-not $Project.BuildSystem -or [string]$Project.BuildSystem.id -cne 'GradleWrapper' -or [string]::IsNullOrWhiteSpace([string]$Project.WrapperPath)){throw 'FORGE_GRADLE_WRAPPER_REQUIRED'}
    $resolution=Resolve-MmtlForgeAdapterTarget -Project $Project -Universe $Universe
    if($resolution.status -cne 'Resolved'){throw "FORGE_TARGET_UNRESOLVED:$($resolution.reasonCode)"}
    $target=@($Universe.targets|Where-Object{[string]$_.targetId -ceq [string]$resolution.targetId}|Select-Object -First 1)
    if(-not $target){throw 'FORGE_TARGET_MISSING_AFTER_RESOLUTION'}
    $build=[pscustomobject][ordered]@{contractVersion=2;adapterId='Forge';targetId=[string]$resolution.targetId;projectRoot=[string]$Project.Root;buildSystem=$Project.BuildSystem;toolchain=$Project.Toolchain;task='build';workingDirectoryPolicy='MMTLManagedSessionCopy';wrapperPath=[string]$Project.WrapperPath;buildJavaRequirement=$Project.BuildJavaRequirement;isExecutablePlan=$false;executionGate='TRUSTED_VALIDATION_RUNNER_REQUIRED';evidence=@($resolution.evidence)}
    $launch=[pscustomobject][ordered]@{contractVersion=2;adapterId='Forge';targetId=[string]$resolution.targetId;projectRoot=[string]$Project.Root;mode='Single';role='Client';task='runClient';workingDirectoryPolicy='MMTLManagedSessionCopy';wrapperPath=[string]$Project.WrapperPath;runtimeJavaRequirement=$target.runtimeJavaRequirement;sideEffectScope='MMTLManagedSession';isExecutablePlan=$false;executionGate='TRUSTED_VALIDATION_RUNNER_REQUIRED';launchCheckStatus='Unverified';evidenceScope='ExactUniverseTargetAndForgeGradleProjectContract';evidence=@($resolution.evidence)}
    [pscustomobject][ordered]@{status='Resolved';targetId=[string]$resolution.targetId;evidence=@($resolution.evidence);buildPlan=$build;launchPlan=$launch}
}
function Get-MmtlForgeClientMarkerHints { [CmdletBinding()]param([string]$MinecraftVersion) return @([pscustomobject]@{eventCode='CLIENT_INIT_DETECTED';pattern='(?i)\[(?:Render|Client) thread/INFO\]: Setting user:';description='Minecraft 客户端开始初始化'}) }
Export-ModuleMember -Function Test-MmtlForgeProject,Get-MmtlForgeAdapterProbe,New-MmtlForgeAdapterBuildPlan,Resolve-MmtlForgeAdapterTarget,New-MmtlForgeAdapterPlans,Get-MmtlForgeClientMarkerHints
