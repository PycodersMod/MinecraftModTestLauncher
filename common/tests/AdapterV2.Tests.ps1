BeforeAll { $root=Split-Path -Parent $PSScriptRoot;$script:contractModule=Import-Module (Join-Path $root 'src/Adapters/ContractV2.psm1') -Force -PassThru;Import-Module (Join-Path $root 'src/Adapters/Forge.psm1') -Force;Import-Module (Join-Path $root 'src/Adapters/Fabric.psm1') -Force;Import-Module (Join-Path $root 'src/Adapters/NeoForge.psm1') -Force;Import-Module (Join-Path $root 'src/Adapters/Quilt.psm1') -Force;Import-Module (Join-Path $root 'src/Architecture/Contracts.psm1') -Force }
Describe 'Adapter Contract v2' {
    It 'resolves evidence without upgrading upstream presence into validation claims' {
        $e=@([pscustomobject]@{loaderId='Quilt';source='GradlePlugin';confidence='High'})
        $r=& $script:contractModule { param($items) Resolve-MmtlProjectStack -Evidence $items } $e
        $r.contractVersion | Should -Be 2;$r.status | Should -Be 'Resolved';$r.loaderId | Should -BeExactly 'Quilt'
        $r.PSObject.Properties.Name | Should -Not -Contain 'validationLevel'
    }
    It 'marks conflicting evidence ambiguous' {
        $e=@([pscustomobject]@{loaderId='Fabric'},[pscustomobject]@{loaderId='Forge'});$r=& $script:contractModule { param($items) Resolve-MmtlProjectStack -Evidence $items } $e
        $r.status | Should -Be 'Ambiguous';$r.conflicts.Count | Should -Be 1
    }
    It 'accepts QuiltLoom as a distinct toolchain' { (New-MmtlToolchainContext -Id QuiltLoom).id | Should -BeExactly 'QuiltLoom' }
    It 'exposes a v2 probe for all four mainstream adapters' {
        (Get-MmtlForgeAdapterProbe -Evidence @([pscustomobject]@{loaderId='Forge'})).contractVersion | Should -Be 2
        (Get-MmtlFabricAdapterProbe -Evidence @([pscustomobject]@{loaderId='Fabric'})).adapterId | Should -BeExactly 'Fabric'
        (Get-MmtlNeoForgeAdapterProbe -Evidence @([pscustomobject]@{loaderId='NeoForge'})).adapterId | Should -BeExactly 'NeoForge'
        (Get-MmtlQuiltAdapterProbe -Evidence @([pscustomobject]@{loaderId='Quilt'})).adapterId | Should -BeExactly 'Quilt'
    }

    It 'resolves a Fabric prerelease target by exact frozen Minecraft and Loader versions' {
        $project=[pscustomobject]@{Loader='Fabric';MinecraftVersion='1.14 Pre-Release 1';LoaderVersion='0.8.0+build.192'}
        $universe=[pscustomobject]@{catalogHash=('a'*64);targets=@([pscustomobject]@{targetId='Fabric@1.14 Pre-Release 1';loaderId='Fabric';minecraftId='1.14 Pre-Release 1';availability='Available';candidateStatus='Resolved';loaderVersionCandidates=@('0.8.0+build.192');sourceHash=('b'*64);candidateSourceHash=('c'*64)})}

        $result=Resolve-MmtlFabricAdapterTarget -Project $project -Universe $universe

        $result.status | Should -BeExactly 'Resolved'
        $result.targetId | Should -BeExactly 'Fabric@1.14 Pre-Release 1'
        $result.minecraftId | Should -BeExactly '1.14 Pre-Release 1'
        $result.loaderVersion | Should -BeExactly '0.8.0+build.192'
        $result.evidence | Should -Contain "universe-sha256:$('a'*64)"
    }

    It 'does not treat a version range as an exact Fabric target' {
        $project=[pscustomobject]@{Loader='Fabric';MinecraftVersion='1.20.x';LoaderVersion='0.15.0'}
        $universe=[pscustomobject]@{catalogHash=('a'*64);targets=@([pscustomobject]@{targetId='Fabric@1.20.1';loaderId='Fabric';minecraftId='1.20.1';availability='Available';candidateStatus='Resolved';loaderVersionCandidates=@('0.15.0')})}

        $result=Resolve-MmtlFabricAdapterTarget -Project $project -Universe $universe

        $result.status | Should -BeExactly 'Unresolved'
        $result.reasonCode | Should -BeExactly 'TARGET_NOT_IN_FROZEN_UNIVERSE'
        $result.targetId | Should -BeNullOrEmpty
    }

    It 'keeps a missing Fabric Loader version unresolved' {
        $project=[pscustomobject]@{Loader='Fabric';MinecraftVersion='1.20.1';LoaderVersion=$null}
        $universe=[pscustomobject]@{catalogHash=('a'*64);targets=@([pscustomobject]@{targetId='Fabric@1.20.1';loaderId='Fabric';minecraftId='1.20.1';availability='Available';candidateStatus='Resolved';loaderVersionCandidates=@('0.15.0')})}

        $result=Resolve-MmtlFabricAdapterTarget -Project $project -Universe $universe

        $result.status | Should -BeExactly 'Unresolved'
        $result.reasonCode | Should -BeExactly 'LOADER_VERSION_UNRESOLVED'
    }

    It 'creates exact Fabric Build and Launch plans while keeping execution gated' {
        $project=[pscustomobject]@{
            Loader='Fabric';MinecraftVersion='26.1-snapshot-1';LoaderVersion='0.19.2';Root='C:/fixture/fabric'
            WrapperPath='C:/fixture/fabric/gradlew.bat';BuildTask='build';BuildSystem=[pscustomobject]@{id='GradleWrapper'}
            Toolchain=[pscustomobject]@{id='FabricLoom';version='1.16-SNAPSHOT'}
            BuildJavaRequirement=[pscustomobject]@{major=25;requirementKind='Minimum'}
        }
        $universe=[pscustomobject]@{
            catalogHash=('a'*64)
            targets=@([pscustomobject]@{
                targetId='Fabric@26.1-snapshot-1';loaderId='Fabric';minecraftId='26.1-snapshot-1';availability='Available'
                candidateStatus='Resolved';loaderVersionCandidates=@('0.19.2');sourceHash=('b'*64);candidateSourceHash=('c'*64)
                runtimeJavaRequirement=[pscustomobject]@{major=25;source='MojangVersionMetadata';requirementKind='AuthoritativeMetadata'}
            })
        }

        $plans=New-MmtlFabricAdapterPlans -Project $project -Universe $universe

        $plans.status | Should -BeExactly 'Resolved'
        $plans.targetId | Should -BeExactly 'Fabric@26.1-snapshot-1'
        $plans.buildPlan.task | Should -BeExactly 'build'
        $plans.buildPlan.targetId | Should -BeExactly 'Fabric@26.1-snapshot-1'
        $plans.buildPlan.isExecutablePlan | Should -BeFalse
        $plans.launchPlan.task | Should -BeExactly 'runClient'
        $plans.launchPlan.mode | Should -BeExactly 'Single'
        $plans.launchPlan.runtimeJavaRequirement.major | Should -Be 25
        $plans.launchPlan.workingDirectoryPolicy | Should -BeExactly 'MMTLManagedSessionCopy'
        $plans.launchPlan.isExecutablePlan | Should -BeFalse
    }

    It 'rejects a Fabric Build and Launch plan when Loom is not detected' {
        $project=[pscustomobject]@{Loader='Fabric';MinecraftVersion='1.20.1';LoaderVersion='0.15.0';Toolchain=[pscustomobject]@{id='Unknown'}}
        $universe=[pscustomobject]@{catalogHash=('a'*64);targets=@([pscustomobject]@{targetId='Fabric@1.20.1';loaderId='Fabric';minecraftId='1.20.1';availability='Available';candidateStatus='Resolved';loaderVersionCandidates=@('0.15.0')})}

        { New-MmtlFabricAdapterPlans -Project $project -Universe $universe } | Should -Throw '*FABRIC_LOOM_REQUIRED*'
    }
}
