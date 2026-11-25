BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Adapters/QuiltSecureBuild.psm1') -Force
    $script:manifestPath = Join-Path $script:repoRoot '../compatibility/quilt-build-pins.json'
    $script:manifestPath = [IO.Path]::GetFullPath($script:manifestPath)
    $script:pin = (Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json).targets[0]
    $script:fixtureRoot = Join-Path $script:repoRoot 'fixtures/quilt/1.20.6-marker'
    $script:fixtureManifest = Get-Content -LiteralPath (Join-Path $script:fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
    $script:target = [pscustomobject]@{targetId='Quilt@1.20.6';minecraftId='1.20.6';loaderVersion='0.26.3'}
    $script:project = [pscustomobject]@{Root=$script:fixtureRoot;Loader='Quilt';MinecraftVersion='1.20.6';LoaderVersion='0.26.3';Toolchain=[pscustomobject]@{id='QuiltLoom';version='1.7.4'}}
    $script:sourceFixture = [pscustomobject]@{type='GeneratedOfficialFixture';source=$script:pin.sourceRepository;commit=$script:pin.sourceCommit;license=$script:pin.sourceLicense;trust='TrustedOfficial';archiveSha256=$script:pin.sourceArchiveSha256;fixtureId='MMTLQuiltMarkerFixtureV1';overlaySha256=$script:fixtureManifest.overlaySha256;overlayFiles=@($script:fixtureManifest.overlayFiles)}
}

Describe 'Quilt exact build pin' {
    It 'accepts only the exact official Quilt 1.20.6 template pin' {
        $schema = Join-Path $script:repoRoot '../compatibility/quilt-build-pins.schema.json'
        $schema = [IO.Path]::GetFullPath($schema)
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        (Test-Json -Json ($manifest | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schema) | Should -BeTrue
        $manifest.targets | Should -HaveCount 3
        $manifest.targets[0].sourceCommit | Should -BeExactly '9a6f89cd481e3f58f128596b5b043353bee6b3f2'
        $manifest.targets[0].buildJavaMajor | Should -Be 21
        $manifest.targets[0].overlaySha256 | Should -BeExactly $script:fixtureManifest.overlaySha256
        $manifest.targets[0].gradleDistributionSha256 | Should -BeExactly 'd725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab'
        $manifest.targets[0].loaderVersion | Should -BeExactly '0.26.3'
    }

    It 'keeps the official Quilt 1.20.4 target bound to its own source and toolchain' {
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        (Test-Json -Json ($manifest | ConvertTo-Json -Depth 20 -Compress) -SchemaFile ([IO.Path]::GetFullPath((Join-Path $script:repoRoot '../compatibility/quilt-build-pins.schema.json')))) | Should -BeTrue
        $pins = @($manifest.targets | Where-Object targetId -CEQ 'Quilt@1.20.4')
        $pins | Should -HaveCount 1
        $pins[0].minecraftVersion | Should -BeExactly '1.20.4'
        $pins[0].loaderVersion | Should -BeExactly '0.25.0'
        $pins[0].quiltLoomVersion | Should -BeExactly '1.6.5'
        $pins[0].quiltMappingsVersion | Should -BeExactly '1.20.4+build.3'
        $pins[0].quiltedFabricApiVersion | Should -BeExactly '9.0.0-alpha.8+0.97.0-1.20.4'
        $pins[0].sourceCommit | Should -BeExactly '9480b2e90b255309c21d19bcdd4646760c66dc2b'
        $pins[0].sourceArchiveSha256 | Should -BeExactly '78ae90ef2873eea6b1a278bb34b2b89b0ba2c8ddfa3a6712e893c9c135b04005'
        $pins[0].gradleVersion | Should -BeExactly '8.8'
        $pins[0].buildJavaMajor | Should -Be 17
    }

    It 'pins Quilt 1.20.5 with exact Loader and mappings while omitting unpublished QFAPI' {
        $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json
        $pins = @($manifest.targets | Where-Object targetId -CEQ 'Quilt@1.20.5')
        $pins | Should -HaveCount 1
        $pin = $pins[0]
        $pin.minecraftVersion | Should -BeExactly '1.20.5'
        $pin.loaderVersion | Should -BeExactly '0.20.0-beta.9'
        $pin.quiltMappingsVersion | Should -BeExactly '1.20.5+build.1'
        $pin.quiltedFabricApiVersion | Should -BeNullOrEmpty

        $fixtureRoot = Join-Path $script:repoRoot 'fixtures/quilt/1.20.5-marker'
        $fixtureManifest = Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $target = [pscustomobject]@{targetId='Quilt@1.20.5';minecraftId='1.20.5';loaderVersion='0.20.0-beta.9'}
        $project = [pscustomobject]@{Root=$fixtureRoot;Loader='Quilt';MinecraftVersion='1.20.5';LoaderVersion='0.20.0-beta.9';Toolchain=[pscustomobject]@{id='QuiltLoom';version=$pin.quiltLoomVersion}}
        $fixture = [pscustomobject]@{type='GeneratedPinnedLoaderFixture';source=$pin.sourceRepository;commit=$pin.sourceCommit;license=$pin.sourceLicense;trust='TrustedOfficial';archiveUrl=$pin.sourceArchiveUrl;archiveSha256=$pin.sourceArchiveSha256;fixtureId='MMTLQuiltMarkerFixtureV1';overlaySha256=$fixtureManifest.overlaySha256;overlayFiles=@($fixtureManifest.overlayFiles)}

        $resolved = Get-MmtlQuiltBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $fixture
        $resolved.policy.targetId | Should -BeExactly 'Quilt@1.20.5'
        $resolved.policy.quiltedFabricApiVersion | Should -BeNullOrEmpty
        $versions = Get-Content -LiteralPath (Join-Path $fixtureRoot 'gradle/libs.versions.toml') -Raw
        $versions | Should -Not -Match 'quilted_fabric_api|quilt_standard_libraries'
    }

    It 'validates exact target, immutable source, dependency and overlay hashes' {
        $pin = Get-MmtlQuiltBuildPin -ManifestPath $script:manifestPath -Target $script:target -Project $script:project -Fixture $script:sourceFixture
        $pin.policy.targetId | Should -BeExactly 'Quilt@1.20.6'
        $pin.policy.sourceVerificationStatus | Should -BeExactly 'PinnedInputsVerified'
        $pin.overlaySha256 | Should -BeExactly $script:fixtureManifest.overlaySha256
        $pin.pinHash | Should -Match '^[a-f0-9]{64}$'
    }

    It 'accepts the exact generated pinned Quilt fixture through a matrix job projection' {
        $matrixProject = [pscustomobject]@{
            Root=$script:fixtureRoot;Loader='Quilt';MinecraftVersion='1.20.6';LoaderVersion='0.26.3'
            Toolchain='Java';javaMajor=21
        }
        $matrixFixture = [pscustomobject]@{
            type='GeneratedPinnedLoaderFixture';source=$script:pin.sourceRepository;commit=$script:pin.sourceCommit
            license=$script:pin.sourceLicense;trust='TrustedOfficial';archiveUrl=$script:pin.sourceArchiveUrl
            archiveSha256=$script:pin.sourceArchiveSha256;fixtureId='MMTLQuiltMarkerFixtureV1'
            overlaySha256=$script:fixtureManifest.overlaySha256;overlayFiles=@($script:fixtureManifest.overlayFiles)
        }

        $resolved = Get-MmtlQuiltBuildPin -ManifestPath $script:manifestPath -Target $script:target -Project $matrixProject -Fixture $matrixFixture

        $resolved.policy.targetId | Should -BeExactly 'Quilt@1.20.6'
        $resolved.policy.quiltLoomVersion | Should -BeExactly '1.7.4'
        $resolved.overlaySha256 | Should -BeExactly $script:fixtureManifest.overlaySha256
    }

    It 'rejects tampered marker overlay files' {
        $copy = Join-Path $TestDrive 'quilt-marker-tampered'
        Copy-Item -LiteralPath $script:fixtureRoot -Destination $copy -Recurse
        Add-Content -LiteralPath (Join-Path $copy 'build.gradle') -Value '// tampered'
        $project = $script:project | Select-Object *
        $project.Root = $copy
        { Get-MmtlQuiltBuildPin -ManifestPath $script:manifestPath -Target $script:target -Project $project -Fixture $script:sourceFixture } | Should -Throw '*QUILT_PIN_OVERLAY_FILE_HASH_MISMATCH*'
    }

    It 'rejects a rewritten fixture manifest even when an attacker recalculates its self-reported overlay hash' {
        $copy = Join-Path $TestDrive 'quilt-marker-self-rehashed'
        Copy-Item -LiteralPath $script:fixtureRoot -Destination $copy -Recurse
        $buildPath = Join-Path $copy 'build.gradle'
        Add-Content -LiteralPath $buildPath -Value '// tampered and rehashed'
        $manifestPath = Join-Path $copy '.mmtl-fixture/manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $record = @($manifest.overlayFiles | Where-Object path -CEQ 'build.gradle')[0]
        $record.sha256 = (Get-FileHash -LiteralPath $buildPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $records = @($manifest.overlayFiles | ForEach-Object { $_.path + '|' + $_.sha256 } | Sort-Object -CaseSensitive)
        $manifest.overlaySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records -join "`n")))).ToLowerInvariant()
        Set-Content -LiteralPath $manifestPath -Value ($manifest | ConvertTo-Json -Depth 12) -Encoding utf8
        $project = $script:project | Select-Object *
        $project.Root = $copy
        $fixture = $script:sourceFixture | Select-Object *
        $fixture.overlaySha256 = $manifest.overlaySha256
        { Get-MmtlQuiltBuildPin -ManifestPath $script:manifestPath -Target $script:target -Project $project -Fixture $fixture } | Should -Throw '*QUILT_PIN_OVERLAY_HASH_MISMATCH*'
    }

    It 'rejects a neighboring Minecraft or loader version even when the project uses the same fixture' {
        $target = [pscustomobject]@{targetId='Quilt@1.20.7';minecraftId='1.20.7';loaderVersion='0.26.3'}
        $project = [pscustomobject]@{Root=$script:fixtureRoot;Loader='Quilt';MinecraftVersion='1.20.7';LoaderVersion='0.26.3';Toolchain=[pscustomobject]@{id='QuiltLoom';version='1.7.4'}}
        (Get-MmtlQuiltBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $script:sourceFixture) | Should -BeNullOrEmpty
        $target.targetId='Quilt@1.20.6';$target.minecraftId='1.20.6';$project.MinecraftVersion='1.20.6';$project.LoaderVersion='0.27.0';$target.loaderVersion='0.27.0'
        { Get-MmtlQuiltBuildPin -ManifestPath $script:manifestPath -Target $target -Project $project -Fixture $script:sourceFixture } | Should -Throw '*QUILT_PIN_TARGET_IDENTITY_MISMATCH*'
    }

    It 'rejects a mismatched official source archive hash' {
        $fixture = $script:sourceFixture | Select-Object *
        $fixture.archiveSha256 = '0' * 64
        { Get-MmtlQuiltBuildPin -ManifestPath $script:manifestPath -Target $script:target -Project $script:project -Fixture $fixture } | Should -Throw '*QUILT_PIN_SOURCE_IDENTITY_MISMATCH*'
    }

    It 'records the controlled exact-target build as BuildVerified while leaving runtime unclaimed' {
        $evidenceRoot = Join-Path $script:repoRoot '../compatibility/evidence/build/Quilt-1.20.6-Windows-x64'
        $evidenceRoot = [IO.Path]::GetFullPath($evidenceRoot)
        $evidencePath = Join-Path $evidenceRoot 'result.json'
        $schema = Join-Path $script:repoRoot '../common/schemas/validation-evidence.schema.json'
        $schema = [IO.Path]::GetFullPath($schema)
        $raw = Get-Content -LiteralPath $evidencePath -Raw
        (Test-Json -Json $raw -SchemaFile $schema) | Should -BeTrue
        $evidence = $raw | ConvertFrom-Json
        $evidence.targetId | Should -BeExactly 'Quilt@1.20.6'
        $evidence.validationLevel | Should -BeExactly 'BUILD_VERIFIED'
        $evidence.result | Should -BeExactly 'PASSED'
        $evidence.quiltSecurity.pinId | Should -BeExactly 'Quilt@1.20.6'
        $evidence.java.observedBuildJava.major | Should -Be 21
        $evidence.source.unchangedDuringBuild | Should -BeTrue
        $evidence.source.artifactFresh | Should -BeTrue
        foreach ($log in $evidence.logs) { (Get-FileHash -LiteralPath (Join-Path $evidenceRoot $log.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $log.sha256 }
        (Get-FileHash -LiteralPath (Join-Path $evidenceRoot $evidence.artifact.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $evidence.artifact.sha256
        $index = Get-Content -LiteralPath (Join-Path $script:repoRoot '../compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        @($index.entries | Where-Object { $_.targetId -ceq 'Quilt@1.20.6' -and $_.dimension -ceq 'BuildVerified' }) | Should -HaveCount 1
        $runtimeEntry = @($index.entries | Where-Object { $_.targetId -ceq 'Quilt@1.20.6' -and $_.dimension -ceq 'RuntimeBinding' })
        $runtimeEntry | Should -HaveCount 1
        $runtimeEvidencePath = [IO.Path]::GetFullPath((Join-Path $script:repoRoot ('../' + $runtimeEntry[0].evidencePath)))
        $runtimeEvidenceRaw = Get-Content -LiteralPath $runtimeEvidencePath -Raw
        (Get-FileHash -LiteralPath $runtimeEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $runtimeEntry[0].evidenceSha256
        (Test-Json -Json $runtimeEvidenceRaw -SchemaFile ([IO.Path]::GetFullPath((Join-Path $script:repoRoot '../common/schemas/runtime-binding-evidence.schema.json')))) | Should -BeTrue
        $runtimeEvidence = $runtimeEvidenceRaw | ConvertFrom-Json
        $runtimeEvidence.targetId | Should -BeExactly 'Quilt@1.20.6'
        $runtimeEvidence.mode | Should -BeExactly 'SameAsBuildJvm'
        $runtimeEvidence.runtimeJavaMajor | Should -Be 21
        @($runtimeEvidence.tasks | Where-Object { $_.task -in @('runClient', 'runServer') }) | Should -HaveCount 2
    }

    It 'accepts immutable BuildVerified evidence for the exact Quilt 1.20.4 pin' {
        $schema = [IO.Path]::GetFullPath((Join-Path $script:repoRoot '../common/schemas/validation-evidence.schema.json'))
        $baselinePath = [IO.Path]::GetFullPath((Join-Path $script:repoRoot '../compatibility/evidence/build/Quilt-1.20.6-Windows-x64/result.json'))
        $evidence = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
        $evidence.targetId = 'Quilt@1.20.4'
        $evidence.minecraftId = '1.20.4'
        $evidence.loaderVersion = '0.25.0'
        $evidence.toolchain.version = '1.6.5'
        $evidence.buildSystem.version = '8.8'
        $evidence.java.observedBuildJava.major = 17
        $evidence.quiltSecurity.pinId = 'Quilt@1.20.4'
        $evidence.quiltSecurity.gradleDistributionUrl = 'https://services.gradle.org/distributions/gradle-8.8-bin.zip'
        $evidence.quiltSecurity.gradleVersion = '8.8'
        $evidence.quiltSecurity.quiltLoomVersion = '1.6.5'
        $evidence.quiltSecurity.loaderVersion = '0.25.0'
        $evidence.quiltSecurity.mappingsVersion = '1.20.4+build.3'
        $evidence.quiltSecurity.quiltedFabricApiVersion = '9.0.0-alpha.8+0.97.0-1.20.4'
        $evidence.quiltSecurity.buildJavaMajor = 17
        $evidence.quiltSecurity.runtimeJavaMajor = 17
        (Test-Json -Json ($evidence | ConvertTo-Json -Depth 30 -Compress) -SchemaFile $schema) | Should -BeTrue
    }

    It 'accepts failure evidence for the exact Quilt 1.20.5 loader-only pin' {
        $schema = [IO.Path]::GetFullPath((Join-Path $script:repoRoot '../common/schemas/validation-evidence.schema.json'))
        $baselinePath = [IO.Path]::GetFullPath((Join-Path $script:repoRoot '../compatibility/evidence/build/Quilt-1.20.6-Windows-x64/result.json'))
        $pin = @((Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json).targets | Where-Object targetId -CEQ 'Quilt@1.20.5')[0]
        $fixtureRoot = Join-Path $script:repoRoot 'fixtures/quilt/1.20.5-marker'
        $fixture = Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $evidence = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
        $evidence.targetId = 'Quilt@1.20.5'
        $evidence.minecraftId = '1.20.5'
        $evidence.loaderVersion = [string]$pin.loaderVersion
        $evidence.toolchain.version = [string]$pin.quiltLoomVersion
        $evidence.buildSystem.version = [string]$pin.gradleVersion
        $evidence.java.buildRequirement.major = [int]$pin.buildJavaMajor
        $evidence.java.observedBuildJava.major = [int]$pin.buildJavaMajor
        $evidence.result = 'FAILED'
        $evidence.failureCode = 'BUILD_FAILED_NETWORK'
        $evidence.sourceFixture = [pscustomobject]@{
            type='GeneratedPinnedLoaderFixture';source=[string]$pin.sourceRepository;commit=[string]$pin.sourceCommit
            license=[string]$pin.sourceLicense;trust='TrustedOfficial';archiveUrl=[string]$pin.sourceArchiveUrl
            archiveSha256=[string]$pin.sourceArchiveSha256;fixtureId=[string]$fixture.fixtureId
            overlaySha256=[string]$fixture.overlaySha256;overlayFiles=@($fixture.overlayFiles)
        }
        $evidence.quiltSecurity.pinId = [string]$pin.targetId
        $evidence.quiltSecurity.sourceArchiveSha256 = [string]$pin.sourceArchiveSha256
        $evidence.quiltSecurity.sourceBuildGradleSha256 = [string]$pin.sourceBuildGradleSha256
        $evidence.quiltSecurity.sourceSettingsGradleSha256 = [string]$pin.sourceSettingsGradleSha256
        $evidence.quiltSecurity.sourceWrapperJarSha256 = [string]$pin.sourceWrapperJarSha256
        $evidence.quiltSecurity.sourceVersionsTomlSha256 = [string]$pin.sourceVersionsTomlSha256
        $evidence.quiltSecurity.gradleDistributionUrl = [string]$pin.gradleDistributionUrl
        $evidence.quiltSecurity.gradleDistributionSha256 = [string]$pin.gradleDistributionSha256
        $evidence.quiltSecurity.gradleVersion = [string]$pin.gradleVersion
        $evidence.quiltSecurity.quiltLoomVersion = [string]$pin.quiltLoomVersion
        $evidence.quiltSecurity.loaderVersion = [string]$pin.loaderVersion
        $evidence.quiltSecurity.mappingsVersion = [string]$pin.quiltMappingsVersion
        $evidence.quiltSecurity.quiltedFabricApiVersion = [string]$pin.quiltedFabricApiVersion
        $evidence.quiltSecurity.overlaySha256 = [string]$pin.overlaySha256
        $evidence.quiltSecurity.buildJavaMajor = [int]$pin.buildJavaMajor
        $evidence.quiltSecurity.runtimeJavaMajor = [int]$pin.runtimeJavaMajor
        (Test-Json -Json ($evidence | ConvertTo-Json -Depth 30 -Compress) -SchemaFile $schema) | Should -BeTrue
    }

    It 'indexes controlled Quilt 1.20.4 BuildVerified and RuntimeBinding evidence for the exact target' {
        $evidenceRoot = [IO.Path]::GetFullPath((Join-Path $script:repoRoot '../compatibility/evidence/build/Quilt-1.20.4-Windows-x64'))
        $evidencePath = Join-Path $evidenceRoot 'result.json'
        $schema = [IO.Path]::GetFullPath((Join-Path $script:repoRoot '../common/schemas/validation-evidence.schema.json'))
        $raw = Get-Content -LiteralPath $evidencePath -Raw
        (Test-Json -Json $raw -SchemaFile $schema) | Should -BeTrue
        $evidence = $raw | ConvertFrom-Json
        $evidence.targetId | Should -BeExactly 'Quilt@1.20.4'
        $evidence.result | Should -BeExactly 'PASSED'
        $evidence.validationLevel | Should -BeExactly 'BUILD_VERIFIED'
        $evidence.quiltSecurity.pinId | Should -BeExactly 'Quilt@1.20.4'
        $evidence.java.observedBuildJava.major | Should -Be 17
        foreach ($log in $evidence.logs) { (Get-FileHash -LiteralPath (Join-Path $evidenceRoot $log.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $log.sha256 }
        (Get-FileHash -LiteralPath (Join-Path $evidenceRoot $evidence.artifact.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $evidence.artifact.sha256
        $index = Get-Content -LiteralPath (Join-Path $script:repoRoot '../compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        @($index.entries | Where-Object { $_.targetId -ceq 'Quilt@1.20.4' -and $_.dimension -ceq 'BuildVerified' }) | Should -HaveCount 1
        $runtimeEntry = @($index.entries | Where-Object { $_.targetId -ceq 'Quilt@1.20.4' -and $_.dimension -ceq 'RuntimeBinding' })
        $runtimeEntry | Should -HaveCount 1
        $runtimeEvidencePath = [IO.Path]::GetFullPath((Join-Path $script:repoRoot ('../' + $runtimeEntry[0].evidencePath)))
        $runtimeEvidenceRaw = Get-Content -LiteralPath $runtimeEvidencePath -Raw
        (Get-FileHash -LiteralPath $runtimeEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $runtimeEntry[0].evidenceSha256
        (Test-Json -Json $runtimeEvidenceRaw -SchemaFile ([IO.Path]::GetFullPath((Join-Path $script:repoRoot '../common/schemas/runtime-binding-evidence.schema.json')))) | Should -BeTrue
        $runtimeEvidence = $runtimeEvidenceRaw | ConvertFrom-Json
        $runtimeEvidence.targetId | Should -BeExactly 'Quilt@1.20.4'
        $runtimeEvidence.mode | Should -BeExactly 'SameAsBuildJvm'
        $runtimeEvidence.runtimeJavaMajor | Should -Be 17
        @($runtimeEvidence.tasks | Where-Object { $_.task -in @('runClient', 'runServer') }) | Should -HaveCount 2
    }
}
