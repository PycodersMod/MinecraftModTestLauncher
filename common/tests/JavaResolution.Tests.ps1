BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Execution/JavaResolution.psm1') -Force
}

Describe 'Build/Runtime Java 本机候选解析' {
    BeforeEach {
        $script:jdk17 = Join-Path $TestDrive 'jdk-17'
        $script:jdk21 = Join-Path $TestDrive 'jdk-21'
        foreach ($jdk in @($script:jdk17, $script:jdk21)) {
            New-Item -ItemType Directory -Path (Join-Path $jdk 'bin') -Force | Out-Null
        }
        New-Item -ItemType File -Path (Join-Path $script:jdk17 'bin/java.exe') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $script:jdk21 'bin/java.exe') -Force | Out-Null
        @('JAVA_VERSION="17.0.19"','IMPLEMENTOR="Oracle Corporation"','OS_ARCH="amd64"') | Set-Content (Join-Path $script:jdk17 'release')
        @('JAVA_VERSION="21.0.9"','IMPLEMENTOR="Eclipse Adoptium"','OS_ARCH="x86_64"') | Set-Content (Join-Path $script:jdk21 'release')
    }

    It '按 Build Java 最低版本和优先版本解析已配置候选及 release 元数据' {
        $requirement = [pscustomobject]@{ purpose='BuildJava'; major=17; minimumMajor=17; preferredMajor=21; requirementKind='Minimum'; source='GradleWrapperRuntimeCompatibility'; confidence='High' }
        $result = Resolve-MmtlJavaCandidate -Requirement $requirement -JavaHomes @{ '17'=$script:jdk17; '21'=$script:jdk21 } -Platform ([pscustomobject]@{ os='Windows'; arch='x64' })

        $result.status | Should -BeExactly 'Resolved'
        $result.actualMajor | Should -Be 21
        $result.exactVersion | Should -BeExactly '21.0.9'
        $result.vendor | Should -BeExactly 'Eclipse Adoptium'
        $result.arch | Should -BeExactly 'x64'
        $result.javaPath | Should -Be (Join-Path $script:jdk21 'bin/java.exe')
    }

    It '不会把超过 Gradle Wrapper JVM 上限的 JDK 选作 Build Java' {
        $requirement = [pscustomobject]@{ purpose='BuildJava'; major=8; minimumMajor=8; maximumMajor=10; requirementKind='Minimum'; source='GradleWrapperRuntimeCompatibility'; confidence='High' }
        $result = Resolve-MmtlJavaCandidate -Requirement $requirement -JavaHomes @{ '17'=$script:jdk17; '21'=$script:jdk21 } -Platform ([pscustomobject]@{ os='Windows'; arch='x64' })
        $result.status | Should -BeExactly 'Unresolved'
        $result.actualMajor | Should -BeNullOrEmpty
    }

    It '不把缺少所需 Runtime Java 误报为 Build Java 已解析' {
        $requirement = [pscustomobject]@{ purpose='RuntimeJava'; major=21; requirementKind='Exact'; source='MojangVersionMetadata'; confidence='High' }
        $result = Resolve-MmtlJavaCandidate -Requirement $requirement -JavaHomes @{ '17'=$script:jdk17 } -Platform ([pscustomobject]@{ os='Windows'; arch='x64' })

        $result.status | Should -BeExactly 'Unresolved'
        $result.reasonCode | Should -BeExactly 'RUNTIME_JAVA_NOT_RESOLVED'
        $result.actualMajor | Should -BeNullOrEmpty
    }

    It 'Build Java Exact requirement 不接受其他已配置主版本' {
        $requirement = [pscustomobject]@{ purpose='BuildJava'; major=17; exactMajor=17; requirementKind='Exact'; source='Fixture'; confidence='High' }
        $result = Resolve-MmtlJavaCandidate -Requirement $requirement -JavaHomes @{ '21'=$script:jdk21 } -Platform ([pscustomobject]@{ os='Windows'; arch='x64' })

        $result.status | Should -BeExactly 'Unresolved'
        $result.reasonCode | Should -BeExactly 'BUILD_JAVA_NOT_RESOLVED'
    }

    It '优先使用平台专属 Java 配置并保留通用回退项' {
        $platformJdk17 = Join-Path $TestDrive 'jdk-17-windows-override'
        New-Item -ItemType Directory -Path (Join-Path $platformJdk17 'bin') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $platformJdk17 'bin/java.exe') -Force | Out-Null
        @('JAVA_VERSION="17.0.20"','IMPLEMENTOR="Oracle Corporation"','OS_ARCH="amd64"') | Set-Content (Join-Path $platformJdk17 'release')
        $config = [pscustomobject]@{
            javaHomes = [pscustomobject]@{ '17'=$script:jdk17; '21'=$script:jdk21 }
            javaHomesByPlatform = [pscustomobject]@{ Windows=[pscustomobject]@{ '17'=$platformJdk17 }; Linux=[pscustomobject]@{}; MacOS=[pscustomobject]@{} }
        }
        $homes = Get-MmtlJavaHomesForPlatform -Config $config -Platform ([pscustomobject]@{os='Windows';arch='x64'})
        $homes['21'] | Should -BeExactly $script:jdk21
        $homes['17'] | Should -BeExactly $platformJdk17
    }

    It '拒绝与运行平台架构不符的 Java candidate' {
        $requirement = [pscustomobject]@{ purpose='BuildJava'; major=17; minimumMajor=17; requirementKind='Minimum'; source='GradleWrapperRuntimeCompatibility'; confidence='High' }
        New-Item -ItemType File -Path (Join-Path $script:jdk17 'bin/java') -Force | Out-Null
        $result = Resolve-MmtlJavaCandidate -Requirement $requirement -JavaHomes @{ '17'=$script:jdk17 } -Platform ([pscustomobject]@{ os='Linux'; arch='ARM64' })

        $result.status | Should -BeExactly 'Unresolved'
        $result.reasonCode | Should -BeExactly 'BUILD_JAVA_ARCH_MISMATCH'
    }

    It '只读 JDK release 文件且不会执行 java binary' {
        $marker = Join-Path $TestDrive 'java-was-executed.txt'
        $fakeJava = Join-Path $script:jdk17 'bin/java.exe'
        Set-Content -LiteralPath $fakeJava -Value "Set-Content '$marker' executed"
        $requirement = [pscustomobject]@{ purpose='BuildJava'; major=17; minimumMajor=17; requirementKind='Minimum'; source='GradleWrapperRuntimeCompatibility'; confidence='High' }

        $null = Resolve-MmtlJavaCandidate -Requirement $requirement -JavaHomes @{ '17'=$script:jdk17 } -Platform ([pscustomobject]@{ os='Windows'; arch='x64' })

        Test-Path -LiteralPath $marker | Should -BeFalse
    }
}
