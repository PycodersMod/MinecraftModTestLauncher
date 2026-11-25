BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:probeModule=Import-Module (Join-Path $script:repoRoot 'src/RuntimeBindingProbe.psm1') -Force -PassThru
    function Invoke-TestRuntimeBindingProbe { param($Project,$Plan,[string]$RuntimeRoot,[string[]]$TrustedProjectRoots,[switch]$Offline,[scriptblock]$GradleInvoker,[int]$GradleTimeoutSeconds=300) & $script:probeModule { param($p,$plan,$runtime,$trusted,$offline,$invoker,$timeout) Invoke-MmtlRuntimeBindingProbe -Project $p -Plan $plan -RuntimeRoot $runtime -TrustedProjectRoots $trusted -Offline:$offline -GradleInvoker $invoker -GradleTimeoutSeconds $timeout } $Project $Plan $RuntimeRoot $TrustedProjectRoots $Offline $GradleInvoker $GradleTimeoutSeconds }
    function Convert-TestFreshRuntimeBindingProbeToAdapterEvidence { param($Project,$Plan,$ProbeResult) & $script:probeModule { param($p,$plan,$result) New-MmtlRuntimeBindingAdapterEvidenceFromFreshProbe -Project $p -Plan $plan -ProbeResult $result } $Project $Plan $ProbeResult }
    function New-TestBindingProject {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root -Force|Out-Null
        $wrapper=Join-Path $Root 'gradlew';Set-Content -LiteralPath $wrapper -Value '#!/bin/sh'
        $null=git -C $Root init -q
        $null=git -C $Root config user.name 'Fixture'
        $null=git -C $Root config user.email 'fixture@example.invalid'
        Set-Content -LiteralPath (Join-Path $Root 'build.gradle') -Value 'plugins { id "base" }'
        $null=git -C $Root add .
        $null=git -C $Root commit -qm 'fixture'
        [pscustomobject]@{Root=$Root;MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';Toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'};WrapperPath=$wrapper;BuildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'}}
    }
    function New-TestBindingPlan { [pscustomobject]@{buildJava=[pscustomobject]@{resolution=[pscustomobject]@{javaHome='<JAVA_HOME>';actualMajor=17}};runtimeJava=[pscustomobject]@{requirement=[pscustomobject]@{major=17}};platform=[pscustomobject]@{os='Windows';arch='x64'}} }
}

Describe 'Runtime Binding 安全探测' {
    It '只把当前精确目标的高置信新鲜 Runtime Binding 探测转为临时 AdapterEvidence' {
        $project=[pscustomobject]@{Root=(Join-Path $TestDrive 'fresh-probe-project');MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';Toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'}}
        $plan=[pscustomobject]@{buildJava=[pscustomobject]@{resolution=[pscustomobject]@{javaHome='D:\jdk-25';actualMajor=25}};runtimeJava=[pscustomobject]@{requirement=[pscustomobject]@{major=17};resolution=[pscustomobject]@{javaPath='D:\jdk-17\bin\java.exe';actualMajor=17}};runtime=[pscustomobject]@{roles=@([pscustomobject]@{role='Client'})}} # public-hygiene: allow-synthetic-path
        $binding=[pscustomobject]@{mode='Direct';confidence='High';evidenceSource='GradleInitScriptJavaExecInspection';runtimeJavaControllable=$true;requiresBuildJvmMatch=$false;evidenceDetails=@([pscustomobject]@{task='runClient';taskType='JavaExec';launcherSource='executable';executable='D:\jdk-17\bin\java.exe'})} # public-hygiene: allow-synthetic-path
        $probe=[pscustomobject]@{status='Observed';timestamp=[DateTimeOffset]::UtcNow.ToString('o');projectRoot=$project.Root;loader='Forge';loaderVersion='47.2.0';minecraft='1.20.1';buildJavaMajor='25';runtimeJavaRequirement=[pscustomobject]@{major=17};runtimeJavaBinding=$binding;cacheHit=$false}

        $evidence=Convert-TestFreshRuntimeBindingProbeToAdapterEvidence -Project $project -Plan $plan -ProbeResult $probe

        $evidence.runtimeJavaBindingMode | Should -BeExactly 'Direct'
        $evidence.runtimeJavaBindingEvidence.evidenceSource | Should -BeExactly 'GradleInitScriptJavaExecInspection'
        $evidence.runtimeJavaBindingEvidence.confidence | Should -BeExactly 'High'
    }

    It '拒绝目标不匹配、过期或失败的临时 Runtime Binding 探测' {
        $project=[pscustomobject]@{Root=(Join-Path $TestDrive 'fresh-probe-project');MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';Toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'}}
        $plan=[pscustomobject]@{buildJava=[pscustomobject]@{resolution=[pscustomobject]@{javaHome='D:\jdk-25';actualMajor=25}};runtimeJava=[pscustomobject]@{requirement=[pscustomobject]@{major=17};resolution=[pscustomobject]@{javaPath='D:\jdk-17\bin\java.exe';actualMajor=17}};runtime=[pscustomobject]@{roles=@([pscustomobject]@{role='Client'})}} # public-hygiene: allow-synthetic-path
        $binding=[pscustomobject]@{mode='Direct';confidence='High';evidenceSource='GradleInitScriptJavaExecInspection';runtimeJavaControllable=$true;requiresBuildJvmMatch=$false;evidenceDetails=@([pscustomobject]@{task='runClient';taskType='JavaExec';launcherSource='executable';executable='D:\jdk-17\bin\java.exe'})} # public-hygiene: allow-synthetic-path
        $probe=[pscustomobject]@{status='Observed';timestamp=[DateTimeOffset]::UtcNow.ToString('o');projectRoot=$project.Root;loader='Forge';loaderVersion='47.2.0';minecraft='1.20.1';buildJavaMajor='25';runtimeJavaRequirement=[pscustomobject]@{major=17};runtimeJavaBinding=$binding;cacheHit=$false}

        $probe.minecraft='1.20.2'
        { Convert-TestFreshRuntimeBindingProbeToAdapterEvidence -Project $project -Plan $plan -ProbeResult $probe } | Should -Throw '*RUNTIME_BINDING_FRESH_PROBE_IDENTITY_MISMATCH*'
        $probe.minecraft='1.20.1';$probe.timestamp=[DateTimeOffset]::UtcNow.AddMinutes(-16).ToString('o')
        { Convert-TestFreshRuntimeBindingProbeToAdapterEvidence -Project $project -Plan $plan -ProbeResult $probe } | Should -Throw '*RUNTIME_BINDING_FRESH_PROBE_STALE*'
        $probe.timestamp=[DateTimeOffset]::UtcNow.ToString('o');$probe.status='ProbeFailed'
        { Convert-TestFreshRuntimeBindingProbeToAdapterEvidence -Project $project -Plan $plan -ProbeResult $probe } | Should -Throw '*RUNTIME_BINDING_FRESH_PROBE_NOT_OBSERVED*'
    }

    It '在信任根之外拒绝 Gradle configuration' {
        $outside=Join-Path $TestDrive 'outside';New-Item -ItemType Directory -Path $outside -Force|Out-Null
        $project=[pscustomobject]@{Root=$outside;MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';Toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'};WrapperPath=(Join-Path $outside 'gradlew')}
        $called=$false
        $invoke={ $called=$true; throw '不应调用 Gradle' }.GetNewClosure()

        { Invoke-TestRuntimeBindingProbe -Project $project -Plan ([pscustomobject]@{}) -RuntimeRoot (Join-Path $TestDrive 'runtime') -TrustedProjectRoots @((Join-Path $TestDrive 'trusted')) -GradleInvoker $invoke } | Should -Throw '*RUNTIME_BINDING_PROJECT_NOT_TRUSTED*'
        $called | Should -BeFalse
    }

    It '只查询 runClient/runServer 的 task model，不执行它们' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project')
        $state=@{seen=$null}
        $invoke={ param($request) $state.seen=$request;[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}')} }.GetNewClosure()

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -Offline -GradleInvoker $invoke

        $result.status | Should -BeExactly 'TaskNotFound'
        $result.runtimeJavaBinding.mode | Should -BeExactly 'Unknown'
        $state.seen.arguments | Should -Contain '--dry-run'
        $state.seen.arguments | Should -Contain 'runClient'
        $state.seen.arguments | Should -Contain '--no-configuration-cache'
        $state.seen.arguments | Should -Not -Contain '--all'
        $state.seen.arguments | Should -Contain '--offline'
    }

    It 'Project 未提供 Gradle 版本时，从 Wrapper URL 解析并停用 configuration cache' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-wrapper-version')
        $project.BuildSystem.version=''
        $wrapperProperties=Join-Path $project.Root 'gradle/wrapper/gradle-wrapper.properties'
        New-Item -ItemType Directory -Path (Split-Path $wrapperProperties) -Force|Out-Null
        Set-Content -LiteralPath $wrapperProperties -Value 'distributionUrl=https\\://services.gradle.org/distributions/gradle-9.7.1-bin.zip'
        $state=@{seen=$null}
        $invoke={ param($request) $state.seen=$request;[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}')} }.GetNewClosure()

        $null=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime-wrapper-version') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -Offline -GradleInvoker $invoke

        $state.seen.arguments | Should -Contain '--no-configuration-cache'
    }

    It 'Gradle 2.7 探测不传入 Gradle 6.6 才引入的 configuration-cache 参数' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-gradle-2.7')
        $project.BuildSystem.version='2.7'
        $state=@{seen=$null}
        $invoke={ param($request) $state.seen=$request;[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[],"buildJavaHome":"<JAVA_HOME>","buildJavaVersion":"17.0.1"}')} }.GetNewClosure()

        $null=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime-gradle-2.7') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -Offline -GradleInvoker $invoke

        $state.seen.arguments | Should -Not -Contain '--no-configuration-cache'
        $state.seen.arguments | Should -Contain '--no-daemon'
        $state.seen.arguments | Should -Contain '--offline'
    }

    It 'Gradle 2.0 探测不传入不受支持的 console 参数' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-gradle-2.0')
        $project.BuildSystem.version='2.0'
        $state=@{seen=$null}
        $invoke={param($request)$state.seen=$request;[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}')}}.GetNewClosure()

        $null=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime-gradle-2.0') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -Offline -GradleInvoker $invoke

        $state.seen.arguments | Should -Not -Contain '--console=plain'
        $state.seen.arguments | Should -Contain '--init-script'
        $state.seen.arguments | Should -Contain '--no-daemon'
        $state.seen.arguments | Should -Contain '--offline'
    }

    It '观察 JavaExec 的 javaLauncher 并记录证据与缓存身份' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project')
        $output='MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>","buildJavaVersion":"17.0.1"}'
        $invoke={ param($request) [pscustomobject]@{exitCode=0;output=@($output)} }.GetNewClosure()

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime-javaexec') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $result.status | Should -BeExactly 'Observed'
        $result.runtimeJavaBinding.mode | Should -BeExactly 'SameAsBuildJvm'
        $result.runtimeJavaBinding.requiresBuildJvmMatch | Should -BeTrue
        $result.evidenceDetails[0].task | Should -BeExactly 'runClient'
        $result.runtimeJavaRequirement.major | Should -Be 17
        $result.adapterVersion | Should -BeExactly '9'
        $result.cacheKey | Should -Match '^[a-f0-9]{64}$'
        $result.cacheHit | Should -BeFalse
        $result.dirty | Should -BeFalse
    }

    It '在延迟注册的启动任务 realize 时观察最终 JavaExec 配置' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-lazy-launch-task')
        $state=@{initScript=''}
        $invoke={
            param($request)
            $initIndex=[Array]::IndexOf([string[]]$request.arguments,'--init-script')
            $state.initScript=[IO.File]::ReadAllText([string]$request.arguments[$initIndex+1])
            [pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"executable","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>","buildJavaVersion":"17.0.1"}')}
        }.GetNewClosure()

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime-lazy-launch-task') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $state.initScript | Should -Match 'tasks\.configureEach'
        $state.initScript | Should -Match 'MMTL_RUNTIME_BINDING_JSON:'
        $result.status | Should -BeExactly 'Observed'
        $result.evidenceDetails[0].task | Should -BeExactly 'runClient'
    }

    It '保持 Gradle Build JDK 并通过共享 init script 绑定不同的 Runtime JDK' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project-dual-jvm')
        $plan=New-TestBindingPlan
        $jdk25=Join-Path $TestDrive 'synthetic-jdks/jdk-25';$jdk21=Join-Path $TestDrive 'synthetic-jdks/jdk-21'
        $javaName=if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){'java.exe'}else{'java'}
        $runtimeJava=Join-Path (Join-Path $jdk21 'bin') $javaName
        $plan.buildJava.resolution=[pscustomobject]@{javaHome=$jdk25;actualMajor=25}
        $plan.runtimeJava=[pscustomobject]@{requirement=[pscustomobject]@{major=21};resolution=[pscustomobject]@{javaPath=$runtimeJava;actualMajor=21}}
        $state=@{request=$null}
        $observed=[pscustomobject]@{tasks=@([pscustomobject]@{task='runClient';taskType='org.gradle.api.tasks.JavaExec';isJavaExec=$true;launcherSource='javaLauncher';executable=$runtimeJava});buildJavaHome=$jdk25;buildJavaVersion='25.0.1'}
        $invoke={param($request)$state.request=$request;[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:'+(ConvertTo-Json -InputObject $observed -Depth 8 -Compress))}}.GetNewClosure()

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan $plan -RuntimeRoot (Join-Path $TestDrive 'runtime-dual-jvm') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $result.runtimeJavaBinding.mode | Should -BeExactly 'Direct' -Because ($result | ConvertTo-Json -Depth 8 -Compress)
        $result.runtimeJavaBinding.runtimeJavaControllable | Should -BeTrue
        $result.runtimeJavaBinding.requiresBuildJvmMatch | Should -BeFalse
        $result.buildSystemVersion | Should -BeExactly '8.8'
        $state.request.javaHome | Should -BeExactly $jdk25
        $state.request.runtimeJavaExecutable | Should -BeExactly $runtimeJava
        $state.request.runtimeJavaMajor | Should -Be 21
        ($state.request.arguments -join ' ') | Should -Match ([regex]::Escape("org.gradle.java.installations.paths=$jdk21"))
    }

    It 'dirty project 绕过已有 cache 并使用 offline Gradle probe' {
        $root=Join-Path $TestDrive 'trusted-project';$project=New-TestBindingProject -Root $root
        Set-Content -LiteralPath (Join-Path $root 'build.gradle') -Value 'plugins { id "base" }; // dirty working tree'
        $runtime=Join-Path $TestDrive 'runtime';$state=@{invocations=0}
        $invoke={ param($request) $state.invocations++;[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}')} }.GetNewClosure()

        $first=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $root -Parent)) -Offline -GradleInvoker $invoke
        $second=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $root -Parent)) -Offline -GradleInvoker $invoke

        $first.dirty | Should -BeTrue
        $second.cacheHit | Should -BeFalse
        $state.invocations | Should -Be 2
    }

    It 'clean project 按 cache key 重用探测结果' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project')
        $runtime=Join-Path $TestDrive 'runtime-clean-cache';$state=@{invocations=0}
        $invoke={ param($request) $state.invocations++;[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}')} }.GetNewClosure()
        $first=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke
        $second=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker {throw '有效缓存不应重跑 Gradle'}

        $first.cacheHit | Should -BeFalse
        $second.cacheHit | Should -BeTrue
        $second.cacheKey | Should -BeExactly $first.cacheKey
        $state.invocations | Should -Be 1
    }

    It '不缓存可由环境恢复的 Gradle 探针失败' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project-retryable-failure')
        $runtime=Join-Path $TestDrive 'runtime-retryable-failure';$state=@{invocations=0}
        $invoke={
            param($request)
            $state.invocations++
            if($state.invocations -eq 1){return [pscustomobject]@{exitCode=1;output=@('temporary dependency resolution failure')}}
            [pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>","buildJavaVersion":"17.0.1"}')}
        }.GetNewClosure()

        $first=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -Offline -GradleInvoker $invoke
        $second=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $first.status | Should -BeExactly 'ProbeFailed'
        $second.status | Should -BeExactly 'Observed'
        $second.cacheHit | Should -BeFalse
        $state.invocations | Should -Be 2
    }

    It 'Launch Preflight 只消费当前干净 SHA 的本地 probe evidence' {
        $root=Join-Path $TestDrive 'trusted-project';$project=New-TestBindingProject -Root $root
        $runtime=Join-Path $TestDrive 'runtime-evidence-read';$output='MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>","buildJavaVersion":"17.0.1"}'
        $invoke={ param($request) [pscustomobject]@{exitCode=0;output=@($output)} }.GetNewClosure()
        $null=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $root -Parent)) -GradleInvoker $invoke

        $cached=Get-MmtlCachedRuntimeBindingEvidence -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime

        $cached.runtimeJavaBinding.mode | Should -BeExactly 'SameAsBuildJvm'
        Set-Content -LiteralPath (Join-Path $root 'build.gradle') -Value 'changed after evidence'
        Get-MmtlCachedRuntimeBindingEvidence -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime | Should -BeNullOrEmpty
    }

    It '缓存读取必须匹配当前 Build Java 与平台完整身份' {
        $root=Join-Path $TestDrive 'trusted-project-cache-identity';$project=New-TestBindingProject -Root $root
        $runtime=Join-Path $TestDrive 'runtime-cache-identity';$plan=New-TestBindingPlan
        $output='MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>","buildJavaVersion":"17.0.1"}'
        $invoke={param($request)[pscustomobject]@{exitCode=0;output=@($output)}}.GetNewClosure()
        $null=Invoke-TestRuntimeBindingProbe -Project $project -Plan $plan -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $root -Parent)) -GradleInvoker $invoke

        (Get-MmtlCachedRuntimeBindingEvidence -Project $project -Plan $plan -RuntimeRoot $runtime).runtimeJavaBinding.mode | Should -BeExactly 'SameAsBuildJvm'
        $plan.buildJava.resolution.javaHome='<OTHER_JAVA_HOME>'
        Get-MmtlCachedRuntimeBindingEvidence -Project $project -Plan $plan -RuntimeRoot $runtime | Should -BeNullOrEmpty
        $plan.buildJava.resolution.javaHome='<JAVA_HOME>';$plan.platform.os='Linux'
        Get-MmtlCachedRuntimeBindingEvidence -Project $project -Plan $plan -RuntimeRoot $runtime | Should -BeNullOrEmpty
    }

    It '每个运行角色都必须有对应且可解析的最终 task 证据' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project-role-task')
        $plan=New-TestBindingPlan;$plan|Add-Member -NotePropertyName runtime -NotePropertyValue ([pscustomobject]@{roles=@([pscustomobject]@{role='Server'})})
        $state=@{request=$null}
        $invoke={param($request)$state.request=$request;[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>","buildJavaVersion":"17.0.1"}')}}.GetNewClosure()

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan $plan -RuntimeRoot (Join-Path $TestDrive 'runtime-role-task') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $result.runtimeJavaBinding.mode | Should -BeExactly 'Unknown'
        $result.errorCode | Should -BeExactly 'RUNTIME_BINDING_ROLE_TASK_UNAVAILABLE'
        $state.request.arguments | Should -Contain 'runServer'
    }

    It '只在观测到的 Gradle JVM 与 Plan Build Java 一致时声明 SameAsBuildJvm' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project-build-jvm')
        $plan=New-TestBindingPlan;$plan.buildJava.resolution.javaHome='<JAVA_HOME>'; $plan.buildJava.resolution.actualMajor=21;$plan.runtimeJava=[pscustomobject]@{requirement=[pscustomobject]@{major=17};resolution=[pscustomobject]@{javaPath='D:\java\jdk-17\bin\java.exe';actualMajor=17}} # public-hygiene: allow-synthetic-path
        $invoke={param($request)[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<OTHER_JAVA_HOME>","buildJavaVersion":"17.0.1"}')}}

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan $plan -RuntimeRoot (Join-Path $TestDrive 'runtime-build-jvm') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $result.runtimeJavaBinding.mode | Should -BeExactly 'Unknown'
        $result.errorCode | Should -BeExactly 'RUNTIME_BINDING_BUILD_JVM_MISMATCH'
    }

    It '将 Java 8 的 java.home JRE 子目录归一到对应 JDK home' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project-jdk8-home')
        $plan=New-TestBindingPlan
        $jdk8=Join-Path $TestDrive 'synthetic-jdks/jdk-8';$javaName=if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){'java.exe'}else{'java'}
        $plan.buildJava.resolution=[pscustomobject]@{javaHome=$jdk8;actualMajor=8}
        $plan.runtimeJava.requirement=[pscustomobject]@{major=8}
        $runtimeJava=Join-Path (Join-Path $jdk8 'bin') $javaName
        $observed=[pscustomobject]@{tasks=@([pscustomobject]@{task='runClient';taskType='org.gradle.api.tasks.JavaExec';isJavaExec=$true;launcherSource='executable';executable=$runtimeJava});buildJavaHome=(Join-Path $jdk8 'jre');buildJavaVersion='1.8.0_503'}
        $invoke={param($request)[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:'+(ConvertTo-Json -InputObject $observed -Depth 8 -Compress))}}.GetNewClosure()

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan $plan -RuntimeRoot (Join-Path $TestDrive 'runtime-jdk8-home') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $result.status | Should -BeExactly 'Observed'
        $result.runtimeJavaBinding.mode | Should -BeExactly 'SameAsBuildJvm'
        $result.runtimeJavaBinding.requiresBuildJvmMatch | Should -BeTrue
    }

    It 'Gradle JVM 版本与 Plan Build Java 不一致时不声明 SameAsBuildJvm' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project-build-version')
        $invoke={param($request)[pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>","buildJavaVersion":"21.0.1"}')}}

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime-build-version') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $result.runtimeJavaBinding.mode | Should -BeExactly 'Unknown'
        $result.errorCode | Should -BeExactly 'RUNTIME_BINDING_BUILD_JVM_MISMATCH'
        $result.observedBuildJavaVersion | Should -BeExactly '21.0.1'
    }

    It '默认执行器在隔离子进程中使用 Plan 的 JDK 且清理临时 init script' {
        $root=Join-Path $TestDrive 'trusted-project';$project=New-TestBindingProject -Root $root
        $javaHome=Join-Path $TestDrive 'build-java';$bin=Join-Path $javaHome 'bin';New-Item -ItemType Directory -Path $bin -Force|Out-Null
        $javaName=if($IsWindows){'java.exe'}else{'java'};Set-Content -LiteralPath (Join-Path $bin $javaName) -Value 'fixture'
        if($IsWindows){
            $wrapper=Join-Path $root 'gradlew.bat';[IO.File]::WriteAllText($wrapper,(@('@echo off','echo MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}') -join "`r`n"))
        }else{
            $wrapper=Join-Path $root 'gradlew';[IO.File]::WriteAllText($wrapper,(@('#!/bin/sh','printf "%s\n" ''MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}''') -join "`n"))
            [IO.File]::SetUnixFileMode($wrapper,[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute)
        }
        $project.WrapperPath=$wrapper
        $plan=New-TestBindingPlan;$plan.buildJava.resolution.javaHome=$javaHome
        $beforeJavaHome=$env:JAVA_HOME;$beforePath=$env:PATH

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan $plan -RuntimeRoot (Join-Path $TestDrive 'runtime-child-process') -TrustedProjectRoots @((Split-Path $root -Parent))

        $result.status | Should -BeExactly 'TaskNotFound'
        $result.evidencePath | Should -Exist
        $env:JAVA_HOME | Should -BeExactly $beforeJavaHome
        $env:PATH | Should -BeExactly $beforePath
        @(Get-ChildItem (Join-Path $TestDrive 'runtime-child-process/diagnostics/runtime-binding') -Filter 'probe-*.gradle' -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'Gradle 探测超时后终止本次启动的进程树并保留超时结果' {
        $root=Join-Path $TestDrive 'trusted-project-timeout';$project=New-TestBindingProject -Root $root
        $javaHome=Join-Path $TestDrive 'timeout-build-java';$bin=Join-Path $javaHome 'bin';New-Item -ItemType Directory -Path $bin -Force|Out-Null
        $javaName=if($IsWindows){'java.exe'}else{'java'};Set-Content -LiteralPath (Join-Path $bin $javaName) -Value 'fixture'
        if($IsWindows){
            $wrapper=Join-Path $root 'gradlew.bat';[IO.File]::WriteAllText($wrapper,(@('@echo off','powershell.exe -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 15"','echo SHOULD_NOT_FINISH') -join "`r`n"))
        }else{
            $wrapper=Join-Path $root 'gradlew';[IO.File]::WriteAllText($wrapper,(@('#!/bin/sh','sleep 15','echo SHOULD_NOT_FINISH') -join "`n"))
            [IO.File]::SetUnixFileMode($wrapper,[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute)
        }
        $project.WrapperPath=$wrapper
        $plan=New-TestBindingPlan;$plan.buildJava.resolution.javaHome=$javaHome
        $stopwatch=[Diagnostics.Stopwatch]::StartNew()
        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan $plan -RuntimeRoot (Join-Path $TestDrive 'runtime-timeout') -TrustedProjectRoots @((Split-Path $root -Parent)) -GradleTimeoutSeconds 1
        $stopwatch.Stop()

        $result.status | Should -BeExactly 'ProbeFailed'
        $result.errorCode | Should -BeExactly 'RUNTIME_BINDING_GRADLE_TIMEOUT'
        $result.diagnosticSummary | Should -Match 'timeout'
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 8
    }

    It '把受信任的本地 Maven 镜像加入离线 Gradle 项目仓库' {
        $mirror=Join-Path $TestDrive 'pinned-maven-mirror'
        New-Item -ItemType Directory -Path $mirror -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $mirror 'maven-metadata.xml') -Value '<metadata />'
        $scriptText=& $script:probeModule {
            param($path)
            New-MmtlRuntimeBindingGradleInitScript -RuntimeJavaMajor 17 -LocalMavenMirrorPath $path
        } $mirror

        $scriptText | Should -Match 'mmtlPinnedMavenMirror'
        $scriptText | Should -Match 'MMTL_RUNTIME_BINDING_MAVEN_MIRROR'
        $scriptText | Should -Match 'beforeProject'
        $scriptText | Should -Match 'metadataSources'
        $scriptText | Should -Match 'artifact\(\)'
    }

    It '为本地 Maven 镜像生成内容敏感摘要并拒绝信任根外路径' {
        $trusted=Join-Path $TestDrive 'trusted-mirror-root'
        $mirror=Join-Path $trusted 'mirror'
        New-Item -ItemType Directory -Path $mirror -Force | Out-Null
        $artifact=Join-Path $mirror 'artifact.pom'
        Set-Content -LiteralPath $artifact -Value '<project />'
        $identity=& $script:probeModule {
            param($path,$roots)
            Get-MmtlProbeDirectoryIdentity -Path $path -TrustedRoots $roots
        } $mirror @($trusted)
        $identity.sha256 | Should -Match '^[a-f0-9]{64}$'

        Set-Content -LiteralPath $artifact -Value '<project><version>2</version></project>'
        $changed=& $script:probeModule {
            param($path,$roots)
            Get-MmtlProbeDirectoryIdentity -Path $path -TrustedRoots $roots
        } $mirror @($trusted)
        $changed.sha256 | Should -Not -BeExactly $identity.sha256

        $outside=Join-Path $TestDrive 'untrusted-mirror'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        { & $script:probeModule { param($path,$roots) Get-MmtlProbeDirectoryIdentity -Path $path -TrustedRoots $roots } $outside @($trusted) } | Should -Throw '*RUNTIME_BINDING_MIRROR_NOT_TRUSTED*'
    }

    It '仅按显式精确动态版本 pin 配置 Gradle 依赖解析' {
        $pins=@([pscustomobject]@{group='net.minecraftforge';artifact='forgespi';selector='1.1.+';version='1.5.0'})
        $scriptText=& $script:probeModule {
            param($resolutions)
            New-MmtlRuntimeBindingGradleInitScript -RuntimeJavaMajor 8 -PinnedDynamicVersionResolutions $resolutions
        } $pins

        $scriptText | Should -Match 'resolutionStrategy.eachDependency'
        $scriptText | Should -Match 'net\.minecraftforge'
        $scriptText | Should -Match '1\.1\.\+'
        $scriptText | Should -Match 'details\.useVersion\(pin\.version\)'
        $scriptText | Should -Match '"version":"1\.5\.0"'
    }

    It '没有动态版本 pin 时不在 init script 中注入空 pin 解析规则' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-no-dynamic-pins')
        $state=@{initScript=''}
        $invoke={
            param($request)
            $initIndex=[Array]::IndexOf([string[]]$request.arguments,'--init-script')
            $state.initScript=[IO.File]::ReadAllText([string]$request.arguments[$initIndex+1])
            [pscustomobject]@{exitCode=0;output=@('MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}')}
        }.GetNewClosure()

        $null=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime-no-dynamic-pins') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -Offline -GradleInvoker $invoke

        $state.initScript | Should -Not -Match 'resolutionStrategy\.eachDependency'
        $state.initScript | Should -Not -Match 'mmtlPinnedDynamicVersionResolutions'
    }
}
