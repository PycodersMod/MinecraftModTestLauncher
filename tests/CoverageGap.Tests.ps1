BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Audit/CoverageAudit.psm1') -Force
}

Describe 'Coverage invariants and reason-code registry' {
    It 'registers stable reason codes and detects unexplained states, missing evidence, and unsafe trust escalation' {
        $codes=Get-MmtlCoverageReasonCodes
        $codes | Should -Contain 'HISTORICAL_SOURCE_NO_RECORD'
        $codes | Should -Contain 'UNMAPPED_UPSTREAM_VERSION'
        $catalog=[pscustomobject]@{source='https://piston-meta.mojang.com/manifest';manifestHash=('c'*64);minimumReleaseId='1.0';latestRelease='1.0';entries=@([pscustomobject]@{id='1.0';type='release';releaseTime='2011-11-18T00:00:00Z';runtimeJava=$null})}
        $state=[pscustomobject]@{availability='Unknown';reasonCode='NOT_REGISTERED';source='https://example.invalid';sourceClass='VerifiedCommunityArchive';cacheStatus='Fresh';lastChecked=$null;notes=@();candidateCount=0;candidates=@();provenance=@();trustClass='TrustedOfficial'}
        $states=@{};foreach($loader in @('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP')){$states[$loader]=$state};$states.JarMod=[pscustomobject]@{availability='Manual';reasonCode='MANUAL_ARTIFACT_REQUIRED';source=$null;sourceClass='ManualArtifact';cacheStatus='NotApplicable';lastChecked=$null;notes=@('manual only');candidateCount=0;candidates=@();provenance=@([pscustomobject]@{reason='manual'})}
        $audit=New-MmtlCoverageAudit -Catalog $catalog -RuntimeRoot $TestDrive -ProviderInputs ([pscustomobject]@{byRelease=@{'1.0'=$states};providerStatuses=@{}})
        $gaps=Test-MmtlCoverageAudit -Audit $audit
        @($gaps|Where-Object reasonCode -eq 'UNKNOWN_REASON_CODE').Count | Should -Be 10
        @($gaps|Where-Object reasonCode -eq 'UNKNOWN_WITHOUT_NOTES').Count | Should -Be 10
        @($gaps|Where-Object reasonCode -eq 'STATE_PROVENANCE_MISSING').Count | Should -Be 10
        @($gaps|Where-Object reasonCode -eq 'UNSAFE_TRUST_ESCALATION').Count | Should -Be 10
    }
}
