Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ValidationRunner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationMatrixRunState.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../Compatibility/EvidenceStore.psm1') -Force

function Invoke-MmtlValidationMatrixTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][object]$Target,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [string]$GradleHomeRoot,
        [Parameter(Mandatory)][object]$CacheIdentity,
        [AllowEmptyCollection()][string[]]$AllowedOwners=@(),
        [string]$BuildJavaHome,
        [ValidateRange(1,7200)][int]$TimeoutSeconds=1800,
        [switch]$Clean
    )
    if([string]$Target.targetId -cne $TargetId){throw 'MATRIX_TARGET_ID_MISMATCH'}
    $row=@($State.targets|Where-Object targetId -CEQ $TargetId)
    if($row.Count -ne 1){throw 'RUN_STATE_TARGET_NOT_FOUND'}
    $identity=ConvertTo-MmtlCompatibilityCacheIdentity -Identity $CacheIdentity
    if($identity.targetId -cne $TargetId -or $identity.universeHash -cne [string]$State.universeHash -or $identity.sourceHash -cne [string]$row[0].sourceHash -or $identity.toolchainHash -cne [string]$row[0].toolchainHash -or $identity.targetSpecHash -cne [string]$row[0].targetSpecHash){
        throw 'MATRIX_CACHE_IDENTITY_MISMATCH'
    }
    if($row[0].status -notin @('Pending','Failed','Blocked')){throw "MATRIX_TARGET_NOT_RUNNABLE:$($row[0].status)"}

    $running=Set-MmtlValidationMatrixTargetStatus -State $State -TargetId $TargetId -Status Running
    try{
        $result=Invoke-MmtlValidationBuild -Project $Project -Target $Target -RuntimeRoot $RuntimeRoot -GradleHomeRoot $GradleHomeRoot -AllowedOwners $AllowedOwners -BuildJavaHome $BuildJavaHome -TimeoutSeconds $TimeoutSeconds -Clean:$Clean -CacheIdentity $identity
    }catch{
        $failureState=Set-MmtlValidationMatrixTargetStatus -State $running -TargetId $TargetId -Status Failed -FailureCode 'BUILD_FAILED_MMTL'
        throw
    }
    switch([string]$result.result){
        'PASSED' {$finalState=Set-MmtlValidationMatrixTargetStatus -State $running -TargetId $TargetId -Status Passed -EvidencePath ([string]$result.evidencePath) -Cached:([bool]$result.cached)}
        'BLOCKED' {$code=if([string]$result.failureCode){[string]$result.failureCode}else{'UPSTREAM_UNAVAILABLE'};$finalState=Set-MmtlValidationMatrixTargetStatus -State $running -TargetId $TargetId -Status Blocked -FailureCode $code}
        'FAILED' {$code=if([string]$result.failureCode){[string]$result.failureCode}else{'BUILD_FAILED_MMTL'};$finalState=Set-MmtlValidationMatrixTargetStatus -State $running -TargetId $TargetId -Status Failed -FailureCode $code}
        default {$finalState=Set-MmtlValidationMatrixTargetStatus -State $running -TargetId $TargetId -Status Blocked -FailureCode 'EVIDENCE_INVALID';throw "MATRIX_RESULT_INVALID:$($result.result)"}
    }
    [pscustomobject]@{targetId=$TargetId;result=$result;runState=$finalState;cached=[bool]$result.cached}
}

Export-ModuleMember -Function Invoke-MmtlValidationMatrixTarget
