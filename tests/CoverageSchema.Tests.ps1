BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Audit/CoverageAudit.psm1') -Force
}

Describe 'Coverage audit JSON Schema' {
    It 'accepts a full audit with all loader modes and rejects missing reasons, illegal state, missing provenance, or null rows' {
        $catalog=[pscustomobject]@{source='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';manifestHash=('b'*64);minimumReleaseId='1.0';latestRelease='1.0';entries=@([pscustomobject]@{id='1.0';type='release';releaseTime='2011-11-18T00:00:00Z';runtimeJava=[pscustomobject]@{major=6;source='fixture'}})}
        $loaders=@('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod')
        $states=@{};foreach($loader in $loaders){$states[$loader]=[pscustomobject]@{availability='Unavailable';reasonCode='NO_UPSTREAM_CANDIDATE';source='https://example.invalid/index';sourceClass='ActiveOfficial';cacheStatus='Fresh';lastChecked='2026-10-02T00:00:00Z';notes=@();candidateCount=0;candidates=@();provenance=@([pscustomobject]@{source='fixture'})}}
        $states.LegacyFabric=[pscustomobject]@{availability='Unknown';reasonCode='LEGACY_FABRIC_PROVIDER_OUTAGE';source='https://meta.legacyfabric.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='Unavailable';lastChecked=$null;notes=@('official endpoint timed out');candidateCount=$null;candidates=@();provenance=@([pscustomobject]@{source='https://meta.legacyfabric.net/v2/versions/game'})}
        $inputs=[pscustomobject]@{byRelease=@{'1.0'=$states};providerStatuses=@{LegacyFabric=[pscustomobject]@{status='Unavailable';source='https://meta.legacyfabric.net/v2/versions/game';sourceClass='ActiveOfficial';cacheStatus='Unavailable';lastChecked=$null;notes=@('official endpoint timed out')}};provenance=@()}
        $audit=New-MmtlCoverageAudit -Catalog $catalog -RuntimeRoot $TestDrive -ProviderInputs $inputs
        $schema=Join-Path $script:repoRoot 'schemas/coverage-audit.schema.json'
        (Test-Json -Json ($audit|ConvertTo-Json -Depth 50 -Compress) -SchemaFile $schema) | Should -BeTrue
        $base=$audit|ConvertTo-Json -Depth 50|ConvertFrom-Json
        $base.releases[0].mainstreamLoaders.Forge.reasonCode=''
        (Test-Json -Json ($base|ConvertTo-Json -Depth 50 -Compress) -SchemaFile $schema -ErrorAction SilentlyContinue) | Should -BeFalse
        $base=$audit|ConvertTo-Json -Depth 50|ConvertFrom-Json
        $base.releases[0].mainstreamLoaders.Forge.availability='Maybe'
        (Test-Json -Json ($base|ConvertTo-Json -Depth 50 -Compress) -SchemaFile $schema -ErrorAction SilentlyContinue) | Should -BeFalse
        $base=$audit|ConvertTo-Json -Depth 50|ConvertFrom-Json
        $base.releases[0].mainstreamLoaders.Forge.PSObject.Properties.Remove('provenance')
        (Test-Json -Json ($base|ConvertTo-Json -Depth 50 -Compress) -SchemaFile $schema -ErrorAction SilentlyContinue) | Should -BeFalse
        $base=$audit|ConvertTo-Json -Depth 50|ConvertFrom-Json
        $base.releases=@($base.releases)+$null
        (Test-Json -Json ($base|ConvertTo-Json -Depth 50 -Compress) -SchemaFile $schema -ErrorAction SilentlyContinue) | Should -BeFalse
    }
}
