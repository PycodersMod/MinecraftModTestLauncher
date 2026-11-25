BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:buildEvidencePath = Join-Path $script:repoRoot 'compatibility/evidence/build/Fabric-1.21.8-Windows-x64.json'
    $script:buildEvidence = Get-Content -LiteralPath $script:buildEvidencePath -Raw | ConvertFrom-Json
}

Describe 'RuntimeBinding 证据转换' {
    It 'accepts exact loader version identity from a structured historical candidate record' {
        $targetId = 'Rift@1.13'
        $buildEvidencePath = Join-Path $script:repoRoot 'compatibility/evidence/build/Rift-1.13-Windows-x64/result.json'
        $buildEvidence = Get-Content -LiteralPath $buildEvidencePath -Raw | ConvertFrom-Json
        $probePath = Join-Path $TestDrive 'rift-runtime-probe.json'
        $outputPath = Join-Path $TestDrive 'rift-runtime-binding.json'
        $probe = [pscustomobject][ordered]@{
            status = 'Observed'; loader = 'Rift'; loaderVersion = '1.0.4'; minecraft = '1.13'
            runtimeJavaRequirement = [pscustomobject]@{ major = 8 }
            buildJavaMajor = 8; observedBuildJavaVersion = [string]$buildEvidence.java.observedBuildJava.exactVersion
            buildSystem = 'GradleWrapper'; toolchain = 'ForgeGradle'; toolchainVersion = '2.3-SNAPSHOT'
            timestamp = '2026-10-14T00:00:00Z'
            runtimeJavaBinding = [pscustomobject]@{
                mode = 'SameAsBuildJvm'; confidence = 'High'; probeStrategy = 'GradleJavaExecTaskInspection'
                evidenceSource = 'GradleInitScriptJavaExecInspection'; runtimeJavaControllable = $false
                requiresBuildJvmMatch = $true
            }
            observedTasks = @([pscustomobject]@{
                task = 'runClient'; taskType = 'org.gradle.api.tasks.JavaExec_Decorated'; isJavaExec = $true
                launcherSource = 'javaLauncher'; executable = '<JAVA_HOME>/bin/java'
            })
        }
        [IO.File]::WriteAllText($probePath,(ConvertTo-Json -InputObject $probe -Depth 10),[Text.UTF8Encoding]::new($false))
        $converter = Join-Path $script:repoRoot 'tools/Convert-RuntimeBindingProbeEvidence.ps1'

        { & $converter -TargetId $targetId -ProbeEvidencePath $probePath -BuildEvidencePath $buildEvidencePath -BuildEvidenceIndexPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -UniversePath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -LedgerPath (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -OutputPath $outputPath } | Should -Not -Throw

        $evidence = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $evidence.targetId | Should -BeExactly $targetId
        $evidence.loaderVersion | Should -BeExactly '1.0.4'
        $evidence.runtimeJavaMajor | Should -Be 8
    }

    It '将已确认 JavaExec 子类的 Loom run task 规范化并移除本机路径' {
        $probePath = Join-Path $TestDrive 'runtime-probe.json'
        $outputPath = Join-Path $TestDrive 'runtime-binding.json'
        $probe = [pscustomobject][ordered]@{
            status = 'Observed'
            loader = 'Fabric'
            loaderVersion = '0.19.5'
            minecraft = '1.21.8'
            runtimeJavaRequirement = [pscustomobject]@{ major = 21 }
            buildJavaMajor = 25
            observedBuildJavaVersion = [string]$script:buildEvidence.java.observedBuildJava.exactVersion
            buildSystem = 'GradleWrapper'
            toolchain = 'FabricLoom'
            toolchainVersion = '1.18.4'
            timestamp = '2026-10-12T00:00:00Z'
            runtimeJavaBinding = [pscustomobject]@{
                mode = 'Direct'; confidence = 'High'; probeStrategy = 'GradleJavaExecTaskInspection'
                evidenceSource = 'GradleInitScriptJavaExecInspection'; runtimeJavaControllable = $true
                requiresBuildJvmMatch = $false
            }
            observedTasks = @([pscustomobject]@{
                task = 'runClient'; taskType = 'net.fabricmc.loom.task.RunGameTask_Decorated'; isJavaExec = $true
                launcherSource = 'javaLauncher'; executable = 'D:\java\jdk-21\bin\java.exe' # public-hygiene: allow-synthetic-path
            })
        }
        [IO.File]::WriteAllText($probePath,(ConvertTo-Json -InputObject $probe -Depth 10),[Text.UTF8Encoding]::new($false))
        $converter = Join-Path $script:repoRoot 'tools/Convert-RuntimeBindingProbeEvidence.ps1'

        { & $converter -TargetId 'Fabric@1.21.8' -ProbeEvidencePath $probePath -BuildEvidencePath $script:buildEvidencePath -BuildEvidenceIndexPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -UniversePath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -LedgerPath (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -OutputPath $outputPath } | Should -Not -Throw

        $evidence = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $evidence.mode | Should -BeExactly 'Direct'
        $evidence.runtimeJavaMajor | Should -Be 21
        $evidence.observedBuildJavaMajor | Should -Be 25
        $evidence.tasks[0].taskType | Should -BeExactly 'JavaExec'
        (Get-Content -LiteralPath $outputPath -Raw) | Should -Not -Match 'D:\\java\\jdk-21' # public-hygiene: allow-synthetic-path
    }

    It '从账本中已验证的 Mojang RuntimeJava 元数据解析 Universe 缺失的 major' {
        $targetId = 'NeoForge@1.21.1'
        $buildEvidencePath = Join-Path $script:repoRoot 'compatibility/evidence/build/NeoForge-1.21.1-Windows-x64/result.json'
        $buildEvidence = Get-Content -LiteralPath $buildEvidencePath -Raw | ConvertFrom-Json
        $probePath = Join-Path $TestDrive 'neoforge-runtime-probe.json'
        $outputPath = Join-Path $TestDrive 'neoforge-runtime-binding.json'
        $probe = [pscustomobject][ordered]@{
            status = 'Observed'
            loader = 'NeoForge'
            loaderVersion = '21.1.235'
            minecraft = '1.21.1'
            runtimeJavaRequirement = [pscustomobject]@{
                major = 21
                requirementKind = 'AuthoritativeMetadata'
                confidence = 'High'
                provenance = [pscustomobject]@{
                    sourceType = 'official'
                    url = 'https://piston-meta.mojang.com/v1/packages/cedfc3b6dcbca34e2b478d498bf1d56a8fa2f404/1.21.1.json'
                    hash = 'cedfc3b6dcbca34e2b478d498bf1d56a8fa2f404'
                }
            }
            buildJavaMajor = 21
            observedBuildJavaVersion = [string]$buildEvidence.java.observedBuildJava.exactVersion
            buildSystem = 'GradleWrapper'
            toolchain = 'NeoGradle'
            toolchainVersion = '7.1.38'
            timestamp = '2026-10-14T00:00:00Z'
            runtimeJavaBinding = [pscustomobject]@{
                mode = 'SameAsBuildJvm'; confidence = 'High'; probeStrategy = 'GradleJavaExecTaskInspection'
                evidenceSource = 'GradleInitScriptJavaExecInspection'; runtimeJavaControllable = $false
                requiresBuildJvmMatch = $true
            }
            observedTasks = @([pscustomobject]@{
                task = 'runClient'; taskType = 'org.gradle.api.tasks.JavaExec_Decorated'; isJavaExec = $true
                launcherSource = 'javaLauncher'; executable = 'D:\java\jdk-21\bin\java.exe' # public-hygiene: allow-synthetic-path
            })
        }
        [IO.File]::WriteAllText($probePath,(ConvertTo-Json -InputObject $probe -Depth 10),[Text.UTF8Encoding]::new($false))
        $converter = Join-Path $script:repoRoot 'tools/Convert-RuntimeBindingProbeEvidence.ps1'

        { & $converter -TargetId $targetId -ProbeEvidencePath $probePath -BuildEvidencePath $buildEvidencePath -BuildEvidenceIndexPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -UniversePath (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -LedgerPath (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -OutputPath $outputPath } | Should -Not -Throw

        $evidence = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $evidence.runtimeJavaMajor | Should -Be 21
        $evidence.observedBuildJavaMajor | Should -Be 21
        $evidence.mode | Should -BeExactly 'SameAsBuildJvm'
        $evidence.targetSpecHash | Should -BeExactly '6b85786192e9709b6e0398a22832d828e510c35c23ca9968e6c673fd92b00354'
    }
}
