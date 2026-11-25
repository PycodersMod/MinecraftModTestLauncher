Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ValidationEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TargetIdentity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationMatrixJobs.psm1') -Force

function New-MmtlFullMatrixShardProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$WorkerScriptPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments
    )
    foreach($path in @($PowerShellPath,$WorkerScriptPath,$WorkingDirectory)){
        if([string]::IsNullOrWhiteSpace($path)){throw 'MATRIX_PROCESS_PATH_REQUIRED'}
    }
    if(-not(Test-Path -LiteralPath $PowerShellPath -PathType Leaf)){throw 'MATRIX_POWERSHELL_NOT_FOUND'}
    if(-not(Test-Path -LiteralPath $WorkerScriptPath -PathType Leaf)){throw 'MATRIX_WORKER_NOT_FOUND'}
    if(-not(Test-Path -LiteralPath $WorkingDirectory -PathType Container)){throw 'MATRIX_WORKING_DIRECTORY_NOT_FOUND'}
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=[IO.Path]::GetFullPath($PowerShellPath)
    $info.WorkingDirectory=[IO.Path]::GetFullPath($WorkingDirectory)
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-File',[IO.Path]::GetFullPath($WorkerScriptPath)) + @($Arguments)){
        if($null -eq $argument -or ([string]$argument).Contains([char]0)){throw 'MATRIX_PROCESS_ARGUMENT_INVALID'}
        $info.ArgumentList.Add([string]$argument)
    }
    return $info
}

function Get-MmtlFullMatrixAggregateStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ShardSummaries)
    if($ShardSummaries.Count -eq 0){throw 'MATRIX_SHARDS_EMPTY'}
    $counts=[ordered]@{passed=0;partial=0;incomplete=0;failed=0}
    $hasFailure=$false;$hasIncomplete=$false
    foreach($shard in $ShardSummaries){
        $status=[string]$shard.status
        switch($status){
            'PASSED'{$counts.passed++}
            {$_ -in 'PARTIAL','BLOCKED'}{$counts.partial++;$hasFailure=$true}
            'FAILED'{$counts.failed++;$hasFailure=$true}
            {$_ -in 'INCOMPLETE','RUNNING'}{$counts.incomplete++;$hasIncomplete=$true}
            default{throw "MATRIX_SHARD_STATUS_INVALID:$status"}
        }
        if($null -ne $shard.PSObject.Properties['exitCode'] -and [int]$shard.exitCode -ne 0){
            if([int]$shard.exitCode -eq 2 -and $status -eq 'INCOMPLETE'){$hasIncomplete=$true}
            else{$hasFailure=$true}
        }
    }
    $status=if($hasFailure){'PARTIAL'}elseif($hasIncomplete){'INCOMPLETE'}else{'PASSED'}
    [pscustomobject][ordered]@{status=$status;statusCounts=[pscustomobject]$counts;shardCount=$ShardSummaries.Count}
}

function Write-MmtlFullMatrixAtomicJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Value)
    $full=[IO.Path]::GetFullPath($Path);$directory=Split-Path -Parent $full
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary=$full+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,(ConvertTo-Json -InputObject $Value -Depth 30),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary,$full,$true)
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}

function Protect-MmtlFullMatrixText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,[Parameter(Mandatory)][string[]]$LocalPaths)
    $safe=ConvertTo-MmtlRedactedValidationText -Text $Text
    foreach($localPath in $LocalPaths){if($localPath){$safe=$safe.Replace($localPath,'[LOCAL_PATH]')}}
    return $safe
}

function Stop-MmtlFullMatrixOwnedWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Worker,[ValidateRange(1,60)][int]$TimeoutSeconds=10)
    $process=$Worker.process
    if(-not $process.HasExited){
        try{$process.Kill($true)}catch{if(-not $process.HasExited){throw 'MATRIX_WORKER_STOP_FAILED'}}
    }
    if(-not $process.WaitForExit($TimeoutSeconds*1000)){throw 'MATRIX_WORKER_STOP_TIMEOUT'}
    $stdout='';$stderr=''
    if($Worker.stdout){try{$stdout=[string]$Worker.stdout.GetAwaiter().GetResult()}catch{throw 'MATRIX_WORKER_STDOUT_DRAIN_FAILED'}}
    if($Worker.stderr){try{$stderr=[string]$Worker.stderr.GetAwaiter().GetResult()}catch{throw 'MATRIX_WORKER_STDERR_DRAIN_FAILED'}}
    [pscustomobject][ordered]@{processId=[int]$Worker.processId;exitCode=[int]$process.ExitCode;stdout=$stdout;stderr=$stderr}
}

function Get-MmtlFullMatrixMemoryParallelLimit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(0,1048576)][double]$AvailableGiB,
        [Parameter(Mandatory)][ValidateRange(1,16)][int]$RequestedMaximum
    )
    if($AvailableGiB -lt 6){return 0}
    if($AvailableGiB -lt 10){return [Math]::Min(1,$RequestedMaximum)}
    return [Math]::Min(2,$RequestedMaximum)
}

function Get-MmtlFullMatrixAvailableMemoryGiB {
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        $memoryOs=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return [double]$memoryOs.FreePhysicalMemory/1MB
    }
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){
        $line=Get-Content -LiteralPath '/proc/meminfo' -ErrorAction Stop | Where-Object {$_ -match '^MemAvailable:\s+(\d+)\s+kB$'} | Select-Object -First 1
        if($line -notmatch '^MemAvailable:\s+(\d+)\s+kB$'){throw 'MATRIX_MEMORY_TELEMETRY_UNAVAILABLE'}
        return [double]$Matches[1]/1MB
    }
    throw 'MATRIX_MEMORY_TELEMETRY_UNAVAILABLE'
}

function Invoke-MmtlFullCompatibilityMatrix {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MatrixManifestPath,
        [Parameter(Mandatory)][string]$JobsPath,
        [Parameter(Mandatory)][ValidateRange(1,10000)][int]$ShardCount,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [ValidateRange(1,16)][int]$MaxParallelShards=1,
        [switch]$MemoryAwareParallelism,
        [ValidateRange(1,60)][int]$MemorySampleIntervalSeconds=5,
        [string]$UniversePath,
        [string]$FamilyManifestPath,
        [string]$LedgerPath,
        [string]$WorkerScriptPath,
        [ValidateRange(1,10)][int]$MaxAttempts=3,
        [ValidateRange(1,7200)][int]$TimeoutSeconds=1800,
        [AllowEmptyCollection()][string[]]$AllowedOwners=@(),
        [string]$BuildJavaHome,
        [string]$GoalProgressRunRoot,
        [switch]$Clean
    )
    $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    if(-not $UniversePath){$UniversePath=Join-Path $repositoryRoot 'compatibility/universe-preview.json'}
    if(-not $FamilyManifestPath){$FamilyManifestPath=Join-Path $repositoryRoot 'compatibility/families.json'}
    if(-not $LedgerPath){$LedgerPath=Join-Path $repositoryRoot 'compatibility/ledger-template.json'}
    foreach($path in @($MatrixManifestPath,$JobsPath,$UniversePath,$FamilyManifestPath,$LedgerPath)){
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "MATRIX_INPUT_NOT_FOUND:$path"}
        if(([IO.File]::GetAttributes([IO.Path]::GetFullPath($path)) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'MATRIX_INPUT_REPARSE_FILE'}
    }
    $manifest=Get-Content -LiteralPath $MatrixManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
    $jobsDocument=Get-Content -LiteralPath $JobsPath -Raw|ConvertFrom-Json -ErrorAction Stop
    $universe=Get-Content -LiteralPath $UniversePath -Raw|ConvertFrom-Json -ErrorAction Stop
    $families=Get-Content -LiteralPath $FamilyManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
    $ledger=Get-Content -LiteralPath $LedgerPath -Raw|ConvertFrom-Json -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'ValidationMatrixChunks.psm1') -Force
    $manifestCheck=Test-MmtlValidationMatrixChunkManifest -Manifest $manifest -Ledger $ledger -Universe $universe -FamilyManifest $families
    if(-not $manifestCheck.isValid){throw "MATRIX_MANIFEST_INVALID:$($manifestCheck.errors -join ';')"}
    if($ShardCount -gt [int]$manifest.chunkCount){throw 'MATRIX_SHARD_COUNT_EXCEEDS_CHUNKS'}
    $jobsSchemaPath=Join-Path $repositoryRoot 'common/schemas/validation-matrix-job-manifest.schema.json'
    $jobsJson=ConvertTo-Json -InputObject $jobsDocument -Depth 40
    if(-not(Test-Json -Json $jobsJson -SchemaFile $jobsSchemaPath -ErrorAction SilentlyContinue)){throw 'MATRIX_JOB_MANIFEST_SCHEMA_INVALID'}
    $jobManifestCheck=Test-MmtlValidationMatrixJobsManifest -Manifest $jobsDocument
    if(-not $jobManifestCheck.isValid){throw "MATRIX_JOB_MANIFEST_INVALID:$($jobManifestCheck.errors -join ';')"}
    if([string]$jobsDocument.manifestHash -cne [string]$manifest.manifestHash){throw 'MATRIX_JOB_MANIFEST_HASH_MISMATCH'}
    if([int]$manifest.targetCount -ne @($jobsDocument.jobs).Count){throw 'MATRIX_JOB_SET_INCOMPLETE'}
    $jobIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectedJobIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($chunk in $manifest.chunks){foreach($target in $chunk.targets){[void]$expectedJobIds.Add([string]$target.targetId)}}
    $ledgerById=@{};foreach($row in $ledger.targets){$ledgerById[[string]$row.targetId]=$row}
    $universeById=@{};foreach($row in $universe.targets){$universeById[[string]$row.targetId]=$row}
    foreach($job in $jobsDocument.jobs){
        $id=[string]$job.targetId
        if(-not $jobIds.Add($id)){throw "MATRIX_JOB_DUPLICATE:$id"}
        if(-not $expectedJobIds.Contains($id)){throw "MATRIX_JOB_TARGET_UNEXPECTED:$id"}
        if(-not $ledgerById.ContainsKey($id) -or -not $universeById.ContainsKey($id)){throw "MATRIX_JOB_TARGET_UNKNOWN:$id"}
        $ledgerTarget=$ledgerById[$id];$frozenTarget=$universeById[$id];$candidateVersions=[string[]]@(Get-MmtlLoaderVersionCandidateValues -Candidates $frozenTarget.loaderVersionCandidates)
        if([string]$job.target.targetId -cne $id -or [string]$job.cacheIdentity.targetId -cne $id){throw "MATRIX_JOB_TARGET_MISMATCH:$id"}
        if([string]$job.cacheIdentity.universeHash -cne [string]$manifest.universeHash -or [string]$job.cacheIdentity.sourceHash -cne [string]$ledgerTarget.sourceHash -or [string]$job.cacheIdentity.toolchainHash -cne [string]$ledgerTarget.toolchainHash -or [string]$job.cacheIdentity.targetSpecHash -cne [string]$ledgerTarget.targetSpecHash){throw "MATRIX_JOB_IDENTITY_MISMATCH:$id"}
        if([string]$job.target.minecraftId -cne [string]$frozenTarget.minecraftId -or [string]$job.project.minecraftVersion -cne [string]$frozenTarget.minecraftId -or [string]$job.project.loader -cne [string]$ledgerTarget.loaderId -or [string]$job.target.loaderStack.primary.id -cne [string]$ledgerTarget.loaderId -or [string]$job.project.loaderVersion -cnotin $candidateVersions -or [string]$job.target.loaderVersion -cnotin $candidateVersions -or [string]$job.target.loaderVersion -cne [string]$job.project.loaderVersion -or [string]$job.target.loaderStack.primary.version -cne [string]$job.project.loaderVersion){throw "MATRIX_JOB_PROJECT_TARGET_MISMATCH:$id"}
        $projectPath=[string]$job.projectPath
        if(-not [IO.Path]::IsPathRooted($projectPath)){$projectPath=Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($JobsPath))) $projectPath}
        $projectPath=[IO.Path]::GetFullPath($projectPath)
        if(-not(Test-Path -LiteralPath $projectPath -PathType Container)){throw "MATRIX_PROJECT_PATH_NOT_FOUND:$($job.targetId)"}
        if(([IO.File]::GetAttributes($projectPath) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'MATRIX_PROJECT_ROOT_REPARSE'}
    }
    if($jobIds.Count -ne [int]$manifest.targetCount -or @($expectedJobIds|Where-Object{-not $jobIds.Contains($_)}).Count -gt 0){throw 'MATRIX_JOB_SET_INCOMPLETE'}
    $powerShell=(Get-Command pwsh -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
    if(-not $WorkerScriptPath){$WorkerScriptPath=Join-Path $repositoryRoot 'tools/Invoke-CompatibilityMatrixShard.ps1'}
    if(-not(Test-Path -LiteralPath $WorkerScriptPath -PathType Leaf)){throw 'MATRIX_WORKER_NOT_FOUND'}
    $worker=[IO.Path]::GetFullPath($WorkerScriptPath)
    $runId=[DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $outputRoot=[IO.Path]::GetFullPath((Join-Path $OutputDirectory $runId));[void][IO.Directory]::CreateDirectory($outputRoot)
    $pending=[Collections.Queue]::new();for($i=0;$i -lt $ShardCount;$i++){$pending.Enqueue($i)}
    $active=[Collections.Generic.List[object]]::new();$completed=[Collections.Generic.List[object]]::new()
    $currentParallelLimit=$MaxParallelShards
    $lastMemorySample=[DateTimeOffset]::MinValue
    $runtimeFull=[IO.Path]::GetFullPath($RuntimeRoot)
    try{
    while($pending.Count -gt 0 -or $active.Count -gt 0){
        if($MemoryAwareParallelism -and (([DateTimeOffset]::UtcNow-$lastMemorySample).TotalSeconds -ge $MemorySampleIntervalSeconds)){
            $lastMemorySample=[DateTimeOffset]::UtcNow
            try{
                $availableGiB=Get-MmtlFullMatrixAvailableMemoryGiB
                $currentParallelLimit=Get-MmtlFullMatrixMemoryParallelLimit -AvailableGiB $availableGiB -RequestedMaximum $MaxParallelShards
                Write-Host ("[MatrixMemory] availableGiB={0:N2} active={1} pending={2} admissionLimit={3}" -f $availableGiB,$active.Count,$pending.Count,$currentParallelLimit)
            }catch{
                $currentParallelLimit=0
                Write-Warning 'Matrix memory telemetry unavailable; pausing new heavy-worker admission until a later successful sample.'
            }
        }
        while($pending.Count -gt 0 -and $active.Count -lt $currentParallelLimit){
            $index=[int]$pending.Dequeue();$baseName=('shard-{0:D4}-of-{1:D4}' -f $index,$ShardCount)
            $summaryPath=Join-Path $outputRoot ($baseName+'.summary.json')
            $argsList=[Collections.Generic.List[string]]::new()
            foreach($pair in @(@('-MatrixManifestPath',[IO.Path]::GetFullPath($MatrixManifestPath)),@('-JobsPath',[IO.Path]::GetFullPath($JobsPath)),@('-ShardIndex',[string]$index),@('-ShardCount',[string]$ShardCount),@('-RuntimeRoot',$runtimeFull),@('-OutputPath',$summaryPath))){$argsList.AddRange([string[]]$pair)}
            foreach($pair in @(@('-UniversePath',[IO.Path]::GetFullPath($UniversePath)),@('-FamilyManifestPath',[IO.Path]::GetFullPath($FamilyManifestPath)),@('-LedgerPath',[IO.Path]::GetFullPath($LedgerPath)),@('-MaxAttempts',[string]$MaxAttempts),@('-TimeoutSeconds',[string]$TimeoutSeconds))){$argsList.AddRange([string[]]$pair)}
            if($BuildJavaHome){$argsList.Add('-BuildJavaHome');$argsList.Add([IO.Path]::GetFullPath($BuildJavaHome))}
            if($GoalProgressRunRoot){$argsList.Add('-GoalProgressRunRoot');$argsList.Add([IO.Path]::GetFullPath($GoalProgressRunRoot))}
            if($AllowedOwners.Count -gt 0){$argsList.Add('-AllowedOwners');foreach($owner in $AllowedOwners){$argsList.Add([string]$owner)}}
            if($Clean){$argsList.Add('-Clean')}
            $info=New-MmtlFullMatrixShardProcessStartInfo -PowerShellPath $powerShell -WorkerScriptPath $worker -WorkingDirectory $repositoryRoot -Arguments $argsList.ToArray()
            $process=[Diagnostics.Process]::new();$process.StartInfo=$info
            try{
                if(-not $process.Start()){throw 'MATRIX_WORKER_START_FAILED'}
                $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
                $active.Add([pscustomobject]@{index=$index;process=$process;processId=[int]$process.Id;stdout=$stdout;stderr=$stderr;summaryPath=$summaryPath;baseName=$baseName})
            }catch{
                $stdoutPath=Join-Path $outputRoot ($baseName+'.stdout.log');$stderrPath=Join-Path $outputRoot ($baseName+'.stderr.log')
                [IO.File]::WriteAllText($stdoutPath,'',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderrPath,'',[Text.UTF8Encoding]::new($false))
                $safeLocalPaths=@(@($repositoryRoot,$runtimeFull,$env:USERPROFILE)|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
                $completed.Add([pscustomobject][ordered]@{shardIndex=$index;status='FAILED';exitCode=1;processId=$null;targetCount=0;statusCounts=$null;statePath=$null;summaryPath=($baseName+'.summary.json');stdoutPath=($baseName+'.stdout.log');stdoutSha256=(Get-FileHash $stdoutPath -Algorithm SHA256).Hash.ToLowerInvariant();stderrPath=($baseName+'.stderr.log');stderrSha256=(Get-FileHash $stderrPath -Algorithm SHA256).Hash.ToLowerInvariant();error=(Protect-MmtlFullMatrixText -Text ([string]$_.Exception.Message) -LocalPaths $safeLocalPaths)})
                $process.Dispose()
            }
        }
        for($i=$active.Count-1;$i -ge 0;$i--){
            $item=$active[$i]
            if(-not $item.process.HasExited){continue}
            $item.process.WaitForExit();$exitCode=[int]$item.process.ExitCode
            $localPaths=@(@($repositoryRoot,$runtimeFull,$env:USERPROFILE)|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
            $stdoutText=Protect-MmtlFullMatrixText -Text ([string]$item.stdout.Result) -LocalPaths $localPaths
            $stderrText=Protect-MmtlFullMatrixText -Text ([string]$item.stderr.Result) -LocalPaths $localPaths
            $stdoutPath=Join-Path $outputRoot ($item.baseName+'.stdout.log');$stderrPath=Join-Path $outputRoot ($item.baseName+'.stderr.log')
            [IO.File]::WriteAllText($stdoutPath,$stdoutText,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderrPath,$stderrText,[Text.UTF8Encoding]::new($false))
            $workerSummary=$null;$workerError=$null
            try{
                $workerSummary=Get-Content -LiteralPath $item.summaryPath -Raw|ConvertFrom-Json -ErrorAction Stop
                if([int]$workerSummary.shardIndex -ne [int]$item.index -or [int]$workerSummary.shardCount -ne $ShardCount -or [string]$workerSummary.manifestHash -cne [string]$manifest.manifestHash){throw 'MATRIX_WORKER_SUMMARY_IDENTITY_MISMATCH'}
                if($workerSummary.PSObject.Properties['statePath'] -and $workerSummary.statePath){
                    $workerStatePath=[string]$workerSummary.statePath
                    if($workerStatePath.StartsWith($runtimeFull,[StringComparison]::OrdinalIgnoreCase)){$workerSummary.statePath=$workerStatePath.Replace($runtimeFull,'[RUNTIME_ROOT]')}
                    else{$workerSummary.statePath=Protect-MmtlFullMatrixText -Text $workerStatePath -LocalPaths $localPaths}
                }
                foreach($resultEntry in @($workerSummary.results)){
                    if($resultEntry -and $resultEntry.PSObject.Properties['error'] -and $resultEntry.error){$resultEntry.error=Protect-MmtlFullMatrixText -Text ([string]$resultEntry.error) -LocalPaths $localPaths}
                }
                $safeWorkerJson=ConvertTo-MmtlRedactedValidationText -Text (ConvertTo-Json -InputObject $workerSummary -Depth 30)
                [IO.File]::WriteAllText($item.summaryPath,$safeWorkerJson,[Text.UTF8Encoding]::new($false))
            }catch{$workerError=Protect-MmtlFullMatrixText -Text ([string]$_.Exception.Message) -LocalPaths $localPaths}
            $status='FAILED'
            if($workerSummary -and (([string]$workerSummary.status -eq 'PASSED' -and $exitCode -eq 0) -or ([string]$workerSummary.status -eq 'PARTIAL' -and $exitCode -eq 1) -or ([string]$workerSummary.status -eq 'INCOMPLETE' -and $exitCode -eq 2))){$status=[string]$workerSummary.status}
            $completed.Add([pscustomobject][ordered]@{shardIndex=[int]$item.index;status=$status;exitCode=$exitCode;processId=$item.processId;targetCount=if($workerSummary){[int]$workerSummary.targetCount}else{0};statusCounts=if($workerSummary){$workerSummary.statusCounts}else{$null};statePath=if($workerSummary){([string]$workerSummary.statePath).Replace($runtimeFull,'[RUNTIME_ROOT]')}else{$null};summaryPath=($item.baseName+'.summary.json');stdoutPath=($item.baseName+'.stdout.log');stdoutSha256=(Get-FileHash $stdoutPath -Algorithm SHA256).Hash.ToLowerInvariant();stderrPath=($item.baseName+'.stderr.log');stderrSha256=(Get-FileHash $stderrPath -Algorithm SHA256).Hash.ToLowerInvariant();error=$workerError})
            $item.process.Dispose();$active.RemoveAt($i)
        }
        if($active.Count -gt 0){Start-Sleep -Milliseconds 200}
        elseif($MemoryAwareParallelism -and $pending.Count -gt 0){Start-Sleep -Seconds 1}
    }
    $orderedShards=@($completed.ToArray()|Sort-Object shardIndex)
    $overall=Get-MmtlFullMatrixAggregateStatus -ShardSummaries $orderedShards
    $summary=[pscustomobject][ordered]@{schemaVersion=1;runId=$runId;status=$overall.status;universeHash=[string]$manifest.universeHash;manifestHash=[string]$manifest.manifestHash;targetCount=[int]$manifest.targetCount;shardCount=$ShardCount;maxParallelShards=$MaxParallelShards;statusCounts=$overall.statusCounts;shards=$orderedShards;generatedAt=[DateTimeOffset]::UtcNow.ToString('o')}
    $schemaPath=Join-Path $repositoryRoot 'common/schemas/full-compatibility-matrix-run.schema.json'
    if(-not(Test-Json -Json (ConvertTo-Json -InputObject $summary -Depth 30) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)){throw 'MATRIX_RUN_SUMMARY_SCHEMA_INVALID'}
    $summaryPath=Join-Path $outputRoot 'matrix-summary.json';Write-MmtlFullMatrixAtomicJson -Path $summaryPath -Value $summary
    $summary|Add-Member -NotePropertyName summaryPath -NotePropertyValue $summaryPath
    return $summary
    }finally{
        foreach($item in @($active.ToArray())){
            try{
                $stopped=Stop-MmtlFullMatrixOwnedWorker -Worker $item
                $localPaths=@(@($repositoryRoot,$runtimeFull,$env:USERPROFILE)|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
                $stdoutText=Protect-MmtlFullMatrixText -Text $stopped.stdout -LocalPaths $localPaths
                $stderrText=Protect-MmtlFullMatrixText -Text $stopped.stderr -LocalPaths $localPaths
                [IO.File]::WriteAllText((Join-Path $outputRoot ($item.baseName+'.stdout.log')),$stdoutText,[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText((Join-Path $outputRoot ($item.baseName+'.stderr.log')),$stderrText,[Text.UTF8Encoding]::new($false))
            }finally{$item.process.Dispose()}
        }
    }
}

Export-ModuleMember -Function New-MmtlFullMatrixShardProcessStartInfo,Stop-MmtlFullMatrixOwnedWorker,Get-MmtlFullMatrixMemoryParallelLimit,Get-MmtlFullMatrixAggregateStatus,Invoke-MmtlFullCompatibilityMatrix
