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
        $projects=@([pscustomobject]@{targetId='user-fabric';minecraftId='1.21.6';loaderId='Fabric';projectRoot='D:\mods\CarpetPlayerAddition';tier='Tier1'})
        $plan=New-MmtlValidationPlan -Scope Portfolio -CurrentStable '26.3' -CatalogReleaseIds @('1.21.6','26.3') -ProjectTargets $projects
        $plan.targets[0].tier | Should -Be 'Tier1'
        $plan.targets[0].projectRoot | Should -Be 'D:\mods\CarpetPlayerAddition'
    }

    It 'accepts only pinned trusted official owners and allowlisted Gradle tasks' {
        $fixture=[pscustomobject]@{type='GeneratedOfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=('a'*40);license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('clean','build')}
        (Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC','NeoForgeMDKs','QuiltMC','MinecraftForge')) | Should -BeTrue
        $fixture.allowedTasks=@('build','build; Remove-Item -Recurse')
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw '*unallowlisted*'
    }

    It 'rejects unpinned, HTTP, unknown-owner, and untrusted fixture sources' {
        $fixture=[pscustomobject]@{type='OfficialFixture';source='http://github.com/FabricMC/fabric-example-mod';commit='main';license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('build')}
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw
        $fixture.source='https://github.com/random-user/mod'
        $fixture.commit=('a'*40)
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw '*owner*'
        $fixture.source='https://github.com/FabricMC/fabric-example-mod'
        $fixture.trust='UnverifiedHistorical'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @('FabricMC')} | Should -Throw '*trust*'
    }

    It 'accepts only checksum-pinned official Forge archive fixtures from approved hosts' {
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/example-mdk.zip';commit=('a'*64);officialChecksum=('b'*32);officialChecksumAlgorithm='MD5';license='Forge MDK license';trust='TrustedOfficial';allowedTasks=@('clean','build')}
        (Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @()) | Should -BeTrue
        $fixture.source='https://example.org/forge-mdk.zip'
        {Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners @()} | Should -Throw '*allowlisted*'
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
}
