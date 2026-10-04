Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SessionLock.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AtomicFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SessionLifecycle.psm1')

function Get-MmtlRecoveryTrackedProcessState {
    param([Parameter(Mandatory)][string]$SessionPath)
    $pidPath=Join-Path $SessionPath 'pids.json'
    if(-not(Test-Path -LiteralPath $pidPath -PathType Leaf)){return [pscustomobject]@{state='None';live=@()}}
    try{$entries=@(Get-Content -LiteralPath $pidPath -Raw|ConvertFrom-Json -ErrorAction Stop)}catch{return [pscustomobject]@{state='Unknown';live=@()}}
    $live=[Collections.Generic.List[object]]::new()
    foreach($entry in $entries){
        $processId=0;try{$processId=[int]$entry.PID}catch{continue}
        $expected=[string](Get-MmtlRecoveryProperty $entry 'ProcessStartIdentity');if(-not $expected){$expected=[string](Get-MmtlRecoveryProperty $entry 'processStartIdentity')}
        if($expected){$actual=Get-MmtlProcessStartIdentity -ProcessId $processId;if($actual -and $actual -ceq $expected){$live.Add([pscustomobject]@{PID=$processId;state='Alive'})};continue}
        if($entry.StartIdentity -or $entry.StartTimeUtc -or $entry.StartTimeToken){
            try{Import-Module (Join-Path $PSScriptRoot 'ProcessManager.psm1') -Force;$record=Get-MmtlProcessRecord -ProcessId $processId;if($record -and (Test-MmtlProcessIdentity -Process $record -Record $entry)){$live.Add([pscustomobject]@{PID=$processId;state='Alive'})}}
            catch{$live.Add([pscustomobject]@{PID=$processId;state='IdentityUnknown'})}
            continue
        }
        $live.Add([pscustomobject]@{PID=$processId;state='IdentityUnknown'})
    }
    if(@($live|Where-Object state -eq 'Alive').Count){return [pscustomobject]@{state='Alive';live=@($live)}}
    if($live.Count){return [pscustomobject]@{state='Unknown';live=@($live)}}
    return [pscustomobject]@{state='None';live=@()}
}

function Get-MmtlRecoveryProperty {
    param([AllowNull()]$Object,[Parameter(Mandatory)][string]$Name)
    if($null -eq $Object){return $null};$property=$Object.PSObject.Properties[$Name];if($property){return $property.Value};return $null
}

function Get-MmtlSessionRecoveryPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $runtime=[IO.Path]::GetFullPath($RuntimeRoot);$sessions=Join-Path $runtime 'sessions';$actions=[Collections.Generic.List[object]]::new()
    if(Test-Path -LiteralPath $sessions -PathType Container){
        Assert-MmtlRecoveryNoReparse -Path $sessions
        $creationLockPath=Join-Path $sessions '.creation.lock';$creationLock=Get-MmtlSessionLockStatus -LockPath $creationLockPath -AllowedRoot $sessions
        if($creationLock.status -eq 'Stale' -and [string](Get-MmtlRecoveryProperty $creationLock.owner 'recoveryState') -ne 'Recovered'){
            $creationOwnerPid=0;try{$creationOwnerPid=[int]$creationLock.owner.ownerPid}catch{};$creationIdentity=[string]$creationLock.owner.processStartIdentity
            if($creationOwnerPid -gt 0 -and $creationIdentity -match '^\d{1,20}$' -and -not [string]::IsNullOrWhiteSpace([string]$creationLock.owner.nonce) -and -not $creationLock.processStillMatches){$actions.Add([pscustomobject]@{sessionId=$null;code='STALE_CREATION_LOCK_METADATA';reasonCode=[string]$creationLock.reasonCode;plannedAction='RepairCreationLock';ownerPid=$creationOwnerPid;processStartIdentity=$creationIdentity;ownerNonce=[string]$creationLock.owner.nonce})}
            else{$actions.Add([pscustomobject]@{sessionId=$null;code='CREATION_LOCK_OWNER_UNPROVEN';reasonCode='SESSION_LOCK_OWNER_IDENTITY_INVALID';plannedAction='None'})}
        }elseif($creationLock.status -eq 'Locked'){$actions.Add([pscustomobject]@{sessionId=$null;code='ACTIVE_CREATION_LOCK';reasonCode='SESSION_LOCKED';plannedAction='None'})}
        elseif($creationLock.status -eq 'Corrupt'){$actions.Add([pscustomobject]@{sessionId=$null;code='CREATION_LOCK_CORRUPT';reasonCode='SESSION_LOCK_CORRUPT';plannedAction='None'})}
        foreach($dir in Get-ChildItem -LiteralPath $sessions -Directory -Force|Sort-Object Name){
            Assert-MmtlRecoveryNoReparse -Path $dir.FullName
            $sessionPath=$dir.FullName;$sessionId=$dir.Name;$manifestPath=Join-Path $sessionPath 'session.v2.json';$manifest=$null
            if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
                try{$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{$actions.Add([pscustomobject]@{sessionId=$sessionId;code='SESSION_MANIFEST_CORRUPT';reasonCode='SESSION_MANIFEST_CORRUPT';plannedAction='None'});continue}
                $manifestValidation=Test-MmtlSessionV2 -SessionPath $sessionPath
                if(-not $manifestValidation.valid){$actions.Add([pscustomobject]@{sessionId=$sessionId;code='SESSION_MANIFEST_CORRUPT';reasonCode=if($manifestValidation.errors.Count){[string]$manifestValidation.errors[0]}else{'SESSION_MANIFEST_INVALID'};plannedAction='None'});continue}
            }
            $tracked=Get-MmtlRecoveryTrackedProcessState -SessionPath $sessionPath
            $lockPath=Join-Path $sessionPath '.session.lock';$lock=Get-MmtlSessionLockStatus -LockPath $lockPath -AllowedRoot $sessionPath
            $stale=$false
            if($tracked.state -eq 'Alive'){$actions.Add([pscustomobject]@{sessionId=$sessionId;code='OrphanedTrackedProcess';reasonCode='SESSION_TRACKED_PROCESS_ALIVE';plannedAction='None'})}
            elseif($tracked.state -eq 'Unknown'){$actions.Add([pscustomobject]@{sessionId=$sessionId;code='TRACKED_PROCESS_IDENTITY_UNKNOWN';reasonCode='SESSION_TRACKED_PROCESS_IDENTITY_UNKNOWN';plannedAction='None'})}
            if($lock.status -eq 'Locked'){$actions.Add([pscustomobject]@{sessionId=$sessionId;code='ACTIVE_SESSION_LOCK';reasonCode='SESSION_LOCKED';plannedAction='None'})}
            elseif($lock.status -eq 'Corrupt'){$actions.Add([pscustomobject]@{sessionId=$sessionId;code='SESSION_LOCK_CORRUPT';reasonCode='SESSION_LOCK_CORRUPT';plannedAction='None'})}
            elseif($lock.status -eq 'Stale' -and [string](Get-MmtlRecoveryProperty $lock.owner 'recoveryState') -ne 'Recovered'){
                $ownerPid=0;try{$ownerPid=[int]$lock.owner.ownerPid}catch{};$ownerIdentity=[string]$lock.owner.processStartIdentity
                if($ownerPid -le 0 -or $ownerIdentity -notmatch '^\d{1,20}$'){$actions.Add([pscustomobject]@{sessionId=$sessionId;code='SESSION_LOCK_OWNER_IDENTITY_UNPROVEN';reasonCode='SESSION_LOCK_OWNER_IDENTITY_INVALID';plannedAction='None'})}
                elseif($tracked.state -in @('Alive','Unknown')){$stale=$false}
                elseif(-not $lock.processStillMatches){$stale=$true}
                else{$actions.Add([pscustomobject]@{sessionId=$sessionId;code='SESSION_LOCK_OWNER_STILL_RUNNING';reasonCode='SESSION_LOCK_OWNER_STILL_RUNNING';plannedAction='None'})}
            }
            elseif($lock.status -eq 'Stale' -and [string](Get-MmtlRecoveryProperty $lock.owner 'recoveryState') -eq 'Recovered'){$actions.Add([pscustomobject]@{sessionId=$sessionId;code='RECOVERY_ALREADY_APPLIED';reasonCode='SESSION_RECOVERY_COMPLETE';plannedAction='None'})}
            if($stale){$actions.Add([pscustomobject]@{sessionId=$sessionId;code='STALE_LOCK_METADATA';reasonCode=[string]$lock.reasonCode;plannedAction='RepairMetadata';ownerPid=[int]$lock.owner.ownerPid;processStartIdentity=[string]$lock.owner.processStartIdentity;ownerNonce=[string]$lock.owner.nonce})}
            $temps=@(Get-ChildItem -LiteralPath $sessionPath -File -Force|Where-Object{$_.Name -match '^\.(session\.v2\.json|execution-plan\.json|session\.json|pids\.json|report\.md)\.[0-9a-fA-F]{32}\.tmp$'})
            foreach($temp in $temps){
                if(($temp.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $temp.LinkType){continue}
                $actions.Add([pscustomobject]@{sessionId=$sessionId;code='PARTIAL_ATOMIC_TEMP';reasonCode=$(if($stale){'SESSION_WRITER_IDENTITY_STALE'}else{'SESSION_TEMP_OWNER_UNPROVEN'});plannedAction=$(if($stale){'RemoveMetadataTemp'}else{'None'});tempName=$temp.Name})
            }
        }
    }
    return [pscustomobject][ordered]@{schemaVersion=1;readOnly=$true;actions=@($actions.ToArray())}
}

function Invoke-MmtlSessionRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][psobject]$Plan)
    $runtime=[IO.Path]::GetFullPath($RuntimeRoot);$sessions=Join-Path $runtime 'sessions';$recovered=0;$skipped=0;$results=[Collections.Generic.List[object]]::new()
    foreach($action in @($Plan.actions|Where-Object plannedAction -eq 'RepairCreationLock')){
        $lockPath=Join-Path $sessions '.creation.lock';$stream=$null
        try{
            Assert-MmtlRecoveryNoReparse -Path $sessions;Assert-MmtlRecoveryNoReparse -Path $lockPath
            if([int]$action.ownerPid -le 0 -or [string]$action.processStartIdentity -notmatch '^\d{1,20}$' -or [string]::IsNullOrWhiteSpace([string]$action.ownerNonce)){throw 'SESSION_LOCK_OWNER_IDENTITY_INVALID'}
            $stream=[IO.FileStream]::new($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,1024,$true);$raw=$reader.ReadToEnd();$reader.Dispose();$current=$raw|ConvertFrom-Json -ErrorAction Stop
            if([int]$current.ownerPid -ne [int]$action.ownerPid -or [string]$current.processStartIdentity -cne [string]$action.processStartIdentity -or [string]$current.nonce -cne [string]$action.ownerNonce){throw 'SESSION_LOCK_CHANGED'}
            $actual=Get-MmtlProcessStartIdentity -ProcessId ([int]$current.ownerPid);if($actual -and $actual -ceq [string]$current.processStartIdentity){throw 'SESSION_LOCK_OWNER_STILL_RUNNING'}
            $current|Add-Member -NotePropertyName recoveryState -NotePropertyValue 'Recovered' -Force;$current|Add-Member -NotePropertyName recoveredUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force;$current.ownerPid=0;$current.processStartIdentity='';$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($current|ConvertTo-Json -Compress));$stream.SetLength(0);$stream.Position=0;$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
            $results.Add([pscustomobject]@{sessionId=$null;status='Recovered';code='CREATION_LOCK_RECOVERY_APPLIED'});$recovered++
        }catch{$results.Add([pscustomobject]@{sessionId=$null;status='Skipped';code='CREATION_LOCK_RECOVERY_FAILED'});$skipped++}
        finally{if($stream){$stream.Dispose()}}
    }
    foreach($group in @($Plan.actions|Where-Object plannedAction -in @('RepairMetadata','RemoveMetadataTemp')|Group-Object sessionId)){
        $sessionId=[string]$group.Name
        if($sessionId -notmatch '^[A-Za-z0-9_-]{1,128}$'){$skipped++;continue}
        $sessionPath=Join-Path $sessions $sessionId
        try{Assert-MmtlRecoveryNoReparse -Path $sessions;Assert-MmtlRecoveryNoReparse -Path $sessionPath}catch{$skipped++;continue}
        if(-not(Test-Path -LiteralPath $sessionPath -PathType Container)){$skipped++;continue}
        $actions=@($group.Group);$staleAction=$actions|Where-Object plannedAction -eq 'RepairMetadata'|Select-Object -First 1
        if(-not $staleAction){$skipped++;continue}
        $manifestPath=Join-Path $sessionPath 'session.v2.json'
        if(Test-Path -LiteralPath $manifestPath -PathType Leaf){try{$manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code='SESSION_MANIFEST_CORRUPT'});$skipped++;continue}}else{$manifest=$null}
        $tracked=Get-MmtlRecoveryTrackedProcessState -SessionPath $sessionPath
        if($tracked.state -ne 'None'){$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code=$(if($tracked.state -eq 'Alive'){'OrphanedTrackedProcess'}else{'TRACKED_PROCESS_IDENTITY_UNKNOWN'})});$skipped++;continue}
        $lockPath=Join-Path $sessionPath '.session.lock';$stream=$null
        try{
            if([int]$staleAction.ownerPid -le 0 -or [string]$staleAction.processStartIdentity -notmatch '^\d{1,20}$' -or [string]::IsNullOrWhiteSpace([string]$staleAction.ownerNonce)){throw 'SESSION_LOCK_OWNER_IDENTITY_INVALID'}
            Assert-MmtlRecoveryNoReparse -Path $lockPath;$stream=[IO.FileStream]::new($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,1024,$true);$raw=$reader.ReadToEnd();$reader.Dispose()
            try{$current=$raw|ConvertFrom-Json -ErrorAction Stop}catch{$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code='SESSION_LOCK_CHANGED'});$skipped++;continue}
            if([int]$current.ownerPid -ne [int]$staleAction.ownerPid -or [string]$current.processStartIdentity -cne [string]$staleAction.processStartIdentity -or [string]$current.nonce -cne [string]$staleAction.ownerNonce -or [string](Get-MmtlRecoveryProperty $current 'recoveryState') -eq 'Recovered'){$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code='SESSION_LOCK_CHANGED'});$skipped++;continue}
            if(Test-Path -LiteralPath $manifestPath -PathType Leaf){$manifestValidation=Test-MmtlSessionV2 -SessionPath $sessionPath;if(-not $manifestValidation.valid){$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code='SESSION_MANIFEST_CORRUPT'});$skipped++;continue};$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json -ErrorAction Stop}
            $tracked=Get-MmtlRecoveryTrackedProcessState -SessionPath $sessionPath
            if($tracked.state -ne 'None'){$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code=$(if($tracked.state -eq 'Alive'){'OrphanedTrackedProcess'}else{'TRACKED_PROCESS_IDENTITY_UNKNOWN'})});$skipped++;continue}
            $actual=Get-MmtlProcessStartIdentity -ProcessId ([int]$current.ownerPid)
            if($actual -and $actual -ceq [string]$current.processStartIdentity){$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code='SESSION_LOCK_OWNER_STILL_RUNNING'});$skipped++;continue}
            $allowedTemps=@($actions|Where-Object{ $_.code -eq 'PARTIAL_ATOMIC_TEMP' -and $_.plannedAction -eq 'RemoveMetadataTemp' }|ForEach-Object{[string]$_.tempName})
            foreach($name in $allowedTemps){if($name -notmatch '^\.(session\.v2\.json|execution-plan\.json|session\.json|pids\.json|report\.md)\.[0-9a-fA-F]{32}\.tmp$'){continue};$target=Join-Path $sessionPath $name;if(Test-Path -LiteralPath $target -PathType Leaf){Assert-MmtlRecoveryNoReparse -Path $target;Remove-Item -LiteralPath $target -Force}}
            if($manifest -and [string]$manifest.state -in @('Created','Preparing','Building','Launching','Running')){$manifest.state='Abandoned';$manifest.updatedUtc=[DateTimeOffset]::UtcNow.ToString('o');Write-MmtlAtomicTextFile -Path $manifestPath -Content (($manifest|ConvertTo-Json -Depth 30)+"`n")}
            $current|Add-Member -NotePropertyName recoveryState -NotePropertyValue 'Recovered' -Force;$current|Add-Member -NotePropertyName recoveredUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force;$current.ownerPid=0;$current.processStartIdentity='';$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($current|ConvertTo-Json -Compress));$stream.SetLength(0);$stream.Position=0;$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
            $results.Add([pscustomobject]@{sessionId=$sessionId;status='Recovered';code='SESSION_RECOVERY_APPLIED'});$recovered++
        }catch [IO.IOException]{$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code='SESSION_LOCKED'});$skipped++}
        catch{$results.Add([pscustomobject]@{sessionId=$sessionId;status='Skipped';code='SESSION_RECOVERY_FAILED'});$skipped++}
        finally{if($stream){$stream.Dispose()}}
    }
    return [pscustomobject][ordered]@{schemaVersion=1;recovered=$recovered;skipped=$skipped;results=@($results.ToArray())}
}

function Assert-MmtlRecoveryNoReparse {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetPathRoot($full);$current=$root
    foreach($part in ($full.Substring($root.Length)-split '[\\/]'|Where-Object{$_})){$current=Join-Path $current $part;if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw 'SESSION_PATH_REPARSE_POINT'}}}
}

Export-ModuleMember -Function Get-MmtlSessionRecoveryPlan,Invoke-MmtlSessionRecovery
