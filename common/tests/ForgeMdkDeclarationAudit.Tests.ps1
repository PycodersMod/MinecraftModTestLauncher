BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:auditPath = Join-Path $script:repoRoot 'tools/Verify-ForgeMdkDeclarations.ps1'
}

Describe 'Forge MDK active declaration audit' {
    It 'verifies the active Plugins DSL version while ignoring commented Snapshot fallback' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $fixtureRoot=Join-Path $TestDrive 'forge-mdk-project'
        [void][IO.Directory]::CreateDirectory($fixtureRoot)
        $buildScript=@'
/* buildscript { dependencies { classpath 'net.minecraftforge.gradle:ForgeGradle:2.0-SNAPSHOT' } } */
plugins { id 'net.minecraftforge.gradle.forge' version '2.0.2' }
'@
        $buildPath=Join-Path $fixtureRoot 'build.gradle'
        [IO.File]::WriteAllText($buildPath,$buildScript,[Text.UTF8Encoding]::new($false))
        $archivePath=Join-Path $TestDrive 'Forge_1.8.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($fixtureRoot,$archivePath)
        $archiveHash=(Get-FileHash $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $buildHash=(Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $target=[ordered]@{targetId='Forge@1.8';minecraftId='1.8';forgeCoordinate='1.8-11.14.4.1577';sourceHash=('a'*64);candidateSourceHash=('a'*64);mdkUrl='https://maven.minecraftforge.net/net/minecraftforge/forge/1.8-11.14.4.1577/forge-1.8-11.14.4.1577-mdk.zip';httpStatus=200;status='Available';archiveSha256=$archiveHash;buildGradleSha256=$buildHash;forgeGradleSpec='2.0.2';gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.7-bin.zip';buildJavaMajor=$null}
        $catalog=[ordered]@{schemaVersion=1;generatedAt=[DateTimeOffset]::UtcNow.ToString('o');auditStatus='PARTIAL';universeHash=('b'*64);targetCount=1;targets=@([pscustomobject]$target)}
        $catalogPath=Join-Path $TestDrive 'catalog.json'
        $serializedCatalog=ConvertTo-Json -InputObject $catalog -Depth 20
        $roundTripped=$serializedCatalog|ConvertFrom-Json
        $core=[pscustomobject][ordered]@{schemaVersion=[int]$roundTripped.schemaVersion;generatedAt=[string]$roundTripped.generatedAt;auditStatus=[string]$roundTripped.auditStatus;universeHash=[string]$roundTripped.universeHash;targetCount=[int]$roundTripped.targetCount;targets=@($roundTripped.targets)}
        $roundTripped | Add-Member -NotePropertyName catalogHash -NotePropertyValue ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 20 -Compress)))).ToLowerInvariant())
        [IO.File]::WriteAllText($catalogPath,(ConvertTo-Json -InputObject $roundTripped -Depth 20),[Text.UTF8Encoding]::new($false))
        $cacheRoot=Join-Path $TestDrive 'cache';[void][IO.Directory]::CreateDirectory($cacheRoot)
        Copy-Item $archivePath (Join-Path $cacheRoot 'Forge_1.8.zip')

        $result=& $script:auditPath -RepositoryRoot $script:repoRoot -CatalogPath $catalogPath -CacheRoot $cacheRoot -Offline

        $result.status | Should -BeExactly 'PASS'
        $result.targets.Count | Should -Be 1
        $result.targets[0].activeDeclarationKind | Should -BeExactly 'PluginsDsl'
        $result.targets[0].activeForgeGradleSpec | Should -BeExactly '2.0.2'
    }
}
