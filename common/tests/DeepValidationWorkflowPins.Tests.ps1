BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot '.github/workflows/deep-validation.yml') -Raw
    $script:fabricPins = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json
    $script:forgePins = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw | ConvertFrom-Json
    $script:universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
}

Describe 'Deep validation workflow exact fixture pins' {
    It 'uses the pinned source commit and Loom version for every Fabric fixture row' {
        $pin = @($script:fabricPins.targets | Where-Object targetId -CEQ 'Fabric@26.3')
        $pin | Should -HaveCount 1

        $blocks = [regex]::Matches($script:workflow, '(?ms)^          - scope:.*?(?=^          - scope:|^    steps:)')
        $fabricRows = @($blocks | ForEach-Object { $_.Value } | Where-Object { $_ -match '(?m)^            fixture: Fabric 26\.3\r?$' })
        $fabricRows.Count | Should -BeGreaterThan 0

        foreach ($row in $fabricRows) {
            $revision = [regex]::Match($row, '(?m)^            revision: ([a-f0-9]{40})\r?$')
            $loaderVersion = [regex]::Match($row, "(?m)^            loaderVersion: ([^\r\n]+)\r?$")
            $loomVersion = [regex]::Match($row, "(?m)^            toolchainVersion: ([^\r\n]+)\r?$")
            $javaVersion = [regex]::Match($row, "(?m)^            java: '([^']+)'\r?$")
            $gradleChecksum = [regex]::Match($row, '(?m)^            gradleDistributionSha256: ([a-f0-9]{64})\r?$')
            $minecraft = [regex]::Match($row, "(?m)^            minecraft: '([^']+)'\r?$")

            $revision.Success | Should -BeTrue
            $revision.Groups[1].Value | Should -BeExactly $pin[0].sourceCommit
            $loaderVersion.Groups[1].Value | Should -BeExactly $pin[0].loaderVersion
            $loomVersion.Groups[1].Value | Should -BeExactly $pin[0].loomVersion
            [int]$javaVersion.Groups[1].Value | Should -Be $pin[0].buildJavaMajor
            $gradleChecksum.Groups[1].Value | Should -BeExactly $pin[0].gradleDistributionSha256
            $minecraft.Groups[1].Value | Should -BeExactly $pin[0].minecraftVersion
        }

        $script:workflow | Should -Match 'sourceBuildGradleSha256'
        $script:workflow | Should -Match 'sourceSettingsGradleSha256'
        $script:workflow | Should -Match 'sourceWrapperPropertiesSha256'
        $script:workflow | Should -Match 'sourceWrapperJarSha256'
        $script:workflow | Should -Match 'FABRIC_CI_WRAPPER_CHECKSUM_MISMATCH'
    }

    It 'keeps the reusable Fabric 26.3 fixture manifest aligned with the target pin' {
        $fixtureManifest = Get-Content -LiteralPath (Join-Path $script:repoRoot 'common/fixtures/deep-validation/fixtures.json') -Raw | ConvertFrom-Json
        $fixture = @($fixtureManifest.fixtures | Where-Object fixtureId -CEQ 'fabric-263')
        $pin = @($script:fabricPins.targets | Where-Object targetId -CEQ 'Fabric@26.3')

        $fixture | Should -HaveCount 1
        $pin | Should -HaveCount 1
        $fixture[0].source | Should -BeExactly $pin[0].sourceRepository
        $fixture[0].minecraftId | Should -BeExactly $pin[0].minecraftVersion
        $fixture[0].loaderVersion | Should -BeExactly $pin[0].loaderVersion
        $fixture[0].commit | Should -BeExactly $pin[0].sourceCommit
        $fixture[0].toolchainVersion | Should -BeExactly $pin[0].loomVersion
        $fixture[0].license | Should -BeExactly $pin[0].sourceLicense
        [int]$fixture[0].buildJava | Should -Be $pin[0].buildJavaMajor
    }

    It 'keeps the generated Fabric 1.21.10 fixture aligned with its pinned archive and build inputs' {
        $fixtureManifest = Get-Content -LiteralPath (Join-Path $script:repoRoot 'common/fixtures/deep-validation/fixtures.json') -Raw | ConvertFrom-Json
        $fixture = @($fixtureManifest.fixtures | Where-Object fixtureId -CEQ 'fabric-1210')
        $pin = @($script:fabricPins.targets | Where-Object targetId -CEQ 'Fabric@1.21.10')

        $fixture | Should -HaveCount 1
        $pin | Should -HaveCount 1
        $fixture[0].type | Should -BeExactly 'GeneratedOfficialFixture'
        $fixture[0].source | Should -BeExactly $pin[0].sourceRepository
        $fixture[0].minecraftId | Should -BeExactly $pin[0].minecraftVersion
        $fixture[0].loaderVersion | Should -BeExactly $pin[0].loaderVersion
        $fixture[0].commit | Should -BeExactly $pin[0].sourceCommit
        $fixture[0].archiveSha256 | Should -BeExactly $pin[0].sourceArchiveSha256
        $fixture[0].toolchainVersion | Should -BeExactly $pin[0].loomVersion
        $fixture[0].license | Should -BeExactly $pin[0].sourceLicense
        [int]$fixture[0].buildJava | Should -Be $pin[0].buildJavaMajor
    }

    It 'keeps the generated Quilt 1.20.6 fixture aligned with its archive hash and exact build pin' {
        $fixtureManifest = Get-Content -LiteralPath (Join-Path $script:repoRoot 'common/fixtures/deep-validation/fixtures.json') -Raw | ConvertFrom-Json
        $pins = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/quilt-build-pins.json') -Raw | ConvertFrom-Json
        $fixture = @($fixtureManifest.fixtures | Where-Object fixtureId -CEQ 'quilt-1206')
        $pin = @($pins.targets | Where-Object targetId -CEQ 'Quilt@1.20.6')
        $fixture | Should -HaveCount 1
        $pin | Should -HaveCount 1
        $fixture[0].type | Should -BeExactly 'GeneratedOfficialFixture'
        $fixture[0].commit | Should -BeExactly $pin[0].sourceCommit
        $fixture[0].archiveSha256 | Should -BeExactly $pin[0].sourceArchiveSha256
        $fixture[0].loaderVersion | Should -BeExactly $pin[0].loaderVersion
        $fixture[0].toolchainVersion | Should -BeExactly $pin[0].quiltLoomVersion
        [int]$fixture[0].buildJava | Should -Be $pin[0].buildJavaMajor
    }

    It 'binds every deep-validation fixture to an Available exact Universe candidate' {
        $fixtureManifest = Get-Content -LiteralPath (Join-Path $script:repoRoot 'common/fixtures/deep-validation/fixtures.json') -Raw | ConvertFrom-Json

        foreach ($fixture in $fixtureManifest.fixtures) {
            $targetId = "$($fixture.loaderId)@$($fixture.minecraftId)"
            $target = @($script:universe.targets | Where-Object targetId -CEQ $targetId)
            $target | Should -HaveCount 1 -Because "fixture $($fixture.fixtureId) must map to one frozen exact target"
            $target[0].availability | Should -BeExactly 'Available' -Because "fixture $($fixture.fixtureId) must target an available loader/version pair"
            @($target[0].loaderVersionCandidates | ForEach-Object { [string]$_ }) | Should -Contain ([string]$fixture.loaderVersion) -Because "fixture $($fixture.fixtureId) loader version must use the exact catalogued identity"
        }
    }

    It 'uses the verified exact-target MDK pin for every Forge deep-validation fixture' {
        $fixtureManifest = Get-Content -LiteralPath (Join-Path $script:repoRoot 'common/fixtures/deep-validation/fixtures.json') -Raw | ConvertFrom-Json
        $evidenceIndex = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        $forgeFixtures = @($fixtureManifest.fixtures | Where-Object loaderId -CEQ 'Forge')

        foreach ($fixture in $forgeFixtures) {
            $targetId = "Forge@$($fixture.minecraftId)"
            $pin = @($script:forgePins.targets | Where-Object targetId -CEQ $targetId)
            $pin | Should -HaveCount 1 -Because "fixture $($fixture.fixtureId) must have one verified Forge build pin"
            $fixture.loaderVersion | Should -BeExactly $pin[0].forgeVersion
            $fixture.source | Should -BeExactly $pin[0].sourceArchiveUrl
            $fixture.commit | Should -BeExactly $pin[0].sourceArchiveSha256
            $fixture.officialChecksumAlgorithm | Should -BeExactly 'SHA256'
            $fixture.officialChecksum | Should -BeExactly $pin[0].sourceArchiveSha256
            [int]$fixture.buildJava | Should -Be $pin[0].buildJavaMajor

            $buildEvidenceRef = @($evidenceIndex.entries | Where-Object { $_.targetId -CEQ $targetId -and $_.dimension -CEQ 'BuildVerified' })
            $buildEvidenceRef | Should -HaveCount 1 -Because "$targetId must have one target-scoped build evidence record"
            $buildEvidencePath = Join-Path $script:repoRoot $buildEvidenceRef[0].evidencePath
            $buildEvidence = Get-Content -LiteralPath $buildEvidencePath -Raw | ConvertFrom-Json
            $buildEvidence.result | Should -BeExactly 'PASSED'
            $buildEvidence.validationLevel | Should -BeExactly 'BUILD_VERIFIED'
            $buildEvidence.loaderVersion | Should -BeExactly $fixture.loaderVersion
            $buildEvidence.sourceFixture.source | Should -BeExactly $fixture.source
            $buildEvidence.sourceFixture.commit | Should -BeExactly $fixture.commit
            [int]$buildEvidence.java.observedBuildJava.major | Should -Be $fixture.buildJava
        }
    }
}
