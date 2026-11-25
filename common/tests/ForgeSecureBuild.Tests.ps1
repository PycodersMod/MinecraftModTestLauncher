BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repoRoot 'common/src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/ForgeSecureBuild.psm1') -Force
}

Describe 'Forge secure build preparation' {
    It 'allows the pinned Gradle plugin artifact redirect host in the FG6 classpath mirror' {
        $payload=[Text.Encoding]::UTF8.GetBytes('pinned plugin artifact')
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
        $artifact=[pscustomobject]@{group='org.gradle.toolchains';artifact='foojay-resolver';version='0.7.0';file='foojay-resolver-0.7.0.jar';bytes=$payload.Length;sha256=$hash;url='https://plugins.gradle.org/m2/org/gradle/toolchains/foojay-resolver/0.7.0/foojay-resolver-0.7.0.jar'}
        $resolved=[pscustomobject]@{catalogHash=('a'*64);artifacts=@($artifact);dependencies=@()}
        $capture=[pscustomobject]@{allowedHosts=@()}
        Mock Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -ModuleName ForgeSecureBuild -MockWith {$resolved}.GetNewClosure()
        $downloadMock={param($Uri,$DestinationPath,$TimeoutSeconds,$AllowedHosts)$capture.allowedHosts=@($AllowedHosts);[IO.File]::WriteAllBytes($DestinationPath,$payload)}.GetNewClosure()
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -MockWith $downloadMock

        $mirror=Get-MmtlForgeGradle6BuildClasspathArtifactMirror -CatalogPath (Join-Path $TestDrive 'unused-catalog.json') -CacheRoot (Join-Path $TestDrive 'fg6-plugin-redirect-cache')

        $capture.allowedHosts | Should -Contain 'plugins-artifacts.gradle.org'
        $mirror.artifactCount | Should -Be 1
    }

    It 'resolves dependencies through the hash-verified local mirror without querying remote repositories' {
        $module=Get-Module -Name ForgeSecureBuild
        $scriptText=& $module { Get-MmtlForgeGradle6OfflineInitScript }
        $scriptText | Should -Match 'metadataSources \{ gradleMetadata\(\); mavenPom\(\); artifact\(\) \}'
        $scriptText | Should -Match ([regex]::Escape("new File(project.rootDir, '.mmtl-forge-secure/maven-mirror').toURI()"))
        $scriptText | Should -Match 'repositories\.clear\(\)'
        $scriptText | Should -Not -Match 'https?://(repo\.maven\.apache\.org|maven\.forge|plugins\.gradle\.org)'
    }

    It 'pins the requested exact ForgeGradle 6 version in the offline init script' {
        $module=Get-Module -Name ForgeSecureBuild
        $scriptText=& $module { Get-MmtlForgeGradle6OfflineInitScript -ForgeGradleResolvedVersion '6.0.42' -FoojayResolverVersion '0.5.0' }
        $scriptText | Should -Match 'ForgeGradle:6\.0\.42'
        $scriptText | Should -Not -Match 'ForgeGradle:6\.0\.54'
        $scriptText | Should -Match 'foojay-resolver:0\.5\.0'
        $scriptText | Should -Not -Match 'foojay-resolver:0\.7\.0'
    }

    It 'validates a target-specific FG6 classpath catalog while preserving its complete dependency pins' {
        $catalogPath=Join-Path $script:repoRoot 'compatibility/forge-gradle6-build-classpath-artifacts/Forge-1.16.5.json'
        $catalog=Get-Content $catalogPath -Raw|ConvertFrom-Json
        $catalog.targetId='Forge@1.18.2'
        $catalog.forgeVersion='1.18.2-40.3.11'
        $dependencies=@($catalog.dependencies);$artifacts=@($catalog.artifacts)
        $core=[ordered]@{schemaVersion=[int]$catalog.schemaVersion;targetId=[string]$catalog.targetId;forgeVersion=[string]$catalog.forgeVersion;forgeGradleSpec=[string]$catalog.forgeGradleSpec;forgeGradleResolvedVersion=[string]$catalog.forgeGradleResolvedVersion;gradleVersion=[string]$catalog.gradleVersion;buildJavaMajor=[int]$catalog.buildJavaMajor;artifactStatus=[string]$catalog.artifactStatus;dependencies=$dependencies;artifacts=$artifacts}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
        $tempCatalog=Join-Path $TestDrive 'Forge-1.18.2.json'
        ConvertTo-Json -InputObject $catalog -Depth 30 | Set-Content -LiteralPath $tempCatalog -Encoding utf8

        $resolved=Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $tempCatalog

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.18.2'
        $resolved.dependencies.Count | Should -Be 33
        $resolved.artifacts.Count | Should -Be 88
        $resolved.foojayResolverVersion | Should -BeExactly '0.7.0'
    }

    It 'requires the pinned ForgeGradle plugin and Foojay resolver in their direct dependency scopes' {
        $catalogPath=Join-Path $script:repoRoot 'compatibility/forge-gradle6-build-classpath-artifacts/Forge-1.16.5.json'
        $catalog=Get-Content $catalogPath -Raw|ConvertFrom-Json
        $catalog.dependencies=@($catalog.dependencies|Where-Object{[string]$_.group -cne 'net.minecraftforge.gradle' -or [string]$_.artifact -cne 'ForgeGradle'})
        $dependencies=@($catalog.dependencies);$artifacts=@($catalog.artifacts)
        $core=[ordered]@{schemaVersion=[int]$catalog.schemaVersion;targetId=[string]$catalog.targetId;forgeVersion=[string]$catalog.forgeVersion;forgeGradleSpec=[string]$catalog.forgeGradleSpec;forgeGradleResolvedVersion=[string]$catalog.forgeGradleResolvedVersion;gradleVersion=[string]$catalog.gradleVersion;buildJavaMajor=[int]$catalog.buildJavaMajor;artifactStatus=[string]$catalog.artifactStatus;dependencies=$dependencies;artifacts=$artifacts}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
        $tempCatalog=Join-Path $TestDrive 'missing-forge-plugin-dependency.json'
        ConvertTo-Json -InputObject $catalog -Depth 30 | Set-Content -LiteralPath $tempCatalog -Encoding utf8

        { Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $tempCatalog } | Should -Throw '*FORGE_GRADLE6_REQUIRED_PLUGIN_DEPENDENCY_MISSING*'
    }

    It 'resolves cached ForgeGradle 6 client and server artifacts by official SHA-1 and size' {
        $cache=Join-Path (Join-Path $TestDrive 'fg6-mojang-cache') 'mojang-artifacts';$null=New-Item -ItemType Directory -Path $cache -Force
        $clientBytes=[byte[]](1,3,5,7);$serverBytes=[byte[]](2,4,6,8,10)
        $clientSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($clientBytes)).ToLowerInvariant();$serverSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($serverBytes)).ToLowerInvariant()
        [IO.File]::WriteAllBytes((Join-Path $cache ('client-'+$clientSha1+'.jar')),$clientBytes);[IO.File]::WriteAllBytes((Join-Path $cache ('server-'+$serverSha1+'.jar')),$serverBytes)
        $pin=[pscustomobject]@{targetId='Forge@1.16.5';minecraftId='1.16.5';client=[pscustomobject]@{url='https://piston-data.mojang.com/v1/objects/'+$clientSha1+'/client.jar';sha1=$clientSha1;sizeBytes=$clientBytes.Length};server=[pscustomobject]@{url='https://piston-data.mojang.com/v1/objects/'+$serverSha1+'/server.jar';sha1=$serverSha1;sizeBytes=$serverBytes.Length}}

        $resolved=Get-MmtlForgeGradle6PinnedMojangArtifacts -Pin $pin -CacheRoot (Split-Path -Parent $cache)

        $resolved.Count | Should -Be 2
        $resolved[0].kind | Should -BeExactly 'client'
        $resolved[1].kind | Should -BeExactly 'server'
        $resolved[0].sha1 | Should -BeExactly $clientSha1
        $resolved[1].sizeBytes | Should -Be $serverBytes.Length
        $familyPin=[pscustomobject]@{targetId='Forge@1.18.2';minecraftId='1.18.2';client=$pin.client;server=$pin.server}
        $familyResolved=Get-MmtlForgeGradle6PinnedMojangArtifacts -Pin $familyPin -CacheRoot (Split-Path -Parent $cache)
        $familyResolved.Count | Should -Be 2
        $familyResolved[0].path | Should -BeExactly (Join-Path $cache ('client-'+$clientSha1+'.jar'))
        $familyResolved[1].path | Should -BeExactly (Join-Path $cache ('server-'+$serverSha1+'.jar'))
        $pin.client.sizeBytes++
        { Get-MmtlForgeGradle6PinnedMojangArtifacts -Pin $pin -CacheRoot (Split-Path -Parent $cache) } | Should -Throw '*FORGE_GRADLE6_MOJANG_CACHE_INVALID:client*'
    }

    It 'rejects FG6 catalog bindings that do not match the pin before modifying the session' {
        $session=Join-Path $TestDrive 'fg6-catalog-pin-mismatch';$null=New-Item -ItemType Directory -Path $session -Force
        $pin=[pscustomobject]@{targetId='Forge@1.16.5';minecraftId='1.16.5';forgeVersion='1.16.5-36.2.42';forgeGradleSpec='[6.0,6.2)';forgeGradleResolvedVersion='6.0.54';buildClasspathCatalogHash=('0'*64);targetInputCatalogHash=('1'*64);runtimeArtifactCatalogHash=('2'*64)}
        $params=@{SessionRoot=$session;Pin=$pin;BuildClasspathCatalogPath=(Join-Path $script:repoRoot 'compatibility/forge-gradle6-build-classpath-artifacts/Forge-1.16.5.json');BuildClasspathMirrorRoot='missing-build-mirror';TargetInputCatalogPath='missing-target.json';TargetInputMirrorRoot='missing-target-mirror';MojangVersionJsonPath='missing-version.json';RuntimeCatalogPath='missing-runtime.json';RuntimeMirrorRoot='missing-runtime-mirror';PinnedMojangArtifacts=@();GradleHome=(Join-Path $TestDrive 'fg6-gradle-home')}

        { Initialize-MmtlForgeGradle6PinnedProject @params } | Should -Throw '*FORGE_GRADLE6_BUILD_CATALOG_PIN_MISMATCH*'
        Test-Path (Join-Path $session '.mmtl-forge-secure') | Should -BeFalse
        Test-Path $params.GradleHome | Should -BeFalse
    }

    It 'accepts an exact FG6 target identity before loading its target-specific catalog' {
        $session=Join-Path $TestDrive 'fg6-family-target-catalog-route';$null=New-Item -ItemType Directory -Path $session -Force
        $pin=[pscustomobject]@{targetId='Forge@1.18.2';minecraftId='1.18.2';forgeVersion='1.18.2-40.2.17';forgeGradleSpec='[6.0,6.2)';forgeGradleResolvedVersion='6.0.54';buildClasspathCatalogHash=('a'*64);targetInputCatalogHash=('b'*64);runtimeArtifactCatalogHash=('c'*64)}
        $classpathPath=Join-Path $TestDrive 'missing-Forge-1.18.2-build-classpath.json'
        $params=@{SessionRoot=$session;Pin=$pin;BuildClasspathCatalogPath=$classpathPath;BuildClasspathMirrorRoot='missing-build-mirror';TargetInputCatalogPath='missing-target.json';TargetInputMirrorRoot='missing-target-mirror';MojangVersionJsonPath='missing-version.json';RuntimeCatalogPath='missing-runtime.json';RuntimeMirrorRoot='missing-runtime-mirror';PinnedMojangArtifacts=@();GradleHome=(Join-Path $TestDrive 'fg6-family-gradle-home')}

        { Initialize-MmtlForgeGradle6PinnedProject @params } | Should -Throw '*missing-Forge-1.18.2-build-classpath.json*'
        @(Get-ChildItem -LiteralPath $session -Force).Count | Should -Be 0
    }

    It 'verifies catalog artifacts against all FG6 mirrors before writing session files' {
        $session=Join-Path $TestDrive 'fg6-missing-mirror-artifact';$null=New-Item -ItemType Directory -Path $session -Force
        Copy-Item -Path (Join-Path $script:repoRoot 'common/fixtures/forge/1.16.5-marker/*') -Destination $session -Recurse -Force
        $pin=(Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json).targets|Where-Object targetId -ceq 'Forge@1.16.5'
        $buildMirror=Join-Path $TestDrive 'empty-fg6-build-mirror';$targetMirror=Join-Path $TestDrive 'empty-fg6-target-mirror';$runtimeMirror=Join-Path $TestDrive 'empty-fg6-runtime-mirror'
        New-Item -ItemType Directory -Path $buildMirror,$targetMirror,$runtimeMirror -Force|Out-Null
        $mojangVersionJsonPath=Join-Path $script:repoRoot "compatibility/snapshots/MojangVersions/$($pin.mojangMetadataSnapshot).bin"
        $params=@{SessionRoot=$session;Pin=$pin;BuildClasspathCatalogPath=(Join-Path $script:repoRoot 'compatibility/forge-gradle6-build-classpath-artifacts/Forge-1.16.5.json');BuildClasspathMirrorRoot=$buildMirror;TargetInputCatalogPath=(Join-Path $script:repoRoot 'compatibility/forge-gradle6-target-inputs/Forge-1.16.5.json');TargetInputMirrorRoot=$targetMirror;MojangVersionJsonPath=$mojangVersionJsonPath;RuntimeCatalogPath=(Join-Path $script:repoRoot 'compatibility/forge-gradle6-runtime-artifacts/Forge-1.16.5-Windows-x64.json');RuntimeMirrorRoot=$runtimeMirror;PinnedMojangArtifacts=@([pscustomobject]@{kind='client'},[pscustomobject]@{kind='server'});GradleHome=(Join-Path $TestDrive 'fg6-unwritten-gradle-home')}

        { Initialize-MmtlForgeGradle6PinnedProject @params } | Should -Throw '*FORGE_GRADLE6_MIRROR_ARTIFACT_MISSING*'
        Test-Path (Join-Path $session '.mmtl-forge-secure') | Should -BeFalse
        Test-Path $params.GradleHome | Should -BeFalse
    }

    It 'resolves the pinned Mojang version JSON URL from the classpath catalog when the Forge pin has no URL field' {
        $module=Get-Module -Name ForgeSecureBuild
        $pin=[pscustomobject]@{targetId='Forge@1.8.9'}
        $catalog=[pscustomobject]@{mojangVersion=[pscustomobject]@{url='https://piston-meta.mojang.com/pinned-version.json'}}
        $url=& $module {param($p,$c) Get-MmtlForgePinnedVersionJsonUrl -Pin $p -ClasspathCatalog $c} $pin $catalog
        $url | Should -BeExactly 'https://piston-meta.mojang.com/pinned-version.json'
    }

    It 'parses active ForgeGradle declarations and ignores commented fallback declarations' {
        $source=@'
/* buildscript { dependencies { classpath 'net.minecraftforge.gradle:ForgeGradle:1.2-SNAPSHOT' } } */
plugins { id 'net.minecraftforge.gradle.forge' version '2.0.2' }
buildscript { dependencies { classpath group: 'net.minecraftforge.gradle', name: 'ForgeGradle', version: '3.+', changing: true } }
'@

        $declarations=Get-MmtlForgeBuildScriptDeclarations -BuildScriptText $source

        @($declarations.classpath | ForEach-Object version) | Should -Be @('3.+')
        @($declarations.plugins | ForEach-Object version) | Should -Be @('2.0.2')
        (@($declarations.classpath.version)+@($declarations.plugins.version)) | Should -Not -Contain '1.2-SNAPSHOT'
    }

    It 'seeds the exact ForgeGradle 3 Mojang version JSON before plugin configuration without targeting nonexistent FG2 tasks' {
        $session=Join-Path $TestDrive 'forge-gradle3-mojang-seed';$null=New-Item -ItemType Directory -Path $session -Force
        $buildScript=@'
buildscript {
    repositories { mavenCentral() }
    dependencies { classpath 'net.minecraftforge.gradle:ForgeGradle:3.+' }
}
apply plugin: 'net.minecraftforge.gradle'
'@
        $buildScript+="`n"
        $buildPath=Join-Path $session 'build.gradle';[IO.File]::WriteAllText($buildPath,$buildScript,[Text.UTF8Encoding]::new($false))
        $wrapperDirectory=Join-Path $session 'gradle/wrapper';$null=New-Item -ItemType Directory -Path $wrapperDirectory -Force
        [IO.File]::WriteAllText((Join-Path $wrapperDirectory 'gradle-wrapper.properties'),'distributionUrl=https\://services.gradle.org/distributions/gradle-4.9-bin.zip')
        $clientBytes=[Text.Encoding]::UTF8.GetBytes('client-12345');$serverBytes=[Text.Encoding]::UTF8.GetBytes('server-content-12345');$clientSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($clientBytes)).ToLowerInvariant();$serverSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($serverBytes)).ToLowerInvariant()
        $clientUrl="https://piston-data.mojang.com/v1/objects/$clientSha1/client.jar";$serverUrl="https://piston-data.mojang.com/v1/objects/$serverSha1/server.jar"
        $versionJson=[ordered]@{id='1.12.2';downloads=[ordered]@{client=[ordered]@{url=$clientUrl;sha1=$clientSha1;size=$clientBytes.Length};server=[ordered]@{url=$serverUrl;sha1=$serverSha1;size=$serverBytes.Length}}}
        $versionPath=Join-Path $TestDrive 'pinned-1.12.2.json';[IO.File]::WriteAllText($versionPath,(ConvertTo-Json -InputObject $versionJson -Compress),[Text.UTF8Encoding]::new($false))
        $jar=Join-Path $TestDrive 'ForgeGradle-3.0.197.jar';$pom=Join-Path $TestDrive 'ForgeGradle-3.0.197.pom';[IO.File]::WriteAllText($jar,'pinned jar');[IO.File]::WriteAllText($pom,'<project/>')
        $pin=[pscustomobject]@{targetId='Forge@1.12.2';minecraftId='1.12.2';forgeVersion='1.12.2-14.23.5.2860';forgeGradleSpec='3.+';forgeGradleResolvedVersion='3.0.197';buildJavaMajor=8;gradleDistributionUrl='https://services.gradle.org/distributions/gradle-4.9-bin.zip';gradleDistributionSha256=('c'*64);buildGradleSha256=(Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradleJarSha256=(Get-FileHash $jar -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradlePomSha256=(Get-FileHash $pom -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradleJarUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/3.0.197/ForgeGradle-3.0.197.jar';forgeGradlePomUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/3.0.197/ForgeGradle-3.0.197.pom';mojangMetadataSnapshot=(Get-FileHash $versionPath -Algorithm SHA256).Hash.ToLowerInvariant();client=[pscustomobject]@{url=$clientUrl;sha1=$clientSha1;sizeBytes=$clientBytes.Length};server=[pscustomobject]@{url=$serverUrl;sha1=$serverSha1;sizeBytes=$serverBytes.Length}}
        $clientFile=Join-Path $TestDrive 'pinned-client.jar';$serverFile=Join-Path $TestDrive 'pinned-server.jar';[IO.File]::WriteAllBytes($clientFile,$clientBytes);[IO.File]::WriteAllBytes($serverFile,$serverBytes)
        $pinnedMojangArtifacts=@([pscustomobject]@{kind='client';path=$clientFile;sha1=$clientSha1;sizeBytes=$clientBytes.Length},[pscustomobject]@{kind='server';path=$serverFile;sha1=$serverSha1;sizeBytes=$serverBytes.Length})
        $classpathMirror=Join-Path $TestDrive 'fg3-classpath-mirror';$targetMirror=Join-Path $TestDrive 'fg3-target-mirror';$runtimeMirror=Join-Path $TestDrive 'fg3-runtime-mirror';$null=New-Item -ItemType Directory -Path $classpathMirror,$targetMirror,$runtimeMirror -Force
        $trustedPomPath=Join-Path $classpathMirror 'com/google/guava/guava/21.0/guava-21.0.pom';$runtimeJarPath=Join-Path $runtimeMirror 'com/google/guava/guava/21.0/guava-21.0.jar';[void][IO.Directory]::CreateDirectory((Split-Path -Parent $trustedPomPath));[void][IO.Directory]::CreateDirectory((Split-Path -Parent $runtimeJarPath));$trustedPom='<?xml version="1.0"?><project><description>verified source POM</description></project>';[IO.File]::WriteAllText($trustedPomPath,$trustedPom);[IO.File]::WriteAllText($runtimeJarPath,'pinned runtime jar')

        $runtimeResolutions=@([pscustomobject]@{group='cpw.mods';artifact='modlauncher';selector='0.10.+';version='0.10.0'})
        $prepared=Initialize-MmtlForgeGradle3PinnedProject -SessionRoot $session -Pin $pin -ForgeGradleJarPath $jar -ForgeGradlePomPath $pom -ClasspathMirrorRoot $classpathMirror -TargetMirrorRoot $targetMirror -RuntimeLibraryMirrorRoot $runtimeMirror -RuntimeVersionResolutions $runtimeResolutions -MojangVersionUrl 'https://piston-meta.mojang.com/pinned.json' -MojangVersionJsonPath $versionPath -PinnedMojangArtifacts $pinnedMojangArtifacts -GradleHome (Join-Path $TestDrive 'gradle-home')

        $seededPath=Join-Path $session 'build/downloadMCMeta/version.json'
        [IO.File]::ReadAllText($seededPath) | Should -BeExactly ([IO.File]::ReadAllText($versionPath))
        $script=Get-Content -LiteralPath $prepared.initScriptPath -Raw
        $script | Should -Match 'MMTL_FORGE_GRADLE3_PINNED_MOJANG_METADATA_SEEDED'
        $script | Should -Match "cpw\.mods:modlauncher:0\.10\.\+'\s*:\s*'0\.10\.0'"
        $script | Should -Not -Match 'getVersionJson|downloadClient|downloadServer'
        [IO.File]::ReadAllText((Join-Path $prepared.repositoryPath 'com/google/guava/guava/21.0/guava-21.0.pom')) | Should -BeExactly $trustedPom
    }

    It 'seeds Forge 1.13.2 Mojang client and server files under version-scoped Gradle cache paths' {
        $session=Join-Path $TestDrive 'forge-gradle3-mojang-seed-1.13.2';$null=New-Item -ItemType Directory -Path $session -Force
        $buildScript=@'
buildscript {
    repositories { mavenCentral() }
    dependencies { classpath 'net.minecraftforge.gradle:ForgeGradle:3.+' }
}
apply plugin: 'net.minecraftforge.gradle'
'@
        $buildScript+="`n";$buildPath=Join-Path $session 'build.gradle';[IO.File]::WriteAllText($buildPath,$buildScript,[Text.UTF8Encoding]::new($false))
        $wrapperDirectory=Join-Path $session 'gradle/wrapper';$null=New-Item -ItemType Directory -Path $wrapperDirectory -Force
        [IO.File]::WriteAllText((Join-Path $wrapperDirectory 'gradle-wrapper.properties'),'distributionUrl=https\://services.gradle.org/distributions/gradle-4.9-bin.zip')
        $clientBytes=[Text.Encoding]::UTF8.GetBytes('forge-1132-client');$serverBytes=[Text.Encoding]::UTF8.GetBytes('forge-1132-server');$clientSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($clientBytes)).ToLowerInvariant();$serverSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($serverBytes)).ToLowerInvariant()
        $clientUrl="https://piston-data.mojang.com/v1/objects/$clientSha1/client.jar";$serverUrl="https://piston-data.mojang.com/v1/objects/$serverSha1/server.jar"
        $versionJson=[ordered]@{id='1.13.2';downloads=[ordered]@{client=[ordered]@{url=$clientUrl;sha1=$clientSha1;size=$clientBytes.Length};server=[ordered]@{url=$serverUrl;sha1=$serverSha1;size=$serverBytes.Length}}}
        $versionPath=Join-Path $TestDrive 'pinned-1.13.2.json';[IO.File]::WriteAllText($versionPath,(ConvertTo-Json -InputObject $versionJson -Compress),[Text.UTF8Encoding]::new($false))
        $jar=Join-Path $TestDrive 'ForgeGradle-3.0.197.jar';$pom=Join-Path $TestDrive 'ForgeGradle-3.0.197.pom';[IO.File]::WriteAllText($jar,'pinned jar');[IO.File]::WriteAllText($pom,'<project/>')
        $pin=[pscustomobject]@{targetId='Forge@1.13.2';minecraftId='1.13.2';forgeVersion='1.13.2-25.0.223';forgeGradleSpec='3.+';forgeGradleResolvedVersion='3.0.197';buildJavaMajor=8;gradleDistributionUrl='https://services.gradle.org/distributions/gradle-4.9-bin.zip';gradleDistributionSha256=('c'*64);buildGradleSha256=(Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradleJarSha256=(Get-FileHash $jar -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradlePomSha256=(Get-FileHash $pom -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradleJarUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/3.0.197/ForgeGradle-3.0.197.jar';forgeGradlePomUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/3.0.197/ForgeGradle-3.0.197.pom';mojangMetadataSnapshot=(Get-FileHash $versionPath -Algorithm SHA256).Hash.ToLowerInvariant();client=[pscustomobject]@{url=$clientUrl;sha1=$clientSha1;sizeBytes=$clientBytes.Length};server=[pscustomobject]@{url=$serverUrl;sha1=$serverSha1;sizeBytes=$serverBytes.Length}}
        $clientFile=Join-Path $TestDrive 'pinned-1132-client.jar';$serverFile=Join-Path $TestDrive 'pinned-1132-server.jar';[IO.File]::WriteAllBytes($clientFile,$clientBytes);[IO.File]::WriteAllBytes($serverFile,$serverBytes)
        $pinnedMojangArtifacts=@([pscustomobject]@{kind='client';path=$clientFile;sha1=$clientSha1;sizeBytes=$clientBytes.Length},[pscustomobject]@{kind='server';path=$serverFile;sha1=$serverSha1;sizeBytes=$serverBytes.Length})
        $classpathMirror=Join-Path $TestDrive 'fg3-classpath-mirror-1132';$targetMirror=Join-Path $TestDrive 'fg3-target-mirror-1132';$null=New-Item -ItemType Directory -Path $classpathMirror,$targetMirror -Force

        $prepared=Initialize-MmtlForgeGradle3PinnedProject -SessionRoot $session -Pin $pin -ForgeGradleJarPath $jar -ForgeGradlePomPath $pom -ClasspathMirrorRoot $classpathMirror -TargetMirrorRoot $targetMirror -MojangVersionUrl 'https://piston-meta.mojang.com/pinned-1.13.2.json' -MojangVersionJsonPath $versionPath -PinnedMojangArtifacts $pinnedMojangArtifacts -GradleHome (Join-Path $TestDrive 'gradle-home-1132')

        $gradleHome=Join-Path $TestDrive 'gradle-home-1132'
        (Test-Path (Join-Path $gradleHome 'caches/minecraft/net/minecraft/minecraft/1.13.2/minecraft-1.13.2.jar')) | Should -BeTrue
        (Test-Path (Join-Path $gradleHome 'caches/minecraft/net/minecraft/minecraft_server/1.13.2/minecraft_server-1.13.2.jar')) | Should -BeTrue
        $prepared.minecraftVersion | Should -BeExactly '1.13.2'
    }

    It 'downloads and verifies the exact ForgeGradle 3 Mojang client and server pins into the isolated cache' {
        $clientBytes=[Text.Encoding]::UTF8.GetBytes('pinned-client-content');$serverBytes=[Text.Encoding]::UTF8.GetBytes('pinned-server-content')
        $clientSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($clientBytes)).ToLowerInvariant();$serverSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($serverBytes)).ToLowerInvariant()
        $pin=[pscustomobject]@{targetId='Forge@1.12.2';client=[pscustomobject]@{url="https://piston-data.mojang.com/v1/objects/$clientSha1/client.jar";sha1=$clientSha1;sizeBytes=$clientBytes.Length};server=[pscustomobject]@{url="https://piston-data.mojang.com/v1/objects/$serverSha1/server.jar";sha1=$serverSha1;sizeBytes=$serverBytes.Length}}
        $downloadMock={
            param($Uri,$DestinationPath,$TimeoutSeconds,$AllowedHosts)
            if($AllowedHosts -notcontains 'piston-data.mojang.com'){throw 'MOJANG_HOST_NOT_ALLOWLISTED'}
            [IO.File]::WriteAllBytes($DestinationPath,($(if($Uri.AbsolutePath.EndsWith('/client.jar')){$clientBytes}else{$serverBytes})))
        }.GetNewClosure()
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -MockWith $downloadMock

        $artifacts=Get-MmtlForgeGradle3PinnedMojangArtifacts -Pin $pin -CacheRoot (Join-Path $TestDrive 'fg3-mojang-cache')

        $artifacts | Should -HaveCount 2
        $artifacts | Where-Object kind -eq 'client' | ForEach-Object { (Get-FileHash $_.path -Algorithm SHA1).Hash.ToLowerInvariant() | Should -BeExactly $clientSha1 }
        $artifacts | Where-Object kind -eq 'server' | ForEach-Object { (Get-FileHash $_.path -Algorithm SHA1).Hash.ToLowerInvariant() | Should -BeExactly $serverSha1 }
    }

    It 'selects Mojang client/server artifacts for Forge 1.14.2 with exact target identity' {
        $clientBytes=[Text.Encoding]::UTF8.GetBytes('forge-1142-client-payload');$serverBytes=[Text.Encoding]::UTF8.GetBytes('forge-1142-server-payload')
        $clientSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($clientBytes)).ToLowerInvariant();$serverSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($serverBytes)).ToLowerInvariant()
        $pin=[pscustomobject]@{targetId='Forge@1.14.2';minecraftId='1.14.2';client=[pscustomobject]@{url="https://piston-data.mojang.com/v1/objects/$clientSha1/client.jar";sha1=$clientSha1;sizeBytes=$clientBytes.Length};server=[pscustomobject]@{url="https://piston-data.mojang.com/v1/objects/$serverSha1/server.jar";sha1=$serverSha1;sizeBytes=$serverBytes.Length}}
        $downloadMock={
            param($Uri,$DestinationPath,$TimeoutSeconds,$AllowedHosts)
            if($AllowedHosts -notcontains 'piston-data.mojang.com'){throw 'MOJANG_HOST_NOT_ALLOWLISTED'}
            [IO.File]::WriteAllBytes($DestinationPath,($(if($Uri.AbsolutePath.EndsWith('/client.jar')){$clientBytes}else{$serverBytes})))
        }.GetNewClosure()
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -MockWith $downloadMock

        $artifacts=Get-MmtlForgeGradle3PinnedMojangArtifacts -Pin $pin -CacheRoot (Join-Path $TestDrive 'fg3-mojang-cache-1142')

        $artifacts | Should -HaveCount 2
        $artifacts | Where-Object kind -eq 'client' | ForEach-Object { (Get-FileHash $_.path -Algorithm SHA1).Hash.ToLowerInvariant() | Should -BeExactly $clientSha1 }
        $artifacts | Where-Object kind -eq 'server' | ForEach-Object { (Get-FileHash $_.path -Algorithm SHA1).Hash.ToLowerInvariant() | Should -BeExactly $serverSha1 }
    }

    It 'selects Mojang client/server artifacts for Forge 1.14.4 with exact target identity' {
        $clientBytes=[Text.Encoding]::UTF8.GetBytes('forge-1144-client-payload');$serverBytes=[Text.Encoding]::UTF8.GetBytes('forge-1144-server-payload')
        $clientSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($clientBytes)).ToLowerInvariant();$serverSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($serverBytes)).ToLowerInvariant()
        $pin=[pscustomobject]@{targetId='Forge@1.14.4';minecraftId='1.14.4';client=[pscustomobject]@{url="https://piston-data.mojang.com/v1/objects/$clientSha1/client.jar";sha1=$clientSha1;sizeBytes=$clientBytes.Length};server=[pscustomobject]@{url="https://piston-data.mojang.com/v1/objects/$serverSha1/server.jar";sha1=$serverSha1;sizeBytes=$serverBytes.Length}}
        $downloadMock={
            param($Uri,$DestinationPath,$TimeoutSeconds,$AllowedHosts)
            if($AllowedHosts -notcontains 'piston-data.mojang.com'){throw 'MOJANG_HOST_NOT_ALLOWLISTED'}
            [IO.File]::WriteAllBytes($DestinationPath,($(if($Uri.AbsolutePath.EndsWith('/client.jar')){$clientBytes}else{$serverBytes})))
        }.GetNewClosure()
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -MockWith $downloadMock

        $artifacts=Get-MmtlForgeGradle3PinnedMojangArtifacts -Pin $pin -CacheRoot (Join-Path $TestDrive 'fg3-mojang-cache-1144')

        $artifacts | Should -HaveCount 2
        $artifacts | Where-Object kind -eq 'client' | ForEach-Object { (Get-FileHash $_.path -Algorithm SHA1).Hash.ToLowerInvariant() | Should -BeExactly $clientSha1 }
        $artifacts | Where-Object kind -eq 'server' | ForEach-Object { (Get-FileHash $_.path -Algorithm SHA1).Hash.ToLowerInvariant() | Should -BeExactly $serverSha1 }
    }

    It 'pins a Plugins DSL marker and rewrites only the isolated session copy to a hash-verified local Maven mirror' {
        $pluginId='net.minecraftforge.gradle.forge';$pluginVersion='2.0.2'
        $markerGroup='net.minecraftforge.gradle.forge';$markerArtifact='net.minecraftforge.gradle.forge.gradle.plugin'
        $implementationGroup='gradle.plugin.net.minecraftforge.gradle';$implementationArtifact='ForgeGradle'
        $markerFile="$markerArtifact-$pluginVersion.pom";$pomFile="$implementationArtifact-$pluginVersion.pom";$jarFile="$implementationArtifact-$pluginVersion.jar"
        $markerUrl="https://plugins.gradle.org/m2/$($markerGroup.Replace('.','/'))/$markerArtifact/$pluginVersion/$markerFile"
        $pomUrl="https://plugins.gradle.org/m2/$($implementationGroup.Replace('.','/'))/$implementationArtifact/$pluginVersion/$pomFile"
        $jarUrl="https://plugins.gradle.org/m2/$($implementationGroup.Replace('.','/'))/$implementationArtifact/$pluginVersion/$jarFile"
        $markerText="<project><groupId>$markerGroup</groupId><artifactId>$markerArtifact</artifactId><version>$pluginVersion</version><dependencies><dependency><groupId>$implementationGroup</groupId><artifactId>$implementationArtifact</artifactId><version>$pluginVersion</version></dependency></dependencies></project>"
        $implementationPom="<project><groupId>$implementationGroup</groupId><artifactId>$implementationArtifact</artifactId><version>$pluginVersion</version></project>"
        $jarText='synthetic-plugin-jar-bytes'
        $mcpText='{"1.8":{"snapshot":[20141130],"stable":[12]}}'
        $mcpPath=Join-Path $TestDrive 'McpMappings.json';[IO.File]::WriteAllText($mcpPath,$mcpText,[Text.UTF8Encoding]::new($false))
        $mcpRecord=[ordered]@{url='https://maven.minecraftforge.net/de/oceanlabs/mcp/versions.json';bytes=[Text.Encoding]::UTF8.GetByteCount($mcpText);sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($mcpText))).ToLowerInvariant()}
        $script:mockArtifactContents=@{$markerUrl=$markerText;$pomUrl=$implementationPom;$jarUrl=$jarText}
        $artifacts=@(
            [pscustomobject][ordered]@{group=$markerGroup;artifact=$markerArtifact;version=$pluginVersion;file=$markerFile;extension='pom';bytes=[Text.Encoding]::UTF8.GetByteCount($markerText);sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($markerText))).ToLowerInvariant();url=$markerUrl},
            [pscustomobject][ordered]@{group=$implementationGroup;artifact=$implementationArtifact;version=$pluginVersion;file=$pomFile;extension='pom';bytes=[Text.Encoding]::UTF8.GetByteCount($implementationPom);sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($implementationPom))).ToLowerInvariant();url=$pomUrl},
            [pscustomobject][ordered]@{group=$implementationGroup;artifact=$implementationArtifact;version=$pluginVersion;file=$jarFile;extension='jar';bytes=[Text.Encoding]::UTF8.GetByteCount($jarText);sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($jarText))).ToLowerInvariant();url=$jarUrl}
        ) | Sort-Object url
        $catalogCore=[pscustomobject][ordered]@{schemaVersion=1;targetId='Forge@1.8';pluginId=$pluginId;pluginVersion=$pluginVersion;implementationCoordinate="$implementationGroup`:$implementationArtifact`:$pluginVersion";sourceRepository='https://plugins.gradle.org/m2';resolver='Gradle 2.7';javaMajor=8;artifactStatus='HashesVerified';targetBuildStatus='PendingRunnerValidation';mcpVersions=$mcpRecord;mcpMapping='snapshot_20141130';forgeVersionMetadataFallback='ExactPinnedTargetOnly';artifacts=@($artifacts)}
        $catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $catalogCore -Depth 20 -Compress)))).ToLowerInvariant()
        $catalog=[ordered]@{schemaVersion=1;targetId='Forge@1.8';pluginId=$pluginId;pluginVersion=$pluginVersion;implementationCoordinate="$implementationGroup`:$implementationArtifact`:$pluginVersion";sourceRepository='https://plugins.gradle.org/m2';resolver='Gradle 2.7';javaMajor=8;artifactStatus='HashesVerified';targetBuildStatus='PendingRunnerValidation';mcpVersions=$mcpRecord;mcpMapping='snapshot_20141130';forgeVersionMetadataFallback='ExactPinnedTargetOnly';artifacts=@($artifacts);catalogHash=$catalogHash}
        $catalogPath=Join-Path $TestDrive 'plugin-artifacts.json';[IO.File]::WriteAllText($catalogPath,(ConvertTo-Json -InputObject $catalog -Depth 20),[Text.UTF8Encoding]::new($false))
        $buildArtifactText='synthetic-forge-build-artifact';$buildArtifactName='fixture-1.0.jar';$buildArtifactUrl='https://libraries.minecraft.net/example/test/fixture/1.0/fixture-1.0.jar';$buildArtifactHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($buildArtifactText))).ToLowerInvariant()
        $buildArtifact=[pscustomobject][ordered]@{group='example.test';artifact='fixture';version='1.0';file=$buildArtifactName;extension='jar';bytes=[Text.Encoding]::UTF8.GetByteCount($buildArtifactText);sha256=$buildArtifactHash;url=$buildArtifactUrl}
        $buildCore=[pscustomobject][ordered]@{schemaVersion=1;targetId='Forge@1.8';resolver='Gradle 2.7 official MDK build cache capture';artifactStatus='HashesVerified';targetBuildStatus='PendingRunnerValidation';artifacts=@($buildArtifact)}
        $buildCatalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $buildCore -Depth 20 -Compress)))).ToLowerInvariant()
        $buildCatalog=[ordered]@{schemaVersion=1;targetId='Forge@1.8';resolver=$buildCore.resolver;artifactStatus=$buildCore.artifactStatus;targetBuildStatus=$buildCore.targetBuildStatus;artifacts=@($buildArtifact);catalogHash=$buildCatalogHash}
        $buildCatalogPath=Join-Path $TestDrive 'build-artifacts.json';[IO.File]::WriteAllText($buildCatalogPath,(ConvertTo-Json -InputObject $buildCatalog -Depth 20),[Text.UTF8Encoding]::new($false))
        $buildMirrorRoot=Join-Path $TestDrive 'build-mirror/example/test/fixture/1.0';[void][IO.Directory]::CreateDirectory($buildMirrorRoot);[IO.File]::WriteAllText((Join-Path $buildMirrorRoot $buildArtifactName),$buildArtifactText,[Text.UTF8Encoding]::new($false))
        $mockArtifactContents=$script:mockArtifactContents
        $downloadMock={
            param($Uri,$DestinationPath,$TimeoutSeconds,$AllowedHosts)
            if($AllowedHosts -notcontains 'plugins.gradle.org' -or $AllowedHosts -notcontains 'plugins-artifacts.gradle.org' -or $AllowedHosts -notcontains 'repo.maven.apache.org'){throw 'PLUGIN_PORTAL_REDIRECT_HOST_NOT_ALLOWLISTED'}
            [IO.File]::WriteAllText($DestinationPath,$mockArtifactContents[$Uri.AbsoluteUri],[Text.UTF8Encoding]::new($false))
        }.GetNewClosure()
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -MockWith $downloadMock
        $cacheRoot=Join-Path $TestDrive 'plugin-cache'
        $mirror=Get-MmtlForgePluginArtifactMirror -CatalogPath $catalogPath -CacheRoot $cacheRoot

        $originalRoot=Join-Path $TestDrive 'forge-original';[void][IO.Directory]::CreateDirectory($originalRoot)
        $source=@'
plugins {
    id "net.minecraftforge.gradle.forge" version "2.0.2"
}
version = "1.0"
'@
        $originalBuildPath=Join-Path $originalRoot 'build.gradle';[IO.File]::WriteAllText($originalBuildPath,$source,[Text.UTF8Encoding]::new($false))
        $originalWrapperDirectory=Join-Path $originalRoot 'gradle/wrapper';[void][IO.Directory]::CreateDirectory($originalWrapperDirectory)
        [IO.File]::WriteAllText((Join-Path $originalWrapperDirectory 'gradle-wrapper.properties'),'distributionUrl=https\://services.gradle.org/distributions/gradle-2.7-bin.zip')
        $session=Join-Path $TestDrive 'forge-session';[void][IO.Directory]::CreateDirectory($session)
        Copy-Item -LiteralPath $originalBuildPath -Destination (Join-Path $session 'build.gradle')
        $wrapperDirectory=Join-Path $session 'gradle/wrapper';[void][IO.Directory]::CreateDirectory($wrapperDirectory)
        [IO.File]::WriteAllText((Join-Path $wrapperDirectory 'gradle-wrapper.properties'),'distributionUrl=https\://services.gradle.org/distributions/gradle-2.7-bin.zip')
        $buildPath=Join-Path $session 'build.gradle'
        $fernflowerPath=Join-Path $TestDrive 'fernflower-fixed.jar';[IO.File]::WriteAllText($fernflowerPath,'test fernflower jar',[Text.UTF8Encoding]::new($false))
        $pin=[pscustomobject]@{targetId='Forge@1.8';minecraftId='1.8';forgeVersion='1.8-11.14.4.1577';pluginVersion='2.0.2';gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.7-bin.zip';buildGradleSha256=(Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant();pluginArtifactCatalogHash=$catalogHash;buildArtifactCatalogHash=$buildCatalogHash;fernflowerArchive=[pscustomobject]@{url='https://files.minecraftforge.net/fernflower-fix-1.0.zip';sha256=('0'*64)};fernflowerJar=[pscustomobject]@{entry='fernflower.jar';bytes=(Get-Item $fernflowerPath).Length;sha256=(Get-FileHash $fernflowerPath -Algorithm SHA256).Hash.ToLowerInvariant()};versionJson=[pscustomobject]@{url='https://piston-meta.mojang.com/v1/packages/0000000000000000000000000000000000000000/1.8.json'};client=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/0000000000000000000000000000000000000000/client.jar'};server=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/1111111111111111111111111111111111111111/server.jar'}}

        $gradleHome=Join-Path $TestDrive 'gradle-home'
        $prepared=Initialize-MmtlForgePluginDslProject -SessionRoot $session -Pin $pin -ArtifactCatalogPath $catalogPath -MirrorRoot $mirror.mirrorRoot -BuildArtifactCatalogPath $buildCatalogPath -BuildMirrorRoot (Join-Path $TestDrive 'build-mirror') -GradleHome $gradleHome -McpVersionsPath $mcpPath -FernflowerJarPath $fernflowerPath

        $prepared.pluginVersion | Should -BeExactly '2.0.2'
        $prepared.catalogHash | Should -BeExactly $catalogHash
        $changed=Get-Content -LiteralPath $buildPath -Raw
        $changed | Should -Match ([regex]::Escape("classpath '$implementationGroup`:$implementationArtifact`:$pluginVersion'"))
        $changed | Should -Match ([regex]::Escape("apply plugin: '$pluginId'"))
        $changed | Should -Match ([regex]::Escape("repositories { maven { url uri('.mmtl-forge-secure/build-repository') } }"))
        $changedScript=Get-Content -LiteralPath $prepared.initScriptPath -Raw
        $changedScript | Should -Match 'MMTL_FORGE_PINNED_MOJANG_URLS_SET'
        $changedScript | Should -Match 'piston-meta\.mojang\.com'
        $changedScript | Should -Match 'MMTL_FORGE_PINNED_FERNFLOWER_SEEDED'
        $prepared.requiresOffline | Should -BeTrue
        $prepared.preparationTasks | Should -Contain 'setupDecompWorkspace'
        $prepared.additionalArguments | Should -Contain 'getAssets'
        $changed | Should -Not -Match '^plugins\s*\{'
        [IO.File]::ReadAllText($originalBuildPath) | Should -BeExactly $source
        $prepared.buildScriptSha256Before | Should -BeExactly $pin.buildGradleSha256
        [IO.File]::ReadAllText((Join-Path $gradleHome 'caches/minecraft/McpMappings.json')) | Should -BeExactly $mcpText
        [IO.File]::ReadAllText((Join-Path $gradleHome 'caches/minecraft/ForgeVersion.json')) | Should -BeExactly '{"promos":{},"number":{"1577":{"version":"11.14.4.1577","mcversion":"1.8"}}}'
        (Get-FileHash (Join-Path $gradleHome 'caches/minecraft/fernflower-fixed.jar') -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $pin.fernflowerJar.sha256
        [IO.File]::ReadAllText((Join-Path $prepared.buildRepositoryPath 'example/test/fixture/1.0/fixture-1.0.jar')) | Should -BeExactly $buildArtifactText
        $prepared.buildCatalogHash | Should -BeExactly $buildCatalogHash
        Should -Invoke Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -Times 3
    }

    It 'blocks a Forge target whose pinned toolchain inputs are still pending verification' {
        $manifest=Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json
        $pinRow=$manifest.targets[0];$pinRow.status='PendingVerification'
        $manifestPath=Join-Path $TestDrive 'pending-forge-pins.json'
        [IO.File]::WriteAllText($manifestPath,(ConvertTo-Json -InputObject $manifest -Depth 20),[Text.UTF8Encoding]::new($false))
        $target=[pscustomobject]@{targetId=$pinRow.targetId;minecraftId=$pinRow.minecraftId;loaderVersion=$pinRow.forgeVersion}
        $project=[pscustomobject]@{Loader='Forge';MinecraftVersion=$pinRow.minecraftId;LoaderVersion=$pinRow.forgeVersion}
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';trust='TrustedOfficial';source=$pinRow.sourceArchiveUrl;commit=$pinRow.sourceArchiveSha256;officialChecksumAlgorithm='SHA256';officialChecksum=$pinRow.sourceArchiveSha256}

        { Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture } | Should -Throw '*FORGE_BUILD_PIN_NOT_VERIFIED*'
    }

    It 'binds a Forge build pin to the exact Minecraft, Forge, and official archive identity' {
        $pinRow=(Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json).targets[0]
        $target=[pscustomobject]@{targetId=$pinRow.targetId;minecraftId=$pinRow.minecraftId;loaderVersion=$pinRow.forgeVersion}
        $project=[pscustomobject]@{Loader='Forge';MinecraftVersion=$pinRow.minecraftId;LoaderVersion=$pinRow.forgeVersion}
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';trust='TrustedOfficial';source=$pinRow.sourceArchiveUrl;commit=$pinRow.sourceArchiveSha256;officialChecksumAlgorithm='SHA256';officialChecksum=$pinRow.sourceArchiveSha256}
        $manifestPath=Join-Path $script:repoRoot 'compatibility/forge-build-pins.json'

        $resolved=Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture

        $resolved.policy.targetId | Should -BeExactly 'Forge@1.7.10'
        $resolved.pinHash | Should -Match '^[a-f0-9]{64}$'
        $fixture.commit='0'*64
        { Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture } | Should -Throw '*FORGE_BUILD_PIN_SOURCE_IDENTITY_MISMATCH*'
    }

    It 'binds an MMTL-owned Forge marker overlay to exact fixture file hashes' {
        $pinRow=(Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json).targets[0]
        $root=Join-Path $TestDrive 'owned-marker-overlay';$null=New-Item -ItemType Directory -Path $root -Force
        $overlayPath=Join-Path $root 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java';$null=New-Item -ItemType Directory -Path (Split-Path -Parent $overlayPath) -Force
        [IO.File]::WriteAllText($overlayPath,'@Mod public final class MmtlMarkerMod {}')
        $overlayFiles=@([pscustomobject]@{path='src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java';sha256=(Get-FileHash $overlayPath -Algorithm SHA256).Hash.ToLowerInvariant()})
        $overlayHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($overlayFiles[0].path+'|'+$overlayFiles[0].sha256))).ToLowerInvariant()
        $fixture=[pscustomobject]@{type='OfficialArtifactFixture';trust='TrustedOfficial';source=$pinRow.sourceArchiveUrl;commit=$pinRow.sourceArchiveSha256;officialChecksumAlgorithm='SHA256';officialChecksum=$pinRow.sourceArchiveSha256;fixtureId='MMTLForgeMarkerFixtureV1';overlaySha256=$overlayHash;overlayFiles=$overlayFiles}
        $target=[pscustomobject]@{targetId=$pinRow.targetId;minecraftId=$pinRow.minecraftId;loaderVersion=$pinRow.forgeVersion}
        $project=[pscustomobject]@{Root=$root;Loader='Forge';MinecraftVersion=$pinRow.minecraftId;LoaderVersion=$pinRow.forgeVersion}
        $manifestPath=Join-Path $script:repoRoot 'compatibility/forge-build-pins.json'

        (Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture).policy.targetId | Should -BeExactly 'Forge@1.7.10'
        [IO.File]::AppendAllText($overlayPath,'changed')
        { Get-MmtlForgeBuildPin -ManifestPath $manifestPath -Target $target -Project $project -Fixture $fixture } | Should -Throw '*FORGE_FIXTURE_OVERLAY_FILE_HASH_MISMATCH*'
    }

    It 'downloads pinned plugin artifacts through HTTPS and reuses only checksum-matching cache entries' {
        $jarText='mocked-pinned-jar';$pomText='<project><groupId>net.minecraftforge.gradle</groupId><artifactId>ForgeGradle</artifactId><version>1.2-SNAPSHOT</version></project>'
        $pin=[pscustomobject]@{
            forgeGradleSpec='1.2-SNAPSHOT';forgeGradleTimestamp='1.2-20211118.175523-305';buildJavaMajor=8;buildGradleSha256=('a'*64)
            forgeGradleJarSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($jarText))).ToLowerInvariant()
            forgeGradlePomSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($pomText))).ToLowerInvariant()
            forgeGradleJarUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/1.2-SNAPSHOT/ForgeGradle-1.2-20211118.175523-305.jar'
            forgeGradlePomUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/1.2-SNAPSHOT/ForgeGradle-1.2-20211118.175523-305.pom'
            gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.0-bin.zip';gradleDistributionSha256=('c'*64)
            client=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/'+('a'*40)+'/client.jar';sha1=('a'*40);sizeBytes=10}
            server=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/'+('b'*40)+'/server.jar';sha1=('b'*40);sizeBytes=20}
        }
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild {
            param($Uri,$DestinationPath,$TimeoutSeconds)
            $content=if($Uri.AbsoluteUri.EndsWith('.jar')){$jarText}else{$pomText}
            [IO.File]::WriteAllText($DestinationPath,$content,[Text.UTF8Encoding]::new($false))
        }

        $first=Get-MmtlForgePinnedArtifacts -Pin $pin -CacheRoot (Join-Path $TestDrive 'pinned-cache')
        $second=Get-MmtlForgePinnedArtifacts -Pin $pin -CacheRoot (Join-Path $TestDrive 'pinned-cache')

        $first.jarSha256 | Should -BeExactly $pin.forgeGradleJarSha256
        $first.pomSha256 | Should -BeExactly $pin.forgeGradlePomSha256
        $second.jarPath | Should -BeExactly $first.jarPath
        Should -Invoke Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -Times 2
    }

    It 'downloads and verifies the exact pinned Gradle distribution before extracting it' {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $pin=(Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json).targets[0]
        $sourceArchive=Join-Path $TestDrive 'synthetic-gradle-2.0.zip'
        $archive=[IO.Compression.ZipFile]::Open($sourceArchive,[IO.Compression.ZipArchiveMode]::Create)
        $hostIsWindows=[Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows);$gradleEntry=if($hostIsWindows){'gradle-2.0/bin/gradle.bat'}else{'gradle-2.0/bin/gradle'}
        try{$entry=$archive.CreateEntry($gradleEntry);$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('pinned')}finally{$writer.Dispose()}}finally{$archive.Dispose()}
        $pin.gradleDistributionSha256=(Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        $downloadMock={
            param($Uri,$DestinationPath,$TimeoutSeconds,$AllowedHosts)
            [IO.File]::Copy($sourceArchive,$DestinationPath)
        }.GetNewClosure()
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -MockWith $downloadMock
        $result=Get-MmtlForgePinnedGradle -Pin $pin -CacheRoot (Join-Path $TestDrive 'gradle-cache')
        $result.version | Should -BeExactly '2.0'
        Test-Path -LiteralPath $result.executablePath -PathType Leaf | Should -BeTrue
        $result.archiveSha256 | Should -BeExactly $pin.gradleDistributionSha256
        Should -Invoke Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -Times 1
    }

    It 'rejects a mismatched Gradle distribution checksum without extracting the archive' {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $pin=(Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json).targets[0]
        $pin.gradleDistributionSha256='0'*64
        $downloadMock={
            param($Uri,$DestinationPath,$TimeoutSeconds,$AllowedHosts)
            [IO.File]::WriteAllText($DestinationPath,'not the pinned archive')
        }.GetNewClosure()
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -MockWith $downloadMock
        $cache=Join-Path $TestDrive 'bad-gradle-cache'
        { Get-MmtlForgePinnedGradle -Pin $pin -CacheRoot $cache } | Should -Throw '*FORGE_GRADLE_DISTRIBUTION_DOWNLOAD_HASH_MISMATCH*'
        Test-Path (Join-Path $cache 'gradle-2.0') | Should -BeFalse
    }

    It 'extracts a pinned Gradle all distribution from a preverified cache' {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $pin=(Get-Content (Join-Path $script:repoRoot 'compatibility/forge-build-pins.json') -Raw|ConvertFrom-Json).targets[0]
        $sourceArchive=Join-Path $TestDrive 'synthetic-gradle-8.4-all.zip'
        $archive=[IO.Compression.ZipFile]::Open($sourceArchive,[IO.Compression.ZipArchiveMode]::Create)
        $hostIsWindows=[Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows);$gradleEntry=if($hostIsWindows){'gradle-8.4/bin/gradle.bat'}else{'gradle-8.4/bin/gradle'}
        try{$entry=$archive.CreateEntry($gradleEntry);$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('pinned')}finally{$writer.Dispose()}}finally{$archive.Dispose()}
        $pin.gradleDistributionUrl='https://services.gradle.org/distributions/gradle-8.4-all.zip'
        $pin.gradleDistributionSha256=(Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        $cache=Join-Path $TestDrive 'gradle-all-cache';$null=New-Item -ItemType Directory -Path $cache -Force
        [IO.File]::Copy($sourceArchive,(Join-Path $cache ('gradle-'+$pin.gradleDistributionSha256+'.zip')))

        $result=Get-MmtlForgePinnedGradle -Pin $pin -CacheRoot $cache

        $result.version | Should -BeExactly '8.4'
        $expectedExecutable=Join-Path $cache $gradleEntry
        $result.executablePath | Should -BeExactly $expectedExecutable
    }

    It 'pins the Maven snapshot locally and rewrites legacy Mojang URLs only in the managed copy' {
        $session=Join-Path $TestDrive 'session';$null=New-Item -ItemType Directory -Path $session -Force
        $buildScript=@'
buildscript {
    repositories {
        mavenCentral()
        maven {
            name = "forge"
            url = "http://files.minecraftforge.net/maven"
        }
    }
    dependencies { classpath 'net.minecraftforge.gradle:ForgeGradle:1.2-SNAPSHOT' }
}
'@
        $buildPath=Join-Path $session 'build.gradle';[IO.File]::WriteAllText($buildPath,$buildScript,[Text.UTF8Encoding]::new($false))
        $wrapperDirectory=Join-Path $session 'gradle/wrapper';$null=New-Item -ItemType Directory -Path $wrapperDirectory -Force
        [IO.File]::WriteAllText((Join-Path $wrapperDirectory 'gradle-wrapper.properties'),'distributionUrl=https\://services.gradle.org/distributions/gradle-2.0-bin.zip')
        $jar=Join-Path $TestDrive 'ForgeGradle.jar';$pom=Join-Path $TestDrive 'ForgeGradle.pom'
        [IO.File]::WriteAllText($jar,'pinned-jar');[IO.File]::WriteAllText($pom,'<project><groupId>net.minecraftforge.gradle</groupId><artifactId>ForgeGradle</artifactId><version>1.2-SNAPSHOT</version></project>')
        $pin=[pscustomobject]@{
            targetId='Forge@1.7.10';minecraftId='1.7.10';forgeVersion='1.7.10-10.13.4.1614-1.7.10';forgeGradleSpec='1.2-SNAPSHOT';forgeGradleTimestamp='1.2-20211118.175523-305';buildJavaMajor=8;gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.0-bin.zip';gradleDistributionSha256=('a'*64)
            buildGradleSha256=(Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradleJarSha256=(Get-FileHash $jar -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradlePomSha256=(Get-FileHash $pom -Algorithm SHA256).Hash.ToLowerInvariant()
            forgeGradleJarUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/1.2-SNAPSHOT/ForgeGradle-1.2-20211118.175523-305.jar';forgeGradlePomUrl='https://maven.minecraftforge.net/net/minecraftforge/gradle/ForgeGradle/1.2-SNAPSHOT/ForgeGradle-1.2-20211118.175523-305.pom'
            client=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/e80d9b3bf5085002218d4be59e668bac718abbc6/client.jar';sha1='e80d9b3bf5085002218d4be59e668bac718abbc6';sizeBytes=5256245}
            server=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/952438ac4e01b4d115c5fc38f891710c4941df29/server.jar';sha1='952438ac4e01b4d115c5fc38f891710c4941df29';sizeBytes=9605030}
        }

        $prepared=Initialize-MmtlForgePinnedProject -SessionRoot $session -Pin $pin -ForgeGradleJarPath $jar -ForgeGradlePomPath $pom

        $prepared.PSObject.Properties['requiresOffline'] | Should -Not -BeNullOrEmpty
        $prepared.requiresOffline | Should -BeFalse
        $metadata=Get-Content -LiteralPath (Join-Path $prepared.repositoryPath 'net/minecraftforge/gradle/ForgeGradle/1.2-SNAPSHOT/maven-metadata.xml') -Raw
        $metadata | Should -Match '<value>1\.2-20211118\.175523-305</value>'
        $metadata | Should -Match '<timestamp>20211118\.175523</timestamp>'
        (Get-FileHash $prepared.pluginJarPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $pin.forgeGradleJarSha256
        $changed=Get-Content -LiteralPath $buildPath -Raw
        $changed | Should -Match ([regex]::Escape("url = `"https://maven.minecraftforge.net`""))
        $changed | Should -Match ([regex]::Escape("maven { url uri('.mmtl-forge-secure/repository') }"))
        $changed | Should -Match ([regex]::Escape("maven { url 'https://repo.maven.apache.org/maven2' }"))
        $script=Get-Content -LiteralPath $prepared.initScriptPath -Raw
        $script | Should -Match ([regex]::Escape("getConstructor(org.gradle.api.Project, String)"))
        $script | Should -Match ([regex]::Escape($pin.client.url))
        $script | Should -Match ([regex]::Escape($pin.server.url))
        $script | Should -Match 'DelayedString'
        $script | Should -Not -Match "setMmtlDownloadUrl\('getVersionJson'"
        $script | Should -Match ([regex]::Escape("MMTL_FORGE_PINNED_MOJANG_URLS_SET"))
        $script | Should -Not -Match '\.output\s*='
        [IO.File]::WriteAllText((Join-Path $wrapperDirectory 'gradle-wrapper.properties'),'distributionUrl=https\://services.gradle.org/distributions/gradle-2.1-bin.zip')
        [IO.File]::WriteAllText($buildPath,$buildScript,[Text.UTF8Encoding]::new($false))
        { Initialize-MmtlForgePinnedProject -SessionRoot $session -Pin $pin -ForgeGradleJarPath $jar -ForgeGradlePomPath $pom } | Should -Throw '*FORGE_GRADLE_WRAPPER_DISTRIBUTION_MISMATCH*'
    }

    It 'normalizes the pinned Forge Maven repository whether the official MDK uses HTTP or HTTPS' {
        $module=Get-Module -Name ForgeSecureBuild
        $source=@'
buildscript {
    repositories {
        maven { url = "https://files.minecraftforge.net/maven" }
        mavenCentral()
    }
}
'@
        $rewritten=& $module { param($text) ConvertTo-MmtlForgeSecureBuildScript -SourceText $text } $source

        $rewritten | Should -Match 'https://maven\.minecraftforge\.net'
        $rewritten | Should -Not -Match 'https://files\.minecraftforge\.net/maven'
        $rewritten | Should -Match "maven \{ url uri\('\.mmtl-forge-secure/repository'\) \}"
        $rewritten | Should -Match "maven \{ url 'https://repo\.maven\.apache\.org/maven2' \}"
    }

    It 'rejects an active ForgeGradle plugin declaration that differs from the pinned coordinate' {
        $session=Join-Path $TestDrive 'plugin-coordinate-mismatch';$null=New-Item -ItemType Directory -Path $session -Force
        $buildScript=@'
plugins { id "net.minecraftforge.gradle.forge" version "2.0.2" }
buildscript {
    repositories { maven { name = "forge"; url = "http://files.minecraftforge.net/maven" } }
    dependencies { classpath 'net.minecraftforge.gradle:ForgeGradle:1.2-SNAPSHOT' }
}
'@
        $buildPath=Join-Path $session 'build.gradle';[IO.File]::WriteAllText($buildPath,$buildScript,[Text.UTF8Encoding]::new($false))
        $wrapperDirectory=Join-Path $session 'gradle/wrapper';$null=New-Item -ItemType Directory -Path $wrapperDirectory -Force
        [IO.File]::WriteAllText((Join-Path $wrapperDirectory 'gradle-wrapper.properties'),'distributionUrl=https\://services.gradle.org/distributions/gradle-2.0-bin.zip')
        $jar=Join-Path $TestDrive 'coordinate-mismatch.jar';$pom=Join-Path $TestDrive 'coordinate-mismatch.pom'
        [IO.File]::WriteAllText($jar,'pinned-jar');[IO.File]::WriteAllText($pom,'<project><groupId>net.minecraftforge.gradle</groupId><artifactId>ForgeGradle</artifactId><version>1.2-SNAPSHOT</version></project>')
        $pin=[pscustomobject]@{targetId='Forge@1.7.10';minecraftId='1.7.10';forgeGradleSpec='1.2-SNAPSHOT';forgeGradleTimestamp='1.2-20211118.175523-305';buildJavaMajor=8;buildGradleSha256=(Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradleJarSha256=(Get-FileHash $jar -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradlePomSha256=(Get-FileHash $pom -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradleJarUrl='https://maven.minecraftforge.net/pinned.jar';forgeGradlePomUrl='https://maven.minecraftforge.net/pinned.pom';gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.0-bin.zip';gradleDistributionSha256=('a'*64);client=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/'+('a'*40)+'/client.jar';sha1=('a'*40);sizeBytes=10};server=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/'+('b'*40)+'/server.jar';sha1=('b'*40);sizeBytes=20}}

        { Initialize-MmtlForgePinnedProject -SessionRoot $session -Pin $pin -ForgeGradleJarPath $jar -ForgeGradlePomPath $pom } | Should -Throw '*FORGE_BUILD_GRADLE_PLUGIN_SPEC_MISMATCH*'
    }

    It 'requires the Forge tasks to produce Mojang files with official SHA-1 and sizes' {
        $directory=Join-Path $TestDrive 'mojang-downloads';$null=New-Item -ItemType Directory -Path $directory -Force
        $clientPath=Join-Path $directory 'client.jar';$serverPath=Join-Path $directory 'server.jar'
        [IO.File]::WriteAllBytes($clientPath,[byte[]](1,2,3,4));[IO.File]::WriteAllBytes($serverPath,[byte[]](5,6,7))
        $prepared=[pscustomobject]@{mojangDirectory=$directory;minecraftVersion='1.7.10';client=[pscustomobject]@{sha1=(Get-FileHash $clientPath -Algorithm SHA1).Hash.ToLowerInvariant();sizeBytes=4};server=[pscustomobject]@{sha1=(Get-FileHash $serverPath -Algorithm SHA1).Hash.ToLowerInvariant();sizeBytes=3}}

        $verified=@(Test-MmtlForgeMojangArtifacts -PreparedProject $prepared)
        $verified.Count | Should -Be 2
        $verified[0].kind | Should -BeExactly 'client'
        $prepared.server.sha1='0'*40
        { Test-MmtlForgeMojangArtifacts -PreparedProject $prepared } | Should -Throw '*FORGE_MOJANG_ARTIFACT_SHA1_MISMATCH:server*'
    }

    It 'rejects source drift or a plugin artifact hash mismatch before modifying the session' {
        $session=Join-Path $TestDrive 'reject-session';$null=New-Item -ItemType Directory -Path $session -Force
        $buildPath=Join-Path $session 'build.gradle';[IO.File]::WriteAllText($buildPath,'buildscript { repositories { } }')
        $jar=Join-Path $TestDrive 'bad.jar';$pom=Join-Path $TestDrive 'bad.pom';[IO.File]::WriteAllText($jar,'jar');[IO.File]::WriteAllText($pom,'pom')
        $pin=[pscustomobject]@{targetId='Forge@1.7.10';forgeGradleSpec='1.2-SNAPSHOT';forgeGradleTimestamp='1.2-20211118.175523-305';buildJavaMajor=8;buildGradleSha256=('0'*64);forgeGradleJarSha256=('0'*64);forgeGradlePomSha256=(Get-FileHash $pom -Algorithm SHA256).Hash.ToLowerInvariant();forgeGradleJarUrl='https://maven.minecraftforge.net/pinned.jar';forgeGradlePomUrl='https://maven.minecraftforge.net/pinned.pom';gradleDistributionUrl='https://services.gradle.org/distributions/gradle-2.0-bin.zip';gradleDistributionSha256=('c'*64);client=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/'+('a'*40)+'/client.jar';sha1=('a'*40);sizeBytes=10};server=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/'+('b'*40)+'/server.jar';sha1=('b'*40);sizeBytes=20}}

        { Initialize-MmtlForgePinnedProject -SessionRoot $session -Pin $pin -ForgeGradleJarPath $jar -ForgeGradlePomPath $pom } | Should -Throw '*FORGE_BUILD_GRADLE_HASH_MISMATCH*'
        Test-Path (Join-Path $session '.mmtl-forge-secure') | Should -BeFalse
    }

    It 'accepts only a hash-verified build.gradle fixture overlay while retaining the source archive pin' {
        $fixtureRoot=Join-Path $TestDrive 'forge-overlay';$null=New-Item -ItemType Directory -Path $fixtureRoot -Force
        $overlayPath=Join-Path $fixtureRoot 'build.gradle';$overlayText='buildscript { dependencies { classpath "net.minecraftforge.gradle:ForgeGradle:2.1-SNAPSHOT" } }'
        [IO.File]::WriteAllText($overlayPath,$overlayText,[Text.UTF8Encoding]::new($false))
        $overlayHash=(Get-FileHash -LiteralPath $overlayPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $overlayRecord=[pscustomobject]@{path='build.gradle';sha256=$overlayHash}
        $records=@('build.gradle|'+$overlayHash);$overlaySha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records -join "`n")))).ToLowerInvariant()
        $fixture=[pscustomobject]@{fixtureId='MMTLForgeMarkerFixtureV1';overlaySha256=$overlaySha256;overlayFiles=@($overlayRecord)}
        $pin=[pscustomobject]@{buildGradleSha256=('a'*64)}
        $module=Get-Module -Name ForgeSecureBuild

        $expected=& $module { param($root,$sourcePin,$sourceFixture) Get-MmtlForgeExpectedBuildGradleSha256 -FixtureOverlayRoot $root -Pin $sourcePin -Fixture $sourceFixture } $fixtureRoot $pin $fixture
        $expected | Should -BeExactly $overlayHash

        [IO.File]::WriteAllText($overlayPath,$overlayText+' // tampered',[Text.UTF8Encoding]::new($false))
        { & $module { param($root,$sourcePin,$sourceFixture) Get-MmtlForgeExpectedBuildGradleSha256 -FixtureOverlayRoot $root -Pin $sourcePin -Fixture $sourceFixture } $fixtureRoot $pin $fixture } | Should -Throw '*FORGE_FIXTURE_OVERLAY_FILE_HASH_MISMATCH*'
    }
}
