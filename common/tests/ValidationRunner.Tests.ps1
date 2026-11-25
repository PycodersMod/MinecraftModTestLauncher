BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:platformRoot=Split-Path -Parent $script:repoRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force -Global
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        Import-Module (Join-Path $script:platformRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
        Register-MmtlWindowsPlatform -RepositoryRoot $script:platformRoot
    }elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){
        Import-Module (Join-Path $script:platformRoot 'linux/src/LinuxPlatformProvider.psm1') -Force
        Register-MmtlLinuxPlatform -RepositoryRoot $script:platformRoot
    }else{
        Import-Module (Join-Path $script:platformRoot 'macos/src/MacOSPlatformProvider.psm1') -Force
        Register-MmtlMacOSPlatform -RepositoryRoot $script:platformRoot
    }
    Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationRunner.psm1') -Force
    function Set-TestGradleWrapper {
        param([string]$ProjectRoot,[string]$WindowsBody,[string]$UnixBody)
        if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { Set-Content -LiteralPath (Join-Path $ProjectRoot 'gradlew.bat') -Value $WindowsBody -Encoding ascii }
        else { $path=Join-Path $ProjectRoot 'gradlew';Set-Content -LiteralPath $path -Value $UnixBody -Encoding utf8;& chmod +x $path }
    }
}

Describe 'Deep validation runner safety and evidence' {
    It 'routes Forge 1.16.5 to the dedicated Gradle 6 build path' {
        $runnerModule=Get-Module -Name ValidationRunner
        $route=& $runnerModule {param($targetId) Get-MmtlValidationForgeBuildRoute -TargetId $targetId} 'Forge@1.16.5'
        $route | Should -BeExactly 'ForgeGradle6'
        $pin=[pscustomobject]@{policy=[pscustomobject]@{targetId='Forge@1.16.5';forgeGradleResolvedVersion='6.0.54'}}
        $toolchain=& $runnerModule {param($target,$project,$forgePin) Get-MmtlValidationToolchainEvidence -Target $target -Project $project -ForgeBuildPin $forgePin} ([pscustomobject]@{targetId='Forge@1.16.5'}) ([pscustomobject]@{}) $pin
        $toolchain.id | Should -BeExactly 'ForgeGradle6'
        $toolchain.version | Should -BeExactly '6.0.54'
        (& $runnerModule {param($targetId) Get-MmtlValidationForgeBuildRoute -TargetId $targetId} 'Forge@1.16.4') | Should -BeExactly 'ForgeGradle3'
        (& $runnerModule {param($targetId) Get-MmtlValidationForgeBuildRoute -TargetId $targetId} 'Forge@1.10.2') | Should -BeExactly 'ForgeGradleClassic'
    }

    It 'routes an exact ForgeGradle 6 pin to its target-scoped catalogs' {
        $runnerModule=Get-Module -Name ValidationRunner
        $pin=[pscustomobject]@{targetId='Forge@1.18.2';minecraftId='1.18.2';forgeGradleSpec='[6.0,6.2)';forgeGradleResolvedVersion='6.0.54'}
        $route=& $runnerModule {param($pin) Get-MmtlValidationForgeBuildRoute -TargetId $pin.targetId -ForgeBuildPin $pin} $pin
        $paths=& $runnerModule {param($root,$targetId) Get-MmtlValidationForgeGradle6CatalogPaths -RepositoryRoot $root -TargetId $targetId} $script:repoRoot 'Forge@1.18.2'

        $route | Should -BeExactly 'ForgeGradle6'
        $paths.buildClasspath | Should -BeExactly (Join-Path $script:repoRoot 'compatibility/forge-gradle6-build-classpath-artifacts/Forge-1.18.2.json')
        $paths.targetInputs | Should -BeExactly (Join-Path $script:repoRoot 'compatibility/forge-gradle6-target-inputs/Forge-1.18.2.json')
        $paths.runtimeArtifacts | Should -BeExactly (Join-Path $script:repoRoot 'compatibility/forge-gradle6-runtime-artifacts/Forge-1.18.2-Windows-x64.json')
    }

    It 'lets ForgeGradle 6 resolve missing exact modules from its validated local mirror' {
        $runnerModule=Get-Module -Name ValidationRunner
        $session=Join-Path $TestDrive 'fg6-local-mirror-resolution'
        $null=New-Item -ItemType Directory -Path $session -Force
        $wrapper=Join-Path $session 'gradlew.bat'
        $initScript=Join-Path $session 'local-mirror.init.gradle'
        [IO.File]::WriteAllText($wrapper,'@echo off')
        [IO.File]::WriteAllText($initScript,'')
        $provider=[pscustomobject]@{OS='Windows'}
        $prepared=[pscustomobject]@{initScriptPath=$initScript;requiresOffline=$false;additionalArguments=@()}

        $startInfo=& $runnerModule {
            param($provider,$wrapper,$session,$prepared)
            New-MmtlValidationBuildProcessStartInfo -Provider $provider -Command ([pscustomobject]@{File='gradle';Arguments=@()}) -Wrapper $wrapper -SessionRoot $session -GradleHome (Join-Path $session 'gradle-home') -Tasks @('clean','build') -ForgePrepared $prepared
        } $provider $wrapper $session $prepared

        $startInfo.Arguments | Should -Match '--init-script'
        $startInfo.Arguments | Should -Not -Match '--offline'
    }

    It 'places target Gradle homes under an explicit short root and preserves the default runtime-root layout' {
        $runnerModule=Get-Module -Name ValidationRunner
        $runtimeRoot=Join-Path $TestDrive 'a-long-runtime-root-for-mmtl-validation'
        $targetId='Forge@1.18.2'
        $targetKey=& $runnerModule {param($id) Get-MmtlValidationTargetStorageKey -TargetId $id} $targetId
        $shortRoot=Join-Path $TestDrive 'short-gradle-home'

        $shortPath=& $runnerModule {param($runtime,$id,$root) Get-MmtlValidationGradleHomePath -RuntimeRoot $runtime -TargetId $id -GradleHomeRoot $root} $runtimeRoot $targetId $shortRoot
        $defaultPath=& $runnerModule {param($runtime,$id) Get-MmtlValidationGradleHomePath -RuntimeRoot $runtime -TargetId $id} $runtimeRoot $targetId

        $shortPath | Should -BeExactly (Join-Path $shortRoot $targetKey)
        $defaultPath | Should -BeExactly (Join-Path (Join-Path (Join-Path $runtimeRoot 'validation') 'gradle-home') $targetKey)
    }

    It 'serializes ForgeGradle 6 build evidence without requiring a legacy timestamp field' {
        $runnerModule=Get-Module -Name ValidationRunner
        $pin=[pscustomobject]@{
            targetId='Forge@1.18.2';pinHash=('a'*64)
            policy=[pscustomobject]@{
                targetId='Forge@1.18.2';forgeGradleSpec='[6.0,6.2)';forgeGradleResolvedVersion='6.0.54'
                forgeGradleJarSha256=('b'*64);forgeGradlePomSha256=('c'*64);buildGradleSha256=('d'*64)
                gradleDistributionUrl='https://services.gradle.org/distributions/gradle-8.8-bin.zip'
            }
        }
        $prepared=[pscustomobject]@{
            buildClasspathCatalogHash=('e'*64);buildClasspathArtifactCount=88
            targetInputCatalogHash=('f'*64);targetInputArtifactCount=11
            runtimeArtifactCatalogHash=('1'*64);runtimeArtifactCount=109;mojangVersionHash=('2'*64)
        }
        $pinnedGradle=[pscustomobject]@{archiveSha256=('3'*64);version='8.8'}
        $evidence=& $runnerModule {
            param($pin,$prepared,$gradle)
            Get-MmtlValidationForgeGradle6SecurityEvidence -ForgeBuildPin $pin -ForgePrepared $prepared -PinnedGradle $gradle -ForgeMojangArtifacts @()
        } $pin $prepared $pinnedGradle

        $evidence.pinId | Should -BeExactly 'Forge@1.18.2'
        $evidence.forgeGradleResolvedVersion | Should -BeExactly '6.0.54'
        $evidence.buildClasspathArtifactCatalogHash | Should -BeExactly ('e'*64)
        $evidence.targetInputArtifactCount | Should -Be 11
        $evidence.runtimeArtifactCount | Should -Be 109
        $evidence.PSObject.Properties.Name | Should -Not -Contain 'forgeGradleTimestamp'
        $evidence.PSObject.Properties.Name | Should -Contain 'forgeGradleJarSha256'
        $evidence.PSObject.Properties.Name | Should -Contain 'forgeGradlePomSha256'
        $evidence.PSObject.Properties.Name | Should -Contain 'integrityFailure'
        $schema=Get-Content (Join-Path $script:repoRoot 'schemas/validation-evidence.schema.json') -Raw|ConvertFrom-Json
        $securitySchemaPath=Join-Path $TestDrive 'forge-gradle6-security-evidence.schema.json'
        [IO.File]::WriteAllText($securitySchemaPath,(ConvertTo-Json -InputObject $schema.properties.forgeSecurity -Depth 30),[Text.UTF8Encoding]::new($false))
        (Test-Json -Json (ConvertTo-Json -InputObject $evidence -Depth 30) -SchemaFile $securitySchemaPath) | Should -BeTrue
    }

    It 'does not let an explicit non-FG6 pin fall through to the legacy 1.16.5 FG6 route' {
        $runnerModule=Get-Module -Name ValidationRunner
        $pin=[pscustomobject]@{targetId='Forge@1.16.5';minecraftId='1.16.5';forgeGradleSpec='3.+';forgeGradleResolvedVersion='3.0.197'}
        $route=& $runnerModule {param($pin) Get-MmtlValidationForgeBuildRoute -TargetId $pin.targetId -ForgeBuildPin $pin} $pin

        $route | Should -BeExactly 'ForgeGradlePinned'
    }

    It 'routes the exact Forge 1.15 target through its resolved ForgeGradle 3 pin' {
        $runnerModule=Get-Module -Name ValidationRunner
        $pin=[pscustomobject]@{targetId='Forge@1.15';minecraftId='1.15';forgeGradleSpec='3.+';forgeGradleResolvedVersion='3.0.197'}
        $route=& $runnerModule {param($pin) Get-MmtlValidationForgeBuildRoute -TargetId $pin.targetId -ForgeBuildPin $pin} $pin

        $route | Should -BeExactly 'ForgeGradle3'
        (& $runnerModule {param($root,$targetId,$minecraftVersion) Get-MmtlValidationForgeGradle3RuntimeCatalogPath -RepositoryRoot $root -TargetId $targetId -MinecraftVersion $minecraftVersion} $script:repoRoot $pin.targetId $pin.minecraftId) | Should -BeExactly (Join-Path $script:repoRoot 'compatibility/forge-gradle3-runtime-artifacts/Forge-1.15.json')
        (& $runnerModule {param($targetId) Test-MmtlValidationForgeGradle3SecurityEvidenceTarget -TargetId $targetId} 'Forge@1.15') | Should -BeTrue
    }

    It 'serializes the detected toolchain object as its identity and version' {
        $runnerModule=Get-Module -Name ValidationRunner
        $target=[pscustomobject]@{targetId='NeoForge@1.21.9'}
        $project=[pscustomobject]@{Toolchain=[pscustomobject]@{id='NeoGradle';version='7.1.39'}}
        $evidence=& $runnerModule {param($target,$project) Get-MmtlValidationToolchainEvidence -Target $target -Project $project} $target $project

        $evidence.id | Should -BeExactly 'NeoGradle'
        $evidence.version | Should -BeExactly '7.1.39'
    }

    It 'selects exact Fabric BuildJava and emits strict dependency verification arguments' {
        $runnerModule=Get-Module -Name ValidationRunner
        $pin=[pscustomobject]@{policy=[pscustomobject]@{targetId='Fabric@1.21.8';buildJavaMajor=25;loomVersion='1.18.4'}}
        $target=[pscustomobject]@{targetId='Fabric@1.21.8'}
        $requirement=& $runnerModule {param($target,$fabricPin) Get-MmtlValidationBuildJavaRequirement -Target $target -FabricBuildPin $fabricPin} $target $pin
        $toolchain=& $runnerModule {param($target,$project,$fabricPin) Get-MmtlValidationToolchainEvidence -Target $target -Project $project -FabricBuildPin $fabricPin} $target ([pscustomobject]@{}) $pin
        $prepared=[pscustomobject]@{additionalArguments=@('--dependency-verification=strict')}
        $arguments=@(& $runnerModule {param($value) Get-MmtlValidationAdditionalArguments -FabricPrepared $value} $prepared)

        $requirement.kind | Should -BeExactly 'Exact'
        $requirement.major | Should -Be 25
        $requirement.source | Should -BeExactly 'PinnedFabricBuildPolicy'
        $toolchain.id | Should -BeExactly 'FabricLoom'
        $toolchain.version | Should -BeExactly '1.18.4'
        $arguments | Should -Contain '--dependency-verification=strict'
    }

    It 'places ForgeGradle workspace preparation before the pinned build task' {
        $runnerModule=Get-Module -Name ValidationRunner
        $prepared=[pscustomobject]@{preparationTasks=@('setupDecompWorkspace')}
        $batches=@(& $runnerModule {param($value) Get-MmtlValidationGradleTaskBatches -Task 'build' -Clean -ForgePrepared $value} $prepared)
        $batches.Count | Should -Be 2
        $batches[0].phase | Should -BeExactly 'clean'
        ($batches[0].tasks -join ',') | Should -BeExactly 'clean'
        $batches[1].phase | Should -BeExactly 'build'
        ($batches[1].tasks -join ',') | Should -BeExactly 'setupDecompWorkspace,build'
        $standardBatches=@(& $runnerModule {Get-MmtlValidationGradleTaskBatches -Task 'build' -Clean})
        $standardBatches.Count | Should -Be 2
        ($standardBatches[1].tasks -join ',') | Should -BeExactly 'build'
    }

    It 'does not classify Gradle unknown-property errors as network failures' {
        $runnerModule = Get-Module -Name ValidationRunner
        $classify = { param($text) Get-MmtlBuildFailureCode -Output $text }.GetNewClosure()
        $unknownProperty = & $runnerModule $classify "Could not get unknown property 'forge_version' for task ':generateModMetadata'."
        $unavailableArtifact = & $runnerModule $classify "Could not resolve all artifacts for configuration ':compileClasspath'. Could not find net.minecraftforge:forge:1.20.1-47.1.106."
        $httpFetch = & $runnerModule $classify "Could not GET 'https://maven.example.invalid/metadata.xml'."
        $unknownProperty | Should -BeExactly 'BUILD_FAILED_TOOLCHAIN'
        $unavailableArtifact | Should -BeExactly 'BUILD_FAILED_TOOLCHAIN'
        $httpFetch | Should -BeExactly 'BUILD_FAILED_NETWORK'
    }

    It 'returns no observed Java instead of throwing when PATH contains no Java executable' {
        $oldPath = $env:PATH
        $oldJavaHome = $env:JAVA_HOME
        $emptyPath = Join-Path $TestDrive 'empty-java-path'
        New-Item -ItemType Directory -Path $emptyPath -Force | Out-Null
        try {
            $env:PATH = $emptyPath
            $env:JAVA_HOME = ''
            $runnerModule = Get-Module -Name ValidationRunner
            $observed = & $runnerModule { Get-MmtlObservedBuildJava }
            $observed | Should -BeNullOrEmpty
        }
        finally {
            $env:PATH = $oldPath
            $env:JAVA_HOME = $oldJavaHome
        }
    }

    It 'enforces the pinned exact Build Java major for historical Forge builds' {
        $runnerModule=Get-Module -Name ValidationRunner
        $target=[pscustomobject]@{java=[pscustomobject]@{buildRequirement=$null}}
        $pin=[pscustomobject]@{policy=[pscustomobject]@{buildJavaMajor=8}}
        $resolve={param($t,$p) Get-MmtlValidationBuildJavaRequirement -Target $t -ForgeBuildPin $p}.GetNewClosure()
        $requirement=& $runnerModule $resolve $target $pin
        $requirement.kind | Should -BeExactly 'Exact'
        $requirement.major | Should -Be 8
        $check={param($r,$o) Test-MmtlBuildJavaRequirement -Requirement $r -Observed $o}.GetNewClosure()
        (& $runnerModule $check $requirement ([pscustomobject]@{major=8})) | Should -BeTrue
        (& $runnerModule $check $requirement ([pscustomobject]@{major=17})) | Should -BeFalse
    }

    It 'requires a selected JDK home to contain both java and javac' {
        $runnerModule=Get-Module -Name ValidationRunner
        $getProvider={Get-MmtlPlatformProvider}.GetNewClosure()
        $provider=& $runnerModule $getProvider
        $jdkHomePath=Join-Path $TestDrive 'incomplete-build-jdk';$bin=Join-Path $jdkHomePath 'bin';$null=New-Item -ItemType Directory -Path $bin -Force
        $java=Join-Path $bin $provider.JavaExecutable;$javac=Join-Path $bin $provider.JavacExecutable
        [IO.File]::WriteAllText($java,'stub');[IO.File]::WriteAllText($javac,'stub')
        $check={param($path) Test-MmtlBuildJdkHome -JavaHome $path}.GetNewClosure()
        (& $runnerModule $check $jdkHomePath) | Should -BeTrue
        Remove-Item -LiteralPath $javac -Force
        (& $runnerModule $check $jdkHomePath) | Should -BeFalse
        (& $runnerModule $check '') | Should -BeFalse
    }

    It 'reuses exact successful compatibility evidence without invoking Gradle again' {
        Import-Module (Join-Path $script:repoRoot 'src/Compatibility/EvidenceStore.psm1') -Force
        $projectRoot=Join-Path $TestDrive 'cache-reuse-project';$libs=Join-Path $projectRoot 'build/libs';$null=New-Item -ItemType Directory -Path $libs -Force
        $jar=Join-Path $libs 'example.jar';$marker=Join-Path $TestDrive 'cache-reuse-wrapper-runs.txt';$runtime=Join-Path $TestDrive 'cache-reuse-runtime'
        [IO.File]::WriteAllText($jar,'initial');
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $fixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=('a'*40);license='MIT';trust='TrustedOfficial';allowedTasks=@('build')}
        $target=[pscustomobject]@{targetId='fabric-cache-reuse';toolchain='FabricLoom';sourceFixture=$fixture}
        $identity=[pscustomobject]@{targetId=$target.targetId;universeHash=('1'*64);sourceHash=('2'*64);toolchainHash=('3'*64);targetSpecHash=('4'*64);agentHash=('5'*64)}
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody "@echo run>>`"$marker`"`n@mkdir build\libs 2>nul`n@echo rebuilt>build\libs\example.jar" -UnixBody "#!/bin/sh`necho run >> '$marker'`nmkdir -p build/libs`necho rebuilt > build/libs/example.jar"

        $first=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $runtime -AllowedOwners @('FabricMC') -TimeoutSeconds 30 -CacheIdentity $identity
        $second=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $runtime -AllowedOwners @('FabricMC') -TimeoutSeconds 30 -CacheIdentity $identity

        $first.result | Should -BeExactly 'PASSED'
        $first.cached | Should -BeFalse
        $second.cached | Should -BeTrue
        $second.cacheKey | Should -Be (Get-MmtlCompatibilityEvidenceCacheKey -Identity $identity)
        (Get-Content -LiteralPath $marker).Count | Should -Be 1
    }

    It 'observes Java from JAVA_HOME when PATH has no Java executable' -Skip:([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $oldPath = $env:PATH
        $javaHome = $env:JAVA_HOME
        $emptyPath = Join-Path $TestDrive 'java-home-only-path'
        New-Item -ItemType Directory -Path $emptyPath -Force | Out-Null
        try {
            $env:PATH = $emptyPath
            $runnerModule = Get-Module -Name ValidationRunner
            $observed = & $runnerModule { Get-MmtlObservedBuildJava }
            $observed.major | Should -BeGreaterOrEqual 17
        }
        finally {
            $env:PATH = $oldPath
        }
    }

    It 'resolves a real project probe and Adapter plan before marking the target resolved' {
        $projectRoot=Join-Path $TestDrive 'resolved-project';$null=New-Item -ItemType Directory -Path (Join-Path $projectRoot 'src/main/resources') -Force
        "plugins { id 'fabric-loom' version '1.7.4' }"|Set-Content (Join-Path $projectRoot 'build.gradle')
        "minecraft_version=1.20.1`nloader_version=0.15.0`norg.gradle.java.home=ignored"|Set-Content (Join-Path $projectRoot 'gradle.properties')
        '{"schemaVersion":1,"id":"testmod","depends":{"minecraft":"~1.20.1","fabricloader":">=0.15.0"}}'|Set-Content (Join-Path $projectRoot 'src/main/resources/fabric.mod.json')
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody '@exit /b 0' -UnixBody "#!/bin/sh`nexit 0"
        $target=[pscustomobject]@{minecraftId='1.20.1';loaderVersion='0.15.0';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric'}}}
        $resolution=Resolve-MmtlValidationProject -Path $projectRoot -Target $target
        $resolution.resolved | Should -BeTrue
        $resolution.buildPlan.isExecutablePlan | Should -BeFalse
        $resolution.project.Toolchain.id | Should -Be 'FabricLoom'
    }

    It 'binds a combined historical Forge Maven coordinate to its exact target version' {
        $projectRoot=Join-Path $script:platformRoot 'common/fixtures/forge/1.13.2-marker'
        $target=[pscustomobject]@{targetId='Forge@1.13.2';minecraftId='1.13.2';loaderVersion='1.13.2-25.0.223';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge'}}}

        $resolution=Resolve-MmtlValidationProject -Path $projectRoot -Target $target

        $resolution.resolved | Should -BeTrue
        $resolution.project.LoaderVersion | Should -BeExactly '1.13.2-25.0.223'
    }

    It 'rejects untrusted fixture before starting a process' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='fixture-one';sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/not-allowed/example';commit=('a'*40);license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('build')}}
        { Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $TestDrive -AllowedOwners @('FabricMC') } | Should -Throw '*来源所有者不在许可清单中*'
    }

    It 'blocks Forge builds without an exact trusted build pin' {
        $projectRoot=Join-Path $TestDrive 'unpinned-forge-project';$null=New-Item -ItemType Directory -Path $projectRoot -Force
        $marker=Join-Path $TestDrive 'unpinned-forge-ran.txt'
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.8';Loader='Forge';LoaderVersion='1.8-11.14.4.1577';JavaMajor=8;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='Forge@1.8';minecraftId='1.8';loaderVersion='1.8-11.14.4.1577';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge';version='1.8-11.14.4.1577'}};sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}}
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody "@echo ran>`"$marker`"" -UnixBody "#!/bin/sh`necho ran > '$marker'"

        { Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot (Join-Path $TestDrive 'unpinned-forge-runtime') -TimeoutSeconds 30 } | Should -Throw '*FORGE_BUILD_PIN_REQUIRED*'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It 'rejects arbitrary Gradle tasks from target metadata' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='fixture-one';task='build;whoami';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}}
        { Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $TestDrive } | Should -Throw '*Gradle 任务*'
    }

    It 'does not treat launch tasks as build evidence' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='user-client-task';task='runClient';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build','runClient')}}
        { Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $TestDrive } | Should -Throw '*专用启动验证器*'
    }

    It 'produces only BUILD_VERIFIED when process succeeds and a JAR is present' {
        $projectRoot=Join-Path $TestDrive 'fixture';$null=New-Item -ItemType Directory -Path (Join-Path $projectRoot 'build/libs') -Force
        $jar=Join-Path $projectRoot 'build/libs/example.jar';[IO.File]::WriteAllText($jar,'fixture jar')
        $logRoot=Join-Path $TestDrive 'logs';$null=New-Item -ItemType Directory -Path $logRoot -Force
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='user-project';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}}
        $fakeToken=('gh'+'p_')+'1234567890123456789012345678901234567890'
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody "@mkdir build\libs 2>nul`n@echo token=$fakeToken>build\libs\example.jar" -UnixBody "#!/bin/sh`nmkdir -p build/libs`necho token=$fakeToken > build/libs/example.jar"
        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $logRoot -TimeoutSeconds 30
        $result.result | Should -Be 'PASSED'
        $result.validationLevel | Should -Be 'BUILD_VERIFIED'
        $result.artifact.sha256 | Should -Match '^[a-f0-9]{64}$'
        (Get-Content $result.logPath -Raw) | Should -Not -Match 'ghp_'
    }

    It 'records the exact archive URL for a generated pinned fixture in immutable evidence' {
        $projectRoot=Join-Path $TestDrive 'generated-pinned-fixture';$null=New-Item -ItemType Directory -Path (Join-Path $projectRoot 'build/libs') -Force
        [IO.File]::WriteAllText((Join-Path $projectRoot 'build/libs/example.jar'),'fixture jar')
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.6';Loader='Quilt';LoaderVersion='0.26.3';JavaMajor=21;Wrapper='gradlew'}
        $commit='1685ed178a113092f8aa002c4f7d78181643d75b'
        $archiveUrl="https://codeload.github.com/FabricMC/fabric-example-mod/zip/$commit"
        $target=[pscustomobject]@{targetId='GeneratedPinnedFixture@1.20.6';minecraftId='1.20.6';loaderVersion='0.26.3';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='GeneratedPinnedLoaderFixture';source='https://github.com/FabricMC/fabric-example-mod';archiveUrl=$archiveUrl;commit=$commit;archiveSha256='3478254c04d8b9953a5fee21628a35d2bdf00ce2f20c567cedf0409152a4d0d5';fixtureId='MMTLFabricMarkerFixtureV1';overlaySha256='4148fe40d341a471a38fb572da502e2c0ceb706acdcf38d731974770185b0c49';overlayFiles=@([pscustomobject]@{path='build.gradle';sha256='fc6ed7f29f57267b8f0b794535f33432058fa23cb27377db3cde7a3b7c270aaa'});license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('build')}}
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody "@mkdir build\libs 2>nul`n@echo jar>build\libs\example.jar" -UnixBody "#!/bin/sh`nmkdir -p build/libs`necho jar > build/libs/example.jar"

        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot (Join-Path $TestDrive 'generated-pinned-runtime') -AllowedOwners @('FabricMC') -TimeoutSeconds 30

        $result.result | Should -BeExactly 'PASSED'
        $evidence=Get-Content -LiteralPath $result.evidencePath -Raw|ConvertFrom-Json
        $evidence.sourceFixture.archiveUrl | Should -BeExactly $archiveUrl
        $evidence.sourceFixture.archiveSha256 | Should -BeExactly '3478254c04d8b9953a5fee21628a35d2bdf00ce2f20c567cedf0409152a4d0d5'
    }

    It 'runs clean and build as separate Gradle invocations' {
        $projectRoot=Join-Path $TestDrive 'clean-build-phases';$null=New-Item -ItemType Directory -Path $projectRoot -Force
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='clean-build-phases';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('clean','build')}}
        $windowsBody=@'
@echo %*>>gradle-invocations.txt
@if "%2"=="clean" echo clean>clean-phase.marker
@if "%2"=="build" if not exist clean-phase.marker exit /b 19
@if "%2"=="build" mkdir build\libs 2>nul
@if "%2"=="build" echo jar>build\libs\example.jar
'@
        $unixBody='#!/bin/sh' + "`n" + 'printf ''%s\n'' "$*" >> gradle-invocations.txt' + "`n" + 'case " $* " in *" clean "*) touch clean-phase.marker;; esac' + "`n" + 'case " $* " in *" build "*) test -f clean-phase.marker || exit 19; mkdir -p build/libs; printf jar > build/libs/example.jar;; esac'
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody $windowsBody -UnixBody $unixBody

        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot (Join-Path $TestDrive 'clean-build-runtime') -TimeoutSeconds 30 -Clean

        $result.result | Should -BeExactly 'PASSED'
        $invocations=@(Get-Content -LiteralPath (Join-Path (Split-Path $result.evidencePath) 'session/gradle-invocations.txt'))
        $invocations.Count | Should -Be 2
        $invocations[0] | Should -Match 'clean'
        $invocations[1] | Should -Match 'build'
    }

    It 'runs builds in an MMTL managed copy and keeps source and source outputs untouched' {
        $projectRoot=Join-Path $TestDrive 'managed-copy-project';$source=Join-Path $projectRoot 'src/main/java/Example.java'
        New-Item -ItemType Directory -Path (Split-Path $source) -Force|Out-Null
        [IO.File]::WriteAllText($source,'class Example {}')
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='managed-copy';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}}
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody "@mkdir build\libs 2>nul`n@echo changed>>src\main\java\Example.java`n@echo %GRADLE_USER_HOME%>gradle-home.txt`n@echo jar>build\libs\example.jar" -UnixBody "#!/bin/sh`nmkdir -p build/libs`necho changed >> src/main/java/Example.java`nprintf '%s' `"`$GRADLE_USER_HOME`" > gradle-home.txt`necho jar > build/libs/example.jar"

        $runtime=Join-Path $TestDrive 'managed-copy-runtime'
        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $runtime -TimeoutSeconds 30

        $result.result | Should -BeExactly 'PASSED'
        [IO.File]::ReadAllText($source) | Should -BeExactly 'class Example {}'
        (Test-Path -LiteralPath (Join-Path $projectRoot 'build/libs/example.jar')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path (Split-Path $result.evidencePath) 'session/build/libs/example.jar')) | Should -BeTrue
        $gradleHome=[IO.File]::ReadAllText((Join-Path (Split-Path $result.evidencePath) 'session/gradle-home.txt')).Trim()
        $runnerModule=Get-Module -Name ValidationRunner;$storageKey=& $runnerModule {Get-MmtlValidationTargetStorageKey -TargetId 'managed-copy'}
        $gradleHome | Should -Match ([regex]::Escape((Join-Path (Join-Path $runtime 'validation/gradle-home') $storageKey)))
        (Test-Path -LiteralPath $gradleHome -PathType Container) | Should -BeTrue
    }

    It '拒绝 Wrapper 返回成功但遗留未刷新旧 JAR 的陈旧产物' {
        $projectRoot=Join-Path $TestDrive 'stale-artifact-project';$null=New-Item -ItemType Directory -Path (Join-Path $projectRoot 'build/libs') -Force
        $jar=Join-Path $projectRoot 'build/libs/example.jar';[IO.File]::WriteAllText($jar,'old artifact')
        $oldTime=[DateTime]::UtcNow.AddDays(-2);[IO.File]::SetLastWriteTimeUtc($jar,$oldTime)
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='stale-artifact';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}}
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody '@exit /b 0' -UnixBody "#!/bin/sh`nexit 0"
        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot (Join-Path $TestDrive 'stale-logs') -TimeoutSeconds 30
        $result.result | Should -Be 'FAILED'
        $result.failureCode | Should -Be 'ARTIFACT_MISSING'
        $result.validationLevel | Should -Not -Be 'BUILD_VERIFIED'
        $evidence=Get-Content -LiteralPath $result.evidencePath -Raw|ConvertFrom-Json
        $evidence.source.artifactFresh | Should -BeFalse
        $evidence.source.fingerprint | Should -Match '^sha256:[a-f0-9]{64}$'
        (Get-Content -LiteralPath $result.evidencePath -Raw) | Should -Not -Match ([regex]::Escape($projectRoot))
    }

    It '构建期间只允许 MMTL 副本变化并保留源项目不变' {
        $projectRoot=Join-Path $TestDrive 'source-change-project';$src=Join-Path $projectRoot 'src/main/java';$libs=Join-Path $projectRoot 'build/libs'
        New-Item -ItemType Directory -Path $src,$libs -Force|Out-Null
        $source=Join-Path $src 'Example.java';[IO.File]::WriteAllText($source,'class Example {}')
        $jar=Join-Path $libs 'example.jar'
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='source-change';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}}
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody "@echo changed>>src\main\java\Example.java`n@mkdir build\libs 2>nul`n@echo jar>build\libs\example.jar" -UnixBody "#!/bin/sh`necho changed >> src/main/java/Example.java`nmkdir -p build/libs`necho jar > build/libs/example.jar"
        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot (Join-Path $TestDrive 'source-change-logs') -TimeoutSeconds 30
        $result.result | Should -Be 'PASSED'
        $evidence=Get-Content -LiteralPath $result.evidencePath -Raw|ConvertFrom-Json
        $evidence.source.unchangedDuringBuild | Should -BeTrue
        [IO.File]::ReadAllText($source) | Should -BeExactly 'class Example {}'
        (Get-Content -LiteralPath (Join-Path (Split-Path $result.evidencePath) 'session/src/main/java/Example.java') -Raw) | Should -Match 'changed'
    }

    It 'records timeout as blocked evidence without claiming a build pass' {
        $projectRoot=Join-Path $TestDrive 'timeout-project';$null=New-Item -ItemType Directory -Path $projectRoot -Force
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='user-timeout';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('clean','build')}}
        $windowsBody='@echo %*>>gradle-invocations.txt'+[Environment]::NewLine+'@if "%2"=="clean" exit /b 0'+[Environment]::NewLine+'@ping -n 8 127.0.0.1 > nul'
        $unixBody='#!/bin/sh'+[Environment]::NewLine+'echo "$*" >> gradle-invocations.txt'+[Environment]::NewLine+'case " $* " in *" clean "*) exit 0;; esac'+[Environment]::NewLine+'sleep 10'
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody $windowsBody -UnixBody $unixBody
        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $TestDrive -TimeoutSeconds 1 -Clean
        $result.result | Should -Be 'BLOCKED'
        $result.failureCode | Should -Be 'BUILD_TIMEOUT'
        $result.validationLevel | Should -Be 'RESOLVED'
        $result.exitCode | Should -BeNull
        $invocations=@(Get-Content -LiteralPath (Join-Path (Split-Path $result.evidencePath) 'session/gradle-invocations.txt'))
        $invocations.Count | Should -Be 2
    }
}
