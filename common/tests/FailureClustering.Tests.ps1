BeforeAll {
    $script:commonRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:commonRoot 'src/Validation/FailureClustering.psm1') -Force
}

Describe 'Structured compatibility failure clustering' {
    It 'classifies the nine required root cause classes from structured reason codes' {
        $cases=@(
            @('NETWORK_TIMEOUT','INFRA_TRANSIENT'),@('CONFIG_TARGET_MISMATCH','CONFIG_MISMATCH'),
            @('ADAPTER_HASH_MISMATCH','ADAPTER_DEFECT'),@('FAMILY_VARIANT_DRIFT','TECH_FAMILY_SPLIT'),
            @('TARGET_BEHAVIOR_UNSUPPORTED','TARGET_EXCEPTION'),
            @('UPSTREAM_UNAVAILABLE','EXTERNAL_BLOCKED'),@('MINECRAFT_EULA_REQUIRED','CONSENT_REQUIRED'),
            @('PROCESS_TREE_OWNERSHIP_INVALID','SAFETY_BLOCKED'),@('UNKNOWN_REASON','INTERNAL_PENDING')
        )
        foreach($case in $cases){
            $attempt=[pscustomobject]@{reasonCode=$case[0];source='https://example.invalid/issue';evidenceRefs=@('reports/attempt-01.json');externalBlockerVerified=($case[0] -eq 'UPSTREAM_UNAVAILABLE');attemptedRemediation='network retry recorded'}
            (Get-MmtlFailureFingerprint -Attempt $attempt).class | Should -BeExactly $case[1]
        }
    }

    It 'uses stable root cause IDs across targets and omits raw exception text and secrets' {
        $a=[pscustomobject]@{loaderId='Fabric';familyId='family-a';adapterId='fabric-v3';reasonCode='ADAPTER_HASH_MISMATCH';targetId='Fabric@1.21.8';error='token=SECRET should never appear';evidenceRefs=@('reports/a.json')}
        $b=$a|ConvertTo-Json|ConvertFrom-Json;$b.targetId='Fabric@1.21.11';$b.error='different raw stack trace'
        $first=Get-MmtlFailureFingerprint -Attempt $a;$second=Get-MmtlFailureFingerprint -Attempt $b
        $first.rootCauseId | Should -BeExactly $second.rootCauseId
        ($first|ConvertTo-Json -Depth 8) | Should -Not -Match 'SECRET|stack trace|token='
    }

    It 'keeps attempt history grouped by root cause without merging unrelated failures' {
        $attempts=@(
            [pscustomobject]@{targetId='Fabric@1.21.8';attemptId='a1';reasonCode='ADAPTER_HASH_MISMATCH';familyId='family-a';adapterId='fabric-v3'},
            [pscustomobject]@{targetId='Fabric@1.21.11';attemptId='a2';reasonCode='ADAPTER_HASH_MISMATCH';familyId='family-a';adapterId='fabric-v3'},
            [pscustomobject]@{targetId='Forge@1.20.1';attemptId='b1';reasonCode='NETWORK_TIMEOUT';familyId='forge-a';adapterId='forge-v2'}
        )
        $groups=Group-MmtlFailureAttempts -Attempts $attempts
        $groups | Should -HaveCount 2
        @($groups|Where-Object class -eq 'ADAPTER_DEFECT')[0].targetIds | Should -HaveCount 2
        @($groups|ForEach-Object{$_.attemptIds.Count}|Measure-Object -Sum).Sum | Should -Be 3
    }

    It 'includes affected failures, family smoke targets, and prior passes at risk' {
        $adapter=[pscustomobject]@{adapterId='fabric-v3';familyId='family-a';adapterSha256=('a'*64);previousAdapterSha256=('b'*64);smokeTargetIds=@('Fabric@1.21.8','Fabric@1.21.11')}
        $attempts=@([pscustomobject]@{targetId='Fabric@1.21.10';reasonCode='ADAPTER_HASH_MISMATCH';familyId='family-a';adapterId='fabric-v3'})
        $baseline=@(
            [pscustomobject]@{targetId='Fabric@1.21.8';status='PASS';adapterSha256=('b'*64);familyId='family-a'},
            [pscustomobject]@{targetId='Fabric@1.20.1';status='PASS';adapterSha256=('c'*64);familyId='family-b'}
        )
        $fingerprint=Get-MmtlFailureFingerprint -Attempt $attempts[0]
        $set=Get-MmtlAffectedRegressionSet -RootCauseId $fingerprint.rootCauseId -AdapterSnapshot $adapter -Attempts $attempts -Baseline $baseline
        $set.failedTargets | Should -Contain 'Fabric@1.21.10'
        $set.smokeTargets | Should -Contain 'Fabric@1.21.11'
        $set.previousPassAtRisk | Should -Contain 'Fabric@1.21.8'
        $set.previousPassAtRisk | Should -Not -Contain 'Fabric@1.20.1'
    }

    It 'does not classify an upstream error as externally blocked without verified evidence' {
        $fp=Get-MmtlFailureFingerprint -Attempt ([pscustomobject]@{reasonCode='UPSTREAM_UNAVAILABLE';externalBlockerVerified=$false;error='raw text ignored'})
        $fp.class | Should -BeExactly 'INFRA_TRANSIENT'
    }
}
