BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Audit/CoverageAudit.psm1') -Force
    $script:catalog=[pscustomobject]@{source='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';manifestHash=('a'*64);minimumReleaseId='1.0';latestRelease='1.1';entries=@([pscustomobject]@{id='1.0';type='release';releaseTime='2011-11-18T00:00:00Z';runtimeJava=[pscustomobject]@{major=6;source='fixture'}};[pscustomobject]@{id='1.1';type='release';releaseTime='2011-12-12T00:00:00Z';runtimeJava=[pscustomobject]@{major=$null;source='Unknown'}})}
    $script:loaderIds=@('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')
    $script:inputs=[pscustomobject]@{providerStatuses=@{};byRelease=@{};validationEvidence=@();provenance=@()}
    foreach($id in @('1.0','1.1')){
        $states=@{}
        foreach($loader in $script:loaderIds){
            $availability=if($loader -eq 'JarMod'){'Manual'}elseif($id -eq '1.0' -and $loader -eq 'Forge'){'Available'}elseif($id -eq '1.1' -and $loader -eq 'Fabric'){'Unknown'}else{'Unavailable'}
            $reason=if($availability -eq 'Available'){'UPSTREAM_CANDIDATE_FOUND'}elseif($availability -eq 'Manual'){'MANUAL_ARTIFACT_REQUIRED'}elseif($availability -eq 'Unknown'){'PROVIDER_UNAVAILABLE'}else{'NO_UPSTREAM_CANDIDATE'}
            $states[$loader]=[pscustomobject]@{availability=$availability;reasonCode=$reason;source='https://example.invalid/index';sourceClass='ActiveOfficial';cacheStatus='Fresh';lastChecked='2026-10-02T00:00:00Z';notes=@();candidateCount=if($availability -eq 'Available'){1}else{0};candidates=if($availability -eq 'Available'){@([pscustomobject]@{loaderVersion='x'})}else{@()}}
        }
        $script:inputs.byRelease[$id]=$states
    }
}

Describe 'Full coverage audit engine' {
    It 'emits one complete release row and all eleven loader modes for every catalog release' {
        $audit=New-MmtlCoverageAudit -Catalog $script:catalog -RuntimeRoot $TestDrive -ProviderInputs $script:inputs
        @($audit.releases).Count | Should -Be $script:catalog.entries.Count
        foreach($release in $audit.releases){
            (@($release.mainstreamLoaders.PSObject.Properties.Name)+@($release.historicalLoaders.PSObject.Properties.Name)+@($release.manualModes.PSObject.Properties.Name)).Count | Should -Be 11
        }
        $audit.minecraftCatalog.minimumRelease | Should -BeExactly '1.0'
        $audit.minecraftCatalog.currentStable | Should -BeExactly '1.1'
        $audit.summary.releaseCount | Should -Be 2
        $audit.summary.perLoader.Forge.releaseCount | Should -Be 2
        $audit.summary.perLoader.Forge.Available | Should -Be 1
        $audit.summary.perLoader.Forge.firstAvailableRelease | Should -BeExactly '1.0'
        $audit.summary.perLoader.Forge.lastAvailableRelease | Should -BeExactly '1.0'
        $audit.summary.perLoader.Forge.continuousRanges[0].minecraftIds | Should -Be @('1.0')
        $audit.summary.perLoader.Forge.gaps[0].minecraftIds | Should -Be @('1.1')
    }

    It 'isolates a failed loader provider while retaining the other ten states' {
        $input=$script:inputs|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
        $input.byRelease['1.0'].Forge=[ordered]@{availability='Unknown';reasonCode='PROVIDER_UNAVAILABLE';source='https://forge.example/index';sourceClass='ActiveOfficial';cacheStatus='Unavailable';lastChecked=$null;notes=@('fixture outage');candidateCount=0;candidates=@()}
        $audit=New-MmtlCoverageAudit -Catalog $script:catalog -RuntimeRoot $TestDrive -ProviderInputs $input
        $audit.releases[0].mainstreamLoaders.Forge.availability | Should -BeExactly 'Unknown'
        $audit.releases[0].mainstreamLoaders.Fabric.availability | Should -BeExactly 'Unavailable'
        $audit.releases[0].manualModes.JarMod.availability | Should -BeExactly 'Manual'
    }

    It 'reports missing rows and empty available candidates as invariant gaps' {
        $input=$script:inputs|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
        $input.byRelease['1.0'].Forge.candidateCount=0;$input.byRelease['1.0'].Forge.candidates=@()
        $input.byRelease['1.1'].Quilt=$null
        $audit=New-MmtlCoverageAudit -Catalog $script:catalog -RuntimeRoot $TestDrive -ProviderInputs $input
        $gaps=Test-MmtlCoverageAudit -Audit $audit
        @($gaps|Where-Object reasonCode -eq 'AVAILABLE_WITHOUT_CANDIDATE').Count | Should -Be 1
        @($gaps|Where-Object reasonCode -eq 'PROVIDER_RECORD_MISSING').Count | Should -Be 1
    }

    It 'returns one exact catalog release record and rejects unknown version ids' {
        $audit=New-MmtlCoverageAudit -Catalog $script:catalog -RuntimeRoot $TestDrive -ProviderInputs $script:inputs
        (Get-MmtlCoverageVersion -Audit $audit -MinecraftId '1.1').minecraftId | Should -BeExactly '1.1'
        {Get-MmtlCoverageVersion -Audit $audit -MinecraftId '1.1-pre1'} | Should -Throw '*is not a formal catalog release*'
    }

    It 'supports an injected catalog/provider snapshot for deterministic live-audit orchestration tests' {
        $audit=New-MmtlLiveCoverageAudit -RuntimeRoot $TestDrive -Catalog $script:catalog -ProviderInputs $script:inputs -SkipCandidateProbes
        @($audit.releases).Count | Should -Be 2
        $audit.releases[0].minecraftId | Should -BeExactly '1.0'
    }

    It 'downgrades an Available state and records a gap when a bounded candidate probe returns zero' {
        $probe={param($MinecraftId,$LoaderId) @()}
        $audit=New-MmtlLiveCoverageAudit -RuntimeRoot $TestDrive -Catalog $script:catalog -ProviderInputs $script:inputs -CandidateProbe $probe
        $audit.releases[0].mainstreamLoaders.Forge.availability | Should -BeExactly 'Unknown'
        $audit.releases[0].mainstreamLoaders.Forge.reasonCode | Should -BeExactly 'COVERAGE_INCONSISTENCY'
        $audit.summary.perLoader.Forge.candidateProbed | Should -Be 1
        $audit.summary.perLoader.Forge.Available | Should -Be 0
        $audit.summary.perLoader.Forge.Unknown | Should -Be 1
        $audit.summary.stateCounts.Unknown | Should -Be 2
        @($audit.gaps|Where-Object{$_.minecraftId -eq '1.0' -and $_.loaderId -eq 'Forge' -and $_.reasonCode -eq 'COVERAGE_INCONSISTENCY'}).Count | Should -Be 1
    }

    It 'keeps offline historical candidate cache misses as unknown warnings, not endpoint contradictions' {
        $input=$script:inputs|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
        $input.byRelease['1.0'].Forge=[ordered]@{availability='Unavailable';reasonCode='NO_UPSTREAM_CANDIDATE';source='https://example.invalid/forge';sourceClass='ActiveOfficial';cacheStatus='Fresh';lastChecked='2026-10-03T00:00:00Z';notes=@();candidateCount=0;candidates=@()}
        $input.byRelease['1.0'].LegacyFabric=[ordered]@{availability='Available';reasonCode='UPSTREAM_GAME_SUPPORT';source='https://meta.legacyfabric.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='OfflineCache';lastChecked='2026-10-03T00:00:00Z';notes=@();candidateCount=$null;candidates=@();candidateProbeStatus='NotProbed';provenance=@()}
        $input.providerStatuses['LegacyFabric']=[ordered]@{status='OfflineCache';source='https://meta.legacyfabric.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='OfflineCache';lastChecked='2026-10-03T00:00:00Z';notes=@()}
        $audit=New-MmtlLiveCoverageAudit -RuntimeRoot $TestDrive -Catalog $script:catalog -ProviderInputs $input -LoaderOffline
        $audit.releases[0].historicalLoaders.LegacyFabric.availability | Should -BeExactly 'Unknown'
        $audit.releases[0].historicalLoaders.LegacyFabric.reasonCode | Should -BeExactly 'CANDIDATE_PROBE_FAILED'
        @($audit.gaps|Where-Object{$_.minecraftId -eq '1.0' -and $_.loaderId -eq 'LegacyFabric' -and $_.reasonCode -eq 'COVERAGE_INCONSISTENCY'}).Count | Should -Be 0
        @($audit.warnings|Where-Object{$_.minecraftId -eq '1.0' -and $_.loaderId -eq 'LegacyFabric' -and $_.reasonCode -eq 'CANDIDATE_PROBE_FAILED'}).Count | Should -Be 1
    }

    It 'does not infer Ornithe Loader availability from game support without a loader candidate' {
        $input=$script:inputs|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
        $input.byRelease['1.0'].OrnitheLoader=[ordered]@{availability='Unknown';reasonCode='ORNITHE_LOADER_CANDIDATE_NOT_PROBED';source='https://meta.ornithemc.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='Fresh';lastChecked='2026-10-03T00:00:00Z';notes=@('Game support alone does not prove a loader candidate.');candidateCount=$null;candidates=@();candidateProbeStatus='NotProbed';provenance=@([pscustomobject]@{source='https://meta.ornithemc.net/v2/versions/game'})}
        $probe={param($MinecraftId,$LoaderId) if($LoaderId -eq 'OrnitheLoader'){@()}else{@([pscustomobject]@{provenance=@([pscustomobject]@{source='https://example.invalid/candidate'})})}}
        $audit=New-MmtlLiveCoverageAudit -RuntimeRoot $TestDrive -Catalog $script:catalog -ProviderInputs $input -CandidateProbe $probe
        $audit.releases[0].historicalLoaders.OrnitheLoader.availability | Should -Be 'Unavailable'
        $audit.releases[0].historicalLoaders.OrnitheLoader.reasonCode | Should -Be 'NO_UPSTREAM_CANDIDATE'
        @($audit.gaps|Where-Object loaderId -eq 'OrnitheLoader').Count | Should -Be 0
    }

    It 'retains aggregated provider outage and unmapped upstream gaps after candidate probes' {
        $input=$script:inputs|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
        foreach($id in @('1.0','1.1')){$input.byRelease[$id].LegacyFabric=[ordered]@{availability='Unknown';reasonCode='LEGACY_FABRIC_PROVIDER_OUTAGE';source='https://meta.legacyfabric.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='Unavailable';lastChecked=$null;notes=@('official endpoint timed out');candidateCount=$null;candidates=@();candidateProbeStatus='NotProbed';provenance=@([pscustomobject]@{source='https://meta.legacyfabric.net/v2/versions/game'})}}
        $input.providerStatuses=[ordered]@{LegacyFabric=[ordered]@{status='Unavailable';source='https://meta.legacyfabric.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='Unavailable';lastChecked=$null;notes=@('official endpoint timed out')};NeoForge=[ordered]@{status='Available';source='https://maven.neoforged.net';sourceClass='ActiveOfficial';cacheStatus='Fresh';lastChecked='2026-10-03T00:00:00Z';notes=@();unmappedVersions=@([ordered]@{artifactFamily='NeoForge';upstreamVersion='99.1.0'})}}
        $probe={param($MinecraftId,$LoaderId) @([pscustomobject]@{source='https://example.invalid/candidate';provenance=@([pscustomobject]@{source='https://example.invalid/candidate'})})}
        $audit=New-MmtlLiveCoverageAudit -RuntimeRoot $TestDrive -Catalog $script:catalog -ProviderInputs $input -CandidateProbe $probe
        @($audit.gaps|Where-Object{$_.loaderId -eq 'LegacyFabric' -and $_.reasonCode -eq 'PROVIDER_UNAVAILABLE' -and $_.releaseCount -eq 2}).Count | Should -Be 1
        @($audit.gaps|Where-Object{$_.loaderId -eq 'NeoForge' -and $_.reasonCode -eq 'UNMAPPED_UPSTREAM_VERSION' -and $_.severity -eq 'Error'}).Count | Should -Be 1
    }
}
