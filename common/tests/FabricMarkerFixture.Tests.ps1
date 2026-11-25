BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

Describe 'Fabric 1.21.8 marker fixture' {
    It 'pins a separate official Fabric 1.21.10 target and its stable exact toolchain' {
        $pins = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json
        $pin = @($pins.targets | Where-Object targetId -CEQ 'Fabric@1.21.10')

        $pin | Should -HaveCount 1
        $pin[0].minecraftVersion | Should -BeExactly '1.21.10'
        $pin[0].loaderVersion | Should -BeExactly '0.19.5'
        $pin[0].fabricApiVersion | Should -BeExactly '0.138.4+1.21.10'
        $pin[0].loomVersion | Should -BeExactly '1.17.21'
        $pin[0].gradleVersion | Should -BeExactly '9.5.1'
        $pin[0].buildJavaMajor | Should -Be 25
        $pin[0].runtimeJavaMajor | Should -Be 21
        $pin[0].sourceCommit | Should -BeExactly '40d278b93501e8019e2eab169465d34efc61865a'
        $pin[0].sourceArchiveSha256 | Should -BeExactly 'd0741395e99f235a31ef29bc4c2a04098b91e9313f188b09158531be4e870618'
        $pin[0].sourceLicense | Should -BeExactly 'CC0-1.0'
        $pin[0].verificationStatus | Should -BeExactly 'PinnedInputsVerified'
    }

    It 'limits 1.21.10 trust to exact Loom-generated mapping and remap filenames' {
        $pin = @((Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json).targets | Where-Object targetId -CEQ 'Fabric@1.21.10')[0]

        $pin.trustedArtifactCount | Should -Be 70
        $pin.trustedArtifactFiles | Should -Contain 'mappings-layered+hash.2198.jar'
        $pin.trustedArtifactFiles | Should -Contain 'minecraft-common-6227aad8ee-1.21.10-loom.mappings.1_21_10.layered+hash.2198-v2.jar'
        @($pin.trustedArtifactFiles | Where-Object { $_ -match '[*?]' }) | Should -HaveCount 0
        @($pin.trustedArtifactFiles | Where-Object { $_ -notmatch '^(mappings-layered\+hash\.2198\.jar|fabric-[A-Za-z0-9._+\-]+\.jar|minecraft-(common|clientOnly)-[A-Za-z0-9._+\-]+\.jar)$' }) | Should -HaveCount 0
    }

    It 'accepts exact-target pin records for the non-obfuscated Loom generation' {
        $schema = Join-Path $script:repoRoot 'compatibility/fabric-build-pins.schema.json'
        $pins = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json
        $newGenerationPin = $pins.targets[0] | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $newGenerationPin.targetId = 'Fabric@26.3'
        $newGenerationPin.minecraftVersion = '26.3'
        $newGenerationPin.fabricApiVersion = '0.162.0+26.3'
        $newGenerationPin.loomPluginId = 'net.fabricmc.fabric-loom'
        $newGenerationPin.runtimeJavaMajor = 25
        $pins.targets += $newGenerationPin

        (Test-Json -Json ($pins | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schema) | Should -BeTrue
    }

    It 'accepts the fixed input catalog while rejecting unsupported version drift' {
        $schema = Join-Path $script:repoRoot 'compatibility/fabric-build-pins.schema.json'
        $pins = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json

        (Test-Json -Json ($pins | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schema) | Should -BeTrue
        $pins.targets[0].loomVersion = '1.18-SNAPSHOT'
        (Test-Json -Json ($pins | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schema -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'pins a complete Gradle dependency verification snapshot by hash' {
        $pin = (Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json).targets[0]
        $verificationPath = Join-Path $script:repoRoot 'compatibility/fabric-verification-metadata/1.21.8.xml'
        $verification = Get-Content -LiteralPath $verificationPath -Raw
        $xml = [xml]$verification
        $components = @(Select-Xml -Xml $xml -XPath "//*[local-name()='component']")
        $artifacts = @(Select-Xml -Xml $xml -XPath "//*[local-name()='artifact']")
        $checksums = @(Select-Xml -Xml $xml -XPath "//*[local-name()='sha256']")
        $trustedArtifacts = @(Select-Xml -Xml $xml -XPath "//*[local-name()='trusted-artifacts']/*[local-name()='trust']")

        (Get-FileHash -LiteralPath $verificationPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $pin.verificationMetadataSha256
        $components | Should -HaveCount $pin.verificationComponentCount
        $artifacts | Should -HaveCount $pin.verificationArtifactCount
        $checksums | Should -HaveCount $pin.verificationArtifactCount
        $trustedArtifacts | Should -HaveCount $pin.trustedArtifactCount
        @($pin.trustedArtifactFiles | Sort-Object -CaseSensitive) | Should -Be @($trustedArtifacts.Node | ForEach-Object { $_.GetAttribute('file') } | Sort-Object -CaseSensitive)
        foreach ($trusted in $trustedArtifacts) {
            $trusted.Node.Attributes | Should -HaveCount 2
            $trusted.Node.HasAttribute('file') | Should -BeTrue
            $trusted.Node.HasAttribute('group') | Should -BeFalse
        }
        $xml.'verification-metadata'.configuration.'verify-metadata' | Should -Be 'true'
    }

    It 'pins the 26.3 non-obfuscated Loom dependency closure with target-exact generated artifact exceptions' {
        $pins = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json
        $pin = @($pins.targets | Where-Object targetId -CEQ 'Fabric@26.3')
        $pin | Should -HaveCount 1
        $verificationPath = Join-Path $script:repoRoot 'compatibility/fabric-verification-metadata/26.3.xml'
        (Get-FileHash -LiteralPath $verificationPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $pin[0].verificationMetadataSha256
        $xml = [xml](Get-Content -LiteralPath $verificationPath -Raw)
        @(Select-Xml -Xml $xml -XPath "//*[local-name()='component']") | Should -HaveCount $pin[0].verificationComponentCount
        @(Select-Xml -Xml $xml -XPath "//*[local-name()='artifact']") | Should -HaveCount $pin[0].verificationArtifactCount
        @(Select-Xml -Xml $xml -XPath "//*[local-name()='sha256']") | Should -HaveCount $pin[0].verificationArtifactCount
        @(Select-Xml -Xml $xml -XPath "//*[local-name()='trusted-artifacts']/*[local-name()='trust']") | Should -HaveCount 2
        $pin[0].trustedArtifactFiles | Should -Be @('minecraft-common-7e9a32a5b8-26.3.jar','minecraft-clientOnly-7e9a32a5b8-26.3.jar')
        $trusted = @(Select-Xml -Xml $xml -XPath "//*[local-name()='trusted-artifacts']/*[local-name()='trust']")
        $trusted | Should -HaveCount 2
        $trusted[0].Node.GetAttribute('file') | Should -BeExactly $pin[0].trustedArtifactFiles[0]
        $pin[0].loomPluginId | Should -BeExactly 'net.fabricmc.fabric-loom'
        $pin[0].runtimeJavaMajor | Should -Be 25
    }

    It 'keeps each target verification metadata synchronized across pin, source fixture, and compatibility copy' {
        $pins = (Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json).targets
        foreach ($pin in $pins) {
            $compatibilityPath = Join-Path $script:repoRoot ('compatibility/fabric-verification-metadata/' + $pin.minecraftVersion + '.xml')
            $fixturePath = Join-Path $script:repoRoot ('common/fixtures/fabric/' + $pin.minecraftVersion + '-marker/gradle/verification-metadata.xml')

            Test-Path -LiteralPath $compatibilityPath -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $fixturePath -PathType Leaf | Should -BeTrue
            (Get-FileHash -LiteralPath $compatibilityPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $pin.verificationMetadataSha256
            (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $pin.verificationMetadataSha256

            $xml = [xml](Get-Content -LiteralPath $compatibilityPath -Raw)
            $trustedArtifacts = @(Select-Xml -Xml $xml -XPath "//*[local-name()='trusted-artifacts']/*[local-name()='trust']" | ForEach-Object { $_.Node.GetAttribute('file') })
            (@($trustedArtifacts | Sort-Object -CaseSensitive) -join "`n") | Should -BeExactly (@($pin.trustedArtifactFiles | Sort-Object -CaseSensitive) -join "`n")
        }
    }

    It 'binds the generated fixture to the exact official source and diagnostic build inputs' {
        $pinPath = Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json'
        $fixtureRoot = Join-Path $script:repoRoot 'common/fixtures/fabric/1.21.8-marker'
        $pinManifest = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
        $fixture = Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $pin = @($pinManifest.targets | Where-Object targetId -CEQ 'Fabric@1.21.8')

        $pin | Should -HaveCount 1
        $pinManifest.status | Should -BeExactly 'PARTIAL'
        $pin[0].verificationStatus | Should -BeExactly 'PinnedInputsVerified'
        $fixture.targetId | Should -BeExactly 'Fabric@1.21.8'
        $fixture.sourceCommit | Should -BeExactly $pin[0].sourceCommit
        $fixture.sourceArchiveSha256 | Should -BeExactly $pin[0].sourceArchiveSha256
        $fixture.loomVersion | Should -BeExactly $pin[0].loomVersion
        $fixture.gradleVersion | Should -BeExactly $pin[0].gradleVersion
        $fixture.verificationMetadataSha256 | Should -BeExactly $pin[0].verificationMetadataSha256
        $fixture.buildJavaMajor | Should -Be 25
        $fixture.runtimeJavaMajor | Should -Be 21
    }

    It 'verifies every owned overlay file and its aggregate hash' {
        $fixtureRoot = Join-Path $script:repoRoot 'common/fixtures/fabric/1.21.8-marker'
        $fixture = Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json

        $fixture.fixtureId | Should -BeExactly 'MMTLFabricMarkerFixtureV1'
        $fixture.overlayFiles | Should -HaveCount 7
        foreach ($file in $fixture.overlayFiles) {
            $path = Join-Path $fixtureRoot $file.path
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256
        }
        $records = @($fixture.overlayFiles | ForEach-Object { $_.path + '|' + $_.sha256 } | Sort-Object -CaseSensitive)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records -join "`n")))).ToLowerInvariant()
        $hash | Should -BeExactly $fixture.overlaySha256
    }

    It 'contains a minimal Fabric entrypoint and pins the Loom declaration in the generated project' {
        $fixtureRoot = Join-Path $script:repoRoot 'common/fixtures/fabric/1.21.8-marker'
        $properties = Get-Content -LiteralPath (Join-Path $fixtureRoot 'gradle.properties') -Raw
        $metadata = Get-Content -LiteralPath (Join-Path $fixtureRoot 'src/main/resources/fabric.mod.json') -Raw | ConvertFrom-Json
        $java = Get-Content -LiteralPath (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw
        $build = Get-Content -LiteralPath (Join-Path $fixtureRoot 'build.gradle') -Raw
        $settings = Get-Content -LiteralPath (Join-Path $fixtureRoot 'settings.gradle') -Raw
        $wrapperProperties = Get-Content -LiteralPath (Join-Path $fixtureRoot 'gradle/wrapper/gradle-wrapper.properties') -Raw
        $pin = (Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json).targets[0]

        $properties | Should -Match '(?m)^loom_version=1\.18\.4$'
        $properties | Should -Match '(?m)^loader_version=0\.19\.5$'
        $properties | Should -Match '(?m)^fabric_api_version=0\.136\.1\+1\.21\.8$'
        $metadata.id | Should -BeExactly 'mmtl_marker'
        $metadata.entrypoints.main | Should -Contain 'org.pycodersmod.mmtlfixture.MmtlMarkerMod'
        $metadata.depends.'fabric-api' | Should -BeExactly '=0.136.1+1.21.8'
        $java | Should -Match 'implements ModInitializer'
        $build | Should -Match '"mmtl_marker"'
        $build | Should -Not -Match '"modid"'
        $settings | Should -Match "rootProject.name = 'mmtl-marker'"
        $wrapperProperties | Should -Match ('(?m)^distributionSha256Sum=' + [regex]::Escape($pin.gradleDistributionSha256) + '$')
        (Get-FileHash -LiteralPath (Join-Path $fixtureRoot 'gradle/wrapper/gradle-wrapper.jar') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $pin.sourceWrapperJarSha256
        (Test-Path -LiteralPath (Join-Path $fixtureRoot 'gradle/verification-metadata.xml')) | Should -BeTrue
    }
}
