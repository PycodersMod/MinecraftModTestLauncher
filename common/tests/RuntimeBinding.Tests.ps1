BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:runtimeBindingModule=Import-Module (Join-Path $script:repoRoot 'src/Adapters/RuntimeBinding.psm1') -Force -PassThru
    function New-TestRuntimeBindingEvidence { param([hashtable]$Options) & $script:runtimeBindingModule { param($parameters) New-MmtlRuntimeBindingEvidence @parameters } $Options }
    function Resolve-TestRuntimeBinding { param([object[]]$Items) & $script:runtimeBindingModule { param($evidence) Resolve-MmtlRuntimeBinding -Evidence $evidence } $Items }
    Import-Module (Join-Path $script:repoRoot 'src/Adapters/Forge.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Adapters/Fabric.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Adapters/NeoForge.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Adapters/Quilt.psm1') -Force
}

Describe 'Runtime Binding contract' {
    It '保留五种稳定 Binding mode 和机器可读字段' {
        $modes=@('Direct','SameAsBuildJvm','ToolchainManaged','Unsupported','Unknown')
        foreach($mode in $modes){
            $evidence=New-TestRuntimeBindingEvidence @{AdapterId='FixtureToolchain';Mode=$mode;EvidenceSource='FixtureTaskInspection';Confidence='Medium';RuntimeJavaControllable=$false;RequiresBuildJvmMatch=($mode -eq 'SameAsBuildJvm');ProbeStrategy='GradleJavaExecTaskInspection';ReasonCode='FIXTURE_EVIDENCE';Notes='受控 fixture'}
            $evidence.mode | Should -BeExactly $mode
            $evidence.evidenceSource | Should -BeExactly 'FixtureTaskInspection'
            $evidence.confidence | Should -BeExactly 'Medium'
            $evidence.runtimeJavaControllable | Should -BeFalse
            $evidence.requiresBuildJvmMatch | Should -Be ($mode -eq 'SameAsBuildJvm')
            $evidence.probeStrategy | Should -BeExactly 'GradleJavaExecTaskInspection'
            $evidence.reasonCode | Should -BeExactly 'FIXTURE_EVIDENCE'
            $evidence.notes | Should -BeExactly '受控 fixture'
        }
    }

    It '没有可信来源时将请求的 Direct 降级为 Unknown' {
        $evidence=New-TestRuntimeBindingEvidence @{AdapterId='FixtureToolchain';Mode='Direct';EvidenceSource='';Confidence='High';RuntimeJavaControllable=$true;RequiresBuildJvmMatch=$false;ProbeStrategy='GradleJavaExecTaskInspection'}
        $resolved=Resolve-TestRuntimeBinding @($evidence)

        $resolved.mode | Should -BeExactly 'Unknown'
        $resolved.reasonCode | Should -BeExactly 'RUNTIME_BINDING_EVIDENCE_SOURCE_MISSING'
    }

    It 'Direct 缺少最终 JVM 可控证据时不能获准' {
        $evidence=New-TestRuntimeBindingEvidence @{AdapterId='FixtureToolchain';Mode='Direct';EvidenceSource='GradleTaskInspection';Confidence='High';RuntimeJavaControllable=$false;RequiresBuildJvmMatch=$false;ProbeStrategy='GradleJavaExecTaskInspection'}
        $resolved=Resolve-TestRuntimeBinding @($evidence)

        $resolved.mode | Should -BeExactly 'Unknown'
        $resolved.reasonCode | Should -BeExactly 'RUNTIME_BINDING_DIRECT_CONTROL_UNPROVEN'
    }

    It '只有记录了最终 Java launcher 观察结果时才接受 Direct' {
        $evidence=New-TestRuntimeBindingEvidence @{AdapterId='FixtureToolchain';Mode='Direct';EvidenceSource='GradleTaskInspection';Confidence='High';RuntimeJavaControllable=$true;RequiresBuildJvmMatch=$false;ProbeStrategy='GradleJavaExecTaskInspection';EvidenceDetails=@([pscustomobject]@{task='runClient';taskType='JavaExec';launcherSource='javaLauncher'})}
        $resolved=Resolve-TestRuntimeBinding @($evidence)

        $resolved.mode | Should -BeExactly 'Direct'
        $resolved.evidenceDetails[0].launcherSource | Should -BeExactly 'javaLauncher'
    }

    It 'SameAsBuildJvm 必须声明并证明 Build JVM 匹配要求' {
        $evidence=New-TestRuntimeBindingEvidence @{AdapterId='FixtureToolchain';Mode='SameAsBuildJvm';EvidenceSource='GradleTaskInspection';Confidence='High';RuntimeJavaControllable=$false;RequiresBuildJvmMatch=$false;ProbeStrategy='GradleJavaExecTaskInspection'}
        $resolved=Resolve-TestRuntimeBinding @($evidence)

        $resolved.mode | Should -BeExactly 'Unknown'
        $resolved.reasonCode | Should -BeExactly 'RUNTIME_BINDING_BUILD_JVM_MATCH_UNPROVEN'
    }

    It '冲突的独立 Adapter 证据不会被静默择一' {
        $first=New-TestRuntimeBindingEvidence @{AdapterId='FixtureA';Mode='SameAsBuildJvm';EvidenceSource='InspectionA';Confidence='High';RuntimeJavaControllable=$false;RequiresBuildJvmMatch=$true;ProbeStrategy='TaskInspection'}
        $second=New-TestRuntimeBindingEvidence @{AdapterId='FixtureB';Mode='ToolchainManaged';EvidenceSource='InspectionB';Confidence='High';RuntimeJavaControllable=$false;RequiresBuildJvmMatch=$false;ProbeStrategy='TaskInspection'}
        $resolved=Resolve-TestRuntimeBinding @($first,$second)

        $resolved.mode | Should -BeExactly 'Unknown'
        $resolved.reasonCode | Should -BeExactly 'RUNTIME_BINDING_EVIDENCE_CONFLICT'
        $resolved.conflicts.Count | Should -Be 2
    }

    It '四个主流 Adapter 都声明探测策略且未探测前保持 Unknown' {
        $probes=@(
            (Get-MmtlForgeAdapterProbe -Evidence @())
            (Get-MmtlFabricAdapterProbe -Evidence @())
            (Get-MmtlNeoForgeAdapterProbe -Evidence @())
            (Get-MmtlQuiltAdapterProbe -Evidence @())
        )
        $probes.Count | Should -Be 4
        foreach($probe in $probes){
            $probe.runtimeJavaBinding.mode | Should -BeExactly 'Unknown'
            $probe.runtimeJavaBinding.probeStrategy | Should -BeExactly 'GradleJavaExecTaskInspection'
            $probe.runtimeJavaBinding.confidence | Should -BeExactly 'Unknown'
        }
    }
}
