BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'
    Import-Module (Join-Path $source 'Observation/RuntimeEvents.psm1') -Force
    Import-Module (Join-Path $source 'Observation/RuntimeEventStore.psm1') -Force
    Import-Module (Join-Path $source 'Observation/JavaRuntimeObserver.psm1') -Force
}

Describe 'Java Runtime Process Evidence' {
    BeforeEach {
        $script:session = Join-Path $TestDrive ('session_java_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $session -Force | Out-Null
        @([pscustomobject]@{PID=30;Role='Client';StartIdentity='gradle-start';RuntimeDirectory=(Join-Path $session 'Client');StatePath=(Join-Path $session 'process-30.exit.json')}) | ConvertTo-Json | Set-Content (Join-Path $session 'pids.json')
        $java = Join-Path $TestDrive ('java_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $java 'bin') -Force | Out-Null
        'synthetic-java-executable' | Set-Content (Join-Path $java 'bin/java.exe')
        @('JAVA_VERSION="21.0.7"','IMPLEMENTOR="Eclipse Adoptium"','OS_NAME="Windows"','OS_ARCH="amd64"') | Set-Content (Join-Path $java 'release')
        $script:javaPath = Join-Path $java 'bin/java.exe'
        [pscustomobject]@{project=[pscustomobject]@{loader=[pscustomobject]@{id='Forge'}};runtimeJava=[pscustomobject]@{bindingMode='Direct';resolution=[pscustomobject]@{javaPath=$javaPath;actualMajor=21}};buildJava=[pscustomobject]@{resolution=[pscustomobject]@{javaPath=$javaPath}}} | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $session 'execution-plan.json')
        $script:rootLookup = { param($processId) [pscustomobject]@{PID=$processId;StartIdentity='gradle-start';Executable='C:\PowerShell\pwsh.exe';CommandLine='pwsh gradle'} }
        $script:snapshot = { param($processId) @([pscustomobject]@{PID=30;StartIdentity='gradle-start';Depth=0;Executable='C:\PowerShell\pwsh.exe';CommandLine='pwsh gradle'},[pscustomobject]@{PID=31;ParentPID=30;StartIdentity='java-start';Depth=1;Executable=$script:javaPath;CommandLine='java net.minecraft.client.main.Main'}) }
        $script:lookup = { param($processId) if($processId -eq 30){[pscustomobject]@{PID=30;StartIdentity='gradle-start';Executable='C:\PowerShell\pwsh.exe';CommandLine='pwsh gradle'}}else{[pscustomobject]@{PID=31;ParentPID=30;StartIdentity='java-start';Executable=$script:javaPath;CommandLine='java net.minecraft.client.main.Main'}} }
        $script:identity = { param($process,$record) $process.StartIdentity -ceq $record.StartIdentity }
    }

    It '只观察登记进程树中的 Minecraft Java 子进程并隐藏绝对路径' {
        $result = Invoke-MmtlJavaRuntimeObserver -SessionPath $session -ProcessSnapshot $snapshot -ProcessLookup $lookup -IdentityCheck $identity
        $result.runtimes.Count | Should -Be 1
        $runtime = $result.runtimes[0]
        $runtime.major | Should -Be 21
        $runtime.exactVersion | Should -Be '21.0.7'
        $runtime.vendor | Should -Be 'Eclipse Adoptium'
        $runtime.architecture | Should -Be 'x64'
        $runtime.PSObject.Properties.Name | Should -Not -Contain 'javaPath'
        (Get-MmtlRuntimeEvents -SessionPath $session).eventCode | Should -Contain 'JAVA_RUNTIME_OBSERVED'
    }

    It 'Java 子进程身份改变时拒绝将其作为当前 Session 证据' {
        $badLookup = { param($processId) if($processId -eq 30){[pscustomobject]@{PID=30;StartIdentity='gradle-start'}}else{[pscustomobject]@{PID=31;StartIdentity='reused-pid';Executable=$script:javaPath;CommandLine='java net.minecraft.client.main.Main'}} }
        $result = Invoke-MmtlJavaRuntimeObserver -SessionPath $session -ProcessSnapshot $snapshot -ProcessLookup $badLookup -IdentityCheck $identity
        $result.runtimes.Count | Should -Be 0
    }

    It '计划路径符号链接与进程实际可执行路径一致' {
        $targetRoot = Join-Path $TestDrive 'canonical-jdk'
        $targetBin = Join-Path $targetRoot 'bin'
        New-Item -ItemType Directory -Path $targetBin -Force | Out-Null
        $targetJava = Join-Path $targetBin 'java'
        'synthetic-java-executable' | Set-Content -LiteralPath $targetJava
        @('JAVA_VERSION="21.0.7"','IMPLEMENTOR="Eclipse Adoptium"','OS_NAME="Linux"','OS_ARCH="amd64"') | Set-Content -LiteralPath (Join-Path $targetRoot 'release')
        $aliasRoot = Join-Path $TestDrive 'jdk-alias'
        [IO.Directory]::CreateSymbolicLink($aliasRoot, $targetRoot) | Out-Null
        $aliasJava = Join-Path (Join-Path $aliasRoot 'bin') 'java'
        $plan = Get-Content -LiteralPath (Join-Path $session 'execution-plan.json') -Raw | ConvertFrom-Json
        $plan.runtimeJava.resolution.javaPath = $aliasJava
        $plan.buildJava.resolution.javaPath = $aliasJava
        $plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $session 'execution-plan.json')
        $script:javaPath = $targetJava
        $result = Invoke-MmtlJavaRuntimeObserver -SessionPath $session -ProcessSnapshot $snapshot -ProcessLookup $lookup -IdentityCheck $identity
        $result.runtimes.Count | Should -Be 1
        $result.runtimes[0].bindingMatch | Should -BeTrue
    }

    It '标记为 Rehearsal 的进程只输出 synthetic evidence' {
        $registry = Get-Content (Join-Path $session 'pids.json') -Raw | ConvertFrom-Json
        $registry[0] | Add-Member -NotePropertyName Rehearsal -NotePropertyValue $true
        @($registry) | ConvertTo-Json | Set-Content (Join-Path $session 'pids.json')
        $result = Invoke-MmtlJavaRuntimeObserver -SessionPath $session -ProcessSnapshot $snapshot -ProcessLookup $lookup -IdentityCheck $identity
        $result.runtimes[0].synthetic | Should -BeTrue
        (Get-MmtlRuntimeEvents -SessionPath $session).metadata.synthetic | Should -Contain $true
    }
}
