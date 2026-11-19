Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimeBinding.psm1') -Force

function New-MmtlAdapterProbeResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AdapterId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,[Parameter(Mandatory)][ValidateSet('High','Medium','Low','Unknown')][string]$Confidence,[object]$RuntimeJavaBinding)
    if (-not $RuntimeJavaBinding) {
        $RuntimeJavaBinding = New-MmtlRuntimeBindingEvidence -AdapterId $AdapterId -Mode Unknown -Confidence Unknown -ProbeStrategy 'GradleJavaExecTaskInspection' -ReasonCode 'RUNTIME_JAVA_BINDING_UNPROBED'
    }
    [pscustomobject][ordered]@{contractVersion=2;adapterId=$AdapterId;matched=($Evidence.Count -gt 0);confidence=$Confidence;evidence=@($Evidence);conflicts=@();runtimeJavaBinding=$RuntimeJavaBinding}
}

function Resolve-MmtlProjectStack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence)
    $primaryEvidence=@($Evidence|Where-Object{-not $_.PSObject.Properties['role'] -or $_.role -ne 'Overlay'});$overlayEvidence=@($Evidence|Where-Object{$_.PSObject.Properties['role'] -and $_.role -eq 'Overlay'})
    $ids=@($primaryEvidence|ForEach-Object {[string]$_.loaderId}|Select-Object -Unique)
    $conflicts=@();if($ids.Count -gt 1){$conflicts=@("主 Loader 证据相互冲突：$($ids -join ', ')。")}
    $selected=if($ids.Count -eq 1){$ids[0]}else{'Unknown'}
    $stack=$null
    if($selected -ne 'Unknown' -and -not $conflicts.Count){
        $primary=$primaryEvidence|Where-Object loaderId -CEQ $selected|Select-Object -First 1
        $overlays=@($overlayEvidence|ForEach-Object{[pscustomobject]@{id=[string]$_.loaderId;version=if($_.PSObject.Properties['version']){[string]$_.version}else{$null};role='Overlay';evidence=$_}})
        $stack=[pscustomobject]@{primaryLoader=[pscustomobject]@{id=$selected;version=if($primary.PSObject.Properties['version']){[string]$primary.version}else{$null};role='Primary';evidence=$primary};overlayLoaders=$overlays}
    }
    [pscustomobject][ordered]@{contractVersion=2;status=if($conflicts.Count){'Ambiguous'}elseif($selected -eq 'Unknown'){'Undetected'}else{'Resolved'};loaderStack=$stack;loaderId=$selected;evidence=@($Evidence);conflicts=$conflicts}
}

function New-MmtlAdapterBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)
    if([string]$Project.Loader -ceq 'Rift'){return New-MmtlRiftAdapterBuildPlan -Project $Project}
    [pscustomobject][ordered]@{contractVersion=2;projectRoot=$Project.Root;buildSystem=$Project.BuildSystem;toolchain=$Project.Toolchain;task=$Project.BuildTask;workingDirectory=$Project.Root;wrapperPath=$Project.WrapperPath;buildJavaRequirement=$Project.BuildJavaRequirement;isExecutablePlan=$false}
}

function New-MmtlRiftAdapterBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)
    if([string]$Project.Loader -cne 'Rift' -or [string]$Project.MinecraftVersion -cne '1.13' -or [string]$Project.Toolchain.id -cne 'ForgeGradle' -or [string]$Project.Toolchain.version -cne '2.3-SNAPSHOT'){
        throw 'Rift BuildPlan 仅适用于已审计的 Rift 1.13 / ForgeGradle 2.3-SNAPSHOT family。'
    }
    $requirement=$Project.BuildJavaRequirement
    [pscustomobject][ordered]@{
        contractVersion=2
        adapterId='Rift'
        projectRoot=$Project.Root
        buildSystem=$Project.BuildSystem
        toolchain=$Project.Toolchain
        task='build'
        workingDirectory=$Project.Root
        wrapperPath=$Project.WrapperPath
        buildJavaRequirement=$requirement
        runtimeJavaRequirement=[pscustomobject][ordered]@{major=8;component='jre-legacy';source='MojangVersionMetadata';confidence='High';requirementKind='AuthoritativeMetadata';provenance=[pscustomobject][ordered]@{sourceUrl='https://piston-meta.mojang.com/v1/packages/c24c2fd37c8ca2e1c18721e2c77caf4d24c87f92/1.13.json';sha1='c24c2fd37c8ca2e1c18721e2c77caf4d24c87f92';snapshotSha256='a4db43540601793fe6b4d5c4823f4c55899b84912e48a7a73c00e798775ea2ba'}}
        isExecutablePlan=$false
        executionGate='PINNED_TRUSTED_TOOLCHAIN_REQUIRED'
        buildEvidence=[pscustomobject][ordered]@{
            target='Rift@1.13'
            evidenceScope='CanonicalPinnedFixtureOnly'
            riftSourceUrl='https://github.com/DimensionalDevelopment/Rift'
            riftSourceCommit='dfc75ff7254cbbea81535c02ddc5252e384ac806'
            forgeGradleSourceUrl='https://github.com/DimensionalDevelopment/ForgeGradle'
            forgeGradleSourceCommit='70d441a286c6673dc0288c3ade5fb8568ca5ce7f'
            buildTool='Gradle 4.9'
            buildJavaMajor=8
            minecraftConfiguration='mcp_config:1.13 + mcp_snapshot:20180908-1.13'
            result='BUILD_VERIFIED'
        }
        historical=[pscustomobject][ordered]@{
            sourceClass='HistoricalOfficial'
            trustClass='VerifiedHistorical'
            sourceTransportSecurity='Mixed'
            automaticArtifactExecution='Denied'
            validationStatus='BuildVerifiedForPinnedFixture'
            launchStatus='Unverified'
            safetyReason='Canonical fixture build rewrites obsolete HTTP repositories to HTTPS and substitutes a source-built, hash-recorded ForgeGradle artifact; arbitrary project builds remain gated.'
        }
        loaderStack=$Project.LoaderStack
    }
}

function New-MmtlRiftAdapterLaunchPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)
    $buildPlan = New-MmtlRiftAdapterBuildPlan -Project $Project
    [pscustomobject][ordered]@{
        contractVersion=2
        adapterId='Rift'
        target='Rift@1.13'
        projectRoot=$Project.Root
        mode='Single'
        role='Client'
        task='runClient'
        workingDirectory=$Project.Root
        wrapperPath=$Project.WrapperPath
        clientTweaker='org.dimdev.riftloader.launch.RiftLoaderClientTweaker'
        runtimeJavaRequirement=$buildPlan.runtimeJavaRequirement
        sideEffectScope='MMTLManagedSession'
        isExecutablePlan=$false
        executionGate='PINNED_TRUSTED_TOOLCHAIN_REQUIRED'
        launchCheckStatus='Unverified'
        evidenceScope='CanonicalPinnedFixtureSourceInspectionOnly'
    }
}

function Get-MmtlHistoricalAdapterProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LoaderId,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence)
    if($LoaderId -notin @('LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){throw "未知的历史适配器：$LoaderId"}
    $matched=@($Evidence|Where-Object loaderId -CEQ $LoaderId)
    New-MmtlAdapterProbeResult -AdapterId $LoaderId -Evidence $matched -Confidence $(if($matched.Count){[string]$matched[0].confidence}else{'Unknown'})
}

function New-MmtlHistoricalAdapterBuildPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)
    if($Project.Loader -notin @('LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')){throw '历史适配器需要对应的历史 Loader 证据。'}
    $plan=New-MmtlAdapterBuildPlan -Project $Project
    if([string]$Project.Loader -ceq 'Rift'){return $plan}
    $plan|Add-Member -NotePropertyName historical -NotePropertyValue ([pscustomobject]@{sourceClass='UnknownHistorical';trustClass='UnverifiedHistorical';automaticArtifactExecution='Denied';validationStatus='Unverified'})
    $plan|Add-Member -NotePropertyName loaderStack -NotePropertyValue $Project.LoaderStack
    return $plan
}

Export-ModuleMember -Function New-MmtlAdapterProbeResult,Resolve-MmtlProjectStack,New-MmtlAdapterBuildPlan,New-MmtlRiftAdapterBuildPlan,New-MmtlRiftAdapterLaunchPlan,Get-MmtlHistoricalAdapterProbe,New-MmtlHistoricalAdapterBuildPlan
