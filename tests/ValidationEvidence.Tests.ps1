BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Audit/ValidationEvidence.psm1') -Force
    $script:validBuild=[pscustomobject]@{minecraftId='1.12.2';loaderId='Forge';loaderVersion='14.23.5.2860';toolchain=[pscustomobject]@{id='ForgeGradle';version='2.3'};platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false};buildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=8;requirementKind='Minimum';source='fixture';confidence='High'};observedBuildJava=[pscustomobject]@{major=8;exactVersion='1.8.0_503';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=[pscustomobject]@{major=8;source='build.gradle'};result='PASSED';artifactSha256=('a'*64);verifiedAt='2026-10-03T00:00:00Z';fixtureProvenance=[pscustomobject]@{sourceUrl='https://example.com/fixture';commit=('b'*40);license='MIT'}}
}

Describe 'Validation evidence audit' {
    It 'preserves all six distinct verification levels' {
        $levels=@('CATALOGUED','RESOLVED','BUILD_VERIFIED','SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')
        $matrices=@(foreach($level in $levels){$validation=[pscustomobject]@{level=$level;result='PASSED';lastVerified='2026-10-03T00:00:00Z';evidence=@();buildEvidence=if($level -in @('BUILD_VERIFIED','SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')){@($script:validBuild)}else{@()}};[pscustomobject]@{minecraft=[pscustomobject]@{id='1.12.2'};loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge'}};validation=$validation;provenance=@()}})
        $result=Get-MmtlValidationEvidenceAudit -Matrices $matrices -CatalogReleaseIds @('1.12.2')
        $result.records.level | Should -Be $levels
        $result.rejectedClaimCount | Should -Be 0
    }

    It 'downgrades a build claim with no evidence' {
        $matrix=[pscustomobject]@{minecraft=[pscustomobject]@{id='1.12.2'};loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge'}};validation=[pscustomobject]@{level='BUILD_VERIFIED';result='PASSED';buildEvidence=@();evidence=@()};provenance=@()}
        $result=Get-MmtlValidationEvidenceAudit -Matrices @($matrix) -CatalogReleaseIds @('1.12.2')
        $result.records[0].level | Should -Be 'RESOLVED'
        $result.records[0].claimAccepted | Should -BeFalse
        $result.records[0].reasonCode | Should -Be 'BUILD_VERIFIED_CLAIM_MISSING_EVIDENCE'
    }

    It 'accepts resolver evidence without optional build fields and reports malformed matrix structures' {
        $resolved=[pscustomobject]@{minecraft=[pscustomobject]@{id='1.12.2'};loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge'}};validation=[pscustomobject]@{level='RESOLVED';result='PASSED'};provenance=@()}
        $malformed=[pscustomobject]@{minecraft=[pscustomobject]@{id='1.12.2'};loaderStack=[pscustomobject]@{};validation=[pscustomobject]@{level='RESOLVED';result='PASSED'}}
        $result=Get-MmtlValidationEvidenceAudit -Matrices @($resolved,$malformed) -CatalogReleaseIds @('1.12.2')
        $result.records[0].level | Should -Be 'RESOLVED'
        $result.warnings[0].reasonCode | Should -Be 'COMPATIBILITY_MATRIX_INVALID_STRUCTURE'
    }

    It 'rejects missing compiler target or observed Java and non-catalog versions' {
        $bad=$script:validBuild.PSObject.Copy();$bad.compilerTarget=$null;$bad.artifactSha256=$null
        $matrix=[pscustomobject]@{minecraft=[pscustomobject]@{id='1.12.2'};loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge'}};validation=[pscustomobject]@{level='BUILD_VERIFIED';result='PASSED';buildEvidence=@($bad);evidence=@()};provenance=@()}
        $invalid=Get-MmtlValidationEvidenceAudit -Matrices @($matrix) -CatalogReleaseIds @('1.12.2')
        $invalid.records[0].level | Should -Be 'RESOLVED'
        $invalid.records[0].reasonCode | Should -Be 'BUILD_EVIDENCE_MISSING_COMPILER_TARGET'
        $outside=$matrix.PSObject.Copy();$outside.minecraft=[pscustomobject]@{id='1.12.2-pre1'}
        (Get-MmtlValidationEvidenceAudit -Matrices @($outside) -CatalogReleaseIds @('1.12.2')).warnings[0].reasonCode | Should -Be 'VALIDATION_VERSION_OUTSIDE_FORMAL_CATALOG'
    }

    It 'reads validation matrices only from designated Runtime Root directories' {
        $path=Join-Path $TestDrive 'evidence/compatibility-matrix';New-Item -ItemType Directory -Path $path -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $path 'matrix.json') -Value '{"fixture":true}'
        $result=Get-MmtlRuntimeValidationMatrices -RuntimeRoot $TestDrive
        @($result.matrices).Count | Should -Be 1
        $result.matrices[0].fixture | Should -BeTrue
    }
}
