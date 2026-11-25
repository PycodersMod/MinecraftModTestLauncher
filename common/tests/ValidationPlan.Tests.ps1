BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationPlan.psm1') -Force
}

Describe 'Validation plan selection and fixture trust' {
    It 'selects only pinned representative P0 fixtures and resolves CurrentStable from the catalog' {
        $catalog=@('1.12.2','1.16.5','1.18.2','1.19.2','1.20.1','1.20.4','1.21.1','26.3')
        $fixtures=@(
            [pscustomobject]@{targetId='forge-1122';minecraftId='1.12.2';loaderId='Forge';tier='Tier2';scopes=@('P0');currentStable=$false},
            [pscustomobject]@{targetId='fabric-stable';minecraftId='26.3';loaderId='Fabric';tier='Tier2';scopes=@('P0');currentStable=$true},
            [pscustomobject]@{targetId='forge-unrelated';minecraftId='1.19.2';loaderId='Forge';tier='Tier3';scopes=@('Historical');currentStable=$false}
        )
        $plan=New-MmtlValidationPlan -Scope P0 -CurrentStable '26.3' -CatalogReleaseIds $catalog -FixtureTargets $fixtures
        $plan.tier0.releaseCount | Should -Be 8
        $plan.tier0.catalogOnly | Should -BeTrue
        @($plan.targets).Count | Should -Be 2
        $plan.targets.minecraftId | Should -Contain '26.3'
        $plan.targets.minecraftId | Should -Contain '1.12.2'
        @($plan.targets).Count | Should -BeLessThan 1133
    }

    It 'selects real projects as Tier 1 targets without converting their paths into commands' {
        $projects=@([pscustomobject]@{targetId='user-fabric';minecraftId='1.21.6';loaderId='Fabric';projectRoot='D:\mods\CarpetPlayerAddition';tier='Tier1'}) # public-hygiene: allow-synthetic-path
        $plan=New-MmtlValidationPlan -Scope Portfolio -CurrentStable '26.3' -CatalogReleaseIds @('1.21.6','26.3') -ProjectTargets $projects
        $plan.targets[0].tier | Should -Be 'Tier1'
        $plan.targets[0].projectRoot | Should -Be 'D:\mods\CarpetPlayerAddition' # public-hygiene: allow-synthetic-path
    }

    It 'accepts only pinned trusted official owners and allowlisted Gradle tasks' {
        $fixture=[pscustomobject]@{type='GeneratedOfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=('a'*40);license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('clean','build')}
        (Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC','NeoForgeMDKs','QuiltMC','MinecraftForge')) | Should -BeTrue
        $fixture.allowedTasks=@('build','build; Remove-Item -Recurse')
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw '*未列入许可清单*'
    }

    It 'accepts a hash-pinned generated official fixture only when archive and overlay identities are complete' {
        $commit='1685ed178a113092f8aa002c4f7d78181643d75b'
        $fixture=[pscustomobject]@{type='GeneratedPinnedLoaderFixture';source='https://github.com/FabricMC/fabric-example-mod';archiveUrl="https://codeload.github.com/FabricMC/fabric-example-mod/zip/$commit";archiveSha256=('a'*64);commit=$commit;fixtureId='MMTLFabricMarkerFixtureV1';overlaySha256=('b'*64);overlayFiles=@([pscustomobject]@{path='build.gradle';sha256=('c'*64)});license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('build')}
        (Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')) | Should -BeTrue
        $fixture.archiveSha256='not-a-sha256'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw '*归档 SHA-256*'
        $fixture.archiveSha256=('a'*64);$fixture.overlayFiles[0].path='../build.gradle'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw '*Overlay*'
    }

    It 'rejects unpinned, HTTP, unknown-owner, and untrusted fixture sources' {
        $fixture=[pscustomobject]@{type='OfficialFixture';source='http://github.com/FabricMC/fabric-example-mod';commit='main';license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('build')}
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw
        $fixture.source='https://github.com/random-user/mod'
        $fixture.commit=('a'*40)
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw '*来源所有者不在许可清单中*'
        $fixture.source='https://github.com/FabricMC/fabric-example-mod'
        $fixture.trust='UnverifiedHistorical'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw '*trust*'
    }

    It 'accepts pinned historical official GitHub fixtures only as VerifiedHistorical' {
        $fixture=[pscustomobject]@{type='HistoricalOfficialFixture';source='https://github.com/DimensionalDevelopment/Rift';commit='dfc75ff7254cbbea81535c02ddc5252e384ac806';license='MIT';trust='VerifiedHistorical';allowedTasks=@('build')}
        (Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('DimensionalDevelopment')) | Should -BeTrue
        $fixture.commit='main'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('DimensionalDevelopment')} | Should -Throw
        $fixture.commit='dfc75ff7254cbbea81535c02ddc5252e384ac806';$fixture.trust='TrustedOfficial'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('DimensionalDevelopment')} | Should -Throw
        $fixture.trust='VerifiedHistorical';$fixture.source='https://github.com/OtherOwner/Rift'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('DimensionalDevelopment')} | Should -Throw '*来源所有者不在许可清单中*'
    }

    It 'accepts only checksum-pinned official Forge archive fixtures from approved hosts' {
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/example-mdk.zip';commit=('a'*64);officialChecksum=('b'*32);officialChecksumAlgorithm='MD5';license='Forge MDK license';trust='TrustedOfficial';allowedTasks=@('clean','build')}
        (Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @()) | Should -BeTrue
        $fixture.source='https://example.org/forge-mdk.zip'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @()} | Should -Throw '*许可清单中的 Forge HTTPS 主机*'
        $fixture.source='https://maven.minecraftforge.net/forge-mdk.zip';$fixture.commit='latest'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @()} | Should -Throw '*SHA-256*'
    }

    It 'derives explicit target IDs from fixture, OS, architecture, and BuildJava dimensions' {
        $fixture=[pscustomobject]@{fixtureId='fabric-263';type='OfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=('a'*40);license='CC0-1.0';trust='TrustedOfficial';minecraftId='26.3';loaderId='Fabric';loaderVersion='0.19.5';toolchain='FabricLoom';toolchainVersion='1.18-SNAPSHOT';buildJava=25;scopes=@('P0','CurrentStable');currentStable=$true;allowedTasks=@('clean','build')}
        $targets=@(New-MmtlValidationFixtureTargets -Fixtures @($fixture) -Platform ([pscustomobject]@{os='Windows';arch='x64';isWSL=$false}))
        $targets.Count | Should -Be 1
        $targets[0].targetId | Should -Be 'fabric-263-windows-x64'
        $targets[0].sourceFixture.allowedTasks | Should -Contain 'build'
        $targets[0].platform.isWSL | Should -BeFalse
    }

    It 'preserves a generated official source archive hash for exact-target secure build pins' {
        $fixture=[pscustomobject]@{fixtureId='quilt-1206';type='GeneratedOfficialFixture';source='https://github.com/QuiltMC/quilt-template-mod';commit='9a6f89cd481e3f58f128596b5b043353bee6b3f2';archiveSha256=('a'*64);license='CC0-1.0';trust='TrustedOfficial';minecraftId='1.20.6';loaderId='Quilt';loaderVersion='0.26.3';toolchain='QuiltLoom';toolchainVersion='1.7.4';buildJava=21;scopes=@('P0');currentStable=$false;allowedTasks=@('clean','build')}
        $target=@(New-MmtlValidationFixtureTargets -Fixtures @($fixture) -Platform ([pscustomobject]@{os='Windows';arch='x64';isWSL=$false}))
        $target | Should -HaveCount 1
        $target[0].sourceFixture.archiveSha256 | Should -BeExactly ('a'*64)
        (Test-MmtlValidationFixture -Fixture $target[0].sourceFixture -AllowedOwners @('QuiltMC')) | Should -BeTrue
    }

    It 'preserves every pinned generated fixture identity field in the validation target' {
        $commit='1685ed178a113092f8aa002c4f7d78181643d75b'
        $fixture=[pscustomobject]@{fixtureId='fabric-263-marker';type='GeneratedPinnedLoaderFixture';source='https://github.com/FabricMC/fabric-example-mod';archiveUrl="https://codeload.github.com/FabricMC/fabric-example-mod/zip/$commit";commit=$commit;archiveSha256=('a'*64);overlaySha256=('b'*64);overlayFiles=@([pscustomobject]@{path='build.gradle';sha256=('c'*64)});license='CC0-1.0';trust='TrustedOfficial';minecraftId='26.3';loaderId='Fabric';loaderVersion='0.19.5';toolchain='FabricLoom';toolchainVersion='1.18.4';buildJava=25;scopes=@('P0');currentStable=$false;allowedTasks=@('clean','build')}

        $target=@(New-MmtlValidationFixtureTargets -Fixtures @($fixture) -Platform ([pscustomobject]@{os='Windows';arch='x64';isWSL=$false}))[0]

        $target.sourceFixture.archiveUrl | Should -BeExactly $fixture.archiveUrl
        $target.sourceFixture.archiveSha256 | Should -BeExactly $fixture.archiveSha256
        $target.sourceFixture.fixtureId | Should -BeExactly $fixture.fixtureId
        $target.sourceFixture.overlaySha256 | Should -BeExactly $fixture.overlaySha256
        $target.sourceFixture.overlayFiles[0].path | Should -BeExactly 'build.gradle'
    }
}
