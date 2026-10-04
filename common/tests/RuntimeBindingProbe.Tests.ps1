BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:probeModule=Import-Module (Join-Path $script:repoRoot 'src/RuntimeBindingProbe.psm1') -Force -PassThru
    function Invoke-TestRuntimeBindingProbe { param($Project,$Plan,[string]$RuntimeRoot,[string[]]$TrustedProjectRoots,[switch]$Offline,[scriptblock]$GradleInvoker) & $script:probeModule { param($p,$plan,$runtime,$trusted,$offline,$invoker) Invoke-MmtlRuntimeBindingProbe -Project $p -Plan $plan -RuntimeRoot $runtime -TrustedProjectRoots $trusted -Offline:$offline -GradleInvoker $invoker } $Project $Plan $RuntimeRoot $TrustedProjectRoots $Offline $GradleInvoker }
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
        $state.seen.arguments | Should -Contain 'tasks'
        $state.seen.arguments | Should -Contain '--all'
        $state.seen.arguments | Should -Contain '--no-configuration-cache'
        ($state.seen.arguments -join ' ') | Should -Not -Match '(^|\s)run(Client|Server)(\s|$)'
        $state.seen.arguments | Should -Contain '--offline'
    }

    It '观察 JavaExec 的 javaLauncher 并记录证据与缓存身份' {
        $project=New-TestBindingProject -Root (Join-Path $TestDrive 'trusted-project')
        $output='MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>"}'
        $invoke={ param($request) [pscustomobject]@{exitCode=0;output=@($output)} }.GetNewClosure()

        $result=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot (Join-Path $TestDrive 'runtime-javaexec') -TrustedProjectRoots @((Split-Path $project.Root -Parent)) -GradleInvoker $invoke

        $result.status | Should -BeExactly 'Observed'
        $result.runtimeJavaBinding.mode | Should -BeExactly 'SameAsBuildJvm'
        $result.runtimeJavaBinding.requiresBuildJvmMatch | Should -BeTrue
        $result.evidenceDetails[0].task | Should -BeExactly 'runClient'
        $result.runtimeJavaRequirement.major | Should -Be 17
        $result.adapterVersion | Should -BeExactly '7'
        $result.cacheKey | Should -Match '^[a-f0-9]{64}$'
        $result.cacheHit | Should -BeFalse
        $result.dirty | Should -BeFalse
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

    It 'Launch Preflight 只消费当前干净 SHA 的本地 probe evidence' {
        $root=Join-Path $TestDrive 'trusted-project';$project=New-TestBindingProject -Root $root
        $runtime=Join-Path $TestDrive 'runtime-evidence-read';$output='MMTL_RUNTIME_BINDING_JSON:{"tasks":[{"task":"runClient","taskType":"org.gradle.api.tasks.JavaExec","isJavaExec":true,"launcherSource":"javaLauncher","executable":"<JAVA_HOME>/bin/java"}],"buildJavaHome":"<JAVA_HOME>"}'
        $invoke={ param($request) [pscustomobject]@{exitCode=0;output=@($output)} }.GetNewClosure()
        $null=Invoke-TestRuntimeBindingProbe -Project $project -Plan (New-TestBindingPlan) -RuntimeRoot $runtime -TrustedProjectRoots @((Split-Path $root -Parent)) -GradleInvoker $invoke

        $cached=Get-MmtlCachedRuntimeBindingEvidence -ProjectRoot $root -RuntimeRoot $runtime

        $cached.runtimeJavaBinding.mode | Should -BeExactly 'SameAsBuildJvm'
        Set-Content -LiteralPath (Join-Path $root 'build.gradle') -Value 'changed after evidence'
        Get-MmtlCachedRuntimeBindingEvidence -ProjectRoot $root -RuntimeRoot $runtime | Should -BeNullOrEmpty
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
}
