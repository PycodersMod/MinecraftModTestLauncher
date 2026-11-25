BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Compatibility/EvidenceStore.psm1') -Force

    function New-TestCompatibilityEvidence {
        param([string]$TargetId = 'fabric-1.20.1-windows-x64', [string]$Result = 'PASSED', [string]$Level = 'BUILD_VERIFIED')
        [pscustomobject][ordered]@{
            schemaVersion=1;targetId=$TargetId;runId='cache-test-001';startedAt='2026-10-08T00:00:00Z';endedAt='2026-10-08T00:01:00Z';durationSeconds=60
            validationLevel=$Level;result=$Result;failureCode=if($Result -eq 'PASSED'){'NONE'}else{'BUILD_FAILED_TOOLCHAIN'}
            platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false}
            java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};observedBuildJava=[pscustomobject]@{major=17;exactVersion='17.0.19';vendor='Temurin';os='Windows';arch='x64'};compilerTarget=17;runtimeRequirement=$null;observedRuntimeJava=$null}
            minecraftId='1.20.1';loaderId='Fabric';loaderVersion='0.15.0';toolchain=[pscustomobject]@{id='FabricLoom';version='1.6.12'};buildSystem=[pscustomobject]@{id='Gradle';version='8.8'}
            source=[pscustomobject]@{fingerprint=('sha256:' + ('1'*64));unchangedDuringBuild=$true;artifactFresh=$true}
            sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=('a'*40);license='CC0-1.0';trust='TrustedOfficial'}
            logs=@([pscustomobject]@{path='stdout.log';sha256=('2'*64)});artifact=[pscustomobject]@{path='build/libs/marker.jar';filename='marker.jar';sizeBytes=123;sha256=('3'*64)}
            process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@()
        }
    }

    function New-TestCacheIdentity {
        param([ValidateSet('d','e','f','0')][string]$Spec='d')
        [pscustomobject][ordered]@{targetId='fabric-1.20.1-windows-x64';universeHash=('a'*64);sourceHash=('b'*64);toolchainHash=('c'*64);targetSpecHash=($Spec*64);agentHash=$null}
    }
}

Describe 'Compatibility evidence cache' {
    It 'derives a deterministic key from every exact source and toolchain identity hash' {
        $identity=New-TestCacheIdentity
        $first=Get-MmtlCompatibilityEvidenceCacheKey -Identity $identity
        $second=Get-MmtlCompatibilityEvidenceCacheKey -Identity $identity
        $changed=$identity.PSObject.Copy();$changed.targetSpecHash=('e'*64)

        $first | Should -BeExactly $second
        $first | Should -Match '^[a-f0-9]{64}$'
        (Get-MmtlCompatibilityEvidenceCacheKey -Identity $changed) | Should -Not -BeExactly $first
    }

    It 'stores and retrieves only immutable successful evidence for the exact cache identity' {
        $root=Join-Path $TestDrive 'runtime';$run=Join-Path $root 'validation/fabric-1.20.1-windows-x64/run-1';New-Item -ItemType Directory -Path $run -Force|Out-Null
        $evidence=New-TestCompatibilityEvidence
        $identity=New-TestCacheIdentity
        $evidence | Add-Member -NotePropertyName compatibilityIdentity -NotePropertyValue $identity
        $evidencePath=Join-Path $run 'result.json';[IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))

        $saved=Add-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $root -Identity $identity -EvidencePath $evidencePath
        $loaded=Get-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $root -Identity $identity

        $saved.status | Should -BeExactly 'STORED'
        $loaded.status | Should -BeExactly 'HIT'
        $loaded.evidence.targetId | Should -BeExactly $identity.targetId
        $loaded.evidence.result | Should -BeExactly 'PASSED'
    }

    It 'returns a cache miss when any target source identity changes' {
        $identity=New-TestCacheIdentity;$changed=$identity.PSObject.Copy();$changed.sourceHash=('f'*64)
        (Get-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $TestDrive -Identity $changed).reason | Should -BeExactly 'CACHE_NOT_FOUND'
    }

    It 'rejects failed, resolved-only, malformed, or target-mismatched evidence' {
        $root=Join-Path $TestDrive 'runtime';$run=Join-Path $root 'validation/fabric-1.20.1-windows-x64/run-2';New-Item -ItemType Directory -Path $run -Force|Out-Null
        $identity=New-TestCacheIdentity
        $stale=New-TestCompatibilityEvidence;$stale.source.artifactFresh=$false
        $untrusted=New-TestCompatibilityEvidence;$untrusted.sourceFixture.trust='UnverifiedHistorical'
        $missingIdentity=New-TestCompatibilityEvidence
        $wrongIdentity=New-TestCompatibilityEvidence;$wrongValue=New-TestCacheIdentity;$wrongValue.toolchainHash=('f'*64);$wrongIdentity | Add-Member -NotePropertyName compatibilityIdentity -NotePropertyValue $wrongValue
        foreach($evidence in @((New-TestCompatibilityEvidence -Result FAILED),(New-TestCompatibilityEvidence -Level RESOLVED),(New-TestCompatibilityEvidence -TargetId 'fabric-other-target'),$stale,$untrusted,$missingIdentity,$wrongIdentity)){
            $path=Join-Path $run ([guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($path,($evidence|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
            { Add-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $root -Identity $identity -EvidencePath $path } | Should -Throw
        }
    }

    It 'returns stale when a cached immutable evidence file is changed after indexing' {
        $root=Join-Path $TestDrive 'runtime';$run=Join-Path $root 'validation/fabric-1.20.1-windows-x64/run-3';New-Item -ItemType Directory -Path $run -Force|Out-Null
        $identity=New-TestCacheIdentity -Spec e
        $cachedEvidence=New-TestCompatibilityEvidence;$cachedEvidence | Add-Member -NotePropertyName compatibilityIdentity -NotePropertyValue $identity
        $evidencePath=Join-Path $run 'result.json';[IO.File]::WriteAllText($evidencePath,($cachedEvidence|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Add-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $root -Identity $identity -EvidencePath $evidencePath|Out-Null
        [IO.File]::AppendAllText($evidencePath,' ')

        $entry=Get-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $root -Identity $identity
        $entry.status | Should -BeExactly 'STALE'
        $entry.reason | Should -BeExactly 'CACHED_EVIDENCE_HASH_MISMATCH'
    }

    It 'rejects cache evidence paths outside Runtime Root and refuses cache overwrite' {
        $root=Join-Path $TestDrive 'runtime';$outside=Join-Path $TestDrive 'outside.json'
        $identity=New-TestCacheIdentity -Spec f
        $outsideEvidence=New-TestCompatibilityEvidence;$outsideEvidence | Add-Member -NotePropertyName compatibilityIdentity -NotePropertyValue $identity
        [IO.File]::WriteAllText($outside,($outsideEvidence|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        { Add-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $root -Identity $identity -EvidencePath $outside } | Should -Throw '*RUNTIME_ROOT*'

        $run=Join-Path $root 'validation/fabric-1.20.1-windows-x64/run-4';New-Item -ItemType Directory -Path $run -Force|Out-Null
        $path=Join-Path $run 'result.json';[IO.File]::WriteAllText($path,($outsideEvidence|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        Add-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $root -Identity $identity -EvidencePath $path|Out-Null
        { Add-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $root -Identity $identity -EvidencePath $path } | Should -Throw '*CACHE_ENTRY_EXISTS*'
    }
}
