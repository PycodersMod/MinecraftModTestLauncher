BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repoRoot 'common/src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
    Register-MmtlWindowsPlatform -RepositoryRoot $script:repoRoot
    $script:projectRoot = Join-Path $TestDrive 'sample-repository/forge/1.20.1'
    $script:javaHome = Join-Path $TestDrive 'jdk-17'
    $script:runtimeRoot = Join-Path $TestDrive 'mmtl-runtime'
    New-Item -ItemType Directory -Path (Join-Path $script:projectRoot 'gradle/wrapper'),(Join-Path $script:projectRoot 'src/main/resources/META-INF'),(Join-Path $script:javaHome 'bin') -Force | Out-Null
    'plugins { id "net.minecraftforge.gradle" version "6.0.0" }' | Set-Content (Join-Path $script:projectRoot 'build.gradle')
    "minecraft_version=1.20.1`nforge_version=47.2.0`njava_version=17`nmod_id=phaseh_fixture" | Set-Content (Join-Path $script:projectRoot 'gradle.properties')
    '[[mods]]`nmodId="phaseh_fixture"' | Set-Content (Join-Path $script:projectRoot 'src/main/resources/META-INF/mods.toml')
    'distributionUrl=https\://services.gradle.org/distributions/gradle-8.8-bin.zip' | Set-Content (Join-Path $script:projectRoot 'gradle/wrapper/gradle-wrapper.properties')
    @('@echo off','if not exist build\libs mkdir build\libs','echo fixture > build\libs\fixture.jar','exit /b 0') | Set-Content -LiteralPath (Join-Path $script:projectRoot 'gradlew.bat')
    New-Item -ItemType File -Path (Join-Path $script:projectRoot 'gradle/wrapper/gradle-wrapper.jar') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $script:javaHome 'bin/java.exe') -Force | Out-Null
    @('JAVA_VERSION="17.0.19"','IMPLEMENTOR="Oracle Corporation"','OS_ARCH="amd64"','OS_NAME="Windows"') | Set-Content (Join-Path $script:javaHome 'release')
    $script:configPath = Join-Path $TestDrive 'launcher.config.json'
    $config=[ordered]@{configVersion=2;defaultProfile='fixture';runtimeRoot=$script:runtimeRoot;javaHomes=@{'17'=$script:javaHome};javaHomesByPlatform=@{Windows=@{};Linux=@{};MacOS=@{}};profiles=@{fixture=@{project=$script:projectRoot;linkedProjects=@();mode='Single';players=1;hostUsername='Dev';clientPrefix='Dev_';autoBuild=$true;cleanBuild=$false;acceptEula=$false;port='Auto';memoryMb=0;hostMemoryMb=0;clientMemoryMb=0;serverMemoryMb=0;jvmArgs=@();gameArgs=@();extraMods=@();resolution='1280x720';guiScale='Auto';windowLayout='None'}}}
    $config | ConvertTo-Json -Depth 20 | Set-Content $script:configPath
    $script:launcher = Join-Path $script:repoRoot 'windows/launcher.ps1'
    $script:pwsh = (Get-Command pwsh -ErrorAction Stop).Source
}

Describe 'Execution Plan CLI' {
    It '--plan --json 仅输出可解析 JSON 且不创建 Runtime/Session' {
        $output = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --plan --json 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $plan = $output | ConvertFrom-Json -ErrorAction Stop
        $plan.schemaVersion | Should -Be 1
        $plan.semanticDigest | Should -Match '^sha256:[0-9a-f]{64}$'
        $plan.buildJava.resolution.actualMajor | Should -Be 17
        Test-Path -LiteralPath $script:runtimeRoot | Should -BeFalse
    }

    It '--plan-output 只写入用户指定文件' {
        $outputPath = Join-Path $TestDrive 'saved-plan.json'
        $output = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --plan --plan-output $outputPath 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        Test-Path -LiteralPath $outputPath | Should -BeTrue
        $saved = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $saved.planId | Should -Match '^plan-[0-9a-f]{16}$'
        Test-Path -LiteralPath $script:runtimeRoot | Should -BeFalse
    }

    It '--explain-java --json 返回独立 Build/Runtime 轨和 binding mode' {
        $output = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --explain-java --json 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $explanation = $output | ConvertFrom-Json -ErrorAction Stop
        $explanation.buildJava.requirement.purpose | Should -BeExactly 'BuildJava'
        $explanation.runtimeJava.requirement.purpose | Should -BeExactly 'RuntimeJava'
        $explanation.runtimeJava.bindingMode | Should -BeExactly 'Unknown'
    }

    It '--launch-check --json 仅输出 Launch Preflight JSON，Blocked 使用稳定退出码 2' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --launch-check --json 2>&1|Out-String

        $LASTEXITCODE | Should -Be 2
        $check=$output|ConvertFrom-Json -ErrorAction Stop
        $check.capabilityGates.buildReady | Should -BeTrue
        $check.capabilityGates.launchReady | Should -BeFalse
        $check.launchBlockingReasons.code | Should -Contain 'RUNTIME_JAVA_BINDING_UNKNOWN'
        Test-Path -LiteralPath $script:runtimeRoot | Should -BeFalse
    }

    It '--build 路径可调用 Session 元数据锁并完成会话初始化' {
        try {
            $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --build 2>&1|Out-String

            $LASTEXITCODE | Should -Be 0
            $session=Get-ChildItem -LiteralPath (Join-Path $script:runtimeRoot 'sessions') -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $state=Get-Content -LiteralPath (Join-Path $session.FullName 'session.json') -Raw | ConvertFrom-Json
            $state.buildResult.exitCode | Should -Be 0
            $state.executionPlanDigest | Should -Match '^sha256:[0-9a-f]{64}$'
        } finally {
            if(Test-Path -LiteralPath $script:runtimeRoot){Remove-Item -LiteralPath $script:runtimeRoot -Recurse -Force}
        }
    }

    It '--runtime-binding --json 在无可信 Probe 证据时保留 Unknown' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --runtime-binding --json 2>&1|Out-String

        $LASTEXITCODE | Should -Be 0
        $binding=$output|ConvertFrom-Json -ErrorAction Stop
        $binding.mode | Should -BeExactly 'Unknown'
        $binding.compatibility | Should -BeExactly 'Unknown'
        Test-Path -LiteralPath $script:runtimeRoot | Should -BeFalse
    }

    It '--runtime-binding --probe 不信任配置中的任意项目且不执行其 wrapper' {
        $project=Join-Path $TestDrive 'untrusted-project';Copy-Item -LiteralPath $script:projectRoot -Destination $project -Recurse -Force
        $marker=Join-Path $TestDrive 'untrusted-wrapper-executed.txt'
        @('@echo off',"echo executed>$marker",'echo MMTL_RUNTIME_BINDING_JSON:{"tasks":[]}')|Set-Content -LiteralPath (Join-Path $project 'gradlew.bat')
        $config=Get-Content -LiteralPath $script:configPath -Raw|ConvertFrom-Json
        $config.profiles.fixture.project=$project
        $testConfig=Join-Path $TestDrive 'untrusted-config.json';$config|ConvertTo-Json -Depth 30|Set-Content $testConfig

        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $testConfig --runtime-binding --probe --json 2>&1|Out-String

        $LASTEXITCODE | Should -Be 2
        $output | Should -Match 'RUNTIME_BINDING_PROJECT_NOT_TRUSTED'
        Test-Path -LiteralPath $marker | Should -BeFalse
    }

    It '--capabilities --json 无配置依赖并输出平台能力' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --capabilities --json 2>&1|Out-String

        $LASTEXITCODE | Should -Be 0
        $capabilities=$output|ConvertFrom-Json -ErrorAction Stop
        $capabilities.os | Should -BeExactly 'Windows'
        $capabilities.Build | Should -BeExactly 'Native'
        $capabilities.PSObject.Properties.Name | Should -Contain 'ProcessManagement'
        $capabilities.PSObject.Properties.Name | Should -Contain 'RuntimeBinding'
    }

    It '--doctor --offline --json 返回状态化 checks 且不联网' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --doctor --offline --json 2>&1|Out-String

        $doctor=$output|ConvertFrom-Json -ErrorAction Stop
        $doctor.offline | Should -BeTrue
        $doctor.checks.Count | Should -BeGreaterThan 10
        ($doctor.checks|Where-Object id -eq 'NETWORK_METADATA').status | Should -BeExactly 'SKIP'
        ($doctor.checks|Where-Object id -eq 'JAVA_DISCOVERY').Count | Should -Be 1
        ($doctor.checks|Where-Object id -eq 'BUILD_JAVA').status | Should -Not -BeExactly 'SKIP'
        ($doctor.checks|Where-Object id -eq 'RUNTIME_JAVA').status | Should -Not -BeExactly 'SKIP'
        ($doctor.checks|Where-Object id -eq 'LAUNCH_TASKS').status | Should -Not -BeExactly 'SKIP'
        ($doctor.checks|Where-Object id -eq 'GRADLE_WRAPPER_JAR').Count | Should -Be 1
        ($doctor.checks|Where-Object id -eq 'PROCESS_MANAGEMENT').Count | Should -Be 1
        $output | Should -Not -Match 'token-value|secret.invalid'
    }

    It '--dry-run 与 --validate 消费同一 Planner 且不创建 Session 或 Runtime' {
        $dry = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --dry-run 2>&1 | Out-String
        if($LASTEXITCODE -ne 0){throw "dry-run exit=$LASTEXITCODE`n$dry"}
        $LASTEXITCODE | Should -Be 0
        $dry | Should -Match 'Build Java'
        $dry | Should -Match 'Auto 端口'
        $validate = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --validate 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $validate | Should -Match 'Plan 校验：PASS'
        Test-Path -LiteralPath $script:runtimeRoot | Should -BeFalse
    }

    It 'Session CLI 可读取 v1 legacy、列出 v2 并校验 Plan 摘要' {
        Import-Module (Join-Path $script:repoRoot 'common/src/Execution/ExecutionPlan.psm1')
        Import-Module (Join-Path $script:repoRoot 'common/src/SessionLifecycle.psm1')
        $planRaw=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --plan --json 2>&1|Out-String
        $plan=$planRaw|ConvertFrom-Json -ErrorAction Stop
        $legacyId='20261004T130000Z_legacy_fixture';$legacyPath=Join-Path $script:runtimeRoot "sessions/$legacyId"
        New-Item -ItemType Directory -Path $legacyPath -Force|Out-Null
        @{sessionId=$legacyId;createdUtc='2026-10-04T00:00:00Z';metadata=@{mode='Single'}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $legacyPath 'session.json')
        $legacyBytes=(Get-FileHash (Join-Path $legacyPath 'session.json') -Algorithm SHA256).Hash
        $legacyInfoRaw=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --session-info $legacyId --json 2>&1|Out-String
        $legacyInfo=$legacyInfoRaw|ConvertFrom-Json -ErrorAction Stop
        $legacyInfo.schemaVersion | Should -Be 1
        $legacyInfo.state | Should -BeExactly 'LegacyReadOnly'
        (Get-FileHash (Join-Path $legacyPath 'session.json') -Algorithm SHA256).Hash | Should -BeExactly $legacyBytes

        $v2Id='20261004T130001Z_v2_fixture';$v2Path=Join-Path $script:runtimeRoot "sessions/$v2Id"
        New-Item -ItemType Directory -Path $v2Path -Force|Out-Null
        Initialize-MmtlSessionV2 -SessionPath $v2Path -ExecutionPlan $plan|Out-Null
        $listRaw=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --list-sessions --json 2>&1|Out-String
        $list=@($listRaw|ConvertFrom-Json -ErrorAction Stop)
        ($list|Where-Object sessionId -eq $v2Id).validation | Should -BeExactly 'Valid'
        $infoRaw=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --session-info $v2Id --json 2>&1|Out-String
        ($infoRaw|ConvertFrom-Json -ErrorAction Stop).planDigest | Should -BeExactly $plan.semanticDigest
        $validateRaw=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --session-validate $v2Id --json 2>&1|Out-String
        $validate=$validateRaw|ConvertFrom-Json -ErrorAction Stop
        $LASTEXITCODE | Should -Be 0
        $validate.valid | Should -BeTrue
    }

    It '--recover-sessions --dry-run --json 只输出无路径的恢复计划，默认执行只修复 stale 元数据' {
        $sessionId='20261004T130002Z_recovery_fixture';$session=Join-Path $script:runtimeRoot "sessions/$sessionId";New-Item -ItemType Directory $session -Force|Out-Null
        @{schemaVersion=1;ownerPid=2147483647;processStartIdentity='0';createdUtc='2000-01-01T00:00:00Z';nonce='fixture'}|ConvertTo-Json -Compress|Set-Content (Join-Path $session '.session.lock')
        $lockPath=Join-Path $session '.session.lock';$before=(Get-FileHash $lockPath -Algorithm SHA256).Hash
        $dry=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --recover-sessions --dry-run --json 2>&1|Out-String
        $LASTEXITCODE|Should -Be 0;$preview=$dry|ConvertFrom-Json -ErrorAction Stop
        $preview.dryRun|Should -BeTrue;$dry|Should -Not -Match [regex]::Escape($script:runtimeRoot)
        (Get-FileHash $lockPath -Algorithm SHA256).Hash|Should -BeExactly $before

        $applied=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --recover-sessions --json 2>&1|Out-String
        $LASTEXITCODE|Should -Be 0;($applied|ConvertFrom-Json -ErrorAction Stop).recovered|Should -Be 1
        (Get-Content $lockPath -Raw|ConvertFrom-Json).recoveryState|Should -BeExactly 'Recovered'
    }

    It '--list-sessions --json 按 createdUtc 降序稳定排序' {
        $sessions=Join-Path $script:runtimeRoot 'sessions';New-Item -ItemType Directory $sessions -Force|Out-Null
        foreach($entry in @(@{id='20261004T130010Z_old';created='2026-10-03T00:00:00Z'},@{id='20261004T130011Z_tie_b';created='2026-10-05T00:00:00Z'},@{id='20261004T130012Z_tie_a';created='2026-10-05T00:00:00Z'})){
            $path=Join-Path $sessions $entry.id;New-Item -ItemType Directory $path -Force|Out-Null
            @{sessionId=$entry.id;createdUtc=$entry.created;metadata=@{}}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $path 'session.json')
        }
        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --list-sessions --json 2>&1|Out-String
        $LASTEXITCODE|Should -Be 0;$rows=@($output|ConvertFrom-Json -ErrorAction Stop)
        $fixtureRows=@($rows|Where-Object sessionId -in @('20261004T130012Z_tie_a','20261004T130011Z_tie_b','20261004T130010Z_old'))
        @($fixtureRows|Select-Object -ExpandProperty sessionId)|Should -Be @('20261004T130011Z_tie_b','20261004T130012Z_tie_a','20261004T130010Z_old')
    }
}
