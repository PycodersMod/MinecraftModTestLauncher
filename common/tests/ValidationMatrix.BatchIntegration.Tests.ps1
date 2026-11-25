BeforeAll {
    $script:commonRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:commonRoot 'src/Validation/FamilyBatchBuildRunner.psm1') -Force
    Import-Module (Join-Path $script:commonRoot 'src/Validation/FamilyBatchPolicy.psm1') -Force
    $script:universeHash = 'a' * 64
    $script:familyHash = '3' * 64
    $script:adapterHash = '4' * 64
    $script:recipes = @(
        [pscustomobject]@{status='RecipeReady';targetId='Fabric@1.21.8';loaderId='Fabric';minecraftId='1.21.8';familyId='fabric-family';universeHash=$script:universeHash;sourceHash=('b'*64);toolchainHash=('c'*64);targetSpecHash=('d'*64);recipeSha256=('e'*64);familyRuleSha256=$script:familyHash;adapterSha256=$script:adapterHash;build=[pscustomobject]@{loaderVersion='0.19.5';buildJavaMajor=25;runtimeJavaMajor=21;gradleVersion='9.7.1';loomVersion='1.18.4'}},
        [pscustomobject]@{status='RecipeReady';targetId='Fabric@1.21.11';loaderId='Fabric';minecraftId='1.21.11';familyId='fabric-family';universeHash=$script:universeHash;sourceHash=('f'*64);toolchainHash=('c'*64);targetSpecHash=('1'*64);recipeSha256=('2'*64);familyRuleSha256=$script:familyHash;adapterSha256=$script:adapterHash;build=[pscustomobject]@{loaderVersion='0.19.5';buildJavaMajor=25;runtimeJavaMajor=21;gradleVersion='9.7.1';loomVersion='1.18.4'}}
    )
    $script:batch = New-MmtlFamilyBatchSnapshot -Recipes $script:recipes -BatchOrdinal 0
    $script:universe = [pscustomobject]@{catalogHash=$script:universeHash;targets=@(
        [pscustomobject]@{targetId='Fabric@1.21.8';loaderId='Fabric';minecraftId='1.21.8';availability='Available';loaderVersionCandidates=@('0.19.5');sourceHash=('b'*64)},
        [pscustomobject]@{targetId='Fabric@1.21.11';loaderId='Fabric';minecraftId='1.21.11';availability='Available';loaderVersionCandidates=@('0.19.5');sourceHash=('f'*64)}
    )}
    $fixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='CC0-1.0';trust='Verified';allowedTasks=@('build')}
    $script:jobs=@(foreach($recipe in $script:recipes){
        $primary=[pscustomobject]@{id='Fabric';version=$recipe.build.loaderVersion}
        [pscustomobject]@{
            targetId=$recipe.targetId
            target=[pscustomobject]@{targetId=$recipe.targetId;minecraftId=$recipe.minecraftId;loaderVersion=$recipe.build.loaderVersion;loaderStack=[pscustomobject]@{primary=$primary};sourceFixture=$fixture}
            project=[pscustomobject]@{Root=(Join-Path $TestDrive $recipe.minecraftId);MinecraftVersion=$recipe.minecraftId;Loader='Fabric';LoaderVersion=$recipe.build.loaderVersion;JavaMajor=25;Wrapper='gradlew'}
            cacheIdentity=[pscustomobject]@{targetId=$recipe.targetId;universeHash=$script:universeHash;sourceHash=$recipe.sourceHash;toolchainHash=$recipe.toolchainHash;targetSpecHash=$recipe.targetSpecHash}
        }
    })
}

Describe 'Family batch to existing Matrix Runner integration' {
    It 'forwards only exact frozen batch targets through the existing shard runner with a three-attempt budget' {
        $capture=[pscustomobject]@{shard=$null;jobs=$null;maxAttempts=0;gradleHomeRoot=$null;calls=0}
        $mock={param($Shard,$Jobs,$RuntimeRoot,$MaxAttempts,$AllowedOwners,$BuildJavaHome,$TimeoutSeconds,$GoalProgressRunRoot,$Clean,$GradleHomeRoot)$capture.shard=$Shard;$capture.jobs=@($Jobs);$capture.maxAttempts=$MaxAttempts;$capture.gradleHomeRoot=$GradleHomeRoot;$capture.calls++;[pscustomobject]@{status='PARTIAL';results=@();runState=[pscustomobject]@{statePath='state.json';targets=@([pscustomobject]@{targetId='Fabric@1.21.8';status='Failed';attempts=1;failureCode='ADAPTER_HASH_MISMATCH'},[pscustomobject]@{targetId='Fabric@1.21.11';status='Failed';attempts=1;failureCode='ADAPTER_HASH_MISMATCH'})}}}.GetNewClosure()
        Mock -CommandName Invoke-MmtlValidationMatrixShard -ModuleName FamilyBatchBuildRunner -MockWith $mock
        $gradleHomeRoot=Join-Path $TestDrive 'isolated-gradle-homes'
        $result=Invoke-MmtlFamilyBatchBuild -Batch $script:batch -CurrentInputs $script:recipes -Universe $script:universe -Jobs $script:jobs -RuntimeRoot (Join-Path $TestDrive 'runtime') -GradleHomeRoot $gradleHomeRoot -MaxBuildWorkers 1
        $capture.calls | Should -Be 1
        $capture.shard.manifestHash | Should -BeExactly $script:batch.batchInputSha256
        $capture.shard.batchId | Should -BeExactly $script:batch.batchId
        $capture.shard.targetCount | Should -Be 2
        $capture.maxAttempts | Should -Be 3
        $capture.gradleHomeRoot | Should -BeExactly $gradleHomeRoot
        @($capture.jobs.targetId | Sort-Object) | Should -Be @('Fabric@1.21.11','Fabric@1.21.8')
        $result.batchId | Should -BeExactly $script:batch.batchId
        $result.failureClusters | Should -HaveCount 1
        $result.failureClusters[0].targetIds | Should -HaveCount 2
    }

    It 'refuses recipe or cache identity drift before calling the build runner' {
        $capture=[pscustomobject]@{calls=0}
        Mock -CommandName Invoke-MmtlValidationMatrixShard -ModuleName FamilyBatchBuildRunner -MockWith {
            $capture.calls++
            [pscustomobject]@{status='COMPLETE';results=@();runState=[pscustomobject]@{statePath='state.json';targets=@()}}
        }.GetNewClosure()
        $changed=@($script:recipes | ForEach-Object {$_|ConvertTo-Json -Depth 20|ConvertFrom-Json})
        $changed[0].adapterSha256='9'*64
        { Invoke-MmtlFamilyBatchBuild -Batch $script:batch -CurrentInputs $changed -Universe $script:universe -Jobs $script:jobs -RuntimeRoot (Join-Path $TestDrive 'changed-runtime') } | Should -Throw '*BATCH_INPUTS_CHANGED*'
        $capture.calls | Should -Be 0
        $badJobs=@($script:jobs|ForEach-Object{$copy=$_.PSObject.Copy();$copy.cacheIdentity=$_.cacheIdentity.PSObject.Copy();$copy.cacheIdentity.sourceHash='9'*64;$copy})
        { Invoke-MmtlFamilyBatchBuild -Batch $script:batch -CurrentInputs $script:recipes -Universe $script:universe -Jobs $badJobs -RuntimeRoot (Join-Path $TestDrive 'bad-cache-runtime') } | Should -Throw '*BATCH_JOB_IDENTITY_MISMATCH*'
        $capture.calls | Should -Be 0
    }

    It 'uses a zero-based local shard index when a family batch has a nonzero global ordinal' {
        $capture=[pscustomobject]@{shard=$null}
        Mock -CommandName Invoke-MmtlValidationMatrixShard -ModuleName FamilyBatchBuildRunner -MockWith {
            param($Shard,$Jobs,$RuntimeRoot,$MaxAttempts,$AllowedOwners,$BuildJavaHome,$TimeoutSeconds,$GoalProgressRunRoot,$Clean)
            $capture.shard=$Shard
            [pscustomobject]@{status='COMPLETE';results=@();runState=[pscustomobject]@{statePath='state.json';targets=@()}}
        }.GetNewClosure()
        $batch=New-MmtlFamilyBatchSnapshot -Recipes $script:recipes -BatchOrdinal 7

        Invoke-MmtlFamilyBatchBuild -Batch $batch -CurrentInputs $script:recipes -Universe $script:universe -Jobs $script:jobs -RuntimeRoot (Join-Path $TestDrive 'ordinal-runtime') | Out-Null

        $capture.shard.shardIndex | Should -Be 0
        $capture.shard.shardCount | Should -Be 1
        $batch.batchOrdinal | Should -Be 7
    }

    It 'rejects a build job whose source fixture differs from the fixture frozen in its recipe' {
        $fixture=[pscustomobject][ordered]@{
            type='OfficialArtifactFixture';source='https://maven.minecraftforge.net/net/minecraftforge/forge/test.zip';commit=('a'*64)
            license='LGPL-2.1';trust='TrustedOfficial';allowedTasks=@('build')
            officialChecksumAlgorithm='SHA256';officialChecksum=('a'*64);fixtureId='fixture-v1';overlaySha256=('b'*64)
            overlayFiles=@([pscustomobject][ordered]@{path='src/main/java/Marker.java';sha256=('c'*64)})
        }
        $recipesWithFixture=[Collections.Generic.List[object]]::new()
        foreach($recipe in $script:recipes){
            $copy=$recipe|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json
            $copy|Add-Member -NotePropertyName sourceFixture -NotePropertyValue $fixture -Force
            $recipeBody=[ordered]@{}
            foreach($property in $copy.PSObject.Properties){if($property.Name -cne 'recipeSha256'){$recipeBody[$property.Name]=$property.Value}}
            $copy.recipeSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject ([pscustomobject]$recipeBody) -Depth 30 -Compress)))).ToLowerInvariant()
            $recipesWithFixture.Add($copy)
        }
        $batch=New-MmtlFamilyBatchSnapshot -Recipes @($recipesWithFixture.ToArray()) -BatchOrdinal 2
        $badJobs=@(foreach($job in $script:jobs){$copy=$job|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json;$copy.target.sourceFixture=$fixture|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json;$copy})
        $badJobs[0].target.sourceFixture.commit='d'*64
        $capture=[pscustomobject]@{calls=0}
        Mock -CommandName Invoke-MmtlValidationMatrixShard -ModuleName FamilyBatchBuildRunner -MockWith {
            $capture.calls++
            [pscustomobject]@{status='COMPLETE';results=@();runState=[pscustomobject]@{statePath='state.json';targets=@()}}
        }.GetNewClosure()

        { Invoke-MmtlFamilyBatchBuild -Batch $batch -CurrentInputs @($recipesWithFixture.ToArray()) -Universe $script:universe -Jobs $badJobs -RuntimeRoot (Join-Path $TestDrive 'fixture-drift-runtime') } | Should -Throw '*FAMILY_BATCH_SOURCE_FIXTURE_MISMATCH*'
        $capture.calls | Should -Be 0
    }
}
