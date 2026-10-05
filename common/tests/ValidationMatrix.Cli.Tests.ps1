Describe 'Validation matrix CLI' {
    BeforeAll { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Validation/ValidationRunner.psm1') -Force;Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Platform/Platform.psm1') -Force }
    It 'loads exact-target definitions, aggregates RuntimeRoot evidence, and writes the matrix outside source files' {
        $repoRoot=Split-Path -Parent $PSScriptRoot
        $runtime=Join-Path $TestDrive 'runtime';$null=New-Item -ItemType Directory -Path $runtime -Force
        $config=Get-Content (Join-Path $repoRoot 'config/launcher.config.example.json') -Raw|ConvertFrom-Json
        $config|Add-Member -NotePropertyName runtimeRoot -NotePropertyValue $runtime;$configPath=Join-Path $TestDrive 'launcher-config.json'
        $config|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $configPath -Encoding utf8
        $target=[pscustomobject]@{targetId='forge-1201-win';tier='Tier2';resolved=$true;minecraftId='1.20.1';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge';version='47.2.0'};overlays=@()};loaderVersion='47.2.0';toolchain='ForgeGradle';toolchainVersion='6';buildSystem='Gradle';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false};java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};observedBuildJava=$null;compilerTarget=17;runtimeRequirement=[pscustomobject]@{kind='Minimum';major=17};observedRuntimeJava=$null};sourceFixture=[pscustomobject]@{type='UserProject';source='local-project';commit='working-tree';license='User-owned';trust='UserOwned'};notes=@()}
        $targets=Join-Path $TestDrive 'targets.json';@($target)|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $targets -Encoding utf8
        $output=Join-Path $TestDrive 'matrix.json'
        $projectRoot=Join-Path $TestDrive 'runnable-project';$null=New-Item -ItemType Directory -Path (Join-Path $projectRoot 'src/main/resources') -Force;$null=New-Item -ItemType Directory -Path (Join-Path $projectRoot 'build/libs') -Force
        "plugins { id 'fabric-loom' version '1.7.4' }"|Set-Content (Join-Path $projectRoot 'build.gradle');"minecraft_version=1.20.1`nloader_version=0.15.0"|Set-Content (Join-Path $projectRoot 'gradle.properties')
        '{"schemaVersion":1,"id":"testmod","depends":{"minecraft":"~1.20.1","fabricloader":">=0.15.0"}}'|Set-Content (Join-Path $projectRoot 'src/main/resources/fabric.mod.json')
        if((Get-MmtlPlatformProvider).OS -eq 'Windows'){Set-Content (Join-Path $projectRoot 'gradlew.bat') @('@echo off','echo fresh fixture>build\libs\testmod.jar')}else{$wrapper=Join-Path $projectRoot 'gradlew';Set-Content $wrapper "#!/bin/sh`nprintf fresh-fixture > build/libs/testmod.jar`necho fixture build passed";& chmod +x $wrapper};Set-Content (Join-Path $projectRoot 'build/libs/testmod.jar') 'old fixture'
        $runnerFixture=[pscustomobject]@{type='UserProject';source='local-project';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('clean','build')}
        $runnerTarget=[pscustomobject]@{targetId='fabric-1201-windows-x64-java17';minecraftId='1.20.1';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric';version='0.15.0'};overlays=@()};loaderVersion='0.15.0';toolchain='FabricLoom';toolchainVersion='1.7.4';buildSystem='Gradle';sourceFixture=$runnerFixture;java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};compilerTarget=17;runtimeRequirement=[pscustomobject]@{kind='Minimum';major=17}}}
        Invoke-MmtlValidationBuild -ProjectPath $projectRoot -Target $runnerTarget -RuntimeRoot $runtime -TimeoutSeconds 30|Out-Null
        $cliOutput=& (Get-Command pwsh).Source -NoProfile -File ($env:MMTL_PLATFORM_ENTRYPOINT) --config-file $configPath --validation-matrix $targets --validation-output $output
        $LASTEXITCODE | Should -Be 0
        (Get-Content $output -Raw|ConvertFrom-Json).targets[0].validation.effectiveLevel | Should -Be 'RESOLVED'
        ($cliOutput|Out-String|ConvertFrom-Json).targetCount | Should -Be 1
        $summaryOutput=& (Get-Command pwsh).Source -NoProfile -File ($env:MMTL_PLATFORM_ENTRYPOINT) --config-file $configPath --validation-summary --json
        ($summaryOutput|Out-String|ConvertFrom-Json).targetCount | Should -Be 1
        ($summaryOutput|Out-String|ConvertFrom-Json).matrix.targets[0].validation.effectiveLevel | Should -Be 'BUILD_VERIFIED'
    }
}
