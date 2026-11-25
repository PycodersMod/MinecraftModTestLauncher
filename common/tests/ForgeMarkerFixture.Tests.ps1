BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:generatorPath = Join-Path $script:repoRoot 'tools/New-MmtlForgeMarkerFixture.ps1'
}

Describe 'Forge marker fixture generation' {
    It 'keeps the Forge 1.16.5 marker fixture bound to its verified official FG6 MDK' {
        $fixtureRoot=Join-Path $script:repoRoot 'common/fixtures/forge/1.16.5-marker'
        $fixture=Get-Content (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $pinManifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pin=@($pinManifest.targets|Where-Object targetId -CEQ 'Forge@1.16.5')

        $pin | Should -HaveCount 1
        $fixture.targetId | Should -BeExactly 'Forge@1.16.5'
        $fixture.sourceArchiveUrl | Should -BeExactly $pin[0].sourceArchiveUrl
        $fixture.sourceArchiveSha256 | Should -BeExactly $pin[0].sourceArchiveSha256
        foreach($file in $fixture.overlayFiles){(Get-FileHash -LiteralPath (Join-Path $fixtureRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256}
    }

    It 'keeps the Forge 1.14.4 marker fixture bound to the verified official archive and overlay' {
        $fixtureRoot=Join-Path $script:repoRoot 'common/fixtures/forge/1.14.4-marker'
        $manifest=Get-Content (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $pinManifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pin=@($pinManifest.targets|Where-Object targetId -CEQ 'Forge@1.14.4')

        $pin | Should -HaveCount 1
        $manifest.targetId | Should -BeExactly 'Forge@1.14.4'
        $manifest.fixtureId | Should -BeExactly 'MMTLForgeMarkerFixtureV1'
        $manifest.sourceArchiveUrl | Should -BeExactly $pin[0].sourceArchiveUrl
        $manifest.sourceArchiveSha256 | Should -BeExactly $pin[0].sourceArchiveSha256
        $manifest.overlayFiles | Should -HaveCount 2
        foreach($file in $manifest.overlayFiles){
            $path=Join-Path $fixtureRoot $file.path
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256
        }
        $overlayRecords=@($manifest.overlayFiles|ForEach-Object{$_.path+'|'+$_.sha256}|Sort-Object -CaseSensitive)
        $overlayHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($overlayRecords -join "`n")))).ToLowerInvariant()
        $overlayHash | Should -BeExactly $manifest.overlaySha256
        (Get-Content (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw) | Should -Match '@Mod\(MmtlMarkerMod\.MOD_ID\)'
        (Get-Content (Join-Path $fixtureRoot 'src/main/resources/mcmod.info') -Raw) | Should -Match '"mcversion": "1\.14\.4"'
    }

    It 'keeps the Forge 1.15.2 marker fixture bound to the official MDK and generated marker overlay' {
        $fixtureRoot=Join-Path $script:repoRoot 'common/fixtures/forge/1.15.2-marker'
        $manifest=Get-Content (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $pinManifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pin=@($pinManifest.targets|Where-Object targetId -CEQ 'Forge@1.15.2')

        $pin | Should -HaveCount 1
        $manifest.targetId | Should -BeExactly 'Forge@1.15.2'
        $manifest.sourceArchiveUrl | Should -BeExactly $pin[0].sourceArchiveUrl
        $manifest.sourceArchiveSha256 | Should -BeExactly $pin[0].sourceArchiveSha256
        $manifest.overlayFiles | Should -HaveCount 2
        foreach($file in $manifest.overlayFiles){(Get-FileHash -LiteralPath (Join-Path $fixtureRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256}
        $overlayRecords=@($manifest.overlayFiles|ForEach-Object{$_.path+'|'+$_.sha256}|Sort-Object -CaseSensitive)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($overlayRecords -join "`n")))).ToLowerInvariant() | Should -BeExactly $manifest.overlaySha256
        (Get-Content (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw) | Should -Match '@Mod\(MmtlMarkerMod\.MOD_ID\)'
        (Get-Content (Join-Path $fixtureRoot 'src/main/resources/mcmod.info') -Raw) | Should -Match '"mcversion": "1\.15\.2"'
    }

    It 'keeps the Forge 1.15.1 marker fixture bound to the official MDK and generated marker overlay' {
        $fixtureRoot=Join-Path $script:repoRoot 'common/fixtures/forge/1.15.1-marker'
        $manifest=Get-Content (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $pinManifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pin=@($pinManifest.targets|Where-Object targetId -CEQ 'Forge@1.15.1')

        $pin | Should -HaveCount 1
        $manifest.targetId | Should -BeExactly 'Forge@1.15.1'
        $manifest.sourceArchiveUrl | Should -BeExactly $pin[0].sourceArchiveUrl
        $manifest.sourceArchiveSha256 | Should -BeExactly $pin[0].sourceArchiveSha256
        $manifest.overlayFiles | Should -HaveCount 2
        foreach($file in $manifest.overlayFiles){(Get-FileHash -LiteralPath (Join-Path $fixtureRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $file.sha256}
        $overlayRecords=@($manifest.overlayFiles|ForEach-Object{$_.path+'|'+$_.sha256}|Sort-Object -CaseSensitive)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($overlayRecords -join "`n")))).ToLowerInvariant() | Should -BeExactly $manifest.overlaySha256
        (Get-Content (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw) | Should -Match '@Mod\(MmtlMarkerMod\.MOD_ID\)'
        (Get-Content (Join-Path $fixtureRoot 'src/main/resources/mcmod.info') -Raw) | Should -Match '"mcversion": "1\.15\.1"'
    }

    It 'keeps the Forge 1.16.1 marker fixture bound to the official MDK and generated marker overlay' {
        $fixtureRoot=Join-Path $script:repoRoot 'common/fixtures/forge/1.16.1-marker'
        $manifest=Get-Content (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $pinManifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pin=@($pinManifest.targets|Where-Object targetId -CEQ 'Forge@1.16.1')

        $pin|Should -HaveCount 1
        $manifest.targetId|Should -BeExactly 'Forge@1.16.1'
        $manifest.sourceArchiveUrl|Should -BeExactly $pin[0].sourceArchiveUrl
        $manifest.sourceArchiveSha256|Should -BeExactly $pin[0].sourceArchiveSha256
        $manifest.overlayFiles|Should -HaveCount 2
        foreach($file in $manifest.overlayFiles){(Get-FileHash -LiteralPath (Join-Path $fixtureRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant()|Should -BeExactly $file.sha256}
        $overlayRecords=@($manifest.overlayFiles|ForEach-Object{$_.path+'|'+$_.sha256}|Sort-Object -CaseSensitive)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($overlayRecords -join "`n")))).ToLowerInvariant() | Should -BeExactly $manifest.overlaySha256
        (Get-Content (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw)|Should -Match '@Mod\(MmtlMarkerMod\.MOD_ID\)'
        (Get-Content (Join-Path $fixtureRoot 'src/main/resources/mcmod.info') -Raw)|Should -Match '"mcversion": "1\.16\.1"'
    }

    It 'keeps the Forge 1.16.2 marker fixture bound to the official MDK and generated marker overlay' {
        $fixtureRoot=Join-Path $script:repoRoot 'common/fixtures/forge/1.16.2-marker'
        $manifest=Get-Content (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $pinManifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pin=@($pinManifest.targets|Where-Object targetId -CEQ 'Forge@1.16.2')

        $pin|Should -HaveCount 1
        $manifest.targetId|Should -BeExactly 'Forge@1.16.2'
        $manifest.sourceArchiveUrl|Should -BeExactly $pin[0].sourceArchiveUrl
        $manifest.sourceArchiveSha256|Should -BeExactly $pin[0].sourceArchiveSha256
        $manifest.overlayFiles|Should -HaveCount 2
        foreach($file in $manifest.overlayFiles){(Get-FileHash -LiteralPath (Join-Path $fixtureRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant()|Should -BeExactly $file.sha256}
        $overlayRecords=@($manifest.overlayFiles|ForEach-Object{$_.path+'|'+$_.sha256}|Sort-Object -CaseSensitive)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($overlayRecords -join "`n")))).ToLowerInvariant() | Should -BeExactly $manifest.overlaySha256
        (Get-Content (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw)|Should -Match '@Mod\(MmtlMarkerMod\.MOD_ID\)'
        (Get-Content (Join-Path $fixtureRoot 'src/main/resources/mcmod.info') -Raw)|Should -Match '"mcversion": "1\.16\.2"'
    }

    It 'keeps the Forge 1.16.3 marker fixture bound to the official MDK and generated marker overlay' {
        $fixtureRoot=Join-Path $script:repoRoot 'common/fixtures/forge/1.16.3-marker'
        $manifest=Get-Content (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $pinManifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pin=@($pinManifest.targets|Where-Object targetId -CEQ 'Forge@1.16.3')

        $pin|Should -HaveCount 1
        $manifest.targetId|Should -BeExactly 'Forge@1.16.3'
        $manifest.sourceArchiveUrl|Should -BeExactly $pin[0].sourceArchiveUrl
        $manifest.sourceArchiveSha256|Should -BeExactly $pin[0].sourceArchiveSha256
        $manifest.overlayFiles|Should -HaveCount 2
        foreach($file in $manifest.overlayFiles){(Get-FileHash -LiteralPath (Join-Path $fixtureRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant()|Should -BeExactly $file.sha256}
        $overlayRecords=@($manifest.overlayFiles|ForEach-Object{$_.path+'|'+$_.sha256}|Sort-Object -CaseSensitive)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($overlayRecords -join "`n")))).ToLowerInvariant() | Should -BeExactly $manifest.overlaySha256
        (Get-Content (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw)|Should -Match '@Mod\(MmtlMarkerMod\.MOD_ID\)'
        (Get-Content (Join-Path $fixtureRoot 'src/main/resources/mcmod.info') -Raw)|Should -Match '"mcversion": "1\.16\.3"'
    }

    It 'keeps the Forge 1.16.4 marker fixture bound to the official MDK and generated marker overlay' {
        $fixtureRoot=Join-Path $script:repoRoot 'common/fixtures/forge/1.16.4-marker'
        $manifest=Get-Content (Join-Path $fixtureRoot '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $pinManifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pin=@($pinManifest.targets|Where-Object targetId -CEQ 'Forge@1.16.4')

        $pin|Should -HaveCount 1
        $manifest.targetId|Should -BeExactly 'Forge@1.16.4'
        $manifest.sourceArchiveUrl|Should -BeExactly $pin[0].sourceArchiveUrl
        $manifest.sourceArchiveSha256|Should -BeExactly $pin[0].sourceArchiveSha256
        $manifest.overlayFiles|Should -HaveCount 2
        foreach($file in $manifest.overlayFiles){(Get-FileHash -LiteralPath (Join-Path $fixtureRoot $file.path) -Algorithm SHA256).Hash.ToLowerInvariant()|Should -BeExactly $file.sha256}
        $overlayRecords=@($manifest.overlayFiles|ForEach-Object{$_.path+'|'+$_.sha256}|Sort-Object -CaseSensitive)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($overlayRecords -join "`n")))).ToLowerInvariant() | Should -BeExactly $manifest.overlaySha256
        (Get-Content (Join-Path $fixtureRoot 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw)|Should -Match '@Mod\(MmtlMarkerMod\.MOD_ID\)'
        (Get-Content (Join-Path $fixtureRoot 'src/main/resources/mcmod.info') -Raw)|Should -Match '"mcversion": "1\.16\.4"'
    }

    It 'generates a Forge 1.8.9 marker with the post-1.8 FML package names' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $sourceRoot = Join-Path $TestDrive 'forge-1.8-mdk'
        $archivePath = Join-Path $TestDrive 'forge-1.8-mdk.zip'
        $destinationPath = Join-Path $TestDrive 'forge-1.8-marker'
        $destination188Path = Join-Path $TestDrive 'forge-1.8.8-marker'
        $destination19Path = Join-Path $TestDrive 'forge-1.9-marker'
        $manifestPath = Join-Path $TestDrive 'forge-build-pins.json'
        foreach ($directory in @('gradle/wrapper','src/main/java/example','src/main/resources')) {
            [void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot $directory))
        }
        $buildGradle = "buildscript { dependencies { classpath 'net.minecraftforge.gradle:ForgeGradle:2.1-SNAPSHOT' } }`n"
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'build.gradle'),$buildGradle,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'gradle/wrapper/gradle-wrapper.properties'),'distributionUrl=https\://services.gradle.org/distributions/gradle-2.7-bin.zip',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'src/main/java/example/Example.java'),'package example; class Example {}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $sourceRoot 'src/main/resources/mcmod.info'),'[]',[Text.UTF8Encoding]::new($false))
        [IO.Compression.ZipFile]::CreateFromDirectory($sourceRoot,$archivePath)
        $archiveHash=(Get-FileHash $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $buildHash=(Get-FileHash (Join-Path $sourceRoot 'build.gradle') -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=[ordered]@{schemaVersion=1;status='PARTIAL';targets=@([ordered]@{targetId='Forge@1.8.9';minecraftId='1.8.9';forgeVersion='1.8.9-11.15.1.2318-1.8.9';sourceArchiveUrl='https://maven.minecraftforge.net/net/minecraftforge/forge/1.8.9-11.15.1.2318-1.8.9/forge-1.8.9-11.15.1.2318-1.8.9-mdk.zip';sourceArchiveSha256=$archiveHash;buildGradleSha256=$buildHash;gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.7-bin.zip'},[ordered]@{targetId='Forge@1.8.8';minecraftId='1.8.8';forgeVersion='1.8.8-11.15.0.1655';sourceArchiveUrl='https://maven.minecraftforge.net/net/minecraftforge/forge/1.8.8-11.15.0.1655/forge-1.8.8-11.15.0.1655-mdk.zip';sourceArchiveSha256=$archiveHash;buildGradleSha256=$buildHash;gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.7-bin.zip'},[ordered]@{targetId='Forge@1.9';minecraftId='1.9';forgeVersion='1.9-12.16.1.1938-1.9.0';sourceArchiveUrl='https://maven.minecraftforge.net/net/minecraftforge/forge/1.9-12.16.1.1938-1.9.0/forge-1.9-12.16.1.1938-1.9.0-mdk.zip';sourceArchiveSha256=$archiveHash;buildGradleSha256=$buildHash;gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.7-bin.zip'})}
        $manifest.targets+=,[ordered]@{targetId='Forge@1.13.2';minecraftId='1.13.2';forgeVersion='1.13.2-25.0.223';sourceArchiveUrl='https://maven.minecraftforge.net/net/minecraftforge/forge/1.13.2-25.0.223/forge-1.13.2-25.0.223-mdk.zip';sourceArchiveSha256=$archiveHash;buildGradleSha256=$buildHash;gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.7-bin.zip'}
        [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifest -Depth 12),[Text.UTF8Encoding]::new($false))

        $result = & $script:generatorPath -SourceArchivePath $archivePath -DestinationPath $destinationPath -TargetId 'Forge@1.8.9' -PinManifestPath $manifestPath

        $result.targetId | Should -BeExactly 'Forge@1.8.9'
        $result.fixtureRoot | Should -BeExactly $destinationPath
        Test-Path (Join-Path $destinationPath 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') | Should -BeTrue
        $markerSource=Get-Content (Join-Path $destinationPath 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw
        $markerSource | Should -Match 'net\.minecraftforge\.fml\.common\.Mod'
        $markerSource | Should -Not -Match 'cpw\.mods\.fml'
        (Get-Content (Join-Path $destinationPath 'src/main/resources/mcmod.info') -Raw) | Should -Match '"mcversion": "1\.8\.9"'
        $fixtureManifest=Get-Content (Join-Path $destinationPath '.mmtl-fixture/manifest.json') -Raw|ConvertFrom-Json
        $fixtureManifest.targetId | Should -BeExactly 'Forge@1.8.9'
        $fixtureManifest.overlayFiles.Count | Should -Be 2

        $result188 = & $script:generatorPath -SourceArchivePath $archivePath -DestinationPath $destination188Path -TargetId 'Forge@1.8.8' -PinManifestPath $manifestPath
        $result188.targetId | Should -BeExactly 'Forge@1.8.8'
        $marker188=Get-Content (Join-Path $destination188Path 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw
        $marker188 | Should -Match 'net\.minecraftforge\.fml\.common\.Mod'
        $marker188 | Should -Not -Match 'cpw\.mods\.fml'
        (Get-Content (Join-Path $destination188Path 'src/main/resources/mcmod.info') -Raw) | Should -Match '"mcversion": "1\.8\.8"'

        $result19 = & $script:generatorPath -SourceArchivePath $archivePath -DestinationPath $destination19Path -TargetId 'Forge@1.9' -PinManifestPath $manifestPath
        $result19.targetId | Should -BeExactly 'Forge@1.9'
        $marker19=Get-Content (Join-Path $destination19Path 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw
        $marker19 | Should -Match 'net\.minecraftforge\.fml\.common\.Mod'
        $marker19 | Should -Not -Match 'cpw\.mods\.fml'
        (Get-Content (Join-Path $destination19Path 'src/main/resources/mcmod.info') -Raw) | Should -Match '"mcversion": "1\.9"'

        $destination1132Path=Join-Path $TestDrive 'forge-1.13.2-marker'
        $result1132=& $script:generatorPath -SourceArchivePath $archivePath -DestinationPath $destination1132Path -TargetId 'Forge@1.13.2' -PinManifestPath $manifestPath
        $result1132.targetId | Should -BeExactly 'Forge@1.13.2'
        $marker1132=Get-Content (Join-Path $destination1132Path 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java') -Raw
        $marker1132 | Should -Match '@Mod\(MmtlMarkerMod\.MOD_ID\)'
        $marker1132 | Should -Not -Match 'FMLInitializationEvent|FMLPreInitializationEvent|EventHandler|modid\s*='
    }
}
