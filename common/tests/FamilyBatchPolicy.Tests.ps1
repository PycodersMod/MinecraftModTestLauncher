BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Validation/FamilyBatchPolicy.psm1') -Force
    $script:recipes = @(
        [pscustomobject]@{ status='RecipeReady'; targetId='Fabric@1.21.8'; loaderId='Fabric'; minecraftId='1.21.8'; familyId='fabric-family'; universeHash=('a'*64); sourceHash=('b'*64); toolchainHash=('c'*64); targetSpecHash=('d'*64); recipeSha256=('e'*64); familyRuleSha256=('3'*64); adapterSha256=('4'*64); build=[pscustomobject]@{loaderVersion='0.19.5';buildJavaMajor=25;runtimeJavaMajor=21;gradleVersion='9.7.1';loomVersion='1.18.4'} },
        [pscustomobject]@{ status='RecipeReady'; targetId='Fabric@1.21.11'; loaderId='Fabric'; minecraftId='1.21.11'; familyId='fabric-family'; universeHash=('a'*64); sourceHash=('f'*64); toolchainHash=('c'*64); targetSpecHash=('1'*64); recipeSha256=('2'*64); familyRuleSha256=('3'*64); adapterSha256=('4'*64); build=[pscustomobject]@{loaderVersion='0.19.5';buildJavaMajor=25;runtimeJavaMajor=21;gradleVersion='9.7.1';loomVersion='1.18.4'} }
    )
}

Describe 'Immutable Family batch policy' {
    It 'creates a deterministically hashed snapshot with exact target inputs' {
        $batch = New-MmtlFamilyBatchSnapshot -Recipes $script:recipes -BatchOrdinal 0
        $batch.targetCount | Should -Be 2
        $batch.loaderId | Should -BeExactly 'Fabric'
        $batch.familyId | Should -BeExactly 'fabric-family'
        $batch.batchInputSha256 | Should -Match '^[a-f0-9]{64}$'
        (Test-MmtlFamilyBatchSnapshot -Snapshot $batch).isValid | Should -BeTrue
        $reverse = New-MmtlFamilyBatchSnapshot -Recipes @($script:recipes[1],$script:recipes[0]) -BatchOrdinal 0
        $reverse.batchInputSha256 | Should -BeExactly $batch.batchInputSha256
    }

    It 'rejects duplicate targets, mixed families, pending recipes, and oversized batches' {
        { New-MmtlFamilyBatchSnapshot -Recipes @($script:recipes[0],$script:recipes[0]) -BatchOrdinal 0 } | Should -Throw '*BATCH_TARGET_DUPLICATE*'
        $mixed = $script:recipes[1] | ConvertTo-Json | ConvertFrom-Json; $mixed.familyId='other-family'
        { New-MmtlFamilyBatchSnapshot -Recipes @($script:recipes[0],$mixed) -BatchOrdinal 0 } | Should -Throw '*BATCH_FAMILY_MISMATCH*'
        $pending = $script:recipes[0] | ConvertTo-Json | ConvertFrom-Json; $pending.status='InternalPending'
        { New-MmtlFamilyBatchSnapshot -Recipes @($pending) -BatchOrdinal 0 } | Should -Throw '*BATCH_RECIPE_NOT_READY*'
        $large = 1..41 | ForEach-Object { $copy=$script:recipes[0] | ConvertTo-Json | ConvertFrom-Json; $copy.targetId="Fabric@x$_"; $copy }
        { New-MmtlFamilyBatchSnapshot -Recipes $large -BatchOrdinal 0 } | Should -Throw '*BATCH_SIZE_LIMIT*'
    }

    It 'detects any snapshot input modification after freeze' {
        $batch = New-MmtlFamilyBatchSnapshot -Recipes $script:recipes -BatchOrdinal 0
        $batch.targets[0].sourceHash = '9' * 64
        $result = Test-MmtlFamilyBatchSnapshot -Snapshot $batch
        $result.isValid | Should -BeFalse
        $result.errors | Should -Contain 'BATCH_SNAPSHOT_HASH_MISMATCH'
    }

    It 'partitions a full 1,631-target exact recipe inventory without loss or duplication' {
        $all = for ($i=0; $i -lt 1631; $i++) {
            [pscustomobject]@{ status='RecipeReady'; targetId="Fabric@v$i"; loaderId='Fabric'; minecraftId="v$i"; familyId='fabric-family'; universeHash=('a'*64); sourceHash=('b'*64); toolchainHash=('c'*64); targetSpecHash=('d'*64); recipeSha256=('e'*64); familyRuleSha256=('3'*64); adapterSha256=('4'*64); build=[pscustomobject]@{loaderVersion='0.19.5';buildJavaMajor=25;runtimeJavaMajor=21;gradleVersion='9.7.1';loomVersion='1.18.4'} }
        }
        $manifest = New-MmtlFamilyBatches -Recipes $all -MaxBatchSize 30
        $manifest.targetCount | Should -Be 1631
        $manifest.readyTargetCount | Should -Be 1631
        $manifest.batchCount | Should -Be ([Math]::Ceiling(1631/30))
        $ids = @($manifest.batches | ForEach-Object { $_.targets.targetId })
        $ids.Count | Should -Be 1631
        @($ids | Select-Object -Unique).Count | Should -Be 1631
        (Test-MmtlBatchSnapshot -Batch $manifest.batches[0] -CurrentInputs $all).valid | Should -BeTrue
    }

    It 'keeps pending exact targets in the coverage report without assigning them to build batches' {
        $pending = $script:recipes[0] | ConvertTo-Json | ConvertFrom-Json
        $pending.targetId = 'Quilt@1.21.8'
        $pending.loaderId = 'Quilt'
        $pending.familyId = 'quilt-family'
        $pending.status = 'InternalPending'
        $manifest = New-MmtlFamilyBatches -Recipes @($script:recipes[0],$pending) -MaxBatchSize 20
        $manifest.targetCount | Should -Be 2
        $manifest.readyTargetCount | Should -Be 1
        $manifest.pendingTargetCount | Should -Be 1
        @($manifest.batches.targets.targetId) | Should -HaveCount 1
        $manifest.deferredTargets[0].reasonCode | Should -BeExactly 'InternalPending'
    }

    It 'atomically reserves disjoint work for sequential workers and reclaims expired work' {
        $batch = New-MmtlFamilyBatchSnapshot -Recipes $script:recipes -BatchOrdinal 0
        $path = Join-Path $TestDrive 'assignments.json'
        $first = Set-MmtlFamilyBatchAssignments -Batch $batch -AssignmentPath $path -WorkerId 'worker-a' -MaxTargets 1 -NowUtc ([DateTimeOffset]::UtcNow) -LeaseMinutes 1
        $second = Set-MmtlFamilyBatchAssignments -Batch $batch -AssignmentPath $path -WorkerId 'worker-b' -MaxTargets 1 -NowUtc ([DateTimeOffset]::UtcNow) -LeaseMinutes 1
        $first.targetIds[0] | Should -Not -BeExactly $second.targetIds[0]
        $expiredTime = [DateTimeOffset]::UtcNow.AddMinutes(2)
        $third = Set-MmtlFamilyBatchAssignments -Batch $batch -AssignmentPath $path -WorkerId 'worker-c' -MaxTargets 1 -NowUtc $expiredTime -LeaseMinutes 1
        $third.targetIds | Should -Contain $first.targetIds[0]
        $third.targetIds | Should -Not -Contain $second.targetIds[0]
    }

    It 'does not reserve passed or exhausted targets and rejects changed current recipe inputs' {
        $batch = New-MmtlFamilyBatchSnapshot -Recipes $script:recipes -BatchOrdinal 0
        $changed = @($script:recipes | ForEach-Object { $_ | ConvertTo-Json | ConvertFrom-Json })
        $changed[0].recipeSha256 = '9' * 64
        (Test-MmtlBatchSnapshot -Batch $batch -CurrentInputs $changed).reasonCode | Should -BeExactly 'BATCH_INPUTS_CHANGED'
        $attempts = @(
            [pscustomobject]@{targetId=$script:recipes[0].targetId;dimension='BuildExact';status='PASS';isFreshExecution=$true},
            [pscustomobject]@{targetId=$script:recipes[1].targetId;dimension='BuildExact';status='FAIL';isFreshExecution=$true},
            [pscustomobject]@{targetId=$script:recipes[1].targetId;dimension='BuildExact';status='FAIL';isFreshExecution=$true},
            [pscustomobject]@{targetId=$script:recipes[1].targetId;dimension='BuildExact';status='FAIL';isFreshExecution=$true}
        )
        $next = Get-MmtlFamilyBatchNextTargets -Batch $batch -ExistingAttempts $attempts
        $next | Should -HaveCount 0
    }
}
