BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:runStateModule=Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationMatrixRunState.psm1') -Force -PassThru
    Import-Module (Join-Path $script:repoRoot 'src/Validation/ValidationMatrixTargetRunner.psm1') -Force
    function New-TestMatrixRunState { param($Shard,[string]$RuntimeRoot) & $script:runStateModule { param($s,$r) New-MmtlValidationMatrixRunState -Shard $s -RuntimeRoot $r } $Shard $RuntimeRoot }
    function Get-TestMatrixRunState { param($Shard,[string]$RuntimeRoot) & $script:runStateModule { param($s,$r) Get-MmtlValidationMatrixRunState -Shard $s -RuntimeRoot $r } $Shard $RuntimeRoot }
    function New-TestMatrixEvidence {
        param($Identity)
        $now=[DateTimeOffset]::UtcNow.ToString('o')
        $e=[pscustomobject][ordered]@{
            schemaVersion=1;targetId='fabric-1.20.1';runId='matrix-pass-01';startedAt=$now;endedAt=$now;durationSeconds=0
            validationLevel='BUILD_VERIFIED';result='PASSED';failureCode='NONE'
            platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false}
            java=[pscustomobject]@{buildRequirement=$null;observedBuildJava=$null;compilerTarget=$null;runtimeRequirement=$null;observedRuntimeJava=$null}
            minecraftId='1.20.1';loaderId='Fabric';loaderVersion='0.15.0'
            toolchain=[pscustomobject]@{id='FabricLoom';version='1.7.4'};buildSystem=[pscustomobject]@{id='Gradle';version='8.8'}
            source=[pscustomobject]@{fingerprint=('sha256:'+('1'*64));unchangedDuringBuild=$true;artifactFresh=$true}
            sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/FabricMC/fabric-example-mod';commit=('a'*40);license='CC0-1.0';trust='TrustedOfficial'}
            logs=@([pscustomobject]@{path='stdout.log';sha256=('2'*64)})
            artifact=[pscustomobject]@{path='build/libs/marker.jar';filename='marker.jar';sizeBytes=1;sha256=('3'*64)}
            process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@()
        }
        $e|Add-Member -NotePropertyName compatibilityIdentity -NotePropertyValue $Identity
        $e
    }
    $script:shard=[pscustomobject]@{schemaVersion=1;universeHash=('a'*64);manifestHash=('b'*64);shardIndex=0;shardCount=1;targetCount=1;chunks=@([pscustomobject]@{loaderId='Fabric';familyId='fabric-family';targets=@([pscustomobject]@{targetId='fabric-1.20.1';targetSpecHash=('d'*64);sourceHash=('e'*64);toolchainHash=('c'*64)})})}
    $script:target=[pscustomobject]@{targetId='fabric-1.20.1';sourceFixture=[pscustomobject]@{type='UserProject';source='local';commit='working-tree';license='User-owned';trust='UserOwned';allowedTasks=@('build')}}
    $script:project=[pscustomobject]@{Root='C:/fixture';MinecraftVersion='1.20.1';Loader='Fabric';LoaderVersion='0.15.0'}
    $script:identity=[pscustomobject]@{targetId='fabric-1.20.1';universeHash=('a'*64);sourceHash=('e'*64);toolchainHash=('c'*64);targetSpecHash=('d'*64);agentHash=$null}
}

Describe 'Validation matrix target runner orchestration' {
    It 'records a bounded build failure in the durable shard state' {
        $mock=[pscustomobject]@{calls=0}
        Mock -CommandName Invoke-MmtlValidationBuild -ModuleName ValidationMatrixTargetRunner -MockWith ({
            $mock.calls++
            [pscustomobject]@{targetId='fabric-1.20.1';result='FAILED';validationLevel='RESOLVED';failureCode='BUILD_FAILED_TOOLCHAIN';evidencePath=$null;cached=$false}
        }.GetNewClosure())
        $root=Join-Path $TestDrive 'target-failure';$state=New-TestMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $result=Invoke-MmtlValidationMatrixTarget -State $state -TargetId 'fabric-1.20.1' -Project $script:project -Target $script:target -RuntimeRoot $root -CacheIdentity $script:identity
        $result.result.result | Should -BeExactly 'FAILED'
        $result.runState.targets[0].status | Should -BeExactly 'Failed'
        $result.runState.targets[0].failureCode | Should -BeExactly 'BUILD_FAILED_TOOLCHAIN'
        $result.runState.targets[0].attempts | Should -Be 1
        $mock.calls | Should -Be 1
    }

    It 'records only schema-valid matching evidence as Passed' {
        $root=Join-Path $TestDrive 'target-pass';$null=New-Item -ItemType Directory -Path (Join-Path $root 'validation') -Force
        $evidencePath=Join-Path $root 'validation/result.json'
        [IO.File]::WriteAllText($evidencePath,(New-TestMatrixEvidence -Identity $script:identity|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        Mock -CommandName Invoke-MmtlValidationBuild -ModuleName ValidationMatrixTargetRunner -MockWith ({
            [pscustomobject]@{targetId='fabric-1.20.1';result='PASSED';validationLevel='BUILD_VERIFIED';failureCode='NONE';evidencePath=$evidencePath;cached=$false}
        }.GetNewClosure())
        $state=New-TestMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $result=Invoke-MmtlValidationMatrixTarget -State $state -TargetId 'fabric-1.20.1' -Project $script:project -Target $script:target -RuntimeRoot $root -CacheIdentity $script:identity
        $result.runState.targets[0].status | Should -BeExactly 'Passed'
        $result.runState.targets[0].evidenceSha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'rejects an identity that differs from the frozen shard before build starts' {
        $mock=[pscustomobject]@{calls=0}
        Mock -CommandName Invoke-MmtlValidationBuild -ModuleName ValidationMatrixTargetRunner -MockWith ({$mock.calls++;throw 'should not run'}.GetNewClosure())
        $root=Join-Path $TestDrive 'target-bad-identity';$state=New-TestMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $bad=$script:identity.PSObject.Copy();$bad.sourceHash=('f'*64)
        { Invoke-MmtlValidationMatrixTarget -State $state -TargetId 'fabric-1.20.1' -Project $script:project -Target $script:target -RuntimeRoot $root -CacheIdentity $bad } | Should -Throw '*MATRIX_CACHE_IDENTITY_MISMATCH*'
        $mock.calls | Should -Be 0
        (Get-TestMatrixRunState -Shard $script:shard -RuntimeRoot $root).targets[0].status | Should -BeExactly 'Pending'
    }

    It 'rejects a cache identity with a different frozen toolchain hash before build starts' {
        $mock=[pscustomobject]@{calls=0}
        Mock -CommandName Invoke-MmtlValidationBuild -ModuleName ValidationMatrixTargetRunner -MockWith ({$mock.calls++;throw 'should not run'}.GetNewClosure())
        $root=Join-Path $TestDrive 'target-bad-toolchain';$state=New-TestMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $bad=$script:identity.PSObject.Copy();$bad.toolchainHash=('9'*64)
        { Invoke-MmtlValidationMatrixTarget -State $state -TargetId 'fabric-1.20.1' -Project $script:project -Target $script:target -RuntimeRoot $root -CacheIdentity $bad } | Should -Throw '*MATRIX_CACHE_IDENTITY_MISMATCH*'
        $mock.calls | Should -Be 0
        (Get-TestMatrixRunState -Shard $script:shard -RuntimeRoot $root).targets[0].status | Should -BeExactly 'Pending'
    }

    It 'records a runner exception before propagating it' {
        Mock -CommandName Invoke-MmtlValidationBuild -ModuleName ValidationMatrixTargetRunner -MockWith { throw 'synthetic runner exception' }
        $root=Join-Path $TestDrive 'target-exception';$state=New-TestMatrixRunState -Shard $script:shard -RuntimeRoot $root
        { Invoke-MmtlValidationMatrixTarget -State $state -TargetId 'fabric-1.20.1' -Project $script:project -Target $script:target -RuntimeRoot $root -CacheIdentity $script:identity } | Should -Throw '*synthetic runner exception*'
        $saved=New-TestMatrixRunState -Shard $script:shard -RuntimeRoot $root
        $saved.targets[0].status | Should -BeExactly 'Failed'
        $saved.targets[0].failureCode | Should -BeExactly 'BUILD_FAILED_MMTL'
    }
}
