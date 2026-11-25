BeforeAll {
    $script:commonRoot = Split-Path -Parent $PSScriptRoot
    $script:repoRoot = Split-Path -Parent $script:commonRoot
    $script:ledgerModule = Import-Module (Join-Path $script:commonRoot 'src/Compatibility/FullCompatibilityLedger.psm1') -Force -PassThru
}

Describe 'Forge runtime binding ledger toolchain identity' {
    It 'trusts only the current and registered historical probe source fingerprints' {
        $bindingModule = Import-Module (Join-Path $script:repoRoot 'common/src/RunTaskJvmBinding.psm1') -Force -PassThru
        $currentHash = (& $bindingModule { (Get-MmtlRunTaskJvmBindingSourceFingerprint).sha256 })
        $historicalHash = '208115e733a69e2db09f6c29966474d33d52e6c44b33e8ae35f6506871619ab6'
        $previousCurrentHash = '031aa68d14831c5dc7bf6d6c90618bf39c5c138c17f795b1a966a8bff4160e87'
        $mirrorIntegrationPredecessorHash = 'f40fa383058a31843dae64a7900a603748964eb420f886fc0662e5c69b88433b'
        $artifactMetadataPredecessorHash = '2a087428d971c9103351a6553105e9f67e00e3df421448f1258bcb50e7aa5327'
        $isTrusted = & $script:ledgerModule {
            param($hash)
            Test-MmtlRuntimeBindingProbeSourceHashTrusted -Hash $hash
        } $historicalHash
        $isUntrusted = & $script:ledgerModule {
            param($hash)
            Test-MmtlRuntimeBindingProbeSourceHashTrusted -Hash $hash
        } ('0' * 64)

        $isTrusted | Should -BeTrue
        $isUntrusted | Should -BeFalse
        $previousCurrentTrusted = & $script:ledgerModule {
            param($hash)
            Test-MmtlRuntimeBindingProbeSourceHashTrusted -Hash $hash
        } $previousCurrentHash
        $previousCurrentTrusted | Should -BeTrue
        $mirrorPredecessorTrusted = & $script:ledgerModule {
            param($hash)
            Test-MmtlRuntimeBindingProbeSourceHashTrusted -Hash $hash
        } $mirrorIntegrationPredecessorHash
        $mirrorPredecessorTrusted | Should -BeTrue
        $artifactMetadataPredecessorTrusted = & $script:ledgerModule {
            param($hash)
            Test-MmtlRuntimeBindingProbeSourceHashTrusted -Hash $hash
        } $artifactMetadataPredecessorHash
        $artifactMetadataPredecessorTrusted | Should -BeTrue
        $currentTrusted = & $script:ledgerModule {
            param($hash)
            Test-MmtlRuntimeBindingProbeSourceHashTrusted -Hash $hash
        } $currentHash
        $currentTrusted | Should -BeTrue
    }

    It 'uses the active ForgeGradle plugin version when no forgeGradleSpec is recorded' {
        $universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $families = Get-Content (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
        $index = Get-Content (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json

        $ledger = & $script:ledgerModule {
            param($u, $f, $i, $root)
            New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -TargetEvidenceIndex $i -EvidenceRoot $root -GeneratedAt ([DateTimeOffset]'2026-10-11T00:00:00Z')
        } $universe $families $index $script:repoRoot

        $target = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.8' | Select-Object -First 1
        $target.dimensions.BuildVerified.status | Should -BeExactly 'Supported'
        $target.dimensions.RuntimeBinding.status | Should -BeExactly 'Supported'
        $runtimeEvidence = Get-Content (Join-Path $script:repoRoot 'compatibility/evidence/runtime-binding/Forge-1.8-Windows-x64.json') -Raw | ConvertFrom-Json
        $runtimeEvidence.toolchain.version | Should -BeExactly '2.0.2'
    }
}
