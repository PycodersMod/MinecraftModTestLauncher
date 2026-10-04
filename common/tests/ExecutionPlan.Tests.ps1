BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Execution/ExecutionPlan.psm1') -Force

    function New-TestExecutionPlan {
        param([string]$ProjectRoot='C:/workspace-a/mod/forge/1.20.1',[string]$RepositoryRoot='C:/workspace-a/mod',[string]$JavaPath='C:/jdk-17/bin/java.exe',[string]$CreatedAt='2026-10-04T00:00:00Z',[string]$Mode='Single',[int]$Players=1)
        [pscustomobject][ordered]@{
            schemaVersion=1;planId='plan-test';semanticDigest='';createdAt=$CreatedAt
            platform=[pscustomobject][ordered]@{os='Windows';arch='x64';isWSL=$false;capabilities=[pscustomobject][ordered]@{Build='Native';Launch='Native'}}
            repository=[pscustomobject][ordered]@{identity='sample-mod';root=$RepositoryRoot}
            project=[pscustomobject][ordered]@{projectRoot=$ProjectRoot;locator='forge/1.20.1';minecraftId='1.20.1';loader=[pscustomobject]@{id='Forge';version='47.2.0'};loaderStack=@();toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'};buildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'};modId='samplemod'}
            buildJava=[pscustomobject][ordered]@{requirement=[pscustomobject]@{purpose='BuildJava';major=17;minimumMajor=17;preferredMajor=$null;requirementKind='Minimum';source='GradleWrapperRuntimeCompatibility';confidence='High'};resolution=[pscustomobject]@{status='Resolved';javaPath=$JavaPath;home='C:/jdk-17';actualMajor=17;exactVersion='17.0.19';vendor='Oracle Corporation';os='Windows';arch='x64';reasonCode=$null}}
            runtimeJava=[pscustomobject][ordered]@{requirement=[pscustomobject]@{purpose='RuntimeJava';major=17;requirementKind='Exact';source='MojangVersionMetadata';confidence='High';component='java-runtime-gamma'};resolution=[pscustomobject]@{status='Resolved';javaPath='C:/jdk-17/bin/java.exe';home='C:/jdk-17';actualMajor=17;exactVersion='17.0.19';vendor='Oracle Corporation';os='Windows';arch='x64';reasonCode=$null};bindingMode='Unknown'}
            profile=[pscustomobject][ordered]@{name='single';mode=$Mode;players=$Players;hostUsername='Dev';clientPrefix='Dev_';memoryMb=4096;jvmArgs=@();gameArgs=@();acceptEula=$false}
            build=[pscustomobject][ordered]@{required=$true;clean=$false;task='build';wrapper='gradlew';artifactExpectation='one-mod-jar'}
            runtime=[pscustomobject][ordered]@{roles=@('Client');runtimeDirectories=@([pscustomobject]@{role='Client';path='C:/runtime/sessions/one/Dev'});memory=[pscustomobject]@{requestedMb=4096;limitMb=12288};jvmArgs=@();gameArgs=@()}
            network=[pscustomobject][ordered]@{portPolicy='None';bindPolicy='Loopback'}
            session=[pscustomobject][ordered]@{intendedMode=$Mode}
            capabilityGates=[pscustomobject][ordered]@{buildReady=$true;launchReady=$true}
            blockingReasons=@();warnings=@();provenance=[pscustomobject]@{runtimeJavaSource='MojangVersionMetadata';metadataStatus='VERIFIED'}
        }
    }
}

Describe 'Execution Plan schema 与语义摘要' {
    It 'canonical digest 不受属性顺序、时间戳、绝对工作区路径和本地 Java 路径影响' {
        $first = New-TestExecutionPlan
        $first.semanticDigest = Get-MmtlExecutionPlanSemanticDigest -Plan $first
        $second = New-TestExecutionPlan -RepositoryRoot 'D:/clone/mod' -ProjectRoot 'D:/clone/mod/forge/1.20.1' -JavaPath 'D:/java/jdk-17/bin/java.exe' -CreatedAt '2027-01-01T12:00:00Z'
        $second.platform = [pscustomobject][ordered]@{capabilities=[pscustomobject][ordered]@{Launch='Native';Build='Native'};isWSL=$false;arch='x64';os='Windows'}
        $second.semanticDigest = Get-MmtlExecutionPlanSemanticDigest -Plan $second

        $second.semanticDigest | Should -BeExactly $first.semanticDigest
        $first.semanticDigest | Should -Match '^sha256:[0-9a-f]{64}$'
    }

    It 'Profile 与运行语义变化会改变 digest' {
        $single = New-TestExecutionPlan
        $dedicated = New-TestExecutionPlan -Mode Dedicated -Players 2

        (Get-MmtlExecutionPlanSemanticDigest -Plan $single) | Should -Not -BeExactly (Get-MmtlExecutionPlanSemanticDigest -Plan $dedicated)
    }

    It 'Plan 符合独立 schema 且 digest 一致' {
        $plan = New-TestExecutionPlan
        $plan.semanticDigest = Get-MmtlExecutionPlanSemanticDigest -Plan $plan

        $result = Test-MmtlExecutionPlan -Plan $plan -SchemaPath (Join-Path $script:repoRoot 'schemas/execution-plan.schema.json')

        $result.valid | Should -BeTrue
        $result.errors | Should -BeNullOrEmpty
    }

    It '拒绝 Build Java 实测版本低于 requirement 的 Plan' {
        $plan = New-TestExecutionPlan
        $plan.buildJava.resolution.actualMajor = 16
        $plan.semanticDigest = Get-MmtlExecutionPlanSemanticDigest -Plan $plan

        $result = Test-MmtlExecutionPlan -Plan $plan -SchemaPath (Join-Path $script:repoRoot 'schemas/execution-plan.schema.json')

        $result.valid | Should -BeFalse
        $result.errors -join ';' | Should -Match 'BUILD_JAVA_RESOLUTION_INCONSISTENT'
    }
}
