BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:bridgeRoot = Join-Path $script:repoRoot 'common/agent/bridges/fabric-1.21.11'
    $script:evidenceRoot = Join-Path $script:repoRoot 'compatibility/evidence/agent-build/Fabric-1.21.11-Windows-x64'
}

Describe 'Fabric 1.21.11 exact Agent bridge' {
    It 'uses the exact target getter instead of shadowing an inherited connection field' {
        $mixinPath = Join-Path $script:bridgeRoot 'src/client/java/org/pycodersmod/mmtl/agent/mixin/ClientPlayNetworkHandlerReadyMixin.java'
        $mixin = Get-Content -LiteralPath $mixinPath -Raw
        $mixin | Should -Match '\.getConnection\(\)\.getRemoteAddress\(\)'
        $mixin | Should -Not -Match '@Shadow\s+@Final\s+protected\s+Connection\s+connection'
    }

    It 'stages a hash-bound provider only for the pinned exact target' {
        $manifestPath = Join-Path $script:evidenceRoot 'agent-manifest.json'
        Test-Path -LiteralPath $manifestPath | Should -BeTrue

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.loaderId | Should -BeExactly 'Fabric'
        @($manifest.minecraftVersions) | Should -Contain '1.21.11'
        @($manifest.loaderVersions) | Should -Contain '0.19.5'
        $manifest.artifact | Should -BeExactly 'providers/fabric-1.21.11/mmtl-agent-fabric-1.21.11-0.1.0.jar'
        $manifest.minJavaMajor | Should -Be 21
        ($manifest.roles -join ',') | Should -BeExactly 'Client,Host,Guest'
        ($manifest.capabilities -join ',') | Should -BeExactly 'OfflineSessionHandshake,SessionEventTelemetry'

        $artifactPath = Join-Path $script:evidenceRoot 'agent.jar'
        Test-Path -LiteralPath $artifactPath | Should -BeTrue
        (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $manifest.sha256
    }

    It 'loads through Fabric ModInitializer and gates activation on an MMTL handshake' {
        $artifactPath = Join-Path $script:evidenceRoot 'agent.jar'
        $artifactStream = [IO.File]::OpenRead($artifactPath)
        $archive = [IO.Compression.ZipArchive]::new($artifactStream, [IO.Compression.ZipArchiveMode]::Read)
        $reader = $null
        try {
            $metadataEntry = $archive.GetEntry('fabric.mod.json')
            $metadataEntry | Should -Not -BeNull
            $reader = [IO.StreamReader]::new($metadataEntry.Open())
            $metadata = $reader.ReadToEnd() | ConvertFrom-Json
        } finally {
            if ($reader) { $reader.Dispose() }
            $archive.Dispose()
            $artifactStream.Dispose()
        }
        @($metadata.entrypoints.main) | Should -Contain 'org.pycodersmod.mmtl.agent.MmtlFabricAgent'
        $metadata.depends.fabricloader | Should -BeExactly '=0.19.5'
        $metadata.depends.minecraft | Should -BeExactly '=1.21.11'
        $metadata.depends.java | Should -BeExactly '>=21'

        $entrypoint = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'src/main/java/org/pycodersmod/mmtl/agent/MmtlFabricAgent.java') -Raw
        $entrypoint | Should -Match 'implements\s+ModInitializer'
        $entrypoint | Should -Match 'FabricAgentBootstrap\.start\(\)'

        $bootstrap = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'src/main/java/org/pycodersmod/mmtl/agent/FabricAgentBootstrap.java') -Raw
        $bootstrap | Should -Match 'AgentHandshake\.fromSystemProperties\(\)'
        $bootstrap | Should -Match 'context\s*==\s*null'
    }
}

Describe 'Fabric 1.21.7 exact Agent bridge evidence' {
    It 'binds the staged artifact to only Minecraft 1.21.7 and Fabric Loader 0.19.5' {
        $evidenceRoot = Join-Path $script:repoRoot 'compatibility/evidence/agent-build/Fabric-1.21.7-Windows-x64'
        $manifestPath = Join-Path $evidenceRoot 'agent-manifest.json'
        Test-Path -LiteralPath $manifestPath | Should -BeTrue

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.loaderId | Should -BeExactly 'Fabric'
        @($manifest.minecraftVersions) | Should -Be @('1.21.7')
        @($manifest.loaderVersions) | Should -Be @('0.19.5')
        $manifest.minJavaMajor | Should -Be 21

        $artifactPath = Join-Path $evidenceRoot 'agent.jar'
        Test-Path -LiteralPath $artifactPath | Should -BeTrue
        (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $manifest.sha256

        $artifactStream = [IO.File]::OpenRead($artifactPath)
        $archive = [IO.Compression.ZipArchive]::new($artifactStream, [IO.Compression.ZipArchiveMode]::Read)
        $reader = $null
        try {
            $metadataEntry = $archive.GetEntry('fabric.mod.json')
            $metadataEntry | Should -Not -BeNull
            $reader = [IO.StreamReader]::new($metadataEntry.Open())
            $metadata = $reader.ReadToEnd() | ConvertFrom-Json
        } finally {
            if ($reader) { $reader.Dispose() }
            $archive.Dispose()
            $artifactStream.Dispose()
        }
        $metadata.depends.minecraft | Should -BeExactly '=1.21.7'
        $metadata.depends.fabricloader | Should -BeExactly '=0.19.5'
        $metadata.depends.java | Should -BeExactly '>=21'
    }
}

Describe 'Fabric 26.3 exact Agent bridge' {
    It 'generates exact Minecraft, Loader, and Java constraints from Gradle properties' {
        $buildScript = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'build.gradle') -Raw
        $settings = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'settings.gradle') -Raw
        $metadata = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'src/main/resources/fabric.mod.json') -Raw
        $properties = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'gradle.properties') -Raw

        $buildScript | Should -Match 'project\.minecraft_version'
        $buildScript | Should -Match 'project\.loader_version'
        $buildScript | Should -Match 'project\.agent_min_java'
        $buildScript | Should -Match 'project\.findProperty\(''loom_plugin_id''\)'
        $buildScript | Should -Match 'loaderConfiguration'
        $buildScript | Should -Not -Match 'configurations\.runtimeClasspath'
        $buildScript | Should -Match 'zipTree\(coreJarFile\)'
        $buildScript | Should -Match 'mappingStrategy\s*==\s*''officialMojang'''
        $buildScript | Should -Match 'mappingStrategy\s*!=\s*''none'''
        $settings | Should -Match 'useModule\("net\.fabricmc:fabric-loom:\$\{requested\.version\}"\)'
        $buildScript | Should -Match 'metadata\.depends\.minecraft\s*!=\s*"=\$\{minecraftVersion\}"'
        $buildScript | Should -Match 'metadata\.depends\.fabricloader\s*!=\s*"=\$\{loaderVersion\}"'
        $metadata | Should -Match '"minecraft":\s*"=\$\{minecraftVersion\}"'
        $metadata | Should -Match '"fabricloader":\s*"=\$\{loaderVersion\}"'
        $metadata | Should -Match '"java":\s*">=\$\{minimumJavaMajor\}"'
        $properties | Should -Match '(?m)^agent_min_java=21$'
        $properties | Should -Match '(?m)^loom_plugin_id=net\.fabricmc\.fabric-loom-remap$'
        $properties | Should -Match '(?m)^mapping_strategy=officialMojang$'
    }

    It 'stages a Java 25 provider bound only to Fabric Loader 0.19.5 and Minecraft 26.3' {
        $evidenceRoot = Join-Path $script:repoRoot 'compatibility/evidence/agent-build/Fabric-26.3-Windows-x64'
        $manifestPath = Join-Path $evidenceRoot 'agent-manifest.json'
        Test-Path -LiteralPath $manifestPath | Should -BeTrue

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.loaderId | Should -BeExactly 'Fabric'
        @($manifest.minecraftVersions) | Should -Contain '26.3'
        @($manifest.loaderVersions) | Should -Contain '0.19.5'
        $manifest.minJavaMajor | Should -Be 25
        ($manifest.capabilities -join ',') | Should -BeExactly 'OfflineSessionHandshake,SessionEventTelemetry'

        $artifactPath = Join-Path $evidenceRoot 'agent.jar'
        Test-Path -LiteralPath $artifactPath | Should -BeTrue
        (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $manifest.sha256
    }
}

Describe 'Fabric Loom-generated artifact integrity' {
    It 'pins only the exact variable-timestamp Minecraft artifacts and their content hashes' {
        $pins = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'gradle/loom-generated-artifacts.json') -Raw | ConvertFrom-Json
        $pins.schemaVersion | Should -Be 1
        $targetPins = @($pins.artifacts | Where-Object minecraftVersion -CEQ '1.21.11')
        $targetPins.Count | Should -Be 2
        @($targetPins | ForEach-Object name | Sort-Object) | Should -Be @('minecraft-clientonly', 'minecraft-common')
        foreach ($pin in $targetPins) {
            $pin.group | Should -BeExactly 'net.minecraft'
            $pin.version | Should -BeExactly '1.21.11-loom.mappings.1_21_11.layered+hash.2198-v2'
            $pin.contentSha256 | Should -Match '^[a-f0-9]{64}$'
            $pin.configuration | Should -BeIn @('compileClasspath', 'clientCompileClasspath')
        }
        $targetPins = @($pins.artifacts | Where-Object minecraftVersion -CEQ '1.21.8')
        $targetPins.Count | Should -Be 2
        @($targetPins | ForEach-Object name | Sort-Object) | Should -Be @('minecraft-clientonly', 'minecraft-common')
    }

    It 'limits Gradle trusted-artifact bypass to the two pinned exact coordinates and verifies content before compilation' {
        $verificationPath = Join-Path $script:bridgeRoot 'gradle/verification-metadata.xml'
        [xml]$verification = Get-Content -LiteralPath $verificationPath -Raw
        $namespace = [Xml.XmlNamespaceManager]::new($verification.NameTable)
        $namespace.AddNamespace('dv', 'https://schema.gradle.org/dependency-verification')
        $trusts = @($verification.SelectNodes('/dv:verification-metadata/dv:configuration/dv:trusted-artifacts/dv:trust[@group="net.minecraft"]', $namespace))
        $pins = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'gradle/loom-generated-artifacts.json') -Raw | ConvertFrom-Json
        $trusts.Count | Should -Be $pins.artifacts.Count
        foreach ($trust in $trusts) {
            $pin = @($pins.artifacts | Where-Object { $_.group -ceq $trust.GetAttribute('group') -and $_.name -ceq $trust.GetAttribute('name') -and $_.version -ceq $trust.GetAttribute('version') -and $_.file -ceq $trust.GetAttribute('file') })
            $pin.Count | Should -Be 1
            $trust.GetAttribute('reason') | Should -Match 'canonical digest'
        }
        $verification.SelectSingleNode('/dv:verification-metadata/dv:configuration/dv:verify-metadata', $namespace).InnerText | Should -BeExactly 'true'
        $buildScript = Get-Content -LiteralPath (Join-Path $script:bridgeRoot 'build.gradle') -Raw
        $buildScript | Should -Match "tasks\.named\('compileJava'\).*dependsOn\(contentGate\)"
        $buildScript | Should -Match "tasks\.named\('compileClientJava'\).*dependsOn\(contentGate\)"
    }
}
