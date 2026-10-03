BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Audit/ValidationEvidence.psm1') -Force
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Validation/ValidationEvidence.psm1') -Force
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Validation/Contracts.psm1') -Force
    $script:validBuild=[pscustomobject]@{minecraftId='1.12.2';loaderId='Forge';loaderVersion='14.23.5.2860';toolchain=[pscustomobject]@{id='ForgeGradle';version='2.3'};platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false};buildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=8;requirementKind='Minimum';source='fixture';confidence='High'};observedBuildJava=[pscustomobject]@{major=8;exactVersion='1.8.0_503';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=[pscustomobject]@{major=8;source='build.gradle'};result='PASSED';artifactSha256=('a'*64);verifiedAt='2026-10-03T00:00:00Z';fixtureProvenance=[pscustomobject]@{sourceUrl='https://example.com/fixture';commit=('b'*40);license='MIT'}}
}

Describe 'Validation evidence audit' {
    It 'preserves all six distinct verification levels' {
        $levels=@('CATALOGUED','RESOLVED','BUILD_VERIFIED','SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')
        $matrices=@(foreach($level in $levels){$validation=[pscustomobject]@{level=$level;result='PASSED';lastVerified='2026-10-03T00:00:00Z';evidence=@();buildEvidence=if($level -in @('BUILD_VERIFIED','SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')){@($script:validBuild)}else{@()};serverEvidence=[pscustomobject]@{readyMarker='Done (2.0s)!';readyMarkerMatched=$true;processIdentityMatched=$true;portListening=$true;stopMethod='ConsoleStop';processExited=$true;portReleased=$true};clientEvidence=[pscustomobject]@{initializationMarker='Minecraft main thread';initializationMarkerMatched=$true;processIdentityMatched=$true;liveAtMarker=$true};integrationEvidence=[pscustomobject]@{scenario='fixture interaction';completed=$true;assertionsPassed=1}};[pscustomobject]@{minecraft=[pscustomobject]@{id='1.12.2'};loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge'}};validation=$validation;provenance=@()}})
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

    It 'does not promote build evidence to server verification without ready, port, identity, and stop evidence' {
        $matrix=[pscustomobject]@{minecraft=[pscustomobject]@{id='1.20.1'};loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge'}};validation=[pscustomobject]@{level='SERVER_VERIFIED';result='PASSED';lastVerified='2026-10-03T00:00:00Z';evidence=@();buildEvidence=@($script:validBuild)};provenance=@()}
        $result=Get-MmtlValidationEvidenceAudit -Matrices @($matrix) -CatalogReleaseIds @('1.20.1')
        $result.records[0].level | Should -Be 'BUILD_VERIFIED'
        $result.records[0].claimAccepted | Should -BeFalse
        $result.records[0].reasonCode | Should -Be 'SERVER_VERIFIED_CLAIM_MISSING_EVIDENCE'
    }

    It 'accepts server verification only with a ready marker, matching process, listening port, and confirmed safe stop' {
        $server=[pscustomobject]@{readyMarker='Done (12.3s)! For help, type "help"';readyMarkerMatched=$true;processIdentityMatched=$true;portListening=$true;stopMethod='ConsoleStop';processExited=$true;portReleased=$true}
        $matrix=[pscustomobject]@{minecraft=[pscustomobject]@{id='1.20.1'};loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge'}};validation=[pscustomobject]@{level='SERVER_VERIFIED';result='PASSED';lastVerified='2026-10-03T00:00:00Z';evidence=@();buildEvidence=@($script:validBuild);serverEvidence=$server};provenance=@()}
        $result=Get-MmtlValidationEvidenceAudit -Matrices @($matrix) -CatalogReleaseIds @('1.20.1')
        $result.records[0].level | Should -Be 'SERVER_VERIFIED'
        $result.records[0].claimAccepted | Should -BeTrue
    }

    It 'does not promote build evidence to client verification without a real initialization marker' {
        $matrix=[pscustomobject]@{minecraft=[pscustomobject]@{id='1.20.1'};loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Fabric'}};validation=[pscustomobject]@{level='CLIENT_LAUNCH_VERIFIED';result='PASSED';lastVerified='2026-10-03T00:00:00Z';evidence=@();buildEvidence=@($script:validBuild)};provenance=@()}
        $result=Get-MmtlValidationEvidenceAudit -Matrices @($matrix) -CatalogReleaseIds @('1.20.1')
        $result.records[0].level | Should -Be 'BUILD_VERIFIED'
        $result.records[0].claimAccepted | Should -BeFalse
        $result.records[0].reasonCode | Should -Be 'CLIENT_LAUNCH_VERIFIED_CLAIM_MISSING_EVIDENCE'
    }

    It 'accepts advanced matrix evidence only when runtime marker and lifecycle checks are complete' {
        $server=[pscustomobject]@{marker=[pscustomobject]@{kind='serverReady';text='Done (2.0s)! For help, type "help"';matched=$true};process=[pscustomobject]@{identityMatched=$true;liveAtMarker=$true;exited=$true;exitCode=0;portListening=$true;portReleased=$true};stopMethod='ConsoleStop'}
        (Test-MmtlAdvancedValidationEvidence -Level SERVER_VERIFIED -Validation $server).valid | Should -BeTrue
        $server.process.portReleased=$false
        (Test-MmtlAdvancedValidationEvidence -Level SERVER_VERIFIED -Validation $server).valid | Should -BeFalse
        $client=[pscustomobject]@{marker=[pscustomobject]@{kind='clientInitialized';text='Sound engine started';matched=$true;elapsedSeconds=20};process=[pscustomobject]@{identityMatched=$true;liveAtMarker=$true}}
        (Test-MmtlAdvancedValidationEvidence -Level CLIENT_LAUNCH_VERIFIED -Validation $client).valid | Should -BeTrue
    }

    It 'reads validation matrices only from designated Runtime Root directories' {
        $path=Join-Path $TestDrive 'evidence/compatibility-matrix';New-Item -ItemType Directory -Path $path -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $path 'matrix.json') -Value '{"fixture":true}'
        $result=Get-MmtlRuntimeValidationMatrices -RuntimeRoot $TestDrive
        @($result.matrices).Count | Should -Be 1
        $result.matrices[0].fixture | Should -BeTrue
    }
}

Describe 'Immutable validation run evidence' {
    It 'redacts credentials and tokens before a log is persisted' {
        $inputText="ghp_abcdefghijklmnopqrstuvwxyz0123456789 Bearer eyJhbGciOiJIUzI1NiJ9.secret.payload password=hunter2 https://alice:secret@github.com/org/repo"
        $redacted=ConvertTo-MmtlRedactedValidationText -Text $inputText
        $redacted | Should -Not -Match 'ghp_abcdefghijklmnopqrstuvwxyz'
        $redacted | Should -Not -Match 'hunter2'
        $redacted | Should -Not -Match 'alice:secret'
        $redacted | Should -Match '\[REDACTED\]'
    }

    It 'writes each run once under Runtime Root and refuses to overwrite completed evidence' {
        $evidence=[pscustomobject]@{
            schemaVersion=1;targetId='1.20.1-forge-windows-x64';runId='run-immutable-001';startedAt='2026-10-03T00:00:00Z';endedAt='2026-10-03T00:01:00Z';durationSeconds=60
            validationLevel='BUILD_VERIFIED';result='PASSED';failureCode='NONE';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false}
            java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};observedBuildJava=[pscustomobject]@{major=17;exactVersion='17.0.19';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=8;runtimeRequirement=$null;observedRuntimeJava=$null}
            toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0.24'};buildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'}
            sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/MinecraftForge/MinecraftForge';commit=('c'*40);license='MIT';trust='TrustedOfficial'}
            logs=@([pscustomobject]@{path='logs/build.log';sha256=('d'*64)});artifact=[pscustomobject]@{path='artifacts/mod.jar';filename='mod.jar';sizeBytes=12;sha256=('e'*64)}
            process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@()
        }
        $path=Write-MmtlValidationRunEvidence -RuntimeRoot $TestDrive -Evidence $evidence
        Test-Path -LiteralPath $path | Should -BeTrue
        $before=Get-FileHash -LiteralPath $path -Algorithm SHA256
        $evidence.notes=@('new state must be a new run')
        {Write-MmtlValidationRunEvidence -RuntimeRoot $TestDrive -Evidence $evidence} | Should -Throw '*immutable*'
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before.Hash
    }

    It 'rejects path traversal in target and run identifiers' {
        $evidence=[pscustomobject]@{targetId='..\outside';runId='run-1'}
        {Write-MmtlValidationRunEvidence -RuntimeRoot $TestDrive -Evidence $evidence} | Should -Throw '*identifier*'
    }
}
