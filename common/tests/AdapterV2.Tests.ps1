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
}
