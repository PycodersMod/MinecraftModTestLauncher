BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Audit/CoverageAudit.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Audit/CoverageCli.psm1') -Force
    $catalog=[pscustomobject]@{source='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';manifestHash=('e'*64);minimumReleaseId='1.0';latestRelease='1.0';entries=@([pscustomobject]@{id='1.0';type='release';releaseTime='2011-11-18T00:00:00Z';runtimeJava=[pscustomobject]@{major=6;source='fixture'}})}
    $loaders=@('Forge','Fabric','NeoForge','Quilt','LegacyFabric','OrnitheLoader','LiteLoader','Rift','ModLoader','ModLoaderMP','JarMod');$states=@{}
    foreach($loader in $loaders){$states[$loader]=[pscustomobject]@{availability=if($loader -eq 'JarMod'){'Manual'}else{'Unavailable'};reasonCode=if($loader -eq 'JarMod'){'MANUAL_ARTIFACT_REQUIRED'}else{'NO_UPSTREAM_CANDIDATE'};source='https://example.invalid/source';sourceClass=if($loader -eq 'JarMod'){'ManualArtifact'}else{'ActiveOfficial'};cacheStatus=if($loader -eq 'JarMod'){'NotApplicable'}else{'Fresh'};lastChecked='2026-10-03T00:00:00Z';notes=@();candidateCount=0;candidates=@();provenance=@([pscustomobject]@{source='fixture'})}}
    $script:audit=New-MmtlCoverageAudit -Catalog $catalog -RuntimeRoot $TestDrive -ProviderInputs ([pscustomobject]@{byRelease=@{'1.0'=$states};providerStatuses=@{}})
    $fixtureAudit=$script:audit
    $script:received=[pscustomobject]@{arguments=$null}
    $record=$script:received
    $script:auditFactory={param($Root,$CatalogOffline,$LoaderOffline,$ForceRefresh)$record.arguments=@($Root,$CatalogOffline,$LoaderOffline,$ForceRefresh);$fixtureAudit}.GetNewClosure()
}

Describe 'Coverage CLI and option registry' {
    It 'provides a concise summary by default and a full report with --json' {
        $summary=Invoke-MmtlCoverageCli -Arguments @('--coverage-report') -RuntimeRoot $TestDrive -CatalogOffline -AuditFactory $script:auditFactory|Out-String|ConvertFrom-Json
        $summary.minecraftCatalog.releaseCount | Should -Be 1
        $summary.PSObject.Properties.Name | Should -Not -Contain 'releases'
        $script:received.arguments[1] | Should -BeTrue
        $full=Invoke-MmtlCoverageCli -Arguments @('--coverage-report','--json') -RuntimeRoot $TestDrive -AuditFactory $script:auditFactory|Out-String|ConvertFrom-Json
        @($full.releases).Count | Should -Be 1
    }

    It 'lists gaps, returns one exact version, and rejects unknown releases' {
        $gaps=Invoke-MmtlCoverageCli -Arguments @('--coverage-gaps') -RuntimeRoot $TestDrive -AuditFactory $script:auditFactory|Out-String|ConvertFrom-Json
        @($gaps).Count | Should -BeGreaterThan 0
        $version=Invoke-MmtlCoverageCli -Arguments @('--coverage-version','1.0') -RuntimeRoot $TestDrive -AuditFactory $script:auditFactory|Out-String|ConvertFrom-Json
        $version.minecraftId | Should -BeExactly '1.0'
        {Invoke-MmtlCoverageCli -Arguments @('--coverage-version','1.0-pre1') -RuntimeRoot $TestDrive -AuditFactory $script:auditFactory} | Should -Throw '*is not a formal catalog release*'
    }

    It 'rejects missing IDs and conflicting coverage commands' {
        {Invoke-MmtlCoverageCli -Arguments @('--coverage-version') -RuntimeRoot $TestDrive -AuditFactory $script:auditFactory} | Should -Throw '*缺少 Minecraft release ID*'
        {Invoke-MmtlCoverageCli -Arguments @('--coverage-report','--coverage-gaps') -RuntimeRoot $TestDrive -AuditFactory $script:auditFactory} | Should -Throw '*COVERAGE_OPTION_CONFLICT*'
        {Invoke-MmtlCoverageCli -Arguments @('--coverage-gaps','--json') -RuntimeRoot $TestDrive -AuditFactory $script:auditFactory} | Should -Throw '*COVERAGE_JSON_OPTION_INVALID*'
    }

    It 'keeps the public option registry present in launcher help and README' {
        $help=& (Get-Command pwsh).Source -NoProfile -File (Join-Path $script:repoRoot 'launcher.ps1') --help|Out-String
        $readme=Get-Content (Join-Path $script:repoRoot 'README.md') -Raw
        foreach($definition in Get-MmtlCoverageCliOptionDefinitions){$help | Should -Match ([regex]::Escape($definition.name));$readme | Should -Match ([regex]::Escape($definition.name))}
        $help | Should -Match '--provider-status'
        $help | Should -Match '--loader-offline'
    }
}
