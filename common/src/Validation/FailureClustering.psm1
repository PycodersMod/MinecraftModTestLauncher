Set-StrictMode -Version Latest

function Get-MmtlFailureFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Attempt)
    $code=[string]$Attempt.reasonCode
    if([string]::IsNullOrWhiteSpace($code)){$code='UNKNOWN_REASON'}
    $class=switch -Regex ($code) {
        '^(NETWORK_TIMEOUT|DNS_FAILURE|DOWNLOAD_TRANSIENT|CACHE_LOCK_TIMEOUT|HTTP_5XX)$' {'INFRA_TRANSIENT';break}
        '^(CONFIG_TARGET_MISMATCH|CONFIG_VERSION_MISMATCH|TOOLCHAIN_PIN_MISMATCH)$' {'CONFIG_MISMATCH';break}
        '^(ADAPTER_HASH_MISMATCH|ADAPTER_CONTRACT_FAILURE|ADAPTER_BUILD_PLAN_INVALID)$' {'ADAPTER_DEFECT';break}
        '^(FAMILY_VARIANT_DRIFT|TECHNICAL_GENERATION_CHANGE|TOOLCHAIN_FAMILY_CONFLICT)$' {'TECH_FAMILY_SPLIT';break}
        '^(TARGET_BEHAVIOR_UNSUPPORTED|TARGET_RUNTIME_EXCEPTION|TARGET_SPECIFIC_FAILURE)$' {'TARGET_EXCEPTION';break}
        '^(UPSTREAM_UNAVAILABLE|UPSTREAM_ARTIFACT_REMOVED|UPSTREAM_INCOMPATIBLE)$' {if($Attempt.PSObject.Properties['externalBlockerVerified'] -and [bool]$Attempt.externalBlockerVerified){'EXTERNAL_BLOCKED'}else{'INFRA_TRANSIENT'};break}
        '^(MINECRAFT_EULA_REQUIRED|CONSENT_REQUIRED|USER_AUTHORIZATION_REQUIRED)$' {'CONSENT_REQUIRED';break}
        '^(PROCESS_TREE_OWNERSHIP_INVALID|UNSAFE_PATH|UNTRUSTED_ARTIFACT|SAFETY_GATE_FAILED)$' {'SAFETY_BLOCKED';break}
        default {'INTERNAL_PENDING'}
    }
    $identity=[ordered]@{class=$class;reasonCode=$code}
    if($class -eq 'TARGET_EXCEPTION'){$identity.targetId=if($Attempt.PSObject.Properties['targetId']){[string]$Attempt.targetId}else{''}}
    if($class -in @('ADAPTER_DEFECT','CONFIG_MISMATCH','TECH_FAMILY_SPLIT')){$identity.loaderId=if($Attempt.PSObject.Properties['loaderId']){[string]$Attempt.loaderId}else{''};$identity.familyId=if($Attempt.PSObject.Properties['familyId']){[string]$Attempt.familyId}else{''};$identity.adapterId=if($Attempt.PSObject.Properties['adapterId']){[string]$Attempt.adapterId}else{''}}
    $rootHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $identity -Compress)))).ToLowerInvariant()
    $refs=[Collections.Generic.List[string]]::new()
    $attemptRefs=if($Attempt.PSObject.Properties['evidenceRefs']){@($Attempt.evidenceRefs)}else{@()};foreach($ref in $attemptRefs){$value=[string]$ref;if($value -match '^(?:[A-Za-z0-9._/-]+|https://[A-Za-z0-9._/?=&%#-]+)$' -and $value -notmatch '(^|/)\.\.(/|$)'){$refs.Add($value)}}
    [pscustomobject][ordered]@{class=$class;rootCauseId="cause-$($rootHash.Substring(0,20))";reasonCode=$code;diagnosticRefs=@($refs.ToArray()|Select-Object -Unique)}
}

function Group-MmtlFailureAttempts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Attempts)
    $groups=@{}
    foreach($attempt in $Attempts){
        $fingerprint=Get-MmtlFailureFingerprint -Attempt $attempt
        $key=[string]$fingerprint.rootCauseId
        if(-not $groups.ContainsKey($key)){$groups[$key]=[pscustomobject][ordered]@{rootCauseId=$key;class=[string]$fingerprint.class;reasonCode=[string]$fingerprint.reasonCode;diagnosticRefs=@($fingerprint.diagnosticRefs);targetIds=[Collections.Generic.List[string]]::new();attemptIds=[Collections.Generic.List[string]]::new();attemptCount=0}}
        $group=$groups[$key];$group.attemptCount++
        $targetId=[string]$attempt.targetId;if($targetId -and -not $group.targetIds.Contains($targetId)){$group.targetIds.Add($targetId)}
        $attemptId=[string]$attempt.attemptId;if($attemptId -and -not $group.attemptIds.Contains($attemptId)){$group.attemptIds.Add($attemptId)}
    }
    @($groups.Values|Sort-Object rootCauseId|ForEach-Object{[pscustomobject][ordered]@{rootCauseId=$_.rootCauseId;class=$_.class;reasonCode=$_.reasonCode;diagnosticRefs=@($_.diagnosticRefs);targetIds=@($_.targetIds.ToArray()|Sort-Object -Unique);attemptIds=@($_.attemptIds.ToArray());attemptCount=$_.attemptCount}})
}

function Get-MmtlAffectedRegressionSet {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RootCauseId,[Parameter(Mandatory)]$AdapterSnapshot,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Attempts,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Baseline)
    $failed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($attempt in $Attempts){$fingerprint=Get-MmtlFailureFingerprint -Attempt $attempt;if([string]$fingerprint.rootCauseId -ceq $RootCauseId -and [string]$attempt.targetId){[void]$failed.Add([string]$attempt.targetId)}}
    $smoke=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($id in @($AdapterSnapshot.smokeTargetIds)){if([string]$id){[void]$smoke.Add([string]$id)}}
    $atRisk=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $previousHash=[string]$AdapterSnapshot.previousAdapterSha256
    foreach($row in $Baseline){
        if([string]$row.status -cne 'PASS'){continue}
        $sameFamily=($row.PSObject.Properties['familyId'] -and [string]$row.familyId -ceq [string]$AdapterSnapshot.familyId)
        $sameAdapter=($row.PSObject.Properties['adapterId'] -and $AdapterSnapshot.PSObject.Properties['adapterId'] -and [string]$row.adapterId -ceq [string]$AdapterSnapshot.adapterId)
        $samePreviousHash=($previousHash -and $row.PSObject.Properties['adapterSha256'] -and [string]$row.adapterSha256 -ceq $previousHash)
        if($sameFamily -and ($sameAdapter -or $samePreviousHash)){[void]$atRisk.Add([string]$row.targetId)}
    }
    $failedIds=@($failed|Sort-Object);$smokeIds=@($smoke|Sort-Object);$riskIds=@($atRisk|Sort-Object)
    [pscustomobject][ordered]@{rootCauseId=$RootCauseId;failedTargets=$failedIds;smokeTargets=$smokeIds;previousPassAtRisk=$riskIds;allTargets=@(@($failedIds)+@($smokeIds)+@($riskIds)|Sort-Object -Unique)}
}

Export-ModuleMember -Function Get-MmtlFailureFingerprint,Group-MmtlFailureAttempts,Get-MmtlAffectedRegressionSet
