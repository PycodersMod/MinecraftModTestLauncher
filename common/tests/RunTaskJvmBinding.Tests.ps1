BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:bindingModulePath = Join-Path $script:repoRoot 'src/RunTaskJvmBinding.psm1'
    if (Test-Path -LiteralPath $script:bindingModulePath -PathType Leaf) {
        $script:bindingModule = Import-Module $script:bindingModulePath -Force -PassThru
    }
}

Describe '受管 Gradle run task 的 Runtime Java 绑定' {
    It '把 MMTL 计划中的 JVM 参数传递给 runClient 和 runServer' {
        $command = Get-Command New-MmtlRunTaskJvmBindingInitScript -ErrorAction Stop
        $scriptText = & $command -RuntimeJavaMajor 21

        $scriptText | Should -Match "projectProperties\['pycodersJavaArgsB64'\]"
        $scriptText | Should -Match 'Base64\.decoder\.decode'
        $scriptText | Should -Match 'mmtlTask\.jvmArgs\(mmtlRuntimeJvmArgs\)'
        $scriptText | Should -Match 'MMTL_RUN_JVM_ARGUMENTS_INVALID'
    }

    It '把受管离线玩家名和游戏参数绑定到 runClient，而不修改 runServer' {
        $command = Get-Command New-MmtlRunTaskJvmBindingInitScript -ErrorAction Stop
        $scriptText = & $command -RuntimeJavaMajor 21

        $scriptText | Should -Match "projectProperties\['pycodersUsername'\]"
        $scriptText | Should -Match "projectProperties\['pycodersGameArgsB64'\]"
        $scriptText | Should -Match 'mmtlTask\.args'
        $scriptText | Should -Match "mmtlTaskName == 'runClient'"
        $scriptText | Should -Match "'--username'"
        $scriptText | Should -Match 'MMTL_RUN_USERNAME_INVALID'
        $scriptText | Should -Match 'MMTL_RUN_GAME_ARGUMENTS_INVALID'
    }

    It '为 JavaExec runClient/runServer 选择指定 Runtime JDK，并在任务执行前校验实际路径' {
        $command = Get-Command New-MmtlRunTaskJvmBindingInitScript -ErrorAction Stop
        $scriptText = & $command -RuntimeJavaMajor 21

        $scriptText | Should -Match "\['runClient', 'runServer'\]"
        $scriptText | Should -Match 'gradle\.projectsEvaluated'
        $scriptText | Should -Match 'tasks\.configureEach'
        $scriptText | Should -Not -Match 'mmtlProject\.tasks\.findByName'
        $scriptText | Should -Match 'launcherFor'
        $scriptText | Should -Match 'MMTL_RUNTIME_JAVA_HOME'
        $scriptText | Should -Match 'MMTL_RUNTIME_JAVA_MAJOR'
        $scriptText | Should -Match 'MMTL_RUNTIME_LAUNCHER_MISMATCH'
        $scriptText | Should -Match 'task\.javaLauncher\.set'
        $scriptText | Should -Match 'pycodersRuntimeDir'
        $scriptText | Should -Match 'mmtlTask\.workingDir'
        $scriptText | Should -Match 'mmtlRunConfiguration\.runDirectory'
    }

    It '为不支持 Java toolchain launcher API 的旧 Gradle 设定精确 executable 并校验' {
        $command = Get-Command New-MmtlRunTaskJvmBindingInitScript -ErrorAction Stop
        $scriptText = & $command -RuntimeJavaMajor 8

        $scriptText | Should -Match 'task\.setExecutable'
        $scriptText | Should -Match 'task\.executable'
        $scriptText | Should -Match 'MMTL_RUNTIME_JAVA_HOME'
    }

    It '在旧 Gradle（包括 2.7）回退到兼容的任务监听 API，同时保留新版 configureEach' {
        $command = Get-Command New-MmtlRunTaskJvmBindingInitScript -ErrorAction Stop
        $scriptText = & $command -RuntimeJavaMajor 8

        $scriptText | Should -Match 'GradleVersion\.current\(\)'
        $scriptText | Should -Match "GradleVersion\.version\('4\.9'\)"
        $scriptText | Should -Match 'tasks\.all'
        $scriptText | Should -Match 'tasks\.configureEach'
    }

    It '拒绝非法 Runtime Java major' {
        $command = Get-Command New-MmtlRunTaskJvmBindingInitScript -ErrorAction Stop

        { & $command -RuntimeJavaMajor 0 } | Should -Throw '*RUNTIME_JAVA_MAJOR_INVALID*'
    }

    It '对探针实现与共享 launcher 注入源生成联合 SHA-256 指纹' {
        $command = Get-Command Get-MmtlRunTaskJvmBindingSourceFingerprint -ErrorAction Stop
        $fingerprint = & $command

        $fingerprint.sha256 | Should -Match '^[a-f0-9]{64}$'
        @($fingerprint.sources).Count | Should -Be 2
        @($fingerprint.sources | ForEach-Object path) | Should -Contain 'common/src/RuntimeBindingProbe.psm1'
        @($fingerprint.sources | ForEach-Object path) | Should -Contain 'common/src/RunTaskJvmBinding.psm1'
    }
}
