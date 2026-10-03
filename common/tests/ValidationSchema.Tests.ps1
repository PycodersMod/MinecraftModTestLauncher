BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:matrixSchema=Join-Path $script:repoRoot 'schemas/validation-matrix.schema.json'
    $script:evidenceSchema=Join-Path $script:repoRoot 'schemas/validation-evidence.schema.json'
}

Describe 'Deep validation JSON schemas' {
    It 'accepts an auditable target with observed and required Java kept distinct' {
        $target=[pscustomobject]@{
            targetId='1.20.1-forge-windows-x64'
            tier='Tier2'
            minecraftId='1.20.1'
            loaderStack=[pscustomobject]@{primary=[pscustomobject]@{id='Forge';version='47.4.20'};overlays=@()}
            loaderVersion='47.4.20'
            toolchain='ForgeGradle'
            toolchainVersion='6.0.24'
            buildSystem='GradleWrapper'
            platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false}
            java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};observedBuildJava=[pscustomobject]@{major=21;exactVersion='21.0.9';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=8;runtimeRequirement=[pscustomobject]@{kind='Preferred';major=21};observedRuntimeJava=$null}
            sourceFixture=[pscustomobject]@{type='UserProject';source='PycodersMod/SharecodeChest';commit=('a'*40);license='MIT';trust='UserOwned'}
            validation=[pscustomobject]@{effectiveLevel='BUILD_VERIFIED';resolved=$true;build=$true;server=$false;client=$false;integration=$false}
            evidence=[pscustomobject]@{runIds=@('run-001');timestamps=@('2026-10-03T00:00:00Z');logs=@('run-001/build.log');hashes=@(('b'*64));artifact='sharecodechest-1.0.0.jar';process=$null;result='PASSED'}
            notes=@()
        }
        $matrix=[pscustomobject]@{schemaVersion=1;generatedAt='2026-10-03T00:00:00Z';scope='P0';targets=@($target)}
        (Test-Json -Json ($matrix|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:matrixSchema) | Should -BeTrue
    }

    It 'requires explicit failure classification in non-passing immutable run evidence' {
        $evidence=[pscustomobject]@{
            schemaVersion=1;targetId='1.20.1-forge-windows-x64';runId='run-002';startedAt='2026-10-03T00:00:00Z';endedAt='2026-10-03T00:01:00Z';durationSeconds=60
            validationLevel='BUILD_VERIFIED';result='FAILED';failureCode='BUILD_FAILED_NETWORK';platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false}
            java=[pscustomobject]@{buildRequirement=[pscustomobject]@{kind='Minimum';major=17};observedBuildJava=[pscustomobject]@{major=17;exactVersion='17.0.19';vendor='Oracle';os='Windows';arch='x64'};compilerTarget=8;runtimeRequirement=$null;observedRuntimeJava=$null}
            toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0.24'};buildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'}
            sourceFixture=[pscustomobject]@{type='OfficialFixture';source='https://github.com/example/fixture';commit=('c'*40);license='MIT';trust='TrustedOfficial'}
            logs=@([pscustomobject]@{path='logs/build.log';sha256=('d'*64)});artifact=$null;process=$null;marker=$null;stopMethod=$null;scenario=$null;notes=@()
        }
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeTrue
        $evidence.failureCode=$null
        (Test-Json -Json ($evidence|ConvertTo-Json -Depth 20 -Compress) -SchemaFile $script:evidenceSchema -ErrorAction SilentlyContinue) | Should -BeFalse
    }
}
