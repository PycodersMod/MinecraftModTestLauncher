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

    It 'aggregates a historical provider outage instead of emitting per-release check-time gaps' {
        $catalog=[pscustomobject]@{source='https://piston-meta.mojang.com/manifest';manifestHash=('d'*64);minimumReleaseId='1.0';latestRelease='1.1';entries=@([pscustomobject]@{id='1.0';type='release';releaseTime='2011-11-18T00:00:00Z'};[pscustomobject]@{id='1.1';type='release';releaseTime='2011-12-12T00:00:00Z'})}
        $states=@{};foreach($loader in @('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP')){$states[$loader]=[pscustomobject]@{availability='Unavailable';reasonCode='NO_UPSTREAM_CANDIDATE';source='https://example.invalid';sourceClass='ActiveOfficial';cacheStatus='Fresh';lastChecked='2026-10-03T00:00:00Z';notes=@();candidateCount=0;candidates=@();candidateProbeStatus='NotProbed';provenance=@([pscustomobject]@{source='https://example.invalid'})}}
        foreach($id in @('1.0','1.1')){$states[$id]=@{};foreach($loader in @('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP')){$states[$id][$loader]=$states[$loader]};$states[$id].JarMod=[pscustomobject]@{availability='Manual';reasonCode='MANUAL_ARTIFACT_REQUIRED';source=$null;sourceClass='ManualArtifact';cacheStatus='NotApplicable';lastChecked=$null;notes=@('manual only');candidateCount=0;candidates=@();provenance=@([pscustomobject]@{reason='manual'})}}
        foreach($id in @('1.0','1.1')){$states[$id].LegacyFabric=[pscustomobject]@{availability='Unknown';reasonCode='LEGACY_FABRIC_PROVIDER_OUTAGE';source='https://meta.legacyfabric.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='Unavailable';lastChecked=$null;notes=@('official endpoint unavailable');candidateCount=$null;candidates=@();candidateProbeStatus='NotProbed';provenance=@([pscustomobject]@{source='https://meta.legacyfabric.net/v2/versions/game'})}}
        $providers=[ordered]@{LegacyFabric=[pscustomobject]@{status='Unavailable';source='https://meta.legacyfabric.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='Unavailable';lastChecked=$null;notes=@('official endpoint unavailable')}}
        $audit=New-MmtlCoverageAudit -Catalog $catalog -RuntimeRoot $TestDrive -ProviderInputs ([pscustomobject]@{byRelease=@{'1.0'=$states['1.0'];'1.1'=$states['1.1']};providerStatuses=[pscustomobject]$providers})
        @($audit.gaps|Where-Object{$_.loaderId -eq 'LegacyFabric' -and $_.reasonCode -eq 'PROVIDER_UNAVAILABLE'}).Count | Should -Be 1
        ($audit.gaps|Where-Object{$_.loaderId -eq 'LegacyFabric' -and $_.reasonCode -eq 'PROVIDER_UNAVAILABLE'}|Select-Object -First 1).releaseCount | Should -Be 2
        @($audit.warnings|Where-Object{$_.loaderId -eq 'LegacyFabric'}).Count | Should -Be 1
    }
}
