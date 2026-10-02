BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Audit/CoverageAudit.psm1') -Force
    $script:catalog=[pscustomobject]@{source='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';manifestHash=('d'*64);minimumReleaseId='1.0';latestRelease='1.0';entries=@([pscustomobject]@{id='1.0';type='release';releaseTime='2011-11-18T00:00:00Z';runtimeJava=[pscustomobject]@{major=$null;source='Unknown'}})}
}

Describe 'Live provider input aggregation' {
    It 'isolates absent offline indexes, explains unknown states, and always includes manual mode' {
        $inputs=New-MmtlLiveCoverageProviderInputs -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'offline-no-cache') -Offline
        $audit=New-MmtlCoverageAudit -Catalog $script:catalog -RuntimeRoot $TestDrive -ProviderInputs $inputs -Offline
        $audit.releases[0].manualModes.JarMod.availability | Should -BeExactly 'Manual'
        foreach($loader in @('Forge','Fabric','NeoForge','Quilt')){
            $state=$audit.releases[0].mainstreamLoaders.$loader
            $state.availability | Should -BeExactly 'Unknown'
            $state.reasonCode | Should -Not -BeNullOrEmpty
            $state.notes.Count | Should -BeGreaterThan 0
        }
        (Test-Json -Json ($audit|ConvertTo-Json -Depth 50 -Compress) -SchemaFile (Join-Path $script:repoRoot 'schemas/coverage-audit.schema.json')) | Should -BeTrue
    }
}
