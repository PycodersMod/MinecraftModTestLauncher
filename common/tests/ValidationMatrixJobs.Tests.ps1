Describe 'Validation matrix Jobs manifest provisioning' {
    BeforeAll {
        $script:repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $script:repoRoot 'common/src/Validation/ValidationMatrixChunks.psm1') -Force
        $script:universe=Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw|ConvertFrom-Json
        $script:ledger=Get-Content (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -Raw|ConvertFrom-Json
        $script:families=Get-Content (Join-Path $script:repoRoot 'compatibility/families.json') -Raw|ConvertFrom-Json
        $script:matrix=New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 100
        $script:ledgerById=@{};foreach($row in $script:ledger.targets){$script:ledgerById[[string]$row.targetId]=$row}
        $script:projectRoot=Join-Path $TestDrive 'fixture project'
        $null=New-Item -ItemType Directory -Path $script:projectRoot -Force
        Import-Module (Join-Path $script:repoRoot 'common/src/Validation/FamilyBatchPolicy.psm1') -Force
        $script:entries=[Collections.Generic.List[object]]::new()
        foreach($target in @($script:universe.targets|Where-Object availability -CEQ 'Available')){
            $firstCandidate=@($target.loaderVersionCandidates|Select-Object -First 1)[0]
            $version=if($firstCandidate -is [string]){[string]$firstCandidate}elseif($firstCandidate.PSObject.Properties['loaderVersion']){[string]$firstCandidate.loaderVersion}else{[string]$firstCandidate.version}
            $script:entries.Add([pscustomobject][ordered]@{
                targetId=[string]$target.targetId
                projectPath='fixture project'
                loaderVersion=$version
                wrapper='gradlew'
                task='build'
                sourceFixture=[pscustomobject][ordered]@{type='UserProject';source='test-fixture';commit='test';license='User-owned';trust='UserOwned';allowedTasks=@('build')}
            })
        }
        $script:provisioning=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=[string]$script:matrix.manifestHash;entries=@($script:entries.ToArray())}
        Import-Module (Join-Path $script:repoRoot 'common/src/Validation/ValidationMatrixJobs.psm1') -Force -ErrorAction SilentlyContinue
    }

    It 'generates complete exact target jobs and canonical cache identities' {
        $result=New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $script:provisioning -ProvisioningRoot $TestDrive
        $result.schemaVersion | Should -Be 1
        $result.manifestHash | Should -BeExactly $script:matrix.manifestHash
        $result.jobs.Count | Should -Be $script:matrix.targetCount
        $jobIds=[string[]]@($result.jobs|ForEach-Object{[string]$_.targetId});$ordinalIds=[string[]]@($jobIds);[Array]::Sort($ordinalIds,[StringComparer]::Ordinal)
        ($jobIds -join "`n") | Should -Be ($ordinalIds -join "`n")
        $result.jobs[0].targetId | Should -BeExactly $result.jobs[0].target.targetId
        $row=$script:ledgerById[[string]$result.jobs[0].targetId]
        $result.jobs[0].cacheIdentity.sourceHash | Should -BeExactly $row.sourceHash
        $result.jobs[0].cacheIdentity.toolchainHash | Should -BeExactly $row.toolchainHash
        $result.jobs[0].cacheIdentity.targetSpecHash | Should -BeExactly $row.targetSpecHash
        $result.jobs[0].cacheIdentity.universeHash | Should -BeExactly $script:matrix.universeHash
        foreach($job in $result.jobs){
            $job.scenario.clientCount | Should -Be 2
            $job.scenario.identityKind | Should -BeExactly 'Offline'
            $job.scenario.transportPolicy | Should -BeExactly 'NativeIntegratedLANOrExplicitHistoricalDedicatedEquivalent'
            @($job.scenario.requiredDimensions) | Should -Contain 'SingleAssertionPass'
            @($job.scenario.requiredDimensions) | Should -Contain 'MultiplayerJoinAndAssertionPass'
            @($job.scenario.requiredDimensions) | Should -Contain 'SafeStopPass'
        }
        $result.jobsHash | Should -Match '^[a-f0-9]{64}$'
        (Get-MmtlValidationMatrixJobsHash -Manifest $result) | Should -BeExactly $result.jobsHash
        $schemaPath=Join-Path $script:repoRoot 'common/schemas/validation-matrix-job-manifest.schema.json'
        (Test-Json -Json (ConvertTo-Json -InputObject $result -Depth 40) -SchemaFile $schemaPath) | Should -BeTrue
    }

    It 'creates only the exact targets in a validated frozen Family Batch' {
        $targets=@($script:universe.targets|Where-Object availability -CEQ 'Available'|Select-Object -First 2)
        $recipes=@(foreach($target in $targets){
            $id=[string]$target.targetId;$row=$script:ledgerById[$id]
            $firstCandidate=@($target.loaderVersionCandidates|Select-Object -First 1)[0]
            $version=if($firstCandidate -is [string]){[string]$firstCandidate}elseif($firstCandidate.PSObject.Properties['loaderVersion']){[string]$firstCandidate.loaderVersion}else{[string]$firstCandidate.version}
            $chunk=@($script:matrix.chunks|Where-Object{$_.targets.targetId -ccontains $id})[0]
            [pscustomobject][ordered]@{status='RecipeReady';targetId=$id;loaderId=[string]$target.loaderId;minecraftId=[string]$target.minecraftId;familyId=[string]$chunk.familyId;universeHash=[string]$script:universe.catalogHash;sourceHash=[string]$row.sourceHash;toolchainHash=[string]$row.toolchainHash;targetSpecHash=[string]$row.targetSpecHash;familyRuleSha256=('a'*64);adapterSha256=('b'*64);recipeSha256=('c'*64);build=[pscustomobject]@{loaderVersion=$version;buildJavaMajor=21;runtimeJavaMajor=21;gradleVersion='8.10';loomVersion='1.8'}}
        })
        $batch=New-MmtlFamilyBatchSnapshot -Recipes $recipes -BatchOrdinal 0
        $entries=@($script:entries|Where-Object targetId -In @($batch.targets.targetId))
        $partial=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=[string]$script:matrix.manifestHash;entries=$entries}
        $result=New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $partial -ProvisioningRoot $TestDrive -FamilyBatchSnapshot $batch -BatchRecipes $recipes
        $result.jobs.Count | Should -Be 2
        @($result.jobs.targetId|Sort-Object) | Should -Be @($batch.targets.targetId|Sort-Object)

        $matrixPath=Join-Path $TestDrive 'batch-matrix.json';$batchPath=Join-Path $TestDrive 'batch-snapshot.json';$recipesPath=Join-Path $TestDrive 'batch-recipes.json';$provisioningPath=Join-Path $TestDrive 'batch-provisioning.json';$jobsPath=Join-Path $TestDrive 'batch-jobs.json'
        [IO.File]::WriteAllText($matrixPath,(ConvertTo-Json -InputObject $script:matrix -Depth 40),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($batchPath,(ConvertTo-Json -InputObject $batch -Depth 40),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($recipesPath,(ConvertTo-Json -InputObject @($recipes) -Depth 40),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($provisioningPath,(ConvertTo-Json -InputObject $partial -Depth 40),[Text.UTF8Encoding]::new($false))
        $cli=Join-Path $script:repoRoot 'tools/New-ValidationMatrixJobs.ps1';$powerShell=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$powerShell;$info.WorkingDirectory=$script:repoRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        foreach($argument in @('-NoProfile','-File',$cli,'-MatrixManifestPath',$matrixPath,'-ProvisioningManifestPath',$provisioningPath,'-OutputPath',$jobsPath,'-FamilyBatchSnapshotPath',$batchPath,'-BatchRecipesPath',$recipesPath)){$info.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        try{$process.Start()|Should -BeTrue;$stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit(60000)|Should -BeTrue;$process.ExitCode|Should -Be 0 -Because $stderrTask.Result;$jobsDocument=Get-Content -LiteralPath $jobsPath -Raw|ConvertFrom-Json;$jobsDocument.jobs.Count|Should -Be 2}finally{if(-not $process.HasExited){$process.Kill($true);$process.WaitForExit(5000)|Out-Null};$process.Dispose()}
    }

    It 'rejects a modified full-goal scenario contract through the immutable jobs hash' {
        $result=New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $script:provisioning -ProvisioningRoot $TestDrive
        $result.jobs[0].scenario.clientCount=1
        $check=Test-MmtlValidationMatrixJobsManifest -Manifest $result
        $check.isValid | Should -BeFalse
        @($check.errors) | Should -Contain 'MATRIX_JOB_SET_HASH_MISMATCH'
    }

    It 'rejects missing and duplicate exact-target provisioning before returning a manifest' {
        $missing=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=$script:matrix.manifestHash;entries=@($script:entries.ToArray()|Select-Object -Skip 1)}
        { New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $missing -ProvisioningRoot $TestDrive } | Should -Throw '*MATRIX_PROVISIONING_SET_INCOMPLETE*'
        $duplicateEntries=@($script:entries.ToArray())+@($script:entries[0])
        $duplicate=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=$script:matrix.manifestHash;entries=$duplicateEntries}
        { New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $duplicate -ProvisioningRoot $TestDrive } | Should -Throw '*MATRIX_PROVISIONING_DUPLICATE*'
        $unexpectedEntry=$script:entries[0].PSObject.Copy();$unexpectedEntry.targetId='Unexpected@1.0'
        $unexpected=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=$script:matrix.manifestHash;entries=@($script:entries.ToArray())+@($unexpectedEntry)}
        { New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $unexpected -ProvisioningRoot $TestDrive } | Should -Throw '*MATRIX_PROVISIONING_TARGET_UNEXPECTED*'
    }

    It 'rejects unpinned Loader versions and tasks not allowed by the source fixture' {
        $badVersionEntries=@($script:entries.ToArray());$badVersionEntries[0]=$badVersionEntries[0].PSObject.Copy();$badVersionEntries[0].loaderVersion='unpublished-version'
        $badVersion=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=$script:matrix.manifestHash;entries=$badVersionEntries}
        { New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $badVersion -ProvisioningRoot $TestDrive } | Should -Throw '*MATRIX_PROVISIONING_LOADER_VERSION_UNPINNED*'
        $badTaskEntries=@($script:entries.ToArray());$badTaskEntries[0]=$badTaskEntries[0].PSObject.Copy();$badTaskEntries[0].task='publish';$badTaskEntries[0].sourceFixture=$badTaskEntries[0].sourceFixture.PSObject.Copy();$badTaskEntries[0].sourceFixture.allowedTasks=@('build')
        $badTask=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=$script:matrix.manifestHash;entries=$badTaskEntries}
        { New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $badTask -ProvisioningRoot $TestDrive } | Should -Throw '*MATRIX_PROVISIONING_TASK_NOT_ALLOWED*'
    }

    It 'rejects missing or non-directory project roots' {
        $badPathEntries=@($script:entries.ToArray());$badPathEntries[0]=$badPathEntries[0].PSObject.Copy();$badPathEntries[0].projectPath='missing project'
        $badPath=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=$script:matrix.manifestHash;entries=$badPathEntries}
        { New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $badPath -ProvisioningRoot $TestDrive } | Should -Throw '*MATRIX_PROJECT_PATH_NOT_FOUND*'
        $filePath=Join-Path $TestDrive 'not a project directory.txt';[IO.File]::WriteAllText($filePath,'fixture')
        $badPathEntries[0]=$script:entries[0].PSObject.Copy();$badPathEntries[0].projectPath='not a project directory.txt'
        $notDirectory=[pscustomobject][ordered]@{schemaVersion=1;manifestHash=$script:matrix.manifestHash;entries=$badPathEntries}
        { New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $notDirectory -ProvisioningRoot $TestDrive } | Should -Throw '*MATRIX_PROJECT_PATH_NOT_FOUND*'
    }

    It 'rejects a reparse-point provisioning root' {
        if(-not $IsWindows){Set-ItResult -Skipped -Because 'Windows junction behavior is validated on Windows; Unix symlink semantics vary by host policy.';return}
        $junction=Join-Path $TestDrive 'linked provisioning root'
        New-Item -ItemType Junction -Path $junction -Target $TestDrive | Out-Null
        try {
            { New-MmtlValidationMatrixJobs -MatrixManifest $script:matrix -Universe $script:universe -Ledger $script:ledger -FamilyManifest $script:families -ProvisioningManifest $script:provisioning -ProvisioningRoot $junction } | Should -Throw '*MATRIX_PROJECT_ROOT_REPARSE*'
        } finally {Remove-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue}
    }

    It 'writes the schema-valid Jobs manifest through the CLI without launching a build' {
        $matrixPath=Join-Path $TestDrive 'matrix.json';$provisioningPath=Join-Path $TestDrive 'provisioning.json';$outputPath=Join-Path $TestDrive 'jobs.json'
        [IO.File]::WriteAllText($matrixPath,(ConvertTo-Json -InputObject $script:matrix -Depth 40),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($provisioningPath,(ConvertTo-Json -InputObject $script:provisioning -Depth 40),[Text.UTF8Encoding]::new($false))
        $cli=Join-Path $script:repoRoot 'tools/New-ValidationMatrixJobs.ps1'
        $powerShell=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$powerShell;$info.WorkingDirectory=$script:repoRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        foreach($argument in @('-NoProfile','-File',$cli,'-MatrixManifestPath',$matrixPath,'-ProvisioningManifestPath',$provisioningPath,'-OutputPath',$outputPath)){$info.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info
        try {
            $process.Start() | Should -BeTrue
            $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
            $process.WaitForExit(60000) | Should -BeTrue
            $process.ExitCode | Should -Be 0 -Because $stderrTask.Result
            $jobsDocument=Get-Content -LiteralPath $outputPath -Raw|ConvertFrom-Json
            $jobsDocument.jobs.Count | Should -Be $script:matrix.targetCount
            (Test-Json -Json (ConvertTo-Json -InputObject $jobsDocument -Depth 40) -SchemaFile (Join-Path $script:repoRoot 'common/schemas/validation-matrix-job-manifest.schema.json')) | Should -BeTrue
            (Get-ChildItem -LiteralPath $TestDrive -Filter 'jobs.json.*.tmp' -File).Count | Should -Be 0
        } finally {if(-not $process.HasExited){$process.Kill($true);$process.WaitForExit(5000)|Out-Null};$process.Dispose()}
    }
}
