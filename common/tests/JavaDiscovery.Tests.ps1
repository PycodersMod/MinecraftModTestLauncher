BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/JavaDiscovery.psm1') -Force
    $script:oldJavaHome=$env:JAVA_HOME;$script:oldPath=$env:PATH;$env:JAVA_HOME='';$env:PATH=''
    function New-TestDiscoveredJdk { param([string]$JdkPath,[int]$Major,[string]$Vendor='Test Vendor')
        New-Item -ItemType Directory -Path (Join-Path $JdkPath 'bin') -Force|Out-Null
        New-Item -ItemType File -Path (Join-Path $JdkPath 'bin/java.exe') -Force|Out-Null
        New-Item -ItemType File -Path (Join-Path $JdkPath 'bin/javac.exe') -Force|Out-Null
        @("JAVA_VERSION=`"$Major.0.1`"","IMPLEMENTOR=`"$Vendor`"",'OS_ARCH="amd64"')|Set-Content (Join-Path $JdkPath 'release')
    }
}
AfterAll { $env:JAVA_HOME=$script:oldJavaHome;$env:PATH=$script:oldPath }

Describe 'Java Discovery' {
    It '按主版本与来源稳定排序并保留 java/javac 与元数据' {
        $jdk17=Join-Path $TestDrive 'jdk17';$jdk21=Join-Path $TestDrive 'jdk21';New-TestDiscoveredJdk $jdk17 17 'Oracle Corporation';New-TestDiscoveredJdk $jdk21 21 'Eclipse Adoptium'
        $before=[pscustomobject]@{javaHomes=[pscustomobject]@{'17'='unchanged'}}|ConvertTo-Json -Compress
        $platform=[pscustomobject]@{OS='Test';JavaExecutable='java.exe';JavacExecutable='javac.exe';ExecutableSuffix='.exe'}

        $found=Get-MmtlJavaDiscovery -Platform $platform -AdditionalRoots @($jdk17,$jdk21)

        $found.candidates.Count | Should -Be 2
        $found.candidates[0].major | Should -Be 21
        $found.candidates[1].vendor | Should -BeExactly 'Oracle Corporation'
        $found.candidates[0].javacPath | Should -BeLike '*jdk21*javac.exe'
        $found.candidates[0].architecture | Should -BeExactly 'x64'
        ([pscustomobject]@{javaHomes=[pscustomobject]@{'17'='unchanged'}}|ConvertTo-Json -Compress) | Should -BeExactly $before
    }

    It '忽略不完整的 JRE 候选并不递归扫描额外目录' {
        $root=Join-Path $TestDrive 'root';$nested=Join-Path $root 'nested/jdk';New-Item -ItemType Directory -Path (Join-Path $nested 'bin') -Force|Out-Null
        New-Item -ItemType File -Path (Join-Path $nested 'bin/java.exe') -Force|Out-Null
        @('JAVA_VERSION="17.0.1"','IMPLEMENTOR="Test"','OS_ARCH="amd64"')|Set-Content (Join-Path $nested 'release')
        $platform=[pscustomobject]@{OS='Test';JavaExecutable='java.exe';JavacExecutable='javac.exe';ExecutableSuffix='.exe'}

        $found=Get-MmtlJavaDiscovery -Platform $platform -AdditionalRoots @($root)

        @($found.candidates).Count | Should -Be 0
    }
}
