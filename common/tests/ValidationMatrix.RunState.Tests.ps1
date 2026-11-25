BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationMatrixRunState.psm1') -Force
    $script:shard = [pscustomobject][ordered]@{
        schemaVersion=1; universeHash=('a'*64); manifestHash=('b'*64); shardIndex=0; shardCount=2; targetCount=2; chunkCount=1
        chunks=@([pscustomobject]@{chunkId='chunk-one';chunkHash=('c'*64);loaderId='Fabric';familyId='fabric-family';ordinal=0;targetCount=2;targets=@(
            [pscustomobject]@{targetId='fabric-1.20.1';targetSpecHash=('d'*64);sourceHash=('e'*64);toolchainHash=('1'*64)},
            [pscustomobject]@{targetId='fabric-1.20.2';targetSpecHash=('f'*64);sourceHash=('0'*64);toolchainHash=('2'*64)}
        )})
    }
}

Describe 'Resumable validation matrix run state' {
    It 'preserves exact loader and Minecraft identifiers while writing a path-safe state file' {
        $target=$script:shard.chunks[0].targets[0].PSObject.Copy();$target.targetId='Fabric@1.14 Pre-Release 1'
        $chunk=$script:shard.chunks[0].PSObject.Copy();$chunk.targets=@($target)
        $exactShard=[pscustomobject]@{schemaVersion=1;universeHash=$script:shard.universeHash;manifestHash=('9'*64);shardIndex=0;shardCount=1;targetCount=1;chunks=@($chunk)}
        $root=Join-Path $TestDrive 'runtime-exact-target';$state=New-MmtlValidationMatrixRunState -Shard $exactShard -RuntimeRoot $root
        $state.targets[0].targetId | Should -BeExactly 'Fabric@1.14 Pre-Release 1'
        $state.statePath | Should -Not -Match 'Fabric@1\.14'
        $invalidTarget=$target.PSObject.Copy();$invalidTarget.targetId='../escape';$invalidChunk=$chunk.PSObject.Copy();$invalidChunk.targets=@($invalidTarget);$invalidShard=$exactShard.PSObject.Copy();$invalidShard.chunks=@($invalidChunk)
        { New-MmtlValidationMatrixRunState -Shard $invalidShard -RuntimeRoot (Join-Path $TestDrive 'runtime-invalid-target') } | Should -Throw '*RUN_STATE_TARGET_IDENTITY_INVALID*'
    }

    It 'creates stable pending state from an immutable shard identity' {
        $root=Join-Path $TestDrive 'runtime-create'
        $state=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $state.manifestHash | Should -BeExactly $script:shard.manifestHash
        $state.targets.Count | Should -Be 2
        @($state.targets | Where-Object status -CEQ 'Pending').Count | Should -Be 2
        (Get-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root).targets.Count | Should -Be 2
    }

    It 'resets interrupted Running targets to Pending while preserving attempts' {
        $root=Join-Path $TestDrive 'runtime-resume'
        $state=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $state=Set-MmtlValidationMatrixTargetStatus -State $state -TargetId 'fabric-1.20.1' -Status Running
        $state.targets[0].attempts | Should -Be 1

        $resumed=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $target=@($resumed.targets | Where-Object targetId -CEQ 'fabric-1.20.1')[0]
        $target.status | Should -BeExactly 'Pending'
        $target.attempts | Should -Be 1
        $target.interruptedPreviousAttempt | Should -BeTrue
    }

    It 'does not reset a Running target while a worker still owns its target lease' {
        $root=Join-Path $TestDrive 'runtime-live-owner'
        $state=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $state=Set-MmtlValidationMatrixTargetStatus -State $state -TargetId 'fabric-1.20.1' -Status Running
        $lease=Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $root -Shard $script:shard
        try{
            { New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root } | Should -Throw '*RUN_STATE_TARGET_ALREADY_ACTIVE*fabric-1.20.1*'
            $onDisk=Get-Content -LiteralPath $state.statePath -Raw|ConvertFrom-Json
            (@($onDisk.targets|Where-Object targetId -CEQ 'fabric-1.20.1')[0]).status | Should -BeExactly 'Running'
        }finally{Exit-MmtlValidationMatrixTargetLeases -Lease $lease}
        $resumed=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $target=@($resumed.targets|Where-Object targetId -CEQ 'fabric-1.20.1')[0]
        $target.status | Should -BeExactly 'Pending'
        $target.interruptedPreviousAttempt | Should -BeTrue
    }

    It 'blocks an interrupted target after its configured attempt budget is exhausted' {
        $root=Join-Path $TestDrive 'runtime-exhausted'
        $state=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root -MaxAttempts 1
        $null=Set-MmtlValidationMatrixTargetStatus -State $state -TargetId 'fabric-1.20.1' -Status Running
        $resumed=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root -MaxAttempts 1
        $target=@($resumed.targets | Where-Object targetId -CEQ 'fabric-1.20.1')[0]
        $target.status | Should -BeExactly 'Blocked'
        $target.failureCode | Should -BeExactly 'RUN_INTERRUPTED_ATTEMPT_LIMIT'
    }

    It 'rejects resuming the same shard state with changed target identities' {
        $root=Join-Path $TestDrive 'runtime-identity'
        New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root | Out-Null
        $changed=$script:shard.PSObject.Copy();$changedChunk=$script:shard.chunks[0].PSObject.Copy();$changedChunk.targets=@($script:shard.chunks[0].targets);$changedChunk.targets[0]=$changedChunk.targets[0].PSObject.Copy();$changedChunk.targets[0].targetSpecHash=('9'*64);$changed.chunks=@($changedChunk)
        { New-MmtlValidationMatrixRunState -Shard $changed -RuntimeRoot $root } | Should -Throw '*RUN_STATE_IDENTITY_MISMATCH*'
        $changedToolchain=$script:shard.PSObject.Copy();$changedChunk=$script:shard.chunks[0].PSObject.Copy();$changedChunk.targets=@($script:shard.chunks[0].targets);$changedChunk.targets[0]=$changedChunk.targets[0].PSObject.Copy();$changedChunk.targets[0].toolchainHash=('8'*64);$changedToolchain.chunks=@($changedChunk)
        { New-MmtlValidationMatrixRunState -Shard $changedToolchain -RuntimeRoot $root } | Should -Throw '*RUN_STATE_IDENTITY_MISMATCH*'
    }

    It 'rejects stale worker revisions instead of overwriting a newer shard update' {
        $root=Join-Path $TestDrive 'runtime-revision'
        $initial=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $stale=[pscustomobject](ConvertFrom-Json -InputObject ($initial|ConvertTo-Json -Depth 20))
        $latest=Set-MmtlValidationMatrixTargetStatus -State $initial -TargetId 'fabric-1.20.1' -Status Running
        $latest.revision | Should -Be 1
        { Set-MmtlValidationMatrixTargetStatus -State $stale -TargetId 'fabric-1.20.2' -Status Running } | Should -Throw '*RUN_STATE_STALE_WRITER*'
        $current=Get-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $current.revision | Should -Be 2
        (@($current.targets | Where-Object targetId -CEQ 'fabric-1.20.2')[0]).status | Should -BeExactly 'Pending'
    }

    It 'permits only valid target state transitions' {
        $root=Join-Path $TestDrive 'runtime-transition'
        $state=New-MmtlValidationMatrixRunState -Shard $script:shard -RuntimeRoot $root
        { Set-MmtlValidationMatrixTargetStatus -State $state -TargetId 'fabric-1.20.1' -Status Passed } | Should -Throw '*RUN_STATE_TRANSITION_INVALID*'
        $running=Set-MmtlValidationMatrixTargetStatus -State $state -TargetId 'fabric-1.20.1' -Status Running
        $failed=Set-MmtlValidationMatrixTargetStatus -State $running -TargetId 'fabric-1.20.1' -Status Failed -FailureCode 'BUILD_FAILED_TOOLCHAIN'
        $failed.targets[0].status | Should -BeExactly 'Failed'
        $retry=Set-MmtlValidationMatrixTargetStatus -State $failed -TargetId 'fabric-1.20.1' -Status Running
        $retry.targets[0].attempts | Should -Be 2
        $blocked=Set-MmtlValidationMatrixTargetStatus -State $retry -TargetId 'fabric-1.20.1' -Status Blocked -FailureCode 'UPSTREAM_UNAVAILABLE'
        { Set-MmtlValidationMatrixTargetStatus -State $blocked -TargetId 'fabric-1.20.1' -Status Running } | Should -Throw '*RUN_STATE_ATTEMPT_LIMIT_REACHED*'
    }

    It 'prevents another PowerShell process from recovering targets while their owner is live' {
        $root=Join-Path $TestDrive 'runtime-target-lease'
        $shardPath=Join-Path $TestDrive 'lease-shard.json';$marker=Join-Path $TestDrive 'lease-child-result.txt'
        [IO.File]::WriteAllText($shardPath,(ConvertTo-Json -InputObject $script:shard -Depth 20),[Text.UTF8Encoding]::new($false))
        $helper=Join-Path $TestDrive 'lease child.ps1'
        $helperText=@'
param([string]$ModulePath,[string]$ShardPath,[string]$RuntimeRoot,[string]$MarkerPath)
Import-Module $ModulePath -Force
$shard=Get-Content -LiteralPath $ShardPath -Raw|ConvertFrom-Json
$lease=$null
try{$lease=Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $RuntimeRoot -Shard $shard;Exit-MmtlValidationMatrixTargetLeases -Lease $lease;[IO.File]::WriteAllText($MarkerPath,'ACQUIRED');exit 0}catch{[IO.File]::WriteAllText($MarkerPath,[string]$_.Exception.Message);exit 7}
'@
        [IO.File]::WriteAllText($helper,$helperText,[Text.UTF8Encoding]::new($false))
        $powerShell=(Get-Command pwsh -CommandType Application|Select-Object -First 1).Source
        $runChild={param([string]$inputShardPath)
            $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$powerShell;$info.WorkingDirectory=$script:repoRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            foreach($arg in @('-NoProfile','-File',$helper,$((Join-Path $script:repoRoot 'src/Validation/ValidationMatrixRunState.psm1')),$inputShardPath,$root,$marker)){$info.ArgumentList.Add([string]$arg)}
            $child=[Diagnostics.Process]::new();$child.StartInfo=$info;$child.Start()|Should -BeTrue
            $stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();$child.WaitForExit(15000)|Should -BeTrue
            [pscustomobject]@{exitCode=$child.ExitCode;stdout=$stdout.Result;stderr=$stderr.Result}
        }
        $lease=Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $root -Shard $script:shard
        try{
            $blocked=& $runChild $shardPath
            $blocked.exitCode | Should -Be 7
            (Get-Content $marker -Raw) | Should -Match 'RUN_STATE_TARGET_ALREADY_ACTIVE'
            $overlapShard=$script:shard.PSObject.Copy();$overlapShard.manifestHash=('9'*64);$overlapShard.shardCount=3;$overlapShard.shardIndex=1
            $overlapPath=Join-Path $TestDrive 'different-shard-layout.json';[IO.File]::WriteAllText($overlapPath,(ConvertTo-Json -InputObject $overlapShard -Depth 20),[Text.UTF8Encoding]::new($false))
            (& $runChild $overlapPath).exitCode | Should -Be 7
            (Get-Content $marker -Raw) | Should -Match 'RUN_STATE_TARGET_ALREADY_ACTIVE'
        }finally{Exit-MmtlValidationMatrixTargetLeases -Lease $lease}
        $released=& $runChild $shardPath
        $released.exitCode | Should -Be 0
        (Get-Content $marker -Raw) | Should -BeExactly 'ACQUIRED'
    }

    It 'releases earlier target locks when acquiring a multi-target shard fails partway through' {
        $root=Join-Path $TestDrive 'runtime-partial-lease'
        $second=$script:shard.PSObject.Copy();$secondChunk=$script:shard.chunks[0].PSObject.Copy();$secondChunk.targets=@($script:shard.chunks[0].targets[1]);$second.chunks=@($secondChunk);$second.targetCount=1
        $first=$script:shard.PSObject.Copy();$firstChunk=$script:shard.chunks[0].PSObject.Copy();$firstChunk.targets=@($script:shard.chunks[0].targets[0]);$first.chunks=@($firstChunk);$first.targetCount=1
        $held=Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $root -Shard $second
        try{
            { Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $root -Shard $script:shard } | Should -Throw '*RUN_STATE_TARGET_ALREADY_ACTIVE*fabric-1.20.2*'
            $firstLease=Enter-MmtlValidationMatrixTargetLeases -RuntimeRoot $root -Shard $first
            Exit-MmtlValidationMatrixTargetLeases -Lease $firstLease
        }finally{Exit-MmtlValidationMatrixTargetLeases -Lease $held}
    }
}
