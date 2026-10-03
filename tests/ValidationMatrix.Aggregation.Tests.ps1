BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationMatrix.psm1') -Force
}

Describe 'Evidence-driven validation matrix aggregation' {
    It 'aggregates only evidence for an exact target ID and uses the strongest verified level' {
        $target=[pscustomobject]@{targetId='forge-1201-win';tier='Tier2';resolved=$true;minecraftId='1.20.1';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge';version='47.2.0'};overlays=@()};loaderVersion='47.2.0';toolchain='ForgeGradle';toolchainVersion='6.0';buildSystem='Gradle';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false};java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};observedBuildJava=$null;compilerTarget=17;runtimeRequirement=[pscustomobject]@{kind='Minimum';major=17};observedRuntimeJava=$null};sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/MinecraftForge/MinecraftForge';commit=('a'*40);license='LGPL-2.1';trust='TrustedOfficial'};notes=@()}
        $ev=[pscustomobject]@{targetId='forge-1201-win';minecraftId='1.20.1';loaderId='Forge';loaderVersion='47.2.0';runId='r1';startedAt=[DateTimeOffset]::UtcNow.ToString('o');endedAt=[DateTimeOffset]::UtcNow.ToString('o');validationLevel='BUILD_VERIFIED';result='PASSED';platform=$target.platform;java=[pscustomobject]@{buildRequirement=$null;observedBuildJava=$null;compilerTarget=17;runtimeRequirement=$null;observedRuntimeJava=$null};toolchain=[pscustomobject]@{id='ForgeGradle';version='6'};buildSystem=[pscustomobject]@{id='Gradle';version='8'};sourceFixture=$target.sourceFixture;logs=@();artifact=$null;process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@()}
        $matrix=New-MmtlValidationMatrix -Targets @($target) -Evidence @($ev)
        $matrix.matrix.targets[0].validation.effectiveLevel | Should -Be 'BUILD_VERIFIED'
        $matrix.matrix.targets[0].validation.build | Should -BeTrue
        $matrix.matrix.targets[0].validation.client | Should -BeFalse
        $matrix.matrix.targets[0].evidence.runIds | Should -Contain 'r1'
    }

    It 'rejects evidence that claims a higher level without required stage-specific proof' {
        $target=[pscustomobject]@{targetId='client-1211-win';tier='Tier2';resolved=$true;minecraftId='1.21.1';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric';version='0.16'};overlays=@()};loaderVersion='0.16';toolchain='FabricLoom';toolchainVersion='1';buildSystem='Gradle';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false};java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=21};observedBuildJava=$null;compilerTarget=21;runtimeRequirement=[pscustomobject]@{kind='Minimum';major=21};observedRuntimeJava=$null};sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=('a'*40);license='CC0-1.0';trust='TrustedOfficial'};notes=@()}
        $ev=[pscustomobject]@{targetId=$target.targetId;runId='r2';startedAt=[DateTimeOffset]::UtcNow.ToString('o');endedAt=[DateTimeOffset]::UtcNow.ToString('o');validationLevel='CLIENT_LAUNCH_VERIFIED';result='PASSED';platform=$target.platform;java=[pscustomobject]@{buildRequirement=$null;observedBuildJava=$null;compilerTarget=21;runtimeRequirement=$null;observedRuntimeJava=$null};toolchain=[pscustomobject]@{id='FabricLoom';version='1'};buildSystem=[pscustomobject]@{id='Gradle';version='8'};sourceFixture=$target.sourceFixture;logs=@();artifact=$null;process=$null;marker=$null;stopMethod=$null;scenario=$null;notes=@()}
        $matrix=New-MmtlValidationMatrix -Targets @($target) -Evidence @($ev)
        $matrix.matrix.targets[0].validation.effectiveLevel | Should -Be 'RESOLVED'
        $matrix.matrix.targets[0].validation.client | Should -BeFalse
    }

    It 'retains client verification when launcher evidence names the Gradle wrapper explicitly' {
        $target=[pscustomobject]@{targetId='fabric-263-win';tier='Tier2';resolved=$true;minecraftId='26.3';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric';version='0.19.2'};overlays=@()};loaderVersion='0.19.2';toolchain='FabricLoom';toolchainVersion='1.16-SNAPSHOT';buildSystem='Gradle';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false};java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Exact';major=25};observedBuildJava=$null;compilerTarget=25;runtimeRequirement=[pscustomobject]@{kind='Exact';major=25};observedRuntimeJava=$null};sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=('b'*40);license='CC0-1.0';trust='TrustedOfficial'};notes=@()}
        $observedJava=[pscustomobject]@{major=25;exactVersion='25.0.1';vendor='Oracle';os='Windows';arch='x64'}
        $build=[pscustomobject]@{targetId=$target.targetId;minecraftId='26.3';loaderId='Fabric';loaderVersion='0.19.2';runId='build-r1';startedAt=[DateTimeOffset]::UtcNow.ToString('o');endedAt=[DateTimeOffset]::UtcNow.ToString('o');validationLevel='BUILD_VERIFIED';result='PASSED';platform=$target.platform;java=[pscustomobject]@{buildRequirement=$null;observedBuildJava=$observedJava;compilerTarget=25;runtimeRequirement=$null;observedRuntimeJava=$null};toolchain=[pscustomobject]@{id='FabricLoom';version='1.16-SNAPSHOT'};buildSystem=[pscustomobject]@{id='Gradle';version='9.2.1'};sourceFixture=$target.sourceFixture;logs=@();artifact=$null;process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@()}
        $client=[pscustomobject]@{targetId=$target.targetId;minecraftId='26.3';loaderId='Fabric';loaderVersion='0.19.2';runId='client-r1';startedAt=[DateTimeOffset]::UtcNow.AddSeconds(1).ToString('o');endedAt=[DateTimeOffset]::UtcNow.AddSeconds(30).ToString('o');validationLevel='CLIENT_LAUNCH_VERIFIED';result='PASSED';platform=$target.platform;java=[pscustomobject]@{buildRequirement=$null;observedBuildJava=$observedJava;compilerTarget=25;runtimeRequirement=$null;observedRuntimeJava=$observedJava};toolchain=[pscustomobject]@{id='FabricLoom';version='1.16-SNAPSHOT'};buildSystem=[pscustomobject]@{id='GradleWrapper';version='9.2.1'};sourceFixture=$target.sourceFixture;logs=@();artifact=$null;process=[pscustomobject]@{identityMatched=$true;liveAtMarker=$true};marker=[pscustomobject]@{kind='clientInitialized';text='Sound engine started';matched=$true;elapsedSeconds=15};stopMethod='Terminate';scenario=$null;notes=@()}
        $matrix=New-MmtlValidationMatrix -Targets @($target) -Evidence @($build,$client)
        $matrix.matrix.targets[0].validation.effectiveLevel | Should -Be 'CLIENT_LAUNCH_VERIFIED'
        $matrix.matrix.targets[0].validation.client | Should -BeTrue
        @($matrix.warnings).Count | Should -Be 0
    }

    It 'separates reused base target IDs when fixture source identity differs' {
        $base=[pscustomobject]@{targetId='neoforge-1211-linux-x64';runId='official-run';minecraftId='1.21.1';loaderId='NeoForge';loaderVersion='21.1.235';startedAt=[DateTimeOffset]::UtcNow.ToString('o');endedAt=[DateTimeOffset]::UtcNow.ToString('o');validationLevel='BUILD_VERIFIED';result='PASSED';platform=[pscustomobject]@{os='Linux';arch='x64';isWSL=$true};toolchain=[pscustomobject]@{id='NeoGradle';version='7.1.38'};buildSystem=[pscustomobject]@{id='Gradle';version='9.2.1'};java=[pscustomobject]@{buildRequirement=$null;observedBuildJava=$null;compilerTarget=21;runtimeRequirement=$null;observedRuntimeJava=$null};sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/NeoForgeMDKs/MDK-1.21.1-NeoGradle';commit=('c'*40);license='MIT';trust='TrustedOfficial'};logs=@();artifact=$null;process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@()}
        $mod=[pscustomobject]@{targetId=$base.targetId;runId='mod-run';minecraftId=$base.minecraftId;loaderId=$base.loaderId;loaderVersion='21.1.238';startedAt=[DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o');endedAt=[DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o');validationLevel='BUILD_VERIFIED';result='PASSED';platform=$base.platform;toolchain=$base.toolchain;buildSystem=$base.buildSystem;java=$base.java;sourceFixture=[pscustomobject]@{type='UserProject';source='workspace-project:CreateProbabilityTuning';commit='3a35781f7d5c08366a0fc5d570b01ad505ebf166';license='Proprietary';trust='UserOwned'};logs=@();artifact=$null;process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@()}
        $derived=Get-MmtlValidationTargetsFromEvidence -Evidence @($base,$mod)
        $derived.targets.Count | Should -Be 2
        @($derived.targets.targetId | Select-Object -Unique).Count | Should -Be 2
        @($derived.targets.sourceFixture.source | Select-Object -Unique).Count | Should -Be 2
        $mapped=[Collections.Generic.List[object]]::new()
        foreach($target in $derived.targets){$record=if($target.sourceFixture.type -eq 'OfficialFixture'){$base}else{$mod};$copy=$record|ConvertTo-Json -Depth 20|ConvertFrom-Json;$copy.targetId=$target.targetId;$mapped.Add($copy)}
        $matrix=New-MmtlValidationMatrix -Targets @($derived.targets) -Evidence @($mapped)
        @($matrix.matrix.targets|Where-Object {$_.validation.effectiveLevel -eq 'BUILD_VERIFIED'}).Count | Should -Be 2
    }
}
