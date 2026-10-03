BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationRunner.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    function Set-TestGradleWrapper {
        param([string]$ProjectRoot,[string]$WindowsBody,[string]$UnixBody)
        if((Get-MmtlPlatformProvider).OS -eq 'Windows') { Set-Content -LiteralPath (Join-Path $ProjectRoot 'gradlew.bat') -Value $WindowsBody -Encoding ascii }
        else { $path=Join-Path $ProjectRoot 'gradlew';Set-Content -LiteralPath $path -Value $UnixBody -Encoding utf8;& chmod +x $path }
    }
}

Describe 'Deep validation runner safety and evidence' {
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

    It 'rejects untrusted fixture before starting a process' {
        $project=[pscustomobject]@{Root=$TestDrive;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='fixture-one';sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/not-allowed/example';commit=('a'*40);license='CC0-1.0';trust='TrustedOfficial';allowedTasks=@('build')}}
        { Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $TestDrive -AllowedOwners @('FabricMC') } | Should -Throw '*来源所有者不在许可清单中*'
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
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody '@echo token=ghp_1234567890123456789012345678901234567890' -UnixBody "#!/bin/sh`necho token=ghp_1234567890123456789012345678901234567890"
        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $logRoot -TimeoutSeconds 30
        $result.result | Should -Be 'PASSED'
        $result.validationLevel | Should -Be 'BUILD_VERIFIED'
        $result.artifact.sha256 | Should -Match '^[a-f0-9]{64}$'
        (Get-Content $result.logPath -Raw) | Should -Not -Match 'ghp_'
    }

    It 'records timeout as blocked evidence without claiming a build pass' {
        $projectRoot=Join-Path $TestDrive 'timeout-project';$null=New-Item -ItemType Directory -Path $projectRoot -Force
        $project=[pscustomobject]@{Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0';JavaMajor=17;Wrapper='gradlew'}
        $target=[pscustomobject]@{targetId='user-timeout';toolchain='FabricLoom';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}}
        Set-TestGradleWrapper -ProjectRoot $projectRoot -WindowsBody '@ping -n 8 127.0.0.1 > nul' -UnixBody "#!/bin/sh`nsleep 10"
        $result=Invoke-MmtlValidationBuild -Project $project -Target $target -RuntimeRoot $TestDrive -TimeoutSeconds 1
        $result.result | Should -Be 'BLOCKED'
        $result.failureCode | Should -Be 'BUILD_TIMEOUT'
        $result.validationLevel | Should -Be 'RESOLVED'
    }
}
