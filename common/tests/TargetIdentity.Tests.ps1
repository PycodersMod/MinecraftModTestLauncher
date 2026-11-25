BeforeAll {
    $script:commonRoot=Split-Path -Parent $PSScriptRoot
    $script:repoRoot=Split-Path -Parent $script:commonRoot
    Import-Module (Join-Path $script:commonRoot 'src/Validation/ValidationMatrixJobs.psm1') -Force
    Import-Module (Join-Path $script:commonRoot 'src/Validation/TargetIdentity.psm1') -Force
}

Describe 'Exact compatibility target identity' {
    It 'extracts exact version strings from scalar and structured catalog candidates' {
        $candidates = @(
            '0.7.10'
            [pscustomobject]@{ providerId = 'ModLoader'; loaderVersion = 'b1.7.3'; version = 'b1.7.3'; artifactFilename = 'modloader.zip' }
            [pscustomobject]@{ providerId = 'Rift'; loaderVersion = '1.0.4'; version = '1.0.4'; repository = 'https://github.com/DimensionalDevelopment/Rift' }
            [pscustomobject]@{ providerId = 'legacy'; version = 'old-beta-1.7.3' }
            [pscustomobject]@{ providerId = 'unversioned' }
        )

        $versions = @(Get-MmtlLoaderVersionCandidateValues -Candidates $candidates)

        $versions | Should -Be @('0.7.10','b1.7.3','1.0.4','old-beta-1.7.3')
    }

    It 'accepts every frozen Universe target and creates unique safe storage keys' {
        $universe=Get-Content (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
        $ids=[string[]]@($universe.targets | ForEach-Object targetId)
        $invalid=@($ids | Where-Object { -not(Test-MmtlExactTargetId -TargetId $_) })
        $keys=[string[]]@($ids | ForEach-Object { Get-MmtlValidationTargetStorageKey -TargetId $_ })
        $invalid.Count | Should -Be 0
        @($keys | Select-Object -Unique).Count | Should -Be $ids.Count
        @($keys | Where-Object { $_ -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' }).Count | Should -Be 0
    }

    It 'rejects path separators and preserves exact identity in hash-derived keys' {
        { Get-MmtlValidationTargetStorageKey -TargetId '../Fabric@1.14' } | Should -Throw '*VALIDATION_TARGET_ID_INVALID*'
        $first=Get-MmtlValidationTargetStorageKey -TargetId 'Fabric@1.14 Pre-Release 1'
        $second=Get-MmtlValidationTargetStorageKey -TargetId 'Fabric@1.14_Pre-Release 1'
        $first | Should -Not -BeExactly $second
    }

    It 'accepts an exact spaced Universe target in a shard job manifest' {
        $identity=[pscustomobject]@{targetId='Fabric@1.14 Pre-Release 1';universeHash=('a'*64);sourceHash=('b'*64);toolchainHash=('c'*64);targetSpecHash=('d'*64);agentHash=$null}
        $job=[pscustomobject]@{targetId=$identity.targetId;projectPath='fixture';project=[pscustomobject]@{minecraftVersion='1.14 Pre-Release 1';loader='Fabric';loaderVersion='0.15.0';wrapper='gradlew'};target=[pscustomobject]@{targetId=$identity.targetId;minecraftId='1.14 Pre-Release 1';loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric';version='0.15.0'}};loaderVersion='0.15.0';sourceFixture=[pscustomobject]@{type='OfficialFixture'}};cacheIdentity=$identity;scenario=[pscustomobject]@{clientCount=2;identityKind='Offline';transportPolicy='NativeIntegratedLANOrExplicitHistoricalDedicatedEquivalent';requiredDimensions=@('BuildExactPass','RuntimeBindingPass','ClientLaunchPass','MultiWindowPass','SingleAssertionPass','MultiplayerJoinAndAssertionPass','TargetReportPass','SafeStopPass')}}
        $document=[pscustomobject]@{schemaVersion=1;manifestHash=('e'*64);jobs=@($job);jobsHash=$null}
        $document.jobsHash=Get-MmtlValidationMatrixJobsHash -Manifest $document
        $json=ConvertTo-Json -InputObject $document -Depth 12
        Test-Json -Json $json -SchemaFile (Join-Path $script:commonRoot 'schemas/validation-matrix-job-manifest.schema.json') | Should -BeTrue
    }
}
