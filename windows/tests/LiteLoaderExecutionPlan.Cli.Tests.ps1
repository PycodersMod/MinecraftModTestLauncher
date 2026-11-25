BeforeAll {
    $script:repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repoRoot 'common/src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
    Register-MmtlWindowsPlatform -RepositoryRoot $script:repoRoot
    $script:pwsh=(Get-Command pwsh -ErrorAction Stop).Source
    $script:launcher=Join-Path $script:repoRoot 'windows/launcher.ps1'
    $script:projectRoot=Join-Path $TestDrive 'liteloader-project/1.7.10'
    New-Item -ItemType Directory -Path (Join-Path $script:projectRoot 'src/main/resources'),(Join-Path $script:projectRoot 'gradle/wrapper') -Force|Out-Null
    'plugins { id "com.mumfrey:liteloader" }'|Set-Content -LiteralPath (Join-Path $script:projectRoot 'build.gradle')
    "minecraft_version=1.7.10`nliteloader_version=1.7.10_04`nmod_id=liteloader_fixture"|Set-Content -LiteralPath (Join-Path $script:projectRoot 'gradle.properties')
    '{"name":"LiteLoader Fixture","mcversion":"1.7.10","revision":1}'|Set-Content -LiteralPath (Join-Path $script:projectRoot 'src/main/resources/litemod.json')
    $javaHome=Join-Path $TestDrive 'jdk-17';New-Item -ItemType Directory -Path (Join-Path $javaHome 'bin') -Force|Out-Null
    New-Item -ItemType File -Path (Join-Path $javaHome 'bin/java.exe') -Force|Out-Null
    @('JAVA_VERSION="17.0.19"','IMPLEMENTOR="Test Vendor"','OS_ARCH="amd64"','OS_NAME="Windows"')|Set-Content -LiteralPath (Join-Path $javaHome 'release')
    $script:runtimeRoot=Join-Path $TestDrive 'liteloader-runtime-not-created'
    $script:configPath=Join-Path $TestDrive 'liteloader-launcher.config.json'
    $config=[ordered]@{configVersion=2;defaultProfile='fixture';runtimeRoot=$script:runtimeRoot;javaHomes=@{'17'=$javaHome};javaHomesByPlatform=@{Windows=@{};Linux=@{};MacOS=@{}};profiles=@{fixture=@{project=$script:projectRoot;linkedProjects=@();mode='Single';players=1;hostUsername='Dev';clientPrefix='Dev_';autoBuild=$true;cleanBuild=$false;acceptEula=$false;port='Auto';memoryMb=0;hostMemoryMb=0;clientMemoryMb=0;serverMemoryMb=0;jvmArgs=@();gameArgs=@();extraMods=@();resolution='1280x720';guiScale='Auto';windowLayout='None'}}}
    $config|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $script:configPath
}

Describe 'LiteLoader Execution Plan CLI integration' {
    It 'includes pinned exact-target runtime dependencies without claiming LaunchReady' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --plan --json 2>&1|Out-String

        $LASTEXITCODE|Should -Be 0
        $plan=$output|ConvertFrom-Json -ErrorAction Stop
        $plan.project.loader.id|Should -BeExactly 'LiteLoader'
        $plan.project.minecraftId|Should -BeExactly '1.7.10'
        $plan.project.loader.version|Should -BeExactly '1.7.10_04'
        $plan.runtime.loaderLaunchPlan.targetId|Should -BeExactly 'LiteLoader@1.7.10'
        $plan.runtime.loaderLaunchPlan.loaderArtifactSha256|Should -BeExactly 'a30e91e7abfcf482fd740893a207e2e00eb6a24d3909bfa2939a13b3c1703b7b'
        @($plan.runtime.loaderLaunchPlan.libraries).Count|Should -Be 3
        $plan.runtimeJava.requirement.major|Should -Be 8
        $plan.runtimeJava.requirement.source|Should -BeExactly 'MojangVersionMetadata'
        $plan.capabilityGates.launchReady|Should -BeFalse
        Test-Path -LiteralPath $script:runtimeRoot|Should -BeFalse
    }
}
