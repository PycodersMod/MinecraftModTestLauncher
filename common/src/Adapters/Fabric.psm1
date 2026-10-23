Import-Module (Join-Path $PSScriptRoot 'ContractV2.psm1') -Force
function Test-MmtlFabricProject { param($Project) return $Project.Loader -eq 'Fabric' }
function Get-MmtlFabricAdapterProbe { [CmdletBinding()]param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,[AllowNull()][object]$RuntimeJavaBinding) $matched=@($Evidence|Where-Object loaderId -CEQ 'Fabric');New-MmtlAdapterProbeResult -AdapterId Fabric -Evidence $matched -Confidence $(if($matched.Count){'High'}else{'Unknown'}) -RuntimeJavaBinding $RuntimeJavaBinding }
function New-MmtlFabricAdapterBuildPlan { [CmdletBinding()]param([Parameter(Mandatory)]$Project) if(-not(Test-MmtlFabricProject $Project)){throw 'Fabric 适配器需要 Fabric 项目证据。'};New-MmtlAdapterBuildPlan -Project $Project }
function New-MmtlFabricAdapterPlans {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Universe)
    if(-not(Test-MmtlFabricProject $Project)){throw 'FABRIC_PROJECT_REQUIRED'}
    if(-not $Project.Toolchain -or [string]$Project.Toolchain.id -cne 'FabricLoom'){throw 'FABRIC_LOOM_REQUIRED'}
    if(-not $Project.BuildSystem -or [string]$Project.BuildSystem.id -cne 'GradleWrapper' -or [string]::IsNullOrWhiteSpace([string]$Project.WrapperPath)){throw 'FABRIC_GRADLE_WRAPPER_REQUIRED'}
    $resolution=Resolve-MmtlFabricAdapterTarget -Project $Project -Universe $Universe
    if($resolution.status -cne 'Resolved'){throw "FABRIC_TARGET_UNRESOLVED:$($resolution.reasonCode)"}
    $target=@($Universe.targets|Where-Object{[string]$_.targetId -ceq [string]$resolution.targetId}|Select-Object -First 1)
    if(-not $target){throw 'FABRIC_TARGET_MISSING_AFTER_RESOLUTION'}
    $build=[pscustomobject][ordered]@{
        contractVersion=2;adapterId='Fabric';targetId=[string]$resolution.targetId
        projectRoot=[string]$Project.Root;buildSystem=$Project.BuildSystem;toolchain=$Project.Toolchain
        task='build';workingDirectoryPolicy='MMTLManagedSessionCopy';wrapperPath=[string]$Project.WrapperPath
        buildJavaRequirement=$Project.BuildJavaRequirement;isExecutablePlan=$false
        executionGate='TRUSTED_VALIDATION_RUNNER_REQUIRED';evidence=@($resolution.evidence)
    }
    $launch=[pscustomobject][ordered]@{
        contractVersion=2;adapterId='Fabric';targetId=[string]$resolution.targetId
        projectRoot=[string]$Project.Root;mode='Single';role='Client';task='runClient'
        workingDirectoryPolicy='MMTLManagedSessionCopy';wrapperPath=[string]$Project.WrapperPath
        runtimeJavaRequirement=$target.runtimeJavaRequirement;sideEffectScope='MMTLManagedSession'
        isExecutablePlan=$false;executionGate='TRUSTED_VALIDATION_RUNNER_REQUIRED'
        launchCheckStatus='Unverified';evidenceScope='ExactUniverseTargetAndFabricLoomProjectContract'
        evidence=@($resolution.evidence)
    }
    [pscustomobject][ordered]@{status='Resolved';targetId=[string]$resolution.targetId;evidence=@($resolution.evidence);buildPlan=$build;launchPlan=$launch}
}
function Resolve-MmtlFabricAdapterTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Universe)
    if(-not(Test-MmtlFabricProject $Project)){throw 'Fabric 目标解析需要 Fabric 项目证据。'}
    $universeHash=[string]$Universe.catalogHash
    if($universeHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'UNIVERSE_HASH_INVALID'}
    $minecraftId=[string]$Project.MinecraftVersion
    if([string]::IsNullOrWhiteSpace($minecraftId)){
        return [pscustomobject][ordered]@{status='Unresolved';reasonCode='MINECRAFT_VERSION_UNRESOLVED';targetId=$null;minecraftId=$null;loaderVersion=[string]$Project.LoaderVersion;evidence=@()}
    }
    $target=@($Universe.targets|Where-Object{$_.loaderId -ceq 'Fabric' -and $_.minecraftId -ceq $minecraftId -and $_.availability -ceq 'Available'})|Select-Object -First 1
    if(-not $target){
        return [pscustomobject][ordered]@{status='Unresolved';reasonCode='TARGET_NOT_IN_FROZEN_UNIVERSE';targetId=$null;minecraftId=$minecraftId;loaderVersion=[string]$Project.LoaderVersion;evidence=@("universe-sha256:$universeHash")}
    }
    $loaderVersion=[string]$Project.LoaderVersion
    if([string]::IsNullOrWhiteSpace($loaderVersion)){
        return [pscustomobject][ordered]@{status='Unresolved';reasonCode='LOADER_VERSION_UNRESOLVED';targetId=$null;minecraftId=$minecraftId;loaderVersion=$null;evidence=@("universe-sha256:$universeHash")}
    }
    if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates|Where-Object{[string]$_ -ceq $loaderVersion}).Count -eq 0){
        return [pscustomobject][ordered]@{status='Unresolved';reasonCode='LOADER_VERSION_NOT_IN_FROZEN_CANDIDATES';targetId=$null;minecraftId=$minecraftId;loaderVersion=$loaderVersion;evidence=@("universe-sha256:$universeHash")}
    }
    $evidence=@("universe-sha256:$universeHash")
    if(-not [string]::IsNullOrWhiteSpace([string]$target.sourceHash)){$evidence+="source-sha256:$([string]$target.sourceHash)"}
    if(-not [string]::IsNullOrWhiteSpace([string]$target.candidateSourceHash)){$evidence+="candidate-source-sha256:$([string]$target.candidateSourceHash)"}
    [pscustomobject][ordered]@{status='Resolved';reasonCode=$null;targetId=[string]$target.targetId;minecraftId=$minecraftId;loaderVersion=$loaderVersion;evidence=$evidence}
}
function Get-MmtlFabricClientMarkerHints { [CmdletBinding()]param([string]$MinecraftVersion) return @([pscustomobject]@{eventCode='CLIENT_INIT_DETECTED';pattern='(?i)\[(?:Render|Client) thread/INFO\]: Setting user:';description='Minecraft 客户端开始初始化'}) }
Export-ModuleMember -Function Test-MmtlFabricProject,Get-MmtlFabricAdapterProbe,New-MmtlFabricAdapterBuildPlan,New-MmtlFabricAdapterPlans,Resolve-MmtlFabricAdapterTarget,Get-MmtlFabricClientMarkerHints
