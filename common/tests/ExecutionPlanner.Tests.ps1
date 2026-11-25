BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Execution/ExecutionPlanner.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Execution/ExecutionPlan.psm1') -Force

    function New-TestJavaHome {
        param([string]$Root,[int]$Major,[string]$Arch='x64')
        New-Item -ItemType Directory -Path (Join-Path $Root 'bin') -Force | Out-Null
        $exe=if($script:platform.os -eq 'Windows'){'java.exe'}else{'java'}
        New-Item -ItemType File -Path (Join-Path $Root "bin/$exe") -Force | Out-Null
        $releaseArch=if($Arch -eq 'x64'){'amd64'}else{'aarch64'}
        @("JAVA_VERSION=`"$Major.0.1`"",'IMPLEMENTOR="Test Vendor"',"OS_ARCH=`"$releaseArch`"") | Set-Content (Join-Path $Root 'release')
    }

    function New-TestPlannerInputs {
        $script:platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false;capabilities=[pscustomobject]@{Build='Native';Launch='Native'}}
        $root=Join-Path $TestDrive 'workspace-one'
        $repo=Join-Path $root 'ExampleMod'
        $projectRoot=Join-Path $repo 'forge/1.20.1'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        $jdk17=Join-Path $TestDrive 'java17';$jdk21=Join-Path $TestDrive 'java21'
        New-TestJavaHome $jdk17 17;New-TestJavaHome $jdk21 21
        $project=[pscustomobject]@{
            RepositoryRoot=$repo;Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';ModId='examplemod';
            LoaderStack=[pscustomobject]@{primaryLoader=[pscustomobject]@{id='Forge';version='47.2.0'};overlayLoaders=@()};
            Toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'};BuildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'};
            BuildTask='build';Wrapper=$true;WrapperPath=(Join-Path $projectRoot 'gradlew');
            BuildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=17;minimumMajor=17;preferredMajor=$null;exactMajor=$null;requirementKind='Minimum';source='GradleWrapperRuntimeCompatibility';confidence='High';reason='fixture'};
            RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=$null;requirementKind='Unknown';source='Unknown';confidence='Unknown'}
        }
        $profile=[pscustomobject]@{project=$projectRoot;linkedProjects=@();mode='Single';players=1;hostUsername='Dev';clientPrefix='Dev_';autoBuild=$true;cleanBuild=$false;acceptEula=$false;port='Auto';memoryMb=4096;hostMemoryMb=4096;clientMemoryMb=4096;serverMemoryMb=4096;jvmArgs=@();gameArgs=@();extraMods=@();resolution='1280x720';guiScale='Auto';windowLayout='None'}
        $config=[pscustomobject]@{defaultProfile='fixture';javaHomes=[pscustomobject]@{'17'=$jdk17;'21'=$jdk21};javaHomesByPlatform=[pscustomobject]@{Windows=[pscustomobject]@{};Linux=[pscustomobject]@{};MacOS=[pscustomobject]@{}}}
        [ordered]@{Project=$project;Profile=$profile;Config=$config;RuntimeRoot=(Join-Path $TestDrive 'runtime');Platform=$script:platform;PhysicalMemoryMb=16384;ProfileName='fixture';CatalogEntry=[pscustomobject]@{id='1.20.1';metadataStatus='VERIFIED_NO_JAVA_VERSION'};VersionMetadata=$null}
    }
}

Describe '统一 Execution Planner' {
    It 'Execution Plan 保留有效场景值及命令行来源，并把客户端数纳入语义摘要' {
        $input=New-TestPlannerInputs
        $input.Profile.mode='IntegratedLAN';$input.Profile.players=3
        $input.Profile|Add-Member -NotePropertyName clientCount -NotePropertyValue 3 -Force
        $input.Profile|Add-Member -NotePropertyName multiplayer -NotePropertyValue ([pscustomobject]@{transport='IntegratedLAN'}) -Force
        $input.Profile|Add-Member -NotePropertyName identity -NotePropertyValue ([pscustomobject]@{kind='Offline';hostName='Host';guestNamePattern='Guest_{index}'}) -Force
        $input.Profile|Add-Member -NotePropertyName scenarioConfiguration -NotePropertyValue ([pscustomobject]@{configDigest=('sha256:'+('a'*64));sourceProfileName='matrix';valueSources=[pscustomobject]@{clientCount='CommandLine';transport='Profile'}}) -Force
        $plan=New-MmtlExecutionPlan @input
        $plan.profile.clientCount | Should -Be 3
        $plan.profile.transport | Should -BeExactly 'IntegratedLAN'
        $plan.profile.identity.kind | Should -BeExactly 'Offline'
        $plan.profile.scenarioConfiguration.valueSources.clientCount | Should -BeExactly 'CommandLine'
        $result=Test-MmtlExecutionPlan -Plan $plan
        $result.valid | Should -BeTrue
        $changed=$plan|ConvertTo-Json -Depth 80|ConvertFrom-Json
        $changed.profile.clientCount=4
        (Get-MmtlExecutionPlanSemanticDigest -Plan $changed) | Should -Not -BeExactly $plan.semanticDigest
    }

    It '将精确 LiteLoader Runtime 描述纳入 Execution Plan 及语义摘要' {
        $input=New-TestPlannerInputs
        $input.Project.Loader='LiteLoader';$input.Project.LoaderVersion='1.7.10_04';$input.Project.MinecraftVersion='1.7.10'
        $input.Project.LoaderStack=[pscustomobject]@{primaryLoader=[pscustomobject]@{id='LiteLoader';version='1.7.10_04'};overlayLoaders=@()}
        $baseline=New-MmtlExecutionPlan @input
        $descriptor=[pscustomobject]@{targetId='LiteLoader@1.7.10';minecraftId='1.7.10';loaderVersion='1.7.10_04';loaderArtifactSha256=('a'*64);loaderArtifactUrl='https://dl.liteloader.com/versions/liteloader.jar';loaderArtifactBytes=100;loaderArtifactOfficialMd5=('c'*32);mainClass='net.minecraft.launchwrapper.Launch';tweakClass='com.mumfrey.liteloader.launch.LiteLoaderTweaker';clientArtifact=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/e80d9b3bf5085002218d4be59e668bac718abbc6/client.jar';sha1='e80d9b3bf5085002218d4be59e668bac718abbc6';bytes=5256245;metadataSnapshotSha256=('d'*64)};serverArtifact=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/952438ac4e01b4d115c5fc38f891710c4941df29/server.jar';sha1='952438ac4e01b4d115c5fc38f891710c4941df29';bytes=9605030;metadataSnapshotSha256=('d'*64)};versionMetadata=[pscustomobject]@{url='https://piston-meta.mojang.com/v1/packages/ed5d8789ed29872ea2ef1c348302b0c55e3f3468/1.7.10.json';sha1='ed5d8789ed29872ea2ef1c348302b0c55e3f3468';bytes=999;sha256=('d'*64)};assetIndex=[pscustomobject]@{url='https://launchermeta.mojang.com/v1/packages/1863782e33ce7b584fc45b037325a1964e095d3e/1.7.10.json';sha1='1863782e33ce7b584fc45b037325a1964e095d3e';bytes=72996;id='1.7.10'};libraries=@([pscustomobject]@{name='net.minecraft:launchwrapper:1.11';url='https://libraries.minecraft.net/net/minecraft/launchwrapper/1.11/launchwrapper-1.11.jar';bytes=33143;sha1='9c0592c6e1e9ea296a70948081bd4cc84dda1289';sha256=('b'*64);hashEvidence='HTTPS_DOWNLOAD_OBSERVATION'})}
        $input.LoaderLaunchPlan=$descriptor

        $plan=New-MmtlExecutionPlan @input

        $plan.runtime.loaderLaunchPlan.targetId | Should -BeExactly 'LiteLoader@1.7.10'
        $plan.runtime.loaderLaunchPlan.libraries[0].name | Should -BeExactly 'net.minecraft:launchwrapper:1.11'
        $plan.semanticDigest | Should -Not -BeExactly $baseline.semanticDigest
        (Test-MmtlExecutionPlan -Plan $plan).valid | Should -BeTrue
    }

    It '拒绝与项目 Loader 或 Minecraft exact target 不一致的 Runtime 描述' {
        $case=New-TestPlannerInputs
        $case.LoaderLaunchPlan=[pscustomobject]@{targetId='LiteLoader@1.7.10';minecraftId='1.7.10';loaderVersion='1.7.10_04';loaderArtifactSha256=('a'*64);loaderArtifactUrl='https://dl.liteloader.com/versions/liteloader.jar';loaderArtifactBytes=100;loaderArtifactOfficialMd5=('c'*32);mainClass='net.minecraft.launchwrapper.Launch';tweakClass='com.mumfrey.liteloader.launch.LiteLoaderTweaker';libraries=@()}
        { New-MmtlExecutionPlan @case } | Should -Throw '*LOADER_LAUNCH_PLAN_PROJECT_MISMATCH*'
    }

    It '对只记录为 Profile 元数据的游戏内行为输出稳定非阻断 warning' {
        $input=New-TestPlannerInputs
        $input.Profile|Add-Member -NotePropertyName hostCheats -NotePropertyValue $true -Force
        $input.Profile|Add-Member -NotePropertyName gameMode -NotePropertyValue 'creative' -Force
        $input.Profile|Add-Member -NotePropertyName difficulty -NotePropertyValue 'normal' -Force
        $input.Profile|Add-Member -NotePropertyName worldName -NotePropertyValue 'AuditWorld' -Force
        $input.Profile|Add-Member -NotePropertyName seed -NotePropertyValue '42' -Force
        $input.Profile|Add-Member -NotePropertyName newWorld -NotePropertyValue $true -Force
        $input.Profile|Add-Member -NotePropertyName clientPermissionLevel -NotePropertyValue 0 -Force
        $input.Profile|Add-Member -NotePropertyName resetWorld -NotePropertyValue $true -Force
        $plan=New-MmtlExecutionPlan @input
        @($plan.warnings|Where-Object code -eq 'PROFILE_FIELD_METADATA_ONLY'|ForEach-Object source) | Should -Contain 'hostCheats'
        @($plan.warnings|Where-Object code -eq 'PROFILE_FIELD_METADATA_ONLY'|ForEach-Object source) | Should -Contain 'worldName'
        @($plan.warnings|Where-Object code -eq 'PROFILE_FIELD_METADATA_ONLY'|ForEach-Object source) | Should -Contain 'clientPermissionLevel'
        $plan.warnings.code | Should -Contain 'WORLD_RESET_SCOPED_TO_SESSION'
        $plan.capabilityGates.launchReady | Should -BeFalse
        $plan.blockingReasons.code | Should -Contain 'RUNTIME_JAVA_REQUIREMENT_UNKNOWN'
    }

    It '分离 Build Java 与 Runtime Java requirement/resolution' {
        $input = New-TestPlannerInputs
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=21;requirementKind='Exact';source='MojangVersionMetadata';confidence='High';component='java-runtime-gamma'}

        $plan = New-MmtlExecutionPlan @input

        $plan.buildJava.requirement.major | Should -Be 17
        $plan.buildJava.resolution.actualMajor | Should -Be 17
        $plan.runtimeJava.requirement.major | Should -Be 21
        $plan.runtimeJava.resolution.actualMajor | Should -Be 21
        $plan.buildJava.resolution.javaPath | Should -Not -BeExactly $plan.runtimeJava.resolution.javaPath
    }

    It 'Build Java 缺失时仍生成解释性 Plan 并保留 stable block code' {
        $input=New-TestPlannerInputs
        $input.config.javaHomes=[pscustomobject]@{}

        $plan=New-MmtlExecutionPlan @input

        $plan.schemaVersion | Should -Be 1
        $plan.buildJava.resolution.status | Should -BeExactly 'Unresolved'
        $plan.blockingReasons.code | Should -Contain 'BUILD_JAVA_NOT_RESOLVED'
        $plan.capabilityGates.buildReady | Should -BeFalse
    }

    It '无效 Profile 返回结构化 Plan 和 INVALID_PROFILE，不让 planner 崩溃' {
        $input=New-TestPlannerInputs
        $input.Profile.mode='InventedMode';$input.Profile.players=0

        $plan=New-MmtlExecutionPlan @input

        $plan.profile.mode | Should -BeExactly 'InventedMode'
        $plan.blockingReasons.code | Should -Contain 'INVALID_PROFILE'
        $plan.capabilityGates.launchReady | Should -BeFalse
    }

    It 'Runtime Java 未知不会阻止纯 Build readiness，但会阻止 Launch readiness' {
        $input=New-TestPlannerInputs

        $plan=New-MmtlExecutionPlan @input

        $plan.capabilityGates.buildReady | Should -BeTrue
        $plan.capabilityGates.launchReady | Should -BeFalse
        $plan.blockingReasons.code | Should -Contain 'RUNTIME_JAVA_REQUIREMENT_UNKNOWN'
    }

    It 'Profile Runtime Java override 优先于项目 requirement 并按精确主版本解析' {
        $input=New-TestPlannerInputs
        $input.config.javaHomes | Add-Member -NotePropertyName '25' -NotePropertyValue (Join-Path $TestDrive 'java25') -Force
        New-TestJavaHome (Join-Path $TestDrive 'java25') 25
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{major=21;requirementKind='Exact';source='MojangVersionMetadata';confidence='High'}
        $input.profile | Add-Member -NotePropertyName runtimeJavaOverride -NotePropertyValue ([pscustomobject]@{major=25;component='java-runtime-test'}) -Force
        $plan=New-MmtlExecutionPlan @input
        $plan.runtimeJava.requirement.major | Should -Be 25
        $plan.runtimeJava.requirement.source | Should -BeExactly 'ProjectOverride'
        $plan.runtimeJava.resolution.actualMajor | Should -Be 25
    }

    It 'Profile Build Java override 精确选择 Gradle JVM 且不改变 Runtime Java' {
        $input=New-TestPlannerInputs
        $jdk25=Join-Path $TestDrive 'java25'
        New-TestJavaHome $jdk25 25
        $input.config.javaHomes | Add-Member -NotePropertyName '25' -NotePropertyValue $jdk25 -Force
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{major=21;requirementKind='Exact';source='MojangVersionMetadata';confidence='High'}
        $input.profile | Add-Member -NotePropertyName buildJavaOverride -NotePropertyValue ([pscustomobject]@{major=25}) -Force

        $plan=New-MmtlExecutionPlan @input

        $plan.buildJava.requirement.major | Should -Be 25
        $plan.buildJava.requirement.exactMajor | Should -Be 25
        $plan.buildJava.requirement.source | Should -BeExactly 'ProfileBuildJavaOverride'
        $plan.buildJava.resolution.actualMajor | Should -Be 25
        $plan.runtimeJava.requirement.major | Should -Be 21
        $plan.runtimeJava.resolution.actualMajor | Should -Be 21
    }

    It 'Dedicated EULA 未预先授权只阻止 Launch 且 Auto 端口不分配' {
        $input=New-TestPlannerInputs
        $input.profile.mode='Dedicated';$input.profile.players=2;$input.profile.port='Auto'

        $plan=New-MmtlExecutionPlan @input

        $plan.capabilityGates.buildReady | Should -BeTrue
        $plan.capabilityGates.launchReady | Should -BeFalse
        $plan.blockingReasons.code | Should -Contain 'EULA_NOT_PREAUTHORIZED'
        $plan.network.portPolicy | Should -BeExactly 'Auto'
        $plan.network.PSObject.Properties['fixedPort'].Value | Should -BeNullOrEmpty
        $plan.session.intendedMode | Should -BeExactly 'Dedicated'
    }

    It 'IntegratedLAN 使用 Session 管理的离线测试身份，不要求正版账号认证' {
        $input=New-TestPlannerInputs
        $input.profile.mode='IntegratedLAN';$input.profile.players=2

        $plan=New-MmtlExecutionPlan @input

        $plan.capabilityGates.buildReady | Should -BeTrue
        $plan.blockingReasons.code | Should -Not -Contain 'AUTH_REQUIRED'
    }

    It 'Plan 生成不创建 Session/Runtime 文件或目录' {
        $input=New-TestPlannerInputs
        $runtime=$input.RuntimeRoot

        $null=New-MmtlExecutionPlan @input

        Test-Path -LiteralPath $runtime | Should -BeFalse
    }

    It '同一项目迁移到另一工作区和 JDK 安装目录后 semantic digest 保持不变' {
        $input=New-TestPlannerInputs
        $first=New-MmtlExecutionPlan @input
        $newRepo=Join-Path $TestDrive 'workspace-two/ExampleMod'
        $newProject=Join-Path $newRepo 'forge/1.20.1'
        New-Item -ItemType Directory -Path $newProject -Force | Out-Null
        $newJdk=Join-Path $TestDrive 'relocated-java17'
        New-TestJavaHome $newJdk 17
        $input.Project.RepositoryRoot=$newRepo;$input.Project.Root=$newProject
        $input.Config.javaHomes.'17'=$newJdk
        $input.RuntimeRoot=Join-Path $TestDrive 'relocated-runtime'

        $second=New-MmtlExecutionPlan @input

        $second.semanticDigest | Should -BeExactly $first.semanticDigest
    }

    It '无适配器证据时不接受 Direct binding 声明' {
        $input=New-TestPlannerInputs
        $input.AdapterEvidence=[pscustomobject]@{runtimeJavaBindingMode='Direct'}

        $plan=New-MmtlExecutionPlan @input

        $plan.runtimeJava.bindingMode | Should -BeExactly 'Unknown'
        $plan.blockingReasons.code | Should -Contain 'RUNTIME_JAVA_BINDING_UNKNOWN'
    }

    It 'Direct binding 使用 Runtime Java candidate 并允许明确的 Launch Plan' {
        $input=New-TestPlannerInputs
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=21;requirementKind='Exact';source='MojangVersionMetadata';confidence='High'}
        $input.AdapterEvidence=[pscustomobject]@{runtimeJavaBindingMode='Direct';runtimeJavaBindingEvidence='Fixture: direct executable path passed to provider'}
        $plan=New-MmtlExecutionPlan @input
        $plan.runtimeJava.bindingMode | Should -BeExactly 'Direct'
        $plan.capabilityGates.launchReady | Should -BeTrue
        $plan.status | Should -BeExactly 'Ready'
    }

    It 'Build 非必需且 Build JDK 缺失时不误阻止独立 Runtime Launch readiness' {
        $input=New-TestPlannerInputs
        $input.profile.autoBuild=$false;$input.project.BuildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=17;minimumMajor=$null;exactMajor=17;requirementKind='Exact';source='Fixture';confidence='High'};$input.config.javaHomes=[pscustomobject]@{'21'=$input.config.javaHomes.'21'}
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=21;requirementKind='Exact';source='MojangVersionMetadata';confidence='High'}
        $input.AdapterEvidence=[pscustomobject]@{runtimeJavaBindingMode='Direct';runtimeJavaBindingEvidence='Fixture: direct executable path passed to provider'}
        $plan=New-MmtlExecutionPlan @input
        $plan.capabilityGates.buildReady | Should -BeFalse
        $plan.capabilityGates.launchReady | Should -BeTrue
        $plan.status | Should -BeExactly 'Ready'
    }

    It 'SameAsBuildJvm adapter 证据与 Runtime requirement 不一致时阻止 Launch' {
        $input=New-TestPlannerInputs
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=21;requirementKind='Exact';source='MojangVersionMetadata';confidence='High'}
        $input.AdapterEvidence=[pscustomobject]@{runtimeJavaBindingMode='SameAsBuildJvm';runtimeJavaBindingEvidence='Fixture: wrapper uses Gradle JVM'}
        $plan=New-MmtlExecutionPlan @input
        $plan.capabilityGates.buildReady | Should -BeTrue
        $plan.capabilityGates.launchReady | Should -BeFalse
        $plan.blockingReasons.code | Should -Contain 'RUNTIME_JAVA_BINDING_MISMATCH'
    }

    It 'SameAsBuildJvm 满足相同 Java requirement 时保留 binding evidence 并允许 Launch' {
        $input=New-TestPlannerInputs
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=17;requirementKind='Exact';source='MojangVersionMetadata';confidence='High'}
        $binding=[pscustomobject]@{mode='SameAsBuildJvm';evidenceSource='GradleInitScriptJavaExecInspection';confidence='High';evidenceDetails=@([pscustomobject]@{task='runClient';taskType='org.gradle.api.tasks.JavaExec'})}
        $input.AdapterEvidence=[pscustomobject]@{runtimeJavaBindingMode='SameAsBuildJvm';runtimeJavaBindingEvidence=$binding}

        $plan=New-MmtlExecutionPlan @input

        $plan.capabilityGates.buildReady | Should -BeTrue
        $plan.capabilityGates.launchReady | Should -BeTrue
        $plan.runtimeJava.requirement.major | Should -Be 17
        $plan.runtimeJava.bindingEvidence.evidenceSource | Should -BeExactly 'GradleInitScriptJavaExecInspection'
        $plan.blockingReasons.code | Should -Not -Contain 'RUNTIME_JAVA_BINDING_MISMATCH'
    }

    It 'Single 客户端不能使用只有 runServer 证据的 Runtime Binding' {
        $input=New-TestPlannerInputs
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=17;requirementKind='Exact';source='MojangVersionMetadata';confidence='High'}
        $binding=[pscustomobject]@{mode='SameAsBuildJvm';evidenceSource='GradleInitScriptJavaExecInspection';confidence='High';evidenceDetails=@([pscustomobject]@{task='runServer';taskType='org.gradle.api.tasks.JavaExec'})}
        $input.AdapterEvidence=[pscustomobject]@{runtimeJavaBindingMode='SameAsBuildJvm';runtimeJavaBindingEvidence=$binding}

        $plan=New-MmtlExecutionPlan @input

        $plan.capabilityGates.launchReady | Should -BeFalse
        $plan.launchBlockingReasons.code | Should -Contain 'RUNTIME_BINDING_ROLE_TASK_UNAVAILABLE'
        $plan.runtime.roles[0].launchReady | Should -BeFalse
    }

    It 'IntegratedLAN Host 与 Guest 都可使用 Session 管理的离线身份启动' {
        $input=New-TestPlannerInputs
        $input.profile.mode='IntegratedLAN';$input.profile.players=2
        $input.project.RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=17;requirementKind='Exact';source='MojangVersionMetadata';confidence='High'}
        $input.AdapterEvidence=[pscustomobject]@{runtimeJavaBindingMode='SameAsBuildJvm';runtimeJavaBindingEvidence=[pscustomobject]@{mode='SameAsBuildJvm';evidenceSource='Fixture';confidence='High'}}

        $plan=New-MmtlExecutionPlan @input

        $plan.runtime.roles[0].launchReady | Should -BeTrue
        $plan.runtime.roles[1].launchReady | Should -BeTrue
        $plan.runtime.roles[1].blockingReasons | Should -Not -Contain 'AUTH_REQUIRED'
        $plan.capabilityGates.launchReady | Should -BeTrue
        $plan.launchBlockingReasons.code | Should -Not -Contain 'AUTH_REQUIRED'
    }

    It 'Linux WSL 保留 BuildReady 并按注入 Launch capability 阻止 launch' {
        $input=New-TestPlannerInputs
        $input.platform=[pscustomobject]@{os='Linux';arch='x64';isWSL=$true;capabilities=[pscustomobject]@{Build='Native';Launch='BuildOnly'}}
        $input.project.BuildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=17;minimumMajor=17;requirementKind='Minimum';source='GradleWrapperRuntimeCompatibility';confidence='High'}
        $input.config.javaHomes=[pscustomobject]@{}
        $input.config.javaHomesByPlatform.Linux=[pscustomobject]@{'17'=(Join-Path $TestDrive 'linux-jdk17')}
        $script:platform=$input.platform
        New-TestJavaHome (Join-Path $TestDrive 'linux-jdk17') 17

        $plan=New-MmtlExecutionPlan @input

        $plan.platform.isWSL | Should -BeTrue
        $plan.capabilityGates.buildReady | Should -BeTrue
        $plan.capabilityGates.launchReady | Should -BeFalse
    }
}
