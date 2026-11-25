BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:fixtureRoot = Join-Path $script:repoRoot 'fixtures/quilt/1.20.6-marker'
    $script:pin = (Get-Content -LiteralPath (Join-Path $script:repoRoot '../compatibility/quilt-build-pins.json') -Raw | ConvertFrom-Json).targets[0]
}

Describe 'Quilt 1.20.6 marker fixture' {
    It 'binds the fixture to its approved exact source and toolchain' {
        $fixture = Get-Content -LiteralPath (Join-Path $script:fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $fixture.fixtureId | Should -BeExactly 'MMTLQuiltMarkerFixtureV1'
        $fixture.targetId | Should -BeExactly 'Quilt@1.20.6'
        $fixture.sourceCommit | Should -BeExactly $script:pin.sourceCommit
        $fixture.sourceArchiveSha256 | Should -BeExactly $script:pin.sourceArchiveSha256
        $fixture.quiltLoomVersion | Should -BeExactly '1.7.4'
        $fixture.loaderVersion | Should -BeExactly '0.26.3'
        $fixture.buildJavaMajor | Should -Be 21
    }

    It 'checks all owned files against the aggregate overlay hash' {
        $fixture = Get-Content -LiteralPath (Join-Path $script:fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $fixture.overlayFiles | Should -HaveCount 7
        foreach ($file in $fixture.overlayFiles) {
            (Get-FileHash -LiteralPath (Join-Path $script:fixtureRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256
        }
        $records = @($fixture.overlayFiles | ForEach-Object { $_.path + '|' + $_.sha256 } | Sort-Object -CaseSensitive)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records -join "`n")))).ToLowerInvariant() | Should -BeExactly $fixture.overlaySha256
    }

    It 'contains an exact Quilt initializer and Minecraft/loader dependency declarations' {
        $metadata = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'src/main/resources/quilt.mod.json') -Raw | ConvertFrom-Json
        $java = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw
        $versions = Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'gradle/libs.versions.toml') -Raw
        $metadata.quilt_loader.id | Should -BeExactly 'mmtl_marker'
        $metadata.quilt_loader.entrypoints.init | Should -Contain 'org.pycodersmod.mmtlfixture.MmtlMarkerMod'
        $metadata.quilt_loader.depends | Where-Object id -CEQ 'minecraft' | ForEach-Object versions | Should -BeExactly '=1.20.6'
        $java | Should -Match 'implements ModInitializer'
        $java | Should -Match 'MMTL_QUILT_MARKER_INITIALIZED target=Quilt@1\.20\.6'
        $versions | Should -Match '(?m)^quilt_loom = "1\.7\.4"$'
        $versions | Should -Match '(?m)^quilt_loader = "0\.26\.3"$'
        (Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'gradle/wrapper/gradle-wrapper.properties') -Raw) | Should -Match ('(?m)^distributionSha256Sum=' + [regex]::Escape($script:pin.gradleDistributionSha256) + '$')
    }

    It 'contains an independent marker fixture for the exact Quilt 1.20.4 target' {
        $repoRoot = $script:repoRoot
        $pinPath = [IO.Path]::GetFullPath((Join-Path $repoRoot '../compatibility/quilt-build-pins.json'))
        $pin = @((Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json).targets | Where-Object targetId -CEQ 'Quilt@1.20.4')
        $pin | Should -HaveCount 1
        $fixtureRoot = Join-Path $repoRoot 'fixtures/quilt/1.20.4-marker'
        $fixture = Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $fixture.targetId | Should -BeExactly 'Quilt@1.20.4'
        $fixture.sourceCommit | Should -BeExactly $pin[0].sourceCommit
        $fixture.overlaySha256 | Should -BeExactly $pin[0].overlaySha256
        $java = Get-Content -LiteralPath (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw
        $java | Should -Match 'MMTL_QUILT_MARKER_INITIALIZED target=Quilt@1\.20\.4'
        $metadata = Get-Content -LiteralPath (Join-Path $fixtureRoot 'src/main/resources/quilt.mod.json') -Raw | ConvertFrom-Json
        $metadata.quilt_loader.depends | Where-Object id -CEQ 'minecraft' | ForEach-Object versions | Should -BeExactly '=1.20.4'
        $metadata.quilt_loader.depends | Where-Object id -CEQ 'quilt_loader' | ForEach-Object versions | Should -BeExactly '=0.25.0'
    }

    It 'uses the Quilt Loader bundled Fabric entrypoint when the exact target has no published QFAPI' {
        $repoRoot = $script:repoRoot
        $pinPath = [IO.Path]::GetFullPath((Join-Path $repoRoot '../compatibility/quilt-build-pins.json'))
        $pin = @((Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json).targets | Where-Object targetId -CEQ 'Quilt@1.20.5')
        $pin | Should -HaveCount 1
        $pin[0].quiltedFabricApiVersion | Should -BeNullOrEmpty
        $fixtureRoot = Join-Path $repoRoot 'fixtures/quilt/1.20.5-marker'
        $fixture = Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $fixture.targetId | Should -BeExactly 'Quilt@1.20.5'
        $fixture.overlayFiles | Should -HaveCount 7
        $fabricMetadataPath = Join-Path $fixtureRoot 'src/main/resources/fabric.mod.json'
        Test-Path -LiteralPath $fabricMetadataPath | Should -BeTrue
        $fabricMetadata = Get-Content -LiteralPath $fabricMetadataPath -Raw | ConvertFrom-Json
        $fabricMetadata.id | Should -BeExactly 'mmtl_marker'
        $fabricMetadata.entrypoints.main | Should -Contain 'org.pycodersmod.mmtlfixture.MmtlMarkerMod'
        $fabricMetadata.depends.minecraft | Should -BeExactly '=1.20.5'
        $fabricMetadata.depends.fabricloader | Should -BeExactly "=$($pin[0].loaderVersion)"
        Test-Path -LiteralPath (Join-Path $fixtureRoot 'src/main/resources/quilt.mod.json') | Should -BeFalse
        $java = Get-Content -LiteralPath (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw
        $java | Should -Match 'implements ModInitializer'
        $java | Should -Match 'void onInitialize\(\)'
        $java | Should -Match 'MMTL_QUILT_MARKER_INITIALIZED target=Quilt@1\.20\.5'
    }
}
