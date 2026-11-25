BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ledgerModule = Import-Module (Join-Path $script:repoRoot 'common/src/Compatibility/FullCompatibilityLedger.psm1') -Force -PassThru
}

Describe 'RuntimeBinding evidence claim validation' {
    It 'trusts the current fingerprint only when the registered RuntimeBinding source files match' {
        $fingerprint = & $script:ledgerModule { Get-MmtlRunTaskJvmBindingSourceFingerprint }
        $trusted = & $script:ledgerModule { param($hash) Test-MmtlRuntimeBindingProbeSourceHashTrusted -Hash $hash } $fingerprint.sha256

        $trusted | Should -BeTrue
    }

    It 'accepts non-Forge RuntimeBinding evidence without Forge-only metadata' {
        $universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $target = @($universe.targets | Where-Object targetId -CEQ 'Fabric@1.21.8')[0]
        $index = Get-Content (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        $targetEntries = @($index.entries | Where-Object targetId -CEQ 'Fabric@1.21.8')
        $miniUniverse = [pscustomobject]@{catalogHash=$universe.catalogHash;targets=@($target)}
        $miniIndex = [pscustomobject]@{schemaVersion=1;universeHash=$index.universeHash;entries=$targetEntries}

        { & $script:ledgerModule { param($u,$i,$root) Get-MmtlTargetEvidenceClaims -Universe $u -Index $i -EvidenceRoot $root } $miniUniverse $miniIndex $script:repoRoot } | Should -Not -Throw
    }

    It 'accepts the Fabric 26.3 RuntimeBinding claim against its exact BuildVerified evidence' {
        $universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $target = @($universe.targets | Where-Object targetId -CEQ 'Fabric@26.3')[0]
        $index = Get-Content (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        $targetEntries = @($index.entries | Where-Object targetId -CEQ 'Fabric@26.3')
        $miniUniverse = [pscustomobject]@{catalogHash=$universe.catalogHash;targets=@($target)}
        $miniIndex = [pscustomobject]@{schemaVersion=1;universeHash=$index.universeHash;entries=$targetEntries}

        { & $script:ledgerModule { param($u,$i,$root) Get-MmtlTargetEvidenceClaims -Universe $u -Index $i -EvidenceRoot $root } $miniUniverse $miniIndex $script:repoRoot } | Should -Not -Throw
    }

    It 'accepts the Fabric 1.21.11 direct RuntimeBinding claim against its exact BuildVerified evidence' {
        $universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $target = @($universe.targets | Where-Object targetId -CEQ 'Fabric@1.21.11')[0]
        $index = Get-Content (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        $targetEntries = @($index.entries | Where-Object targetId -CEQ 'Fabric@1.21.11')
        $miniUniverse = [pscustomobject]@{catalogHash=$universe.catalogHash;targets=@($target)}
        $miniIndex = [pscustomobject]@{schemaVersion=1;universeHash=$index.universeHash;entries=$targetEntries}

        { & $script:ledgerModule { param($u,$i,$root) Get-MmtlTargetEvidenceClaims -Universe $u -Index $i -EvidenceRoot $root } $miniUniverse $miniIndex $script:repoRoot } | Should -Not -Throw
    }
}
