BeforeAll {
    $script:commonRoot = Split-Path -Parent $PSScriptRoot
    $script:repoRoot = Split-Path -Parent $script:commonRoot
    $script:ledgerModule = Import-Module (Join-Path $script:commonRoot 'src/Compatibility/FullCompatibilityLedger.psm1') -Force -PassThru
}

Describe 'Runtime Binding exact-target evidence promotion' {
    It 'accepts a sanitized observed binding claim for its exact target and source/toolchain evidence' {
        $universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $families = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
        $baseLedger = & $script:ledgerModule { param($u,$f) New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -GeneratedAt ([DateTimeOffset]'2026-10-11T00:00:00Z') } $universe $families
        $targetId = 'Forge@1.8.8'
        $ledgerTarget = $baseLedger.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1
        $existingIndex = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        $buildEntry = $existingIndex.entries | Where-Object { $_.targetId -ceq $targetId -and $_.dimension -ceq 'BuildVerified' } | Select-Object -First 1
        $evidenceRoot = Join-Path $TestDrive 'runtime-binding-evidence'
        [IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
        foreach ($entry in @($buildEntry)) {
            $sourcePath = Join-Path $script:repoRoot $entry.evidencePath
            $destinationPath = Join-Path $evidenceRoot $entry.evidencePath
            [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        }
        $buildEvidencePath = Join-Path $script:repoRoot $buildEntry.evidencePath
        $probePath = Join-Path $TestDrive 'raw-probe.json'
        $rawProbe = [pscustomobject][ordered]@{
            schemaVersion=1;status='Observed';timestamp='2026-10-11T00:00:00Z';minecraft='1.8.8';loader='Forge';loaderVersion='1.8.8-11.15.0.1655'
            buildJavaMajor='8';observedBuildJavaVersion='1.8.0_503';runtimeJavaRequirement=[pscustomobject]@{major=8}
            buildSystem='GradleWrapper';toolchain='ForgeGradle';toolchainVersion='2.1-SNAPSHOT';adapterVersion='8'
            runtimeJavaBinding=[pscustomobject]@{mode='SameAsBuildJvm';confidence='High';probeStrategy='GradleJavaExecTaskInspection';evidenceSource='GradleInitScriptJavaExecInspection';runtimeJavaControllable=$false;requiresBuildJvmMatch=$true}
            evidenceDetails=@([pscustomobject]@{task='runClient';taskType='org.gradle.api.tasks.JavaExec_Decorated';launcherSource='executable';executable='D:\java\jdk-8\bin\java.exe'}) # public-hygiene: allow-synthetic-path
        }
        [IO.File]::WriteAllText($probePath,($rawProbe|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $ledgerPath = Join-Path $TestDrive 'base-ledger.json'
        [IO.File]::WriteAllText($ledgerPath,($baseLedger|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
        $evidencePath = Join-Path $evidenceRoot 'forge-1.8.8.json'
        $converter = Join-Path $script:repoRoot 'tools/Convert-RuntimeBindingProbeEvidence.ps1'
        & $converter -TargetId $targetId -ProbeEvidencePath $probePath -BuildEvidencePath $buildEvidencePath -BuildEvidenceIndexPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -UniversePath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -LedgerPath $ledgerPath -OutputPath $evidencePath | Out-Null
        $index = [pscustomobject][ordered]@{schemaVersion=1;universeHash=[string]$universe.catalogHash;entries=@($buildEntry)+@([pscustomobject][ordered]@{targetId=$targetId;dimension='RuntimeBinding';targetSpecHash=[string]$ledgerTarget.targetSpecHash;evidencePath='forge-1.8.8.json';evidenceSha256=(Get-FileHash $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()})}

        $ledger = & $script:ledgerModule { param($u,$f,$i,$root) New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -TargetEvidenceIndex $i -EvidenceRoot $root -GeneratedAt ([DateTimeOffset]'2026-10-11T00:00:00Z') } $universe $families $index $evidenceRoot
        $verified = $ledger.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1

        $verified.dimensions.RuntimeBinding.status | Should -BeExactly 'Supported'
        $verified.dimensions.RuntimeBinding.evidenceRefs | Should -Contain "runtime-binding-evidence-sha256:$($index.entries[-1].evidenceSha256)"
        $evidenceJson = Get-Content -LiteralPath $evidencePath -Raw
        $evidenceJson | Should -Not -Match '[A-Za-z]:\\Users\\|/home/|/Users/' # public-hygiene: allow-synthetic-path
    }

    It 'converts the Forge 1.8 plugin DSL version into runtime binding toolchain evidence' {
        $universe=Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw|ConvertFrom-Json
        $target=$universe.targets|Where-Object targetId -CEQ 'Forge@1.8'|Select-Object -First 1
        $index=Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw|ConvertFrom-Json
        $buildEntry=$index.entries|Where-Object {$_.targetId -ceq 'Forge@1.8' -and $_.dimension -ceq 'BuildVerified'}|Select-Object -First 1
        $buildPath=Join-Path $script:repoRoot $buildEntry.evidencePath
        $build=Get-Content -LiteralPath $buildPath -Raw|ConvertFrom-Json
        $baseLedger=& $script:ledgerModule {param($u,$f) New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -GeneratedAt ([DateTimeOffset]'2026-10-11T00:00:00Z')} $universe (Get-Content (Join-Path $script:repoRoot 'compatibility/families.json') -Raw|ConvertFrom-Json)
        $ledgerPath=Join-Path $TestDrive 'forge-1.8-ledger.json'
        [IO.File]::WriteAllText($ledgerPath,($baseLedger|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
        $probe=[pscustomobject][ordered]@{
            schemaVersion=1;status='Observed';timestamp='2026-10-11T00:00:00Z';minecraft='1.8';loader='Forge';loaderVersion=[string]$build.loaderVersion
            buildJavaMajor=8;observedBuildJavaVersion=[string]$build.java.observedBuildJava.exactVersion;runtimeJavaRequirement=[pscustomobject]@{major=[int]$target.runtimeJavaRequirement.major}
            buildSystem=[string]$build.buildSystem.id;toolchain='ForgeGradle';toolchainVersion=[string]$build.forgeSecurity.pluginVersion
            runtimeJavaBinding=[pscustomobject]@{mode='SameAsBuildJvm';confidence='High';probeStrategy='GradleJavaExecTaskInspection';evidenceSource='GradleInitScriptJavaExecInspection';runtimeJavaControllable=$false;requiresBuildJvmMatch=$true}
            observedTasks=@([pscustomobject]@{task='runClient';taskType='org.gradle.api.tasks.JavaExec_Decorated';isJavaExec=$true;launcherSource='executable';executable='D:\java\jdk-8\bin\java.exe'},[pscustomobject]@{task='runServer';taskType='org.gradle.api.tasks.JavaExec_Decorated';isJavaExec=$true;launcherSource='executable';executable='D:\java\jdk-8\bin\java.exe'}) # public-hygiene: allow-synthetic-path
        }
        $probePath=Join-Path $TestDrive 'forge-1.8-runtime-probe.json'
        [IO.File]::WriteAllText($probePath,($probe|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $outputPath=Join-Path $TestDrive 'forge-1.8-runtime-binding.json'

        & (Join-Path $script:repoRoot 'tools/Convert-RuntimeBindingProbeEvidence.ps1') -TargetId 'Forge@1.8' -ProbeEvidencePath $probePath -BuildEvidencePath $buildPath -BuildEvidenceIndexPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -UniversePath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -LedgerPath $ledgerPath -OutputPath $outputPath | Out-Null
        $evidence=Get-Content -LiteralPath $outputPath -Raw|ConvertFrom-Json

        $evidence.toolchain.id | Should -BeExactly 'ForgeGradle'
        $evidence.toolchain.version | Should -BeExactly ([string]$build.forgeSecurity.pluginVersion)
        $evidence.mode | Should -BeExactly 'SameAsBuildJvm'
    }

    It 'accepts Forge run tasks by the observed JavaExec contract when the concrete wrapper type name differs' {
        $universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $families = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
        $targetId = 'Forge@1.16.5'
        $baseLedger = & $script:ledgerModule { param($u,$f) New-MmtlFullCompatibilityLedger -Universe $u -FamilyManifest $f -GeneratedAt ([DateTimeOffset]'2026-10-11T00:00:00Z') } $universe $families
        $ledgerTarget = $baseLedger.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1
        $existingIndex = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        $buildEntry = $existingIndex.entries | Where-Object { $_.targetId -ceq $targetId -and $_.dimension -ceq 'BuildVerified' } | Select-Object -First 1
        $buildEvidencePath = Join-Path $script:repoRoot $buildEntry.evidencePath
        $buildEvidence = Get-Content -LiteralPath $buildEvidencePath -Raw | ConvertFrom-Json
        $taskType = 'net.minecraftforge.gradle.common.util.runs.MinecraftRunTask_Decorated'
        $tasks = @(
            [pscustomobject][ordered]@{task='runClient';taskType=$taskType;isJavaExec=$true;launcherSource='javaLauncher';executable='D:\fixture\jdk8\bin\java.exe'}, # public-hygiene: allow-synthetic-path
            [pscustomobject][ordered]@{task='runServer';taskType=$taskType;isJavaExec=$true;launcherSource='javaLauncher';executable='D:\fixture\jdk8\bin\java.exe'} # public-hygiene: allow-synthetic-path
        )
        $rawProbe = [pscustomobject][ordered]@{
            schemaVersion=1;status='Observed';timestamp='2026-10-11T00:00:00Z';minecraft='1.16.5';loader='Forge';loaderVersion='1.16.5-36.2.42'
            buildJavaMajor='17';observedBuildJavaVersion=[string]$buildEvidence.java.observedBuildJava.exactVersion;runtimeJavaRequirement=[pscustomobject]@{major=8}
            buildSystem='Gradle';toolchain='ForgeGradle';toolchainVersion=[string]$buildEvidence.forgeSecurity.forgeGradleSpec;adapterVersion='8'
            runtimeJavaBinding=[pscustomobject]@{mode='ToolchainManaged';confidence='High';probeStrategy='GradleJavaExecTaskInspection';evidenceSource='GradleInitScriptJavaExecInspection';runtimeJavaControllable=$false;requiresBuildJvmMatch=$false}
            observedTasks=$tasks;evidenceDetails=$tasks
        }
        $probePath = Join-Path $TestDrive 'forge-1.16.5-raw-probe.json'
        [IO.File]::WriteAllText($probePath,($rawProbe|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        $ledgerPath = Join-Path $TestDrive 'forge-1.16.5-ledger.json'
        [IO.File]::WriteAllText($ledgerPath,($baseLedger|ConvertTo-Json -Depth 50),[Text.UTF8Encoding]::new($false))
        $evidencePath = Join-Path $TestDrive 'forge-1.16.5-runtime-binding.json'
        $converter = Join-Path $script:repoRoot 'tools/Convert-RuntimeBindingProbeEvidence.ps1'

        & $converter -TargetId $targetId -ProbeEvidencePath $probePath -BuildEvidencePath $buildEvidencePath -BuildEvidenceIndexPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -UniversePath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -LedgerPath $ledgerPath -OutputPath $evidencePath | Out-Null
        $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json

        @($evidence.tasks).Count | Should -Be 2
        @($evidence.tasks | ForEach-Object task) | Should -Be @('runClient','runServer')
        $evidence.tasks[0].taskType | Should -BeExactly 'JavaExec'
        $evidence.tasks[0].isJavaExec | Should -BeTrue
        $evidence.tasks[1].isJavaExec | Should -BeTrue
        $evidence.tasks[0].executable | Should -BeExactly '<RUNTIME_JAVA_HOME>/bin/java.exe'
        $evidence.tasks[1].executable | Should -BeExactly '<RUNTIME_JAVA_HOME>/bin/java.exe'
    }
}
