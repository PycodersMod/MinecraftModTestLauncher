Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../Platform/Platform.psm1') -Force

function Resolve-MmtlLegacyFabricAdapterTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)]$Universe)

    if ([string]$Project.Loader -cne 'LegacyFabric') { throw 'LEGACYFABRIC_PROJECT_REQUIRED' }
    if ([string]$Project.DetectionStatus -cne 'Resolved') { throw 'LEGACYFABRIC_PROJECT_DETECTION_UNRESOLVED' }
    if (-not $Project.Toolchain -or [string]$Project.Toolchain.id -cne 'LegacyLooming' -or [string]$Project.Toolchain.ecosystem -cne 'LegacyFabric') { throw 'LEGACYFABRIC_LOOMING_REQUIRED' }
    if (-not $Project.BuildSystem -or [string]$Project.BuildSystem.id -cne 'GradleWrapper' -or [string]::IsNullOrWhiteSpace([string]$Project.WrapperPath)) { throw 'LEGACYFABRIC_GRADLE_WRAPPER_REQUIRED' }
    if ([string]::IsNullOrWhiteSpace([string]$Project.Root) -or -not (Test-Path -LiteralPath $Project.Root -PathType Container)) { throw 'LEGACYFABRIC_PROJECT_ROOT_INVALID' }
    if (-not (Test-Path -LiteralPath $Project.WrapperPath -PathType Leaf) -or -not (Test-MmtlPlatformPathInsideRoot -Root ([string]$Project.Root) -Target ([string]$Project.WrapperPath))) { throw 'LEGACYFABRIC_GRADLE_WRAPPER_UNSAFE' }

    $universeHash = [string]$Universe.catalogHash
    if ($universeHash -notmatch '^(?i:[a-f0-9]{64})$') { throw 'UNIVERSE_HASH_INVALID' }
    $minecraftId = [string]$Project.MinecraftVersion
    $loaderVersion = [string]$Project.LoaderVersion
    if ([string]::IsNullOrWhiteSpace($minecraftId)) { return [pscustomobject][ordered]@{ status='Unresolved'; reasonCode='MINECRAFT_VERSION_UNRESOLVED'; targetId=$null; evidence=@("universe-sha256:$universeHash") } }
    if ([string]::IsNullOrWhiteSpace($loaderVersion)) { return [pscustomobject][ordered]@{ status='Unresolved'; reasonCode='LOADER_VERSION_UNRESOLVED'; targetId=$null; evidence=@("universe-sha256:$universeHash") } }

    $target = @($Universe.targets | Where-Object { [string]$_.loaderId -ceq 'LegacyFabric' -and [string]$_.minecraftId -ceq $minecraftId -and [string]$_.availability -ceq 'Available' }) | Select-Object -First 1
    if (-not $target) { return [pscustomobject][ordered]@{ status='Unresolved'; reasonCode='TARGET_NOT_IN_FROZEN_UNIVERSE'; targetId=$null; evidence=@("universe-sha256:$universeHash") } }
    if ([string]$target.targetId -cne "LegacyFabric@$minecraftId" -or [string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates | Where-Object { [string]$_ -ceq $loaderVersion }).Count -eq 0) {
        return [pscustomobject][ordered]@{ status='Unresolved'; reasonCode='LOADER_VERSION_NOT_IN_FROZEN_CANDIDATES'; targetId=$null; evidence=@("universe-sha256:$universeHash") }
    }

    $evidence = [Collections.Generic.List[string]]::new()
    $evidence.Add("universe-sha256:$universeHash")
    if (-not [string]::IsNullOrWhiteSpace([string]$target.sourceHash)) { $evidence.Add("source-sha256:$([string]$target.sourceHash)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$target.authoritativeSource)) { $evidence.Add("source-url:$([string]$target.authoritativeSource)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$target.candidateSourceHash)) { $evidence.Add("candidate-source-sha256:$([string]$target.candidateSourceHash)") }
    if (-not [string]::IsNullOrWhiteSpace([string]$target.candidateSourceUrl)) { $evidence.Add("candidate-source-url:$([string]$target.candidateSourceUrl)") }
    [pscustomobject][ordered]@{ status='Resolved'; reasonCode=$null; targetId=[string]$target.targetId; minecraftId=$minecraftId; loaderVersion=$loaderVersion; evidence=@($evidence.ToArray()) }
}

function New-MmtlLegacyFabricAdapterPlans {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)]$Universe)

    $resolution = Resolve-MmtlLegacyFabricAdapterTarget -Project $Project -Universe $Universe
    if ([string]$resolution.status -cne 'Resolved') { throw "LEGACYFABRIC_TARGET_UNRESOLVED:$($resolution.reasonCode)" }
    $target = @($Universe.targets | Where-Object { [string]$_.targetId -ceq [string]$resolution.targetId } | Select-Object -First 1)
    if (-not $target) { throw 'LEGACYFABRIC_TARGET_MISSING_AFTER_RESOLUTION' }

    $buildPlan = [pscustomobject][ordered]@{
        contractVersion=2; adapterId='LegacyFabric'; targetId=[string]$resolution.targetId
        projectRoot=[string]$Project.Root; buildSystem=$Project.BuildSystem; toolchain=$Project.Toolchain
        task='build'; workingDirectoryPolicy='MMTLManagedSessionCopy'; wrapperPath=[string]$Project.WrapperPath
        buildJavaRequirement=$Project.BuildJavaRequirement; isExecutablePlan=$false
        executionGate='TRUSTED_VALIDATION_RUNNER_REQUIRED'; evidence=@($resolution.evidence)
    }
    $launchPlan = [pscustomobject][ordered]@{
        contractVersion=2; adapterId='LegacyFabric'; targetId=[string]$resolution.targetId
        projectRoot=[string]$Project.Root; mode='Single'; role='Client'; task='runClient'
        workingDirectoryPolicy='MMTLManagedSessionCopy'; wrapperPath=[string]$Project.WrapperPath
        runtimeJavaRequirement=$target[0].runtimeJavaRequirement; sideEffectScope='MMTLManagedSession'
        isExecutablePlan=$false; executionGate='TRUSTED_VALIDATION_RUNNER_REQUIRED'; launchCheckStatus='Unverified'
        evidenceScope='ExactUniverseTargetAndLegacyLoomingProjectContract'; evidence=@($resolution.evidence)
    }
    [pscustomobject][ordered]@{ status='Resolved'; targetId=[string]$resolution.targetId; evidence=@($resolution.evidence); buildPlan=$buildPlan; launchPlan=$launchPlan }
}

Export-ModuleMember -Function Resolve-MmtlLegacyFabricAdapterTarget, New-MmtlLegacyFabricAdapterPlans
