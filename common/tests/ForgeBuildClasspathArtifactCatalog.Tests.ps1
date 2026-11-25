BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Adapters/ForgeSecureBuild.psm1') -Force
    $script:catalogPath=Join-Path (Split-Path -Parent $script:repoRoot) 'compatibility/forge-gradle-classpath-artifacts.json'

function New-ModernForgeGradle6ClasspathFixture {
    param([Parameter(Mandatory)][string]$MinecraftId)
    $targets=@{
        '1.18.2'=@{forge='1.18.2-40.3.11';gradle='8.8';foojay='0.7.0';mdk='06dc30e30b148d33e36e1c24f47c985e46ae669556f2060d750a141264bcdc26';wrapper='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612'}
        '1.19.2'=@{forge='1.19.2-43.5.1';gradle='8.8';foojay='0.7.0';mdk='145514b3e54c78c05fb7e6d8bbc22c5ab63b1155a31415478b454e53baffd90e';wrapper='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612'}
        '1.19.4'=@{forge='1.19.4-45.4.1';gradle='8.8';foojay='0.7.0';mdk='9af67ea5ac56c0113dce53d879cbe4f38a0b1b45542e7488c8757b3509b963ae';wrapper='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612'}
        '1.20'=@{forge='1.20-46.0.14';gradle='8.1.1';foojay='0.5.0';mdk='a7a0cc82e28092fc069dfecb689212a6e36203a6ce9e1548c871b3f445e36d7f';wrapper='e111cb9948407e26351227dabce49822fb88c37ee72f1d1582a69c68af2e702f'}
        '1.20.1'=@{forge='1.20.1-47.4.5';gradle='8.8';foojay='0.7.0';mdk='3a55c4c6cb66420d69f5d99858da222272fea19592077cd60652143c188360fc';wrapper='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612'}
    }
    $target=$targets[$MinecraftId]
    $sourceCatalogPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle6-build-classpath-artifacts/Forge-1.16.5.json'
    $catalog=Get-Content -LiteralPath $sourceCatalogPath -Raw|ConvertFrom-Json
    $catalog.schemaVersion=2;$catalog.targetId='Forge@'+$MinecraftId;$catalog.forgeVersion=$target.forge;$catalog.gradleVersion=$target.gradle
    $catalog|Add-Member -NotePropertyName mdkSha256 -NotePropertyValue $target.mdk -Force
    $catalog|Add-Member -NotePropertyName gradleDistributionUrl -NotePropertyValue ('https://services.gradle.org/distributions/gradle-'+$target.gradle+'-bin.zip') -Force
    $catalog|Add-Member -NotePropertyName gradleDistributionSha256 -NotePropertyValue $target.wrapper -Force
    $catalog|Add-Member -NotePropertyName foojayResolverVersion -NotePropertyValue $target.foojay -Force
    if($target.foojay -ceq '0.5.0'){
        $pins=@{
            marker=@{file='org.gradle.toolchains.foojay-resolver-convention.gradle.plugin-0.5.0.pom';bytes=715L;sha256='8cb9db3f46febd5b0f981f5e1ce0e4f8bffe74c1e37504c1ba22d6b35823dd37'}
            jar=@{file='foojay-resolver-0.5.0.jar';bytes=40620L;sha256='531608349a6e5d6b053876b11dc1c1987d0b012d642cffdb28e38032e5e7f81b'}
            pom=@{file='foojay-resolver-0.5.0.pom';bytes=975L;sha256='824e8819d685581917eb6211904b03f18152247338bc5df231a3c251438212b0'}
        }
        foreach($artifact in $catalog.artifacts){
            $kind=if([string]$artifact.group -ceq 'org.gradle.toolchains.foojay-resolver-convention'){'marker'}elseif([string]$artifact.group -ceq 'org.gradle.toolchains' -and [string]$artifact.artifact -ceq 'foojay-resolver'){[string]$artifact.extension}else{$null}
            if($kind){$pin=$pins[$kind];$artifact.version='0.5.0';$artifact.file=$pin.file;$artifact.bytes=$pin.bytes;$artifact.sha256=$pin.sha256;$artifact.url='https://plugins.gradle.org/m2/'+[string]$artifact.group.Replace('.','/')+'/'+[string]$artifact.artifact+'/0.5.0/'+$pin.file}
        }
        foreach($dependency in $catalog.dependencies){if([string]$dependency.scope -ceq 'settings-plugin' -and [string]$dependency.group -ceq 'org.gradle.toolchains' -and [string]$dependency.artifact -ceq 'foojay-resolver'){$dependency.version='0.5.0'}}
    }
    $catalog.catalogHash=''
    $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
    $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
    $path=Join-Path $TestDrive ('Forge-'+$MinecraftId+'-modern-classpath.json')
    ConvertTo-Json -InputObject $catalog -Depth 30|Set-Content -LiteralPath $path -Encoding utf8
    $path
}
}

Describe 'ForgeGradle classpath artifact catalog' {
    It 'validates exact source and wrapper pins for all five modern FG6 targets' {
        $schemaPath=Join-Path $script:repoRoot 'schemas/forge-gradle6-build-classpath.schema.json'
        foreach($minecraftId in @('1.18.2','1.19.2','1.19.4','1.20','1.20.1')){
            $path=New-ModernForgeGradle6ClasspathFixture -MinecraftId $minecraftId
            $resolved=Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $path
            $resolved.catalog.targetId | Should -BeExactly ('Forge@'+$minecraftId)
            $resolved.catalog.mdkSha256 | Should -Match '^[a-f0-9]{64}$'
            $resolved.catalog.gradleDistributionSha256 | Should -Match '^[a-f0-9]{64}$'
            $resolved.foojayResolverVersion | Should -BeExactly $(if($minecraftId -ceq '1.20'){'0.5.0'}else{'0.7.0'})
            (Test-Json -LiteralPath $path -SchemaFile $schemaPath) | Should -BeTrue
        }
    }

    It 'rejects a modern FG6 catalog paired with the wrong Foojay version or wrapper checksum' {
        $path=New-ModernForgeGradle6ClasspathFixture -MinecraftId '1.20'
        $catalog=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        $catalog.foojayResolverVersion='0.7.0'
        $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
        $tampered=Join-Path $TestDrive 'Forge-1.20-wrong-foojay.json'
        ConvertTo-Json -InputObject $catalog -Depth 30|Set-Content -LiteralPath $tampered -Encoding utf8
        { Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $tampered } | Should -Throw '*FORGE_GRADLE6_CLASSPATH_CATALOG_TARGET_PIN_MISMATCH*'
    }

    It 'validates the complete ForgeGradle 6.0.54 plugin and settings-plugin artifact closure' {
        $schemaPath=Join-Path $script:repoRoot 'schemas/forge-gradle6-build-classpath.schema.json'
        $catalogPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle6-build-classpath-artifacts/Forge-1.16.5.json'
        Test-Path -LiteralPath $schemaPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $catalogPath -PathType Leaf | Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $catalogPath -Raw) -SchemaFile $schemaPath) | Should -BeTrue

        $resolved=Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $catalogPath

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.16.5'
        $resolved.catalog.forgeGradleSpec | Should -BeExactly '[6.0,6.2)'
        $resolved.catalog.forgeGradleResolvedVersion | Should -BeExactly '6.0.54'
        $resolved.catalog.gradleVersion | Should -BeExactly '8.4'
        $resolved.catalog.buildJavaMajor | Should -Be 17
        $resolved.dependencies | Should -HaveCount 33
        @($resolved.dependencies | Where-Object scope -ceq 'project-plugin') | Should -HaveCount 31
        @($resolved.dependencies | Where-Object scope -ceq 'settings-plugin') | Should -HaveCount 2
        $resolved.artifacts | Should -HaveCount 88
        @($resolved.artifacts | Where-Object { $_.group -ceq 'net.minecraftforge.gradle' -and $_.artifact -ceq 'net.minecraftforge.gradle.gradle.plugin' -and $_.extension -ceq 'pom' }) | Should -HaveCount 1
        @($resolved.artifacts | Where-Object { $_.group -ceq 'org.gradle.toolchains.foojay-resolver-convention' -and $_.extension -ceq 'pom' }) | Should -HaveCount 1
    }

    It 'pins the Commons Compress parent POM required by the ForgeGradle 6.0.54 closure' {
        $catalogPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle6-build-classpath-artifacts/Forge-1.18.2.json'
        $resolved=Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $catalogPath
        $parent=@($resolved.artifacts|Where-Object {$_.group -ceq 'org.apache.commons' -and $_.artifact -ceq 'commons-parent' -and $_.version -ceq '47' -and $_.extension -ceq 'pom'})
        $apacheParent=@($resolved.artifacts|Where-Object {$_.group -ceq 'org.apache' -and $_.artifact -ceq 'apache' -and $_.version -ceq '19' -and $_.extension -ceq 'pom'})

        $parent | Should -HaveCount 1
        $parent[0].file | Should -BeExactly 'commons-parent-47.pom'
        $parent[0].sha256 | Should -Match '^[a-f0-9]{64}$'
        $apacheParent | Should -HaveCount 1
        $apacheParent[0].file | Should -BeExactly 'apache-19.pom'
        $apacheParent[0].sha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'pins the exact Minecraft 1.18.2 JSR-305 compile artifact and its Maven parent closure' {
        $catalogPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle6-build-classpath-artifacts/Forge-1.18.2.json'
        $catalog=Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $catalogPath
        $jar=@($catalog.artifacts|Where-Object { $_.group -CEQ 'com.google.code.findbugs' -and $_.artifact -CEQ 'jsr305' -and $_.version -CEQ '3.0.1' -and $_.extension -CEQ 'jar' })
        $pom=@($catalog.artifacts|Where-Object { $_.group -CEQ 'com.google.code.findbugs' -and $_.artifact -CEQ 'jsr305' -and $_.version -CEQ '3.0.1' -and $_.extension -CEQ 'pom' })
        $parent=@($catalog.artifacts|Where-Object { $_.group -CEQ 'org.sonatype.oss' -and $_.artifact -CEQ 'oss-parent' -and $_.version -CEQ '7' -and $_.extension -CEQ 'pom' })

        $jar | Should -HaveCount 1
        $jar[0].bytes | Should -Be 19943
        $jar[0].sha256 | Should -BeExactly 'c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd'
        $pom | Should -HaveCount 1
        $pom[0].bytes | Should -Be 4286
        $pom[0].sha256 | Should -BeExactly '4170a761dc5bfd3981a8e6f7aab9e2acdce82d34fd5aa9bb11e3c090d25314ce'
        $parent | Should -HaveCount 1
        $parent[0].bytes | Should -Be 4824
        $parent[0].sha256 | Should -BeExactly 'b51f8867c92b6a722499557fc3a1fdea77bdf9ef574722fe90ce436a29559454'
    }

    It 'declares Forge 1.14.4 as an exact target in every ForgeGradle 3 catalog schema' {
        $schemaNames = @('forge-gradle3-target-inputs.schema.json','forge-gradle3-runtime-artifacts.schema.json','forge-gradle3-build-classpath.schema.json')
        foreach ($schemaName in $schemaNames) {
            $schema = Get-Content -LiteralPath (Join-Path $script:repoRoot "schemas/$schemaName") -Raw | ConvertFrom-Json
            $schema.properties.targetId.enum | Should -Contain 'Forge@1.14.4' -Because $schemaName
        }
    }

    It 'declares Forge 1.15.2 as an exact target in every ForgeGradle 3 catalog schema' {
        $schemaNames = @('forge-gradle3-target-inputs.schema.json','forge-gradle3-runtime-artifacts.schema.json','forge-gradle3-build-classpath.schema.json')
        foreach ($schemaName in $schemaNames) {
            $schema = Get-Content -LiteralPath (Join-Path $script:repoRoot "schemas/$schemaName") -Raw | ConvertFrom-Json
            $schema.properties.targetId.enum | Should -Contain 'Forge@1.15.2' -Because $schemaName
        }
    }

    It 'declares Forge 1.15.1 as an exact target and validates its target inputs' {
        $schemaNames = @('forge-gradle3-target-inputs.schema.json','forge-gradle3-runtime-artifacts.schema.json','forge-gradle3-build-classpath.schema.json')
        foreach ($schemaName in $schemaNames) {
            $schema = Get-Content -LiteralPath (Join-Path $script:repoRoot "schemas/$schemaName") -Raw | ConvertFrom-Json
            $schema.properties.targetId.enum | Should -Contain 'Forge@1.15.1' -Because $schemaName
        }
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.15.1.json'
        Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.15.1'
        $resolved.catalog.forgeVersion | Should -BeExactly '1.15.1-30.0.51'
    }

    It 'declares Forge 1.15 as an exact target in every ForgeGradle 3 catalog schema' {
        $schemaNames=@('forge-gradle3-target-inputs.schema.json','forge-gradle3-runtime-artifacts.schema.json','forge-gradle3-build-classpath.schema.json')
        foreach($schemaName in $schemaNames){$schema=Get-Content -LiteralPath (Join-Path $script:repoRoot "schemas/$schemaName") -Raw|ConvertFrom-Json;$schema.properties.targetId.enum|Should -Contain 'Forge@1.15' -Because $schemaName}
    }

    It 'validates Forge 1.15 userdev MCP config and the separately selected MCP snapshot mapping' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.15.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'
        Test-Path -LiteralPath $path -PathType Leaf|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema)|Should -BeTrue
        $target=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path
        $target.catalog.targetId|Should -BeExactly 'Forge@1.15'
        $target.catalog.forgeVersion|Should -BeExactly '1.15-29.0.4'
        $target.catalog.mcpConfig.coordinate|Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.15-20191212.203412@zip'
        $target.catalog.mcpConfig.mappingsSha256|Should -BeExactly '26919352a2dfe781c5f10d155824df88a5e5d9a66eae3993fb85d0ca8af0689d'
        $target.catalog.userdev.libraries|Should -HaveCount 20
        $target.catalog.mcpSnapshot.channel|Should -BeExactly 'snapshot'
        $target.catalog.mcpSnapshot.version|Should -BeExactly '20190719-1.14.3'
        $snapshot=@($target.artifacts|Where-Object kind -CEQ 'mcpSnapshot')
        $snapshot|Should -HaveCount 1
        $snapshot[0].bytes|Should -Be 366977
        $snapshot[0].sha256|Should -BeExactly 'eafd59009aa0c7f72a2f4a92a0d5d56b04a79460ad885948e4ddb4f509381142'
    }

    It 'validates the official Forge 1.16.1 target, runtime, and buildscript closures' {
        $schemaNames=@('forge-gradle3-target-inputs.schema.json','forge-gradle3-runtime-artifacts.schema.json','forge-gradle3-build-classpath.schema.json')
        foreach($schemaName in $schemaNames){$schema=Get-Content -LiteralPath (Join-Path $script:repoRoot "schemas/$schemaName") -Raw|ConvertFrom-Json;$schema.properties.targetId.enum|Should -Contain 'Forge@1.16.1' -Because $schemaName}
        $targetPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.16.1.json'
        $runtimePath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.16.1.json'
        $buildscriptPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.16.1-buildscript.json'
        (Test-Json -Json (Get-Content -LiteralPath $targetPath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'))|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $runtimePath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'))|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $buildscriptPath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'))|Should -BeTrue
        $target=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $targetPath
        $runtime=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $runtimePath
        $buildscript=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $buildscriptPath
        $target.catalog.forgeVersion|Should -BeExactly '1.16.1-32.0.108'
        $target.catalog.userdev.libraries|Should -HaveCount 23
        $target.catalog.userdev.processors|Should -Contain 'net.minecraftforge:binarypatcher:1.0.12:fatjar'
        $runtime.catalogHash|Should -BeExactly '350db0585949da4b97097a0a68f014e4a7ab3bd9f2bdac077bb9ab387a3bccc6'
        $runtime.components|Should -HaveCount 30
        $runtime.artifacts|Should -HaveCount 63
        $runtime.catalog.supportArtifacts|Should -HaveCount 12
        $runtime.catalog.mojangArtifacts|Should -HaveCount 65
        $runtime.catalog.componentSelections|Should -HaveCount 4
        $typetools=@($runtime.artifacts|Where-Object group -CEQ 'net.jodah')
        $typetools|Should -HaveCount 2
        foreach($artifact in $typetools){([Uri][string]$artifact.url).Host|Should -BeExactly 'maven.minecraftforge.net'}
        $modLauncherMetadata=@($runtime.catalog.dynamicMetadata|Where-Object { $_.group -CEQ 'cpw.mods' -and $_.artifact -CEQ 'modlauncher' })
        $modLauncherMetadata|Should -HaveCount 1
        $modLauncherMetadata[0].requiredSelectors|Should -Contain '5.1.+'
        @($modLauncherMetadata[0].resolutions|Where-Object selector -CEQ '5.1.+')[0].version|Should -BeExactly '6.1.3'
        $buildscript.catalog.dependencies|Should -HaveCount 12
        $buildscript.artifacts|Should -HaveCount 193
    }

    It 'validates Forge 1.16.2 dynamic resolution and exact official artifact closure' {
        $schemaNames=@('forge-gradle3-target-inputs.schema.json','forge-gradle3-runtime-artifacts.schema.json','forge-gradle3-build-classpath.schema.json')
        foreach($schemaName in $schemaNames){$schema=Get-Content -LiteralPath (Join-Path $script:repoRoot "schemas/$schemaName") -Raw|ConvertFrom-Json;$schema.properties.targetId.enum|Should -Contain 'Forge@1.16.2' -Because $schemaName}
        $targetPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.16.2.json'
        $runtimePath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.16.2.json'
        $buildscriptPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.16.2-buildscript.json'
        (Test-Json -Json (Get-Content -LiteralPath $targetPath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'))|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $runtimePath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'))|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $buildscriptPath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'))|Should -BeTrue
        $target=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $targetPath
        $runtime=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $runtimePath
        $buildscript=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $buildscriptPath
        $target.catalog.forgeVersion|Should -BeExactly '1.16.2-33.0.61'
        $target.catalog.mcpConfig.coordinate|Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.16.2-20200812.004259@zip'
        $target.catalog.userdev.libraries|Should -HaveCount 23
        $target.catalog.mojangVersion.sha256|Should -BeExactly 'f696986f4c07cd12dede183c86266d5cd34def6846eb0f014e1a84c2a76688d4'
        $runtime.catalogHash|Should -BeExactly '998437205defd36c14ae0c040734353ac3da11868bbe6bda5a4203ebdf5cf118'
        $runtime.components|Should -HaveCount 30
        $runtime.artifacts|Should -HaveCount 63
        $runtime.catalog.supportArtifacts|Should -HaveCount 12
        $runtime.catalog.mojangArtifacts|Should -HaveCount 65
        $runtime.catalog.componentSelections|Should -HaveCount 4
        $modLauncher=@($runtime.catalog.dynamicMetadata|Where-Object { $_.group -CEQ 'cpw.mods' -and $_.artifact -CEQ 'modlauncher' })
        $modLauncher[0].requiredSelectors|Should -Contain '5.1.+'
        $modLauncher[0].requiredSelectors|Should -Contain '6.1.+'
        @($modLauncher[0].resolutions|Where-Object selector -CEQ '5.1.+')[0].version|Should -BeExactly '7.0.1'
        $buildscript.catalog.dependencies|Should -HaveCount 12
        $buildscript.artifacts|Should -HaveCount 193
    }

    It 'validates Forge 1.16.3 ModLauncher 8 and ForgeSPI 3.2 exact official closures' {
        $schemaNames=@('forge-gradle3-target-inputs.schema.json','forge-gradle3-runtime-artifacts.schema.json','forge-gradle3-build-classpath.schema.json')
        foreach($schemaName in $schemaNames){$schema=Get-Content -LiteralPath (Join-Path $script:repoRoot "schemas/$schemaName") -Raw|ConvertFrom-Json;$schema.properties.targetId.enum|Should -Contain 'Forge@1.16.3' -Because $schemaName}
        $targetPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.16.3.json'
        $runtimePath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.16.3.json'
        $buildscriptPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.16.3-buildscript.json'
        (Test-Json -Json (Get-Content -LiteralPath $targetPath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'))|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $runtimePath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'))|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $buildscriptPath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'))|Should -BeTrue
        $target=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $targetPath
        $runtime=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $runtimePath
        $buildscript=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $buildscriptPath
        $target.catalog.forgeVersion|Should -BeExactly '1.16.3-34.1.42'
        $target.catalog.mcpConfig.coordinate|Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.16.3-20201025.185957@zip'
        $target.catalog.userdev.libraries|Should -HaveCount 23
        $target.catalog.mojangVersion.sha256|Should -BeExactly '193c5226095ce9e8a317f1e35ddbe4d976f176f6df7ac649ecfa669e17160ead'
        $runtime.catalogHash|Should -BeExactly '143108a0d7a1099c3c1383af0012c862da17fa23023109554cf75b2686ac2120'
        $runtime.components|Should -HaveCount 30
        $runtime.artifacts|Should -HaveCount 63
        $runtime.catalog.supportArtifacts|Should -HaveCount 12
        $runtime.catalog.mojangArtifacts|Should -HaveCount 65
        $runtime.catalog.componentSelections|Should -HaveCount 5
        $modLauncher=@($runtime.catalog.dynamicMetadata|Where-Object { $_.group -CEQ 'cpw.mods' -and $_.artifact -CEQ 'modlauncher' })
        $modLauncher[0].requiredSelectors|Should -Contain '5.1.+'
        $modLauncher[0].requiredSelectors|Should -Contain '6.1.+'
        @($modLauncher[0].resolutions|Where-Object selector -CEQ '5.1.+')[0].version|Should -BeExactly '8.0.6'
        $forgeSpi=@($runtime.catalog.dynamicMetadata|Where-Object { $_.group -CEQ 'net.minecraftforge' -and $_.artifact -CEQ 'forgespi' })
        @($forgeSpi[0].resolutions|Where-Object selector -CEQ '3.1.+')[0].version|Should -BeExactly '3.2.0'
        $buildscript.catalog.dependencies|Should -HaveCount 12
        $buildscript.artifacts|Should -HaveCount 193
    }

    It 'validates Forge 1.16.4 ModLauncher 8.0.9 and ForgeSPI 3.2 exact official closures' {
        $schemaNames=@('forge-gradle3-target-inputs.schema.json','forge-gradle3-runtime-artifacts.schema.json','forge-gradle3-build-classpath.schema.json')
        foreach($schemaName in $schemaNames){$schema=Get-Content -LiteralPath (Join-Path $script:repoRoot "schemas/$schemaName") -Raw|ConvertFrom-Json;$schema.properties.targetId.enum|Should -Contain 'Forge@1.16.4' -Because $schemaName}
        $targetPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.16.4.json'
        $runtimePath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.16.4.json'
        $buildscriptPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.16.4-buildscript.json'
        (Test-Json -Json (Get-Content -LiteralPath $targetPath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'))|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $runtimePath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'))|Should -BeTrue
        (Test-Json -Json (Get-Content -LiteralPath $buildscriptPath -Raw) -SchemaFile (Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'))|Should -BeTrue
        $target=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $targetPath
        $runtime=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $runtimePath
        $buildscript=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $buildscriptPath
        $target.catalog.forgeVersion|Should -BeExactly '1.16.4-35.1.37'
        $target.catalog.mcpConfig.coordinate|Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.16.4-20201102.104115@zip'
        $target.catalog.userdev.libraries|Should -HaveCount 25
        $target.catalog.mojangVersion.sha256|Should -BeExactly '667fff4ca7fd0f56ab78b757224515e8e64375868e8d1ce6040091d7b63a0cb5'
        $runtime.catalogHash|Should -BeExactly '4300bc9c8ab6d3e44536483225fba6d878d01f0f2d88f0115c694b39fef6f1fd'
        $runtime.components|Should -HaveCount 31
        $runtime.artifacts|Should -HaveCount 65
        $runtime.catalog.supportArtifacts|Should -HaveCount 12
        $runtime.catalog.mojangArtifacts|Should -HaveCount 65
        $runtime.catalog.componentSelections|Should -HaveCount 5
        $modLauncher=@($runtime.catalog.dynamicMetadata|Where-Object { $_.group -CEQ 'cpw.mods' -and $_.artifact -CEQ 'modlauncher' })
        $modLauncher[0].requiredSelectors|Should -Contain '5.1.+'
        $modLauncher[0].requiredSelectors|Should -Contain '6.1.+'
        @($modLauncher[0].resolutions|Where-Object selector -CEQ '5.1.+')[0].version|Should -BeExactly '8.0.9'
        $forgeSpi=@($runtime.catalog.dynamicMetadata|Where-Object { $_.group -CEQ 'net.minecraftforge' -and $_.artifact -CEQ 'forgespi' })
        @($forgeSpi[0].resolutions|Where-Object selector -CEQ '3.1.+')[0].version|Should -BeExactly '3.2.0'
        $buildscript.catalog.dependencies|Should -HaveCount 12
        $buildscript.artifacts|Should -HaveCount 193
    }

    It 'validates Forge 1.13.2 userdev and MCP inputs without assuming the 1.12.2 userdev3 layout' {
        $artifacts=@(
            [ordered]@{kind='userdev';group='net.minecraftforge';artifact='forge';version='1.13.2-25.0.223';file='forge-1.13.2-25.0.223-userdev.jar';bytes=100;sha256=('a'*64);url='https://maven.minecraftforge.net/net/minecraftforge/forge/1.13.2-25.0.223/forge-1.13.2-25.0.223-userdev.jar'},
            [ordered]@{kind='mcpConfig';group='de.oceanlabs.mcp';artifact='mcp_config';version='1.13.2-20190213.203750';file='mcp_config-1.13.2-20190213.203750.zip';bytes=101;sha256=('b'*64);url='https://maven.minecraftforge.net/de/oceanlabs/mcp/mcp_config/1.13.2-20190213.203750/mcp_config-1.13.2-20190213.203750.zip'},
            [ordered]@{kind='forgeSources';group='net.minecraftforge';artifact='forge';version='1.13.2-25.0.223';file='forge-1.13.2-25.0.223-sources.jar';bytes=102;sha256=('c'*64);url='https://maven.minecraftforge.net/net/minecraftforge/forge/1.13.2-25.0.223/forge-1.13.2-25.0.223-sources.jar'},
            [ordered]@{kind='forgeUniversal';group='net.minecraftforge';artifact='forge';version='1.13.2-25.0.223';file='forge-1.13.2-25.0.223-universal.jar';bytes=103;sha256=('d'*64);url='https://maven.minecraftforge.net/net/minecraftforge/forge/1.13.2-25.0.223/forge-1.13.2-25.0.223-universal.jar'},
            [ordered]@{kind='launcher';group='net.minecraftforge';artifact='forge';version='1.13.2-25.0.223';file='forge-1.13.2-25.0.223-launcher.jar';bytes=104;sha256=('e'*64);url='https://maven.minecraftforge.net/net/minecraftforge/forge/1.13.2-25.0.223/forge-1.13.2-25.0.223-launcher.jar'},
            [ordered]@{kind='binarypatcher';group='net.minecraftforge';artifact='binarypatcher';version='1.1.1';file='binarypatcher-1.1.1-fatjar.jar';bytes=105;sha256=('f'*64);url='https://maven.minecraftforge.net/net/minecraftforge/binarypatcher/1.1.1/binarypatcher-1.1.1-fatjar.jar'}
        )
        $catalog=[ordered]@{
            schemaVersion=1;targetId='Forge@1.13.2';forgeVersion='1.13.2-25.0.223';resolver='ForgeGradle 3.0.197 target inputs captured from the official MDK build';artifactStatus='HashesVerified';artifacts=$artifacts
            mcpConfig=[ordered]@{coordinate='de.oceanlabs.mcp:mcp_config:1.13.2-20190213.203750@zip';configEntry='config.json';configBytes=1000;configSha256=('c'*64);mappingsEntry='config/joined.tsrg';mappingsBytes=1429394;mappingsSha256='ec7e91e860a6e1ad6b7337cfc517f469afbf3deb109dec483267a86be7fc07d0'}
            userdev=[ordered]@{configEntry='config.json';configBytes=2595;configSha256=('a'*64);mcpCoordinate='de.oceanlabs.mcp:mcp_config:1.13.2-20190213.203750@zip';libraries=@('cpw.mods:modlauncher:2.1.5');processors=@('net.minecraftforge:binarypatcher:1.1.1:fatjar')}
            mojangVersion=[ordered]@{url='https://piston-meta.mojang.com/v1/packages/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.13.2.json';sha1=('a'*40);bytes=22583;sha256='26ddcd28289a44d4ae4179307b7193ce0227d2da57350e717ff1d8c6e27e8c95'}
        }
        $catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $catalog -Depth 30 -Compress)))).ToLowerInvariant()
        $catalog.catalogHash=$catalogHash
        $path=Join-Path $TestDrive 'forge-gradle3-target-inputs-1.13.2.json'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $catalog -Depth 30),[Text.UTF8Encoding]::new($false))
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'

        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path

        $resolved.catalogHash | Should -BeExactly $catalogHash
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.13.2'
        $resolved.artifacts | Should -HaveCount 6
        $resolved.catalog.userdev.processors | Should -Contain 'net.minecraftforge:binarypatcher:1.1.1:fatjar'
    }

    It 'validates the separately pinned ForgeGradle 3 userdev3, MCP, Forge processor, and Mojang inputs' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.12.2.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path
        $resolved.catalogHash | Should -BeExactly 'c3c8db56014f86e2ef1bc06fba648ee09a88641b76c3f558f44a8bafc72113b3'
        $resolved.artifacts | Should -HaveCount 6
        $resolved.catalog.userdev3.libraries | Should -HaveCount 22
        $resolved.catalog.userdev3.processors | Should -HaveCount 2
    }

    It 'validates the official Forge 1.13.2 target-input catalog and its captured userdev closure' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.13.2.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path

        $resolved.catalogHash | Should -BeExactly '8fb514df77b900d16f329c4669ccb5f6453e3d39a2ddb652684a3f48d461aeb8'
        $resolved.catalog.forgeVersion | Should -BeExactly '1.13.2-25.0.223'
        $resolved.artifacts | Should -HaveCount 6
        $resolved.catalog.mcpConfig.coordinate | Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.13.2-20190213.203750@zip'
        $resolved.catalog.userdev.libraries | Should -HaveCount 23
        $resolved.catalog.userdev.libraries | Should -Contain 'cpw.mods:modlauncher:2.1.5'
        $resolved.catalog.userdev.processors | Should -Contain 'net.minecraftforge:binarypatcher:1.1.1:fatjar'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly '26ddcd28289a44d4ae4179307b7193ce0227d2da57350e717ff1d8c6e27e8c95'
    }

    It 'validates Forge 1.14.2 target inputs captured from the official MDK build' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.14.2.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'

        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path

        $resolved.catalog.forgeVersion | Should -BeExactly '1.14.2-26.0.63'
        $resolved.artifacts | Should -HaveCount 6
        $resolved.catalog.mcpConfig.coordinate | Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.14.2-20190603.175704@zip'
        $resolved.catalog.userdev.libraries | Should -HaveCount 21
        $resolved.catalog.userdev.libraries | Should -Contain 'cpw.mods:modlauncher:2.1.4'
        $resolved.catalog.userdev.processors | Should -Contain 'net.minecraftforge:binarypatcher:1.0.5:fatjar'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly '237aa8d499b71bb17122cbee40b8748efcd5ac9d8362c68c89e99ab0703e66b8'
    }

    It 'validates Forge 1.14.3 target inputs captured from the official MDK build' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.14.3.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path
        $resolved.catalog.forgeVersion | Should -BeExactly '1.14.3-27.0.60'
        $resolved.artifacts | Should -HaveCount 6
        $resolved.catalog.mcpConfig.coordinate | Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.14.3-20190624.152911@zip'
        $resolved.catalog.mcpConfig.mappingsBytes | Should -Be 1699455
        $resolved.catalog.userdev.libraries | Should -HaveCount 21
        $resolved.catalog.userdev.libraries | Should -Contain 'cpw.mods:modlauncher:3.0.2'
        $resolved.catalog.userdev.libraries | Should -Contain 'net.minecraftforge:eventbus:0.10.3-milestone.0.1+1a5fa31:service'
        $resolved.catalog.userdev.processors | Should -Contain 'net.minecraftforge:binarypatcher:1.0.5:fatjar'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly 'ebf2df95d9bd83c6687f287d5a6f5f41f74bc1b39159fcbb74ff6d1d19d8464c'
    }

    It 'validates Forge 1.14.4 target inputs and the target-specific userdev configuration' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.14.4.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.14.4'
        $resolved.catalog.forgeVersion | Should -BeExactly '1.14.4-28.2.26'
        $resolved.artifacts | Should -HaveCount 6
        $resolved.catalog.mcpConfig.coordinate | Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.14.4-20190829.143755@zip'
        $resolved.catalog.mcpConfig.configBytes | Should -Be 6436
        $resolved.catalog.mcpConfig.mappingsBytes | Should -Be 1786864
        $resolved.catalog.userdev.libraries | Should -HaveCount 22
        $resolved.catalog.userdev.libraries | Should -Contain 'cpw.mods:modlauncher:4.1.0'
        $resolved.catalog.userdev.processors | Should -Contain 'net.minecraftforge:binarypatcher:1.0.12:fatjar'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly '615f466a39d2c19ae9b6e2401aa7bd07dbda337f976bcce383326b8d6ba4e532'
    }

    It 'validates Forge 1.15.2 target inputs and its MCP and userdev configuration' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.15.2.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-target-inputs.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path

        $resolved.catalog.forgeVersion | Should -BeExactly '1.15.2-31.2.57'
        $resolved.artifacts | Should -HaveCount 6
        $resolved.catalog.mcpConfig.coordinate | Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.15.2-20200515.085601@zip'
        $resolved.catalog.userdev.libraries | Should -HaveCount 24
        $resolved.catalog.userdev.libraries | Should -Contain 'cpw.mods:modlauncher:5.1.2'
        $resolved.catalog.userdev.processors | Should -Contain 'net.minecraftforge:binarypatcher:1.0.12:fatjar'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly 'e974511243e845b2427ab635eba5612481cb420a70c0630aa041eab3eeb590c5'
    }

    It 'rejects a ForgeGradle 3 target input pin modified without updating its catalog digest' {
        $source=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-target-inputs/Forge-1.12.2.json'
        $catalog=Get-Content -LiteralPath $source -Raw|ConvertFrom-Json
        $catalog.artifacts[0].sha256='0'*64
        $path=Join-Path $TestDrive 'tampered-forge-gradle3-target-inputs.json'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $catalog -Depth 30),[Text.UTF8Encoding]::new($false))
        { Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $path } | Should -Throw '*FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH*'
    }

    It 'validates the captured ForgeGradle 3.0.197 dependency closure and both dynamic pins' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.2-buildscript.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'

        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $path

        $resolved.catalogHash | Should -BeExactly 'd88535879e24afbde6e8df53c2ad2925250fe0b5a34bd3235d13eb6344e74bb8'
        $resolved.dependencies | Should -HaveCount 13
        $resolved.artifacts | Should -HaveCount 195
        $resolved.dynamicVersionResolutions | Should -HaveCount 2
    }

    It 'validates the ForgeGradle 3.0.197 closure for Forge 1.13.2 without the 1.12.2 userdev legacydev dependency' {
        $source=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.2-buildscript.json'
        $catalog=Get-Content -LiteralPath $source -Raw|ConvertFrom-Json
        $catalog.targetId='Forge@1.13.2'
        $catalog.resolver='ForgeGradle 3.0.197 buildscript closure'
        $catalog.dependencies=@($catalog.dependencies|Where-Object artifact -CNE 'legacydev')
        $catalog.artifacts=@($catalog.artifacts|Where-Object artifact -CNE 'legacydev')
        $catalog.dynamicVersionResolutions=@($catalog.dynamicVersionResolutions|Where-Object artifact -CEQ 'artifactural')
        $core=[ordered]@{}
        foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
        $path=Join-Path $TestDrive 'forge-1.13.2-buildscript.json'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $catalog -Depth 30),[Text.UTF8Encoding]::new($false))
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'

        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.13.2'
        $resolved.dependencies | Should -HaveCount 12
        $resolved.artifacts | Should -HaveCount 193
        $resolved.dynamicVersionResolutions | Should -HaveCount 1
        @($resolved.dependencies|Where-Object artifact -CEQ 'legacydev') | Should -HaveCount 0
    }

    It 'validates the Forge 1.13.2 buildscript closure captured by the official MDK research build' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.13.2-buildscript.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path

        $resolved.catalogHash | Should -BeExactly '59815582bc005c13d7e5c2f669ee776a439b9ab2d7b3854e1b60af8e00bbba88'
        $resolved.dependencies | Should -HaveCount 12
        $resolved.artifacts | Should -HaveCount 193
        $resolved.dynamicVersionResolutions | Should -HaveCount 1
        @($resolved.dependencies|Where-Object artifact -CEQ 'legacydev') | Should -HaveCount 0
        $resolved.catalog.rootCoordinate | Should -BeExactly 'net.minecraftforge.gradle:ForgeGradle:3.0.197'
    }

    It 'validates the shared ForgeGradle 3.0.197 buildscript closure for Forge 1.14.2' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.14.2-buildscript.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.14.2'
        $resolved.catalogHash | Should -BeExactly '41ba3af30d803e449865c9e74ba2cca5a0b349bf482c849a5521df4f7d3270e0'
        $resolved.dependencies | Should -HaveCount 12
        $resolved.artifacts | Should -HaveCount 193
        $resolved.dynamicVersionResolutions | Should -HaveCount 1
        @($resolved.dependencies|Where-Object artifact -CEQ 'legacydev') | Should -HaveCount 0
    }

    It 'validates the Forge 1.14.3 buildscript closure against its official MDK resolution' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.14.3-buildscript.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.14.3'
        $resolved.dependencies | Should -HaveCount 12
        $resolved.artifacts | Should -HaveCount 193
        $resolved.dynamicVersionResolutions | Should -HaveCount 1
        @($resolved.dependencies|Where-Object artifact -CEQ 'legacydev') | Should -HaveCount 0
        @($resolved.dependencies|Where-Object artifact -CEQ 'artifactural').version | Should -Contain '1.0.13'
    }

    It 'validates the Forge 1.14.4 buildscript closure against its official MDK resolution' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.14.4-buildscript.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.14.4'
        $resolved.dependencies | Should -HaveCount 12
        $resolved.artifacts | Should -HaveCount 193
        $resolved.dynamicVersionResolutions | Should -HaveCount 1
        @($resolved.dependencies|Where-Object artifact -CEQ 'legacydev') | Should -HaveCount 0
        @($resolved.dependencies|Where-Object artifact -CEQ 'artifactural').version | Should -Contain '1.0.13'
    }

    It 'validates the Forge 1.15.2 buildscript closure against its official MDK resolution' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.15.2-buildscript.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.15.2'
        $resolved.dependencies | Should -HaveCount 12
        $resolved.artifacts | Should -HaveCount 193
        $resolved.dynamicVersionResolutions | Should -HaveCount 1
        @($resolved.dependencies|Where-Object artifact -CEQ 'legacydev') | Should -HaveCount 0
        @($resolved.dependencies|Where-Object artifact -CEQ 'artifactural').version | Should -Contain '1.0.13'
    }

    It 'validates the Forge 1.15.1 buildscript closure against its official Gradle 4.9 MDK resolution' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.15.1-buildscript.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.15.1'
        $resolved.dependencies | Should -HaveCount 12
        $resolved.artifacts | Should -HaveCount 193
        $resolved.dynamicVersionResolutions | Should -HaveCount 1
        @($resolved.dependencies|Where-Object artifact -CEQ 'legacydev') | Should -HaveCount 0
        @($resolved.dependencies|Where-Object artifact -CEQ 'artifactural').version | Should -Contain '1.0.13'
    }

    It 'accepts the Forge 1.15 target when bound to the exact ForgeGradle 3.0.197 buildscript closure' {
        $source=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.15.1-buildscript.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-build-classpath.schema.json'
        $catalog=Get-Content -LiteralPath $source -Raw|ConvertFrom-Json
        $catalog.targetId='Forge@1.15'
        $catalog.catalogHash=''
        $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
        $path=Join-Path $TestDrive 'Forge-1.15-buildscript.json'
        ConvertTo-Json -InputObject $catalog -Depth 30|Set-Content -LiteralPath $path -Encoding utf8

        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema)|Should -BeTrue
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path
        $resolved.catalog.targetId|Should -BeExactly 'Forge@1.15'
        $resolved.catalog.rootCoordinate|Should -BeExactly 'net.minecraftforge.gradle:ForgeGradle:3.0.197'
        $resolved.dependencies|Should -HaveCount 12
        $resolved.artifacts|Should -HaveCount 193
        $resolved.dynamicVersionResolutions|Should -HaveCount 1
        @($resolved.dependencies|Where-Object artifact -CEQ 'legacydev')|Should -HaveCount 0
        @($resolved.dependencies|Where-Object artifact -CEQ 'artifactural').version|Should -Contain '1.0.13'
    }

    It 'emits only the artifactural dynamic-version metadata required by Forge 1.13.2' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.13.2-buildscript.json'
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path
        $repository=Join-Path $TestDrive 'forge-1132-dynamic-metadata'

        $metadataPaths=@(New-MmtlForgeClasspathDynamicVersionMetadata -ClasspathCatalog $resolved -RepositoryRoot $repository)

        $metadataPaths | Should -HaveCount 1
        $metadataPaths[0] | Should -BeExactly (Join-Path $repository 'net/minecraftforge/artifactural/maven-metadata.xml')
        Test-Path (Join-Path $repository 'net/minecraftforge/legacydev/maven-metadata.xml') | Should -BeFalse
        Get-Content -LiteralPath $metadataPaths[0] -Raw | Should -Match '<version>1\.0\.13</version>'
    }

    It 'emits only the artifactural dynamic-version metadata required by Forge 1.14.4' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.14.4-buildscript.json'
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path
        $repository=Join-Path $TestDrive 'forge-1144-dynamic-metadata'

        $metadataPaths=@(New-MmtlForgeClasspathDynamicVersionMetadata -ClasspathCatalog $resolved -RepositoryRoot $repository)

        $metadataPaths | Should -HaveCount 1
        $metadataPaths[0] | Should -BeExactly (Join-Path $repository 'net/minecraftforge/artifactural/maven-metadata.xml')
        Get-Content -LiteralPath $metadataPaths[0] -Raw | Should -Match '<version>1\.0\.13</version>'
    }

    It 'emits the exact artifactural dynamic-version metadata required by Forge 1.15.2' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.15.2-buildscript.json'
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path
        $repository=Join-Path $TestDrive 'forge-1152-dynamic-metadata'

        $metadataPaths=@(New-MmtlForgeClasspathDynamicVersionMetadata -ClasspathCatalog $resolved -RepositoryRoot $repository)

        $metadataPaths | Should -HaveCount 1
        $metadataPaths[0] | Should -BeExactly (Join-Path $repository 'net/minecraftforge/artifactural/maven-metadata.xml')
        Get-Content -LiteralPath $metadataPaths[0] -Raw | Should -Match '<version>1\.0\.13</version>'
    }

    It 'emits the exact artifactural dynamic-version metadata required by Forge 1.15' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.15-buildscript.json'
        $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $path
        $repository=Join-Path $TestDrive 'forge-115-dynamic-metadata'

        $metadataPaths=@(New-MmtlForgeClasspathDynamicVersionMetadata -ClasspathCatalog $resolved -RepositoryRoot $repository)

        $metadataPaths | Should -HaveCount 1
        $metadataPaths[0] | Should -BeExactly (Join-Path $repository 'net/minecraftforge/artifactural/maven-metadata.xml')
        Test-Path (Join-Path $repository 'net/minecraftforge/legacydev/maven-metadata.xml') | Should -BeFalse
        Get-Content -LiteralPath $metadataPaths[0] -Raw | Should -Match '<version>1\.0\.13</version>'
    }

    It 'validates the official Forge 1.13.2 userdev runtime artifact and POM closure' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.13.2.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $path

        $resolved.catalogHash | Should -BeExactly '170fde03fc76a05a6ecf383a16dcd9734f845ccb60bf5160c48ce9d11c21857c'
        $resolved.artifacts | Should -HaveCount 71
        @($resolved.artifacts|Where-Object extension -eq 'jar') | Should -HaveCount 36
        @($resolved.artifacts|Where-Object extension -eq 'pom') | Should -HaveCount 35
        $resolved.catalog.supportArtifacts | Should -HaveCount 16
        $resolved.catalog.dynamicMetadata | Should -HaveCount 5
        $resolved.catalog.mojangArtifacts | Should -HaveCount 58
        @($resolved.catalog.mojangArtifacts|Where-Object file -match 'natives-(windows|linux|macos|osx)') | Should -HaveCount 21
        $resolved.components | Should -HaveCount 35
        $resolved.catalog.userdevLibraries | Should -HaveCount 23
        @($resolved.dynamicVersionResolutions|Where-Object group -eq 'cpw.mods'|Where-Object artifact -eq 'modlauncher') | Should -HaveCount 3
        @($resolved.dynamicVersionResolutions|Where-Object selector -eq '0.10.+').version | Should -Contain '0.10.0'
        $resolved.artifacts.url | Should -Contain 'https://libraries.minecraft.net/java3d/vecmath/1.5.2/vecmath-1.5.2.jar'
        @($resolved.artifacts|Where-Object url -eq 'https://maven.minecraftforge.net/net/java/dev/jna/jna/4.2.2/jna-4.2.2.jar') | Should -HaveCount 1
    }

    It 'validates the official Forge 1.14.2 userdev runtime artifact and POM closure' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.14.2.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $path

        $resolved.catalogHash | Should -BeExactly '1645cec636c4983bb57483895f594c6e2ab067ad1ee0764ae68091e601cda328'
        $resolved.artifacts | Should -HaveCount 77
        @($resolved.artifacts|Where-Object extension -eq 'jar') | Should -HaveCount 40
        @($resolved.artifacts|Where-Object extension -eq 'pom') | Should -HaveCount 37
        $resolved.catalog.supportArtifacts | Should -HaveCount 18
        $resolved.catalog.dynamicMetadata | Should -HaveCount 5
        $resolved.catalog.mojangArtifacts | Should -HaveCount 55
        @($resolved.catalog.mojangArtifacts|Where-Object file -match 'natives-(windows|linux|macos|osx)') | Should -HaveCount 21
        $resolved.components | Should -HaveCount 37
        $resolved.catalog.userdevLibraries | Should -HaveCount 21
        @($resolved.dynamicVersionResolutions|Where-Object group -eq 'cpw.mods'|Where-Object artifact -eq 'modlauncher') | Should -HaveCount 3
        @($resolved.dynamicVersionResolutions|Where-Object group -eq 'cpw.mods'|Where-Object artifact -eq 'modlauncher').version | Should -Contain '2.1.4'
        @($resolved.dynamicVersionResolutions|Where-Object group -eq 'org.apache.logging.log4j').version | Should -Contain '2.11.2'
        $resolved.artifacts.url | Should -Contain 'https://libraries.minecraft.net/java3d/vecmath/1.5.2/vecmath-1.5.2.jar'
        @($resolved.artifacts|Where-Object url -eq 'https://repo.maven.apache.org/maven2/net/java/jinput/jinput-platform/2.0.5/jinput-platform-2.0.5-natives-windows.jar') | Should -HaveCount 1
    }

    It 'validates the Forge 1.14.3 runtime closure against its resolved userdev and Mojang inputs' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.14.3.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $path
        $resolved.catalog.userdevLibraries | Should -HaveCount 21
        $resolved.components | Should -HaveCount 37
        $resolved.artifacts | Should -HaveCount 77
        @($resolved.artifacts|Where-Object extension -eq 'jar') | Should -HaveCount 40
        @($resolved.artifacts|Where-Object extension -eq 'pom') | Should -HaveCount 37
        $resolved.catalog.supportArtifacts | Should -HaveCount 18
        $resolved.catalog.dynamicMetadata | Should -HaveCount 5
        $resolved.catalog.mojangArtifacts | Should -HaveCount 55
        $resolved.catalog.mojangVersionSha256 | Should -BeExactly 'ebf2df95d9bd83c6687f287d5a6f5f41f74bc1b39159fcbb74ff6d1d19d8464c'
        @($resolved.dynamicVersionResolutions|Where-Object artifact -CEQ 'modlauncher'|Where-Object version -CEQ '2.1.4') | Should -HaveCount 3
        $resolved.catalog.userdevLibraries | Should -Contain 'cpw.mods:modlauncher:3.0.2'
        @($resolved.catalog.mojangArtifacts|Where-Object file -match 'natives-(windows|linux|macos|osx)') | Should -HaveCount 21
    }

    It 'validates the Forge 1.14.4 runtime closure against its resolved userdev and Mojang inputs' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.14.4.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $path

        $resolved.catalog.userdevLibraries | Should -HaveCount 22
        $resolved.components | Should -HaveCount 33
        $resolved.artifacts | Should -HaveCount 69
        @($resolved.artifacts|Where-Object extension -CEQ 'jar') | Should -HaveCount 36
        @($resolved.artifacts|Where-Object extension -CEQ 'pom') | Should -HaveCount 33
        $resolved.catalog.supportArtifacts | Should -HaveCount 16
        $resolved.catalog.dynamicMetadata | Should -HaveCount 5
        $resolved.catalog.mojangArtifacts | Should -HaveCount 60
        $resolved.catalog.mojangVersionSha256 | Should -BeExactly '615f466a39d2c19ae9b6e2401aa7bd07dbda337f976bcce383326b8d6ba4e532'
        @($resolved.dynamicVersionResolutions|Where-Object artifact -CEQ 'modlauncher'|Where-Object version -CEQ '4.1.0') | Should -HaveCount 1
        @($resolved.dynamicVersionResolutions|Where-Object artifact -CEQ 'forgespi'|Where-Object version -CEQ '1.5.0') | Should -HaveCount 1
        @($resolved.dynamicVersionResolutions|Where-Object group -CEQ 'org.apache.logging.log4j'|Where-Object version -CEQ '2.15.0') | Should -HaveCount 2
        $resolved.catalog.userdevLibraries | Should -Contain 'cpw.mods:modlauncher:4.1.0'
        @($resolved.catalog.mojangArtifacts|Where-Object file -match 'natives-(windows|linux|macos|osx)') | Should -HaveCount 21
    }

    It 'validates the Forge 1.15.2 runtime closure and records the selected Maven Artifact conflict' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.15.2.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $path

        $resolved.catalog.userdevLibraries | Should -HaveCount 24
        $resolved.catalogHash | Should -BeExactly 'e427b92a8955d008f3f0af86c185e7d0f3379fa3dd73cf4d3c358dbdb1dbbe4f'
        $resolved.catalog.userdevLibraries | Should -Contain 'org.apache.maven:maven-artifact:3.6.0'
        $resolved.components | Should -Contain 'org.apache.maven:maven-artifact:3.6.3'
        $resolved.components | Should -Contain 'net.minecraftforge:mergetool:1.0.9'
        $resolved.components | Should -Contain 'net.java.jinput:jinput-platform:2.0.5'
        $resolved.components | Should -HaveCount 33
        $resolved.artifacts | Should -HaveCount 69
        @($resolved.artifacts|Where-Object extension -CEQ 'jar') | Should -HaveCount 36
        @($resolved.artifacts|Where-Object extension -CEQ 'pom') | Should -HaveCount 33
        @($resolved.catalog.artifacts|Where-Object { $_.group -CEQ 'net.minecraftforge' -and $_.artifact -CEQ 'mergetool' -and $_.version -CEQ '1.0.9' -and $_.file -CEQ 'mergetool-1.0.9-api.jar' }) | Should -HaveCount 1
        @($resolved.catalog.artifacts|Where-Object { $_.group -CEQ 'net.java.jinput' -and $_.artifact -CEQ 'jinput-platform' -and $_.version -CEQ '2.0.5' -and $_.extension -CEQ 'jar' }) | Should -HaveCount 3
        @($resolved.catalog.componentSelections|Where-Object requested -CEQ 'org.apache.maven:maven-artifact:3.6.0').selected | Should -BeExactly 'org.apache.maven:maven-artifact:3.6.3'
        @($resolved.catalog.componentSelections|Where-Object requested -CEQ 'org.apache.maven:maven-artifact:3.6.0').reason | Should -BeExactly 'between versions 3.6.0 and 3.6.3'
        @($resolved.catalog.artifacts|Where-Object { $_.group -CEQ 'org.apache.maven' -and $_.artifact -CEQ 'maven-artifact' -and $_.version -CEQ '3.6.0' }) | Should -BeNullOrEmpty
        $resolved.catalog.mojangArtifacts | Should -HaveCount 65
    }

    It 'validates the Forge 1.15.1 runtime closure against its official Gradle 4.9 capture' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.15.1.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $path

        $resolved.catalog.userdevLibraries | Should -HaveCount 20
        $resolved.catalog.userdevLibraries | Should -Contain 'cpw.mods:modlauncher:5.0.0-milestone.4'
        $resolved.components | Should -HaveCount 30
        $resolved.components | Should -Contain 'net.minecraftforge:mergetool:1.0.9'
        $resolved.artifacts | Should -HaveCount 63
        @($resolved.artifacts|Where-Object extension -CEQ 'jar') | Should -HaveCount 33
        @($resolved.artifacts|Where-Object extension -CEQ 'pom') | Should -HaveCount 30
        $resolved.catalog.supportArtifacts | Should -HaveCount 12
        $resolved.catalog.dynamicMetadata | Should -HaveCount 5
        $resolved.catalog.mojangArtifacts | Should -HaveCount 65
        $resolved.catalog.mojangVersionSha256 | Should -BeExactly 'dda0859bca7447ff5f071643006b35a51f54e2fbef851a6665b424cf5743c598'
        @($resolved.dynamicVersionResolutions|Where-Object artifact -CEQ 'modlauncher'|Where-Object version -CEQ '5.0.0-milestone.4') | Should -HaveCount 1
        @($resolved.dynamicVersionResolutions|Where-Object artifact -CEQ 'forgespi'|Where-Object version -CEQ '2.0.0-milestone.1') | Should -HaveCount 1
        @($resolved.dynamicVersionResolutions|Where-Object group -CEQ 'org.apache.logging.log4j'|Where-Object version -CEQ '2.12.1') | Should -HaveCount 4
        @($resolved.catalog.componentSelections|Where-Object requested -CEQ 'org.apache.maven:maven-artifact:3.6.0').selected | Should -BeExactly 'org.apache.maven:maven-artifact:3.6.3'
        @($resolved.catalog.componentSelections|Where-Object requested -CEQ 'org.apache.logging.log4j:log4j-api:2.11.2').selected | Should -BeExactly 'org.apache.logging.log4j:log4j-api:2.12.1'
        @($resolved.catalog.componentSelections|Where-Object requested -CEQ 'org.apache.logging.log4j:log4j-core:2.11.2').selected | Should -BeExactly 'org.apache.logging.log4j:log4j-core:2.12.1'
        $resolved.components | Should -Contain 'org.apache.logging.log4j:log4j-api:2.12.1'
        $resolved.components | Should -Contain 'org.apache.logging.log4j:log4j-core:2.12.1'
        @($resolved.catalog.mojangArtifacts|Where-Object file -match 'natives-(windows|linux|macos|osx)') | Should -HaveCount 24
    }

    It 'validates the Forge 1.15 runtime closure against its exact official target inputs' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle3-runtime-artifacts/Forge-1.15.json'
        $schema=Join-Path $script:repoRoot 'schemas/forge-gradle3-runtime-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $path -Raw) -SchemaFile $schema) | Should -BeTrue
        $resolved=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $path

        $resolved.catalog.userdevLibraries | Should -HaveCount 20
        $resolved.catalog.userdevLibraries | Should -Contain 'net.minecraftforge:forge:1.15-29.0.4:launcher'
        $resolved.components | Should -HaveCount 30
        $resolved.components | Should -Contain 'net.minecraftforge:forge:1.15-29.0.4'
        $resolved.components | Should -Contain 'net.minecraftforge:mergetool:1.0.9'
        $resolved.artifacts | Should -HaveCount 63
        @($resolved.artifacts|Where-Object extension -CEQ 'jar') | Should -HaveCount 33
        @($resolved.artifacts|Where-Object extension -CEQ 'pom') | Should -HaveCount 30
        $resolved.catalog.supportArtifacts | Should -HaveCount 12
        $resolved.catalog.dynamicMetadata | Should -HaveCount 5
        $resolved.catalog.mojangArtifacts | Should -HaveCount 65
        $resolved.catalog.mojangVersionSha256 | Should -BeExactly 'd154eaf07885a7fd6dfc6014bb9caf08fecc19ccd9a0862b31b1c7d1639e7785'
        @($resolved.catalog.componentSelections|Where-Object requested -CEQ 'org.apache.maven:maven-artifact:3.6.0').selected | Should -BeExactly 'org.apache.maven:maven-artifact:3.6.3'
        @($resolved.catalog.componentSelections|Where-Object requested -CEQ 'org.apache.logging.log4j:log4j-api:2.11.2').selected | Should -BeExactly 'org.apache.logging.log4j:log4j-api:2.12.1'
        @($resolved.catalog.componentSelections|Where-Object requested -CEQ 'org.apache.logging.log4j:log4j-core:2.11.2').selected | Should -BeExactly 'org.apache.logging.log4j:log4j-core:2.12.1'
        $resolved.components | Should -Not -Contain 'net.minecraftforge:forge:1.15.1-30.0.51'
    }

    It 'accepts Maven Central path prefixes and Mojang native classifier filenames in the ForgeGradle 3 catalog' {
        $path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.2-buildscript.json'
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $path

        @($resolved.artifacts | Where-Object { $_.url -match '^https://repo\.maven\.apache\.org/maven2/' }).Count | Should -BeGreaterThan 0
        @($resolved.artifacts | Where-Object { $_.file -match '-natives-(windows|linux|osx)(-\d+)?\.jar$' }).Count | Should -Be 5
    }

    It 'rejects a ForgeGradle 3 classpath catalog when an artifact pin changes without updating its digest' {
        $source=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.2-buildscript.json'
        $catalog=Get-Content -LiteralPath $source -Raw|ConvertFrom-Json
        $catalog.artifacts[0].sha256='0'*64
        $path=Join-Path $TestDrive 'tampered-forge-gradle3-classpath.json'
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $catalog -Depth 30),[Text.UTF8Encoding]::new($false))

        { Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $path } | Should -Throw '*FORGE_GRADLE3_CLASSPATH_CATALOG_HASH_MISMATCH*'
    }

    It 'reads a pinned ForgeGradle 3 userdev config and verifies the MCP coordinate and exact library set' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $expectedLibraries=@('org.ow2.asm:asm-debug-all:5.2','net.minecraftforge:legacydev:0.2.3.+:fatjar')
        $config=[ordered]@{mcp='de.oceanlabs.mcp:mcp_config:1.12.2-20200226.224830@zip';libraries=$expectedLibraries}
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $config -Compress))
        $archivePath=Join-Path $TestDrive 'forge-userdev3.zip'
        $file=[IO.File]::Open($archivePath,[IO.FileMode]::CreateNew)
        try{$zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Create);try{$entry=$zip.CreateEntry('config.json');$stream=$entry.Open();try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}}finally{$file.Dispose()}

        $result=Get-MmtlForgeUserdevConfiguration -ArchivePath $archivePath -EntryName 'config.json' -ExpectedBytes $bytes.Length -ExpectedSha256 ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()) -ExpectedMcpCoordinate 'de.oceanlabs.mcp:mcp_config:1.12.2-20200226.224830@zip' -ExpectedLibraries $expectedLibraries

        $result.mcp | Should -BeExactly 'de.oceanlabs.mcp:mcp_config:1.12.2-20200226.224830@zip'
        $result.libraries | Should -HaveCount 2
        $result.sha256 | Should -BeExactly ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())
    }

    It 'reads Forge 1.12.1 userdev library coordinates from object entries' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $expectedLibraries=@('net.minecraft:launchwrapper:1.12','org.ow2.asm:asm-debug-all:5.2')
        $config=[ordered]@{libraries=@([ordered]@{name=$expectedLibraries[0]},[ordered]@{name=$expectedLibraries[1];url='https://repo.maven.apache.org/maven2'})}
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $config -Compress))
        $archivePath=Join-Path $TestDrive 'forge-userdev-object-libraries.zip'
        $file=[IO.File]::Open($archivePath,[IO.FileMode]::CreateNew)
        try{$zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Create);try{$entry=$zip.CreateEntry('dev.json');$stream=$entry.Open();try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}}finally{$file.Dispose()}

        $result=Get-MmtlForgeUserdevConfiguration -ArchivePath $archivePath -EntryName 'dev.json' -ExpectedBytes $bytes.Length -ExpectedSha256 ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()) -ExpectedLibraries $expectedLibraries

        $result.libraries | Should -Be $expectedLibraries
    }

    It 'rejects a ForgeGradle userdev config whose pinned bytes do not match' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $config=[ordered]@{mcp='de.oceanlabs.mcp:mcp_config:1.12.2-20200226.224830@zip';libraries=@('net.minecraftforge:legacydev:0.2.3.+:fatjar')}
        $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $config -Compress))
        $archivePath=Join-Path $TestDrive 'forge-userdev3-bad-hash.zip'
        $file=[IO.File]::Open($archivePath,[IO.FileMode]::CreateNew)
        try{$zip=[IO.Compression.ZipArchive]::new($file,[IO.Compression.ZipArchiveMode]::Create);try{$entry=$zip.CreateEntry('config.json');$stream=$entry.Open();try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}}finally{$file.Dispose()}

        { Get-MmtlForgeUserdevConfiguration -ArchivePath $archivePath -EntryName 'config.json' -ExpectedBytes $bytes.Length -ExpectedSha256 ('0'*64) -ExpectedMcpCoordinate 'de.oceanlabs.mcp:mcp_config:1.12.2-20200226.224830@zip' -ExpectedLibraries @('net.minecraftforge:legacydev:0.2.3.+:fatjar') } | Should -Throw '*FORGE_USERDEV_CONFIG_HASH_MISMATCH*'
    }

    It 'locks every ForgeGradle 2.1 direct dependency to a local Maven artifact and POM' {
        $schemaPath=Join-Path $script:repoRoot 'schemas/forge-gradle-classpath-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $script:catalogPath -Raw) -SchemaFile $schemaPath) | Should -BeTrue
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $script:catalogPath
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.8.9'
        $resolved.catalog.rootCoordinate | Should -BeExactly 'net.minecraftforge.gradle:ForgeGradle:2.1-SNAPSHOT'
        $resolved.catalog.artifactStatus | Should -BeExactly 'HashesVerified'
        $resolved.catalog.mcpVersions.url | Should -BeExactly 'https://maven.minecraftforge.net/de/oceanlabs/mcp/versions.json'
        $resolved.catalog.mcpMapping | Should -BeExactly 'stable_22'
        $resolved.catalog.mojangVersion.url | Should -BeExactly 'https://piston-meta.mojang.com/v1/packages/d546f1707a3f2b7d034eece5ea2e311eda875787/1.8.9.json'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly '341af5f47a6b5bc137bfe681f4f3533e081041290aabbf9d7ebeae9881de768f'
        $resolved.mcpArtifacts.Count | Should -Be 2
        $resolved.mcpArtifacts[0].sha256 | Should -BeExactly 'ea6fdd37e68569a378fd149b0ab7cfede1de7fa3e794f4ed81f9018366fbdc51'
        $resolved.mcpArtifacts[1].version | Should -BeExactly '22-1.8.9'
        $resolved.mcpArtifacts[1].bytes | Should -Be 282686
        $resolved.mcpArtifacts[1].sha256 | Should -BeExactly 'aeed0aaba9d159b7ce60a21e2dcc36adb249fade65ce2f76c730dd0ec7270763'
        $resolved.catalog.dependencies.Count | Should -Be 13
        foreach($dependency in $resolved.catalog.dependencies){
            foreach($extension in @('jar','pom')){
                @($resolved.artifacts | Where-Object { $_.group -ceq $dependency.group -and $_.artifact -ceq $dependency.artifact -and $_.version -ceq $dependency.version -and $_.extension -ceq $extension }).Count | Should -Be 1
            }
        }
    }

    It 'declares the stable_22 correction as a hash-pinned Forge 1.8.9 build.gradle overlay' {
        $fixtureRoot=Join-Path $script:repoRoot 'fixtures/forge/1.8.9-marker'
        $manifest=Get-Content -LiteralPath (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw | ConvertFrom-Json
        $overlay=@($manifest.overlayFiles|Where-Object path -CEQ 'build.gradle')
        $overlay.Count | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $fixtureRoot 'build.gradle') -Raw) | Should -Match 'stable_22'
        (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $fixtureRoot 'build.gradle')).Hash.ToLowerInvariant() | Should -BeExactly $overlay[0].sha256
    }

    It 'pins the exact 1.8.9 Mojang and Forge UserDev development library closure' {
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $script:catalogPath
        $libraries=@($resolved.catalog.requiredLibraries)
        $libraries.Count | Should -Be 46
        @($libraries|Where-Object source -eq 'MojangVersionJson').Count | Should -Be 29
        @($libraries|Where-Object source -eq 'ForgeUserdevDevJson').Count | Should -Be 17
        $mojangSnapshot=Get-Content (Join-Path (Split-Path -Parent $script:repoRoot) 'compatibility/snapshots/MojangVersions/341af5f47a6b5bc137bfe681f4f3533e081041290aabbf9d7ebeae9881de768f.bin') -Raw|ConvertFrom-Json
        $devSnapshot=Get-Content (Join-Path (Split-Path -Parent $script:repoRoot) 'compatibility/snapshots/ForgeUserdev/Forge-1.8.9-dev.json') -Raw|ConvertFrom-Json
        $existing=@($resolved.catalog.artifacts|Where-Object extension -eq 'jar'|ForEach-Object{$_.group+':'+$_.artifact+':'+$_.version})
        $expectedMojang=@($mojangSnapshot.libraries|Where-Object {$_.downloads.artifact}|ForEach-Object name|Where-Object{$_ -notin $existing}|Sort-Object -Unique)
        $expectedDev=@($devSnapshot.libraries|ForEach-Object name|Where-Object{$_ -notin $existing}|Sort-Object -Unique)
        @($libraries|Where-Object source -eq 'MojangVersionJson'|ForEach-Object coordinate|Sort-Object) | Should -Be $expectedMojang
        @($libraries|Where-Object source -eq 'ForgeUserdevDevJson'|ForEach-Object coordinate|Sort-Object) | Should -Be $expectedDev
        foreach($library in $libraries){
            $library.file | Should -Match '\.jar$'
            $library.bytes | Should -BeGreaterThan 0
            $library.sha1 | Should -Match '^[a-f0-9]{40}$'
            $library.sha256 | Should -Match '^[a-f0-9]{64}$'
            $library.url | Should -Match '^https://(libraries\.minecraft\.net|repo\.maven\.apache\.org)/'
        }
        $resolved.catalog.forgeUserdev.devJson.sha256 | Should -BeExactly '47adbb996168cd35aa54931d1ca50b8dc172e8c78321fcc1e9cec0dd04f14629'
        @($resolved.catalog.forgeUserdev.devLibraries).Count | Should -Be 18
    }

    It 'pins Forge 1.8.8 against its own Mojang, UserDev and MCP inputs' {
        $catalog188Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.8.8.json'
        $schemaPath=Join-Path $script:repoRoot 'schemas/forge-gradle-classpath-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $catalog188Path -Raw) -SchemaFile $schemaPath) | Should -BeTrue
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog188Path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.8.8'
        $resolved.catalog.mojangVersion.url | Should -BeExactly 'https://piston-meta.mojang.com/v1/packages/690172f1227e1c1d2fa8fceadd0f578f7851a69e/1.8.8.json'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly '7f002c1dca74cc51ce995e7fdb465ab4984c940e77a1b1c4f2b09bed8702e558'
        $resolved.catalog.forgeUserdev.version | Should -BeExactly '1.8.8-11.15.0.1655'
        $resolved.catalog.forgeUserdev.devJson.sha256 | Should -BeExactly '6260944d8e1619da5553ae8bb04e1353eb878d2fd1415e7478ae334dfe60cb44'
        @($resolved.catalog.forgeUserdev.devLibraries).Count | Should -Be 54
        @($resolved.catalog.requiredLibraries).Count | Should -Be 46
        @($resolved.catalog.requiredLibraries | Where-Object source -eq 'MojangVersionJson').Count | Should -Be 29
        @($resolved.catalog.requiredLibraries | Where-Object source -eq 'ForgeUserdevDevJson').Count | Should -Be 17
        $resolved.mcpArtifacts[0].file | Should -BeExactly 'mcp-1.8.8-srg.zip'
        $resolved.mcpArtifacts[1].file | Should -BeExactly 'mcp_stable-20-1.8.8.zip'
        @($resolved.mcpArtifacts).Count | Should -Be 3
        $resolved.mcpArtifacts[2].coordinate | Should -BeExactly 'de.oceanlabs.mcp:mcp_snapshot'
        $resolved.mcpArtifacts[2].version | Should -BeExactly '20151122-1.8'
        $resolved.mcpArtifacts[2].sha256 | Should -BeExactly '41e4a56901b39df2db48c4f22332b9a2c365737ce7e75466117b3609098386a3'
    }

    It 'pins Forge 1.9 against its exact Mojang, UserDev and MCP closure' {
        $catalog19Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.9.json'
        $schemaPath=Join-Path $script:repoRoot 'schemas/forge-gradle-classpath-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $catalog19Path -Raw) -SchemaFile $schemaPath) | Should -BeTrue
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog19Path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.9'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly '8d6f1e7f3a99f1236914b61e64eeade955ba21e8150563457142d3981aeee688'
        $resolved.catalog.forgeUserdev.version | Should -BeExactly '1.9-12.16.1.1938-1.9.0'
        @($resolved.catalog.forgeUserdev.devLibraries).Count | Should -Be 18
        @($resolved.catalog.requiredLibraries).Count | Should -Be 45
        @($resolved.catalog.requiredLibraries | Where-Object source -eq 'MojangVersionJson').Count | Should -Be 28
        @($resolved.catalog.requiredLibraries | Where-Object source -eq 'ForgeUserdevDevJson').Count | Should -Be 17
        @($resolved.mcpArtifacts).Count | Should -Be 3
        $resolved.mcpArtifacts[0].version | Should -BeExactly '1.9'
        $resolved.mcpArtifacts[1].version | Should -BeExactly '24-1.9'
        $resolved.mcpArtifacts[2].version | Should -BeExactly '20160312-1.9'
    }

    It 'pins Forge 1.10.2 against its exact ForgeGradle 2.2, Mojang, UserDev and MCP closure' {
        $catalog102Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.10.2.json'
        $schemaPath=Join-Path $script:repoRoot 'schemas/forge-gradle-classpath-artifacts.schema.json'
        (Test-Json -Json (Get-Content -LiteralPath $catalog102Path -Raw) -SchemaFile $schemaPath) | Should -BeTrue
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog102Path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.10.2'
        $resolved.catalog.rootCoordinate | Should -BeExactly 'net.minecraftforge.gradle:ForgeGradle:2.2-SNAPSHOT'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly 'd0624badea6367233d47c830341952126cdb0f99b1e11fb60428dd530a0d4db5'
        $resolved.catalog.forgeUserdev.version | Should -BeExactly '1.10.2-12.18.3.2511'
        @($resolved.catalog.forgeUserdev.devLibraries).Count | Should -Be 18
        @($resolved.catalog.requiredLibraries).Count | Should -Be 48
        @($resolved.catalog.requiredLibraries | Where-Object source -eq 'MojangVersionJson').Count | Should -Be 29
        @($resolved.catalog.requiredLibraries | Where-Object source -eq 'ForgeUserdevDevJson').Count | Should -Be 18
        $forgeMcLibrary=@($resolved.catalog.requiredLibraries | Where-Object source -eq 'ForgeGradleMinecraftClasspath')
        $forgeMcLibrary.Count | Should -Be 1
        $forgeMcLibrary[0].coordinate | Should -BeExactly 'com.google.code.findbugs:jsr305:3.0.1'
        $forgeMcLibrary[0].bytes | Should -Be 19943
        $forgeMcLibrary[0].sha1 | Should -BeExactly 'f7be08ec23c21485b9b5a1cf1654c2ec8c58168d'
        $forgeMcLibrary[0].sha256 | Should -BeExactly 'c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd'
        $resolved.catalog.dependencies | Where-Object artifact -eq 'asm-debug-all' | ForEach-Object version | Should -BeExactly '5.1'
        @($resolved.mcpArtifacts).Count | Should -Be 3
        $resolved.mcpArtifacts[0].version | Should -BeExactly '1.10.2'
        $resolved.mcpArtifacts[1].version | Should -BeExactly '29-1.10.2'
        $resolved.mcpArtifacts[2].version | Should -BeExactly '20161111-1.10.2'
    }

    It 'resolves Forge 1.10 snapshot mappings through the published 1.9.4 MCP fallback' {
        $catalog110Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.10.json'
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog110Path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.10'
        $resolved.catalog.mcpMapping | Should -BeExactly 'snapshot_20160518'
        $resolved.catalog.mojangVersion.url | Should -BeExactly 'https://piston-meta.mojang.com/v1/packages/a827abf9c022a08ed9c4c7807a8c1b7f2f05deca/1.10.json'
        $resolved.catalog.mojangVersion.sha1 | Should -BeExactly 'a827abf9c022a08ed9c4c7807a8c1b7f2f05deca'
        @($resolved.mcpArtifacts | Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_snapshot').Count | Should -Be 1
        ($resolved.mcpArtifacts | Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_snapshot').version | Should -BeExactly '20160518-1.9.4'
        @($resolved.catalog.requiredLibraries | Where-Object source -eq 'MojangVersionJson').Count | Should -BeGreaterThan 0
        @($resolved.catalog.requiredLibraries | Where-Object source -eq 'ForgeUserdevDevJson').Count | Should -BeGreaterThan 0
    }

    It 'pins Forge 1.11 to its published native MCP snapshot mapping' {
        $catalog111Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.11.json'
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog111Path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.11'
        $resolved.catalog.mcpMapping | Should -BeExactly 'snapshot_20161220'
        @($resolved.mcpArtifacts | Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_snapshot').Count | Should -Be 1
        ($resolved.mcpArtifacts | Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_snapshot').version | Should -BeExactly '20161220-1.11'
        $resolved.catalog.forgeUserdev.version | Should -BeExactly '1.11-13.19.1.2199'
    }
    It 'pins Forge 1.11.2 to its published MCP branch fallback and exact SRG target' {
        $catalog112Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.11.2.json'
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog112Path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.11.2'
        $resolved.catalog.mcpMapping | Should -BeExactly 'snapshot_20161220'
        ($resolved.mcpArtifacts | Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp').version | Should -BeExactly '1.11.2'
        ($resolved.mcpArtifacts | Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_snapshot').version | Should -BeExactly '20161220-1.11'
        $resolved.catalog.forgeUserdev.version | Should -BeExactly '1.11.2-13.20.1.2588'
    }
    It 'pins Forge 1.12 to ForgeGradle 2.3 and its native MCP snapshot' {
        $catalog112Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.json'
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog112Path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.12'
        $resolved.catalog.rootCoordinate | Should -BeExactly 'net.minecraftforge.gradle:ForgeGradle:2.3-SNAPSHOT'
        $resolved.catalog.mcpMapping | Should -BeExactly 'snapshot_20170624'
        ($resolved.mcpArtifacts | Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_snapshot').version | Should -BeExactly '20170624-1.12'
        $resolved.catalog.forgeUserdev.version | Should -BeExactly '1.12-14.21.1.2443'
        $forgeMinecraftLibraries=@($resolved.requiredLibraries|Where-Object source -eq 'ForgeGradleMinecraftClasspath')
        $forgeMinecraftLibraries.Count | Should -Be 1
        $forgeMinecraftLibraries[0].coordinate | Should -BeExactly 'com.google.code.findbugs:jsr305:3.0.1'
        $forgeMinecraftLibraries[0].bytes | Should -Be 19943
        $forgeMinecraftLibraries[0].sha1 | Should -BeExactly 'f7be08ec23c21485b9b5a1cf1654c2ec8c58168d'
        $forgeMinecraftLibraries[0].sha256 | Should -BeExactly 'c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd'
    }
    It 'pins Forge 1.12.1 to ForgeGradle 2.3 and the official MCP fallback branch' {
        $catalog121Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.1.json'
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog121Path
        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.12.1'
        $resolved.catalog.mojangVersion.sha256 | Should -BeExactly 'a83e8ab7e3e78fd8dfa8fdbd0216b090ef7298fb44637b79093fe663bf2d6814'
        $resolved.catalog.mojangVersion.sha1 | Should -BeExactly '5b3e7d137ea360e1d418f0cf68de160acf93fbff'
        ($resolved.mcpArtifacts|Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp').version | Should -BeExactly '1.12.1'
        ($resolved.mcpArtifacts|Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_stable').version | Should -BeExactly '39-1.12'
        ($resolved.mcpArtifacts|Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_snapshot').version | Should -BeExactly '20170624-1.12'
        $resolved.requiredLibraries.Count | Should -Be 51
    }
    It 'accepts identical Mojang library pins repeated across platform-rule entries' {
        $catalog112Path=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.json'
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalog112Path
        $mojangPath=Join-Path (Split-Path -Parent $script:repoRoot) 'compatibility/snapshots/MojangVersions/33cc40a05466b4e34e04e65def732094388e9149eb6bd37e5daa227c06cbde4b.bin'
        Test-MmtlForgeClasspathMojangLibraryPins -ClasspathCatalog $resolved -MojangVersionJsonPath $mojangPath | Should -BeTrue
    }
    It 'rejects classpath artifact catalog hash tampering' {
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $catalog.artifacts[0].sha256=('0'*64)
        $tampered=Join-Path $TestDrive 'forge-gradle-classpath-artifacts.json'
        $catalog | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tampered -Encoding utf8
        { Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $tampered } | Should -Throw '*FORGE_BUILD_CLASSPATH_CATALOG_HASH_MISMATCH*'
    }

    It 'materializes artifacts from the verified content cache without network access' {
        $payload=[Text.Encoding]::UTF8.GetBytes('pinned-fixture-content')
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
        $mcpPayload=[IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $script:repoRoot) 'compatibility/snapshots/MCPVersions/df5875099a4191293a4d36df5cc95086eb95eed4d4549a7a976e847ee3ae5156.bin'))
        $mcpHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($mcpPayload)).ToLowerInvariant()
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw|ConvertFrom-Json
        $dependencies=@($catalog.dependencies);$artifacts=@($catalog.artifacts);$requiredLibraries=@($catalog.requiredLibraries)
        foreach($artifact in $artifacts){$artifact.bytes=$payload.Length;$artifact.sha256=$hash;$artifact.url='https://plugins.gradle.org/m2/'+$artifact.group.Replace('.','/')+'/'+$artifact.artifact+'/'+$artifact.version+'/'+$artifact.file}
        foreach($library in $requiredLibraries){$library.bytes=$payload.Length;$library.sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($payload)).ToLowerInvariant();$library.sha256=$hash}
        $mojangPayload=[IO.File]::ReadAllBytes((Join-Path (Split-Path -Parent $script:repoRoot) 'compatibility/snapshots/MojangVersions/341af5f47a6b5bc137bfe681f4f3533e081041290aabbf9d7ebeae9881de768f.bin'))
        $mojangHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($mojangPayload)).ToLowerInvariant()
        $catalog.mcpVersions.bytes=$mcpPayload.Length;$catalog.mcpVersions.sha256=$mcpHash
        $mcpVersions=[pscustomobject][ordered]@{url=[string]$catalog.mcpVersions.url;bytes=[long]$catalog.mcpVersions.bytes;sha256=[string]$catalog.mcpVersions.sha256}
        $mojangVersion=[pscustomobject][ordered]@{url=[string]$catalog.mojangVersion.url;bytes=[long]$catalog.mojangVersion.bytes;sha256=[string]$catalog.mojangVersion.sha256;sha1=[string]$catalog.mojangVersion.sha1;snapshotSha256=[string]$catalog.mojangVersion.snapshotSha256}
        $core=[pscustomobject][ordered]@{schemaVersion=[int]$catalog.schemaVersion;targetId=[string]$catalog.targetId;rootCoordinate=[string]$catalog.rootCoordinate;resolver=[string]$catalog.resolver;artifactStatus=[string]$catalog.artifactStatus;mcpVersions=$mcpVersions;mcpMapping=[string]$catalog.mcpMapping;mojangVersion=$mojangVersion;forgeUserdev=$catalog.forgeUserdev;mcpArtifacts=@($catalog.mcpArtifacts);dependencies=$dependencies;artifacts=$artifacts;requiredLibraries=$requiredLibraries}
        $catalog=[ordered]@{};foreach($property in $core.PSObject.Properties){$catalog[$property.Name]=$property.Value};$catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
        $catalogPath=Join-Path $TestDrive 'synthetic-classpath-catalog.json';[IO.File]::WriteAllText($catalogPath,($catalog|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        $cacheRoot=Join-Path $TestDrive 'synthetic-classpath-cache';$artifactCache=Join-Path $cacheRoot 'artifact-cache';$null=New-Item -ItemType Directory -Path $artifactCache -Force
        [IO.File]::WriteAllBytes((Join-Path $artifactCache $hash),$payload)
        [IO.File]::WriteAllBytes((Join-Path $artifactCache $mcpHash),$mcpPayload)
        [IO.File]::WriteAllBytes((Join-Path $artifactCache $mojangHash),$mojangPayload)
        [IO.File]::WriteAllBytes((Join-Path $artifactCache $hash),$payload)

        $mirror=Get-MmtlForgeBuildClasspathArtifactMirror -CatalogPath $catalogPath -CacheRoot $cacheRoot

        $mirror.dependencyCount | Should -Be 13
        $mirror.artifactCount | Should -Be 99
        (Get-FileHash -LiteralPath $mirror.mcpVersionsPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $mcpHash
        (Get-FileHash -LiteralPath $mirror.mojangVersionPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $mojangHash
        foreach($artifact in $artifacts){
            $path=Join-Path (Join-Path (Join-Path $mirror.mirrorRoot $artifact.group.Replace('.',[IO.Path]::DirectorySeparatorChar)) (Join-Path $artifact.artifact $artifact.version)) $artifact.file
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $hash
        }
    }

    It 'materializes ForgeGradle 2.3 forgeflower snapshot metadata in the isolated Maven mirror' {
        $catalog=Get-Content (Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.json') -Raw|ConvertFrom-Json
        $catalogPath=Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.json'
        $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $catalogPath
        $repositoryRoot=Join-Path $TestDrive 'forgeflower-maven-repository'
        $metadataPath=New-MmtlForgeClasspathSnapshotMetadata -ClasspathCatalog $resolved -RepositoryRoot $repositoryRoot
        Test-Path -LiteralPath $metadataPath | Should -BeTrue
        $metadataPath | Should -BeExactly (Join-Path $repositoryRoot 'net/minecraftforge/forgeflower/1.0.342-SNAPSHOT/maven-metadata.xml')
        ([xml](Get-Content -LiteralPath $metadataPath -Raw)).metadata.versioning.snapshotVersions.snapshotVersion | ForEach-Object value | Should -Contain '1.0.342-20171208.041249-7'
    }

    It 'materializes only the pinned release for a ForgeGradle dynamic dependency selector' {
        $resolved=[pscustomobject]@{
            catalog=[pscustomobject]@{dynamicVersionResolutions=@(
                [pscustomobject]@{group='net.minecraftforge';artifact='artifactural';selector='1.0.+';resolvedVersion='1.0.13'},
                [pscustomobject]@{group='net.minecraftforge';artifact='legacydev';selector='0.2.3.+';resolvedVersion='0.2.3.1'}
            )}
            dependencies=@(
                [pscustomobject]@{group='net.minecraftforge';artifact='artifactural';version='1.0.13'},
                [pscustomobject]@{group='net.minecraftforge';artifact='legacydev';version='0.2.3.1'}
            )
        }
        $repositoryRoot=Join-Path $TestDrive 'forgegradle-dynamic-maven-repository'

        $metadataPaths=@(New-MmtlForgeClasspathDynamicVersionMetadata -ClasspathCatalog $resolved -RepositoryRoot $repositoryRoot)

        $metadataPaths.Count | Should -Be 2
        $metadataPaths | Should -Contain (Join-Path $repositoryRoot 'net/minecraftforge/artifactural/maven-metadata.xml')
        $metadataPaths | Should -Contain (Join-Path $repositoryRoot 'net/minecraftforge/legacydev/maven-metadata.xml')
        foreach($metadataPath in $metadataPaths){
            $metadata=[xml](Get-Content -LiteralPath $metadataPath -Raw)
            $expectedVersion=if($metadataPath -match '[\\/]artifactural[\\/]maven-metadata\.xml$'){'1.0.13'}else{'0.2.3.1'}
            @($metadata.metadata.versioning.versions.version) | Should -HaveCount 1
            [string]$metadata.metadata.versioning.versions.version | Should -BeExactly $expectedVersion
            [string]$metadata.metadata.versioning.latest | Should -BeExactly $expectedVersion
            [string]$metadata.metadata.versioning.release | Should -BeExactly $expectedVersion
        }
    }

    It 'allows the exact ForgeGradle 3.0.197 catalog to declare both pinned dynamic dependency resolutions' {
        $catalog=Get-Content (Join-Path (Split-Path -Parent $script:catalogPath) 'forge-gradle-classpath-artifacts/Forge-1.12.1.json') -Raw|ConvertFrom-Json
        $catalog.targetId='Forge@1.12.2'
        $catalog.rootCoordinate='net.minecraftforge.gradle:ForgeGradle:3.0.197'
        $catalog.resolver='ForgeGradle 3.0.197 POM compile dependency union plus pinned Mojang 1.12.2 and Forge UserDev development libraries and exact ForgeGradle Minecraft compile classpath'
        $catalog|Add-Member -NotePropertyName dynamicVersionResolutions -NotePropertyValue @([pscustomobject]@{group='net.minecraftforge';artifact='artifactural';selector='1.0.+';resolvedVersion='1.0.13'},[pscustomobject]@{group='net.minecraftforge';artifact='legacydev';selector='0.2.3.+';resolvedVersion='0.2.3.1'})
        $schemaPath=Join-Path $script:repoRoot 'schemas/forge-gradle-classpath-artifacts.schema.json'

        Test-Json -Json (ConvertTo-Json -InputObject $catalog -Depth 30) -SchemaFile $schemaPath | Should -BeTrue
    }
}
