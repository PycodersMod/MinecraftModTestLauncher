BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:convertScript = Join-Path $script:repoRoot 'tools/Convert-LaunchCheckEvidence.ps1'
    Import-Module (Join-Path $PSScriptRoot '../src/Execution/ExecutionPlanner.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/Execution/ExecutionPlan.psm1') -Force
    $script:universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json

    function New-LaunchCheckTestJavaHome {
        param([string]$Root,[int]$Major)
        [IO.Directory]::CreateDirectory((Join-Path $Root 'bin')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root 'bin/java.exe'),'', [Text.UTF8Encoding]::new($false))
        @("JAVA_VERSION=`"$Major.0.1`"",'IMPLEMENTOR="Test Vendor"','OS_ARCH="amd64"') | Set-Content -LiteralPath (Join-Path $Root 'release')
    }

    function New-ReadyLaunchCheckPlan {
        param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)][string]$Root,[switch]$Blocked)
        $projectRoot=Join-Path $Root 'project'
        [IO.Directory]::CreateDirectory($projectRoot) | Out-Null
        $wrapper=Join-Path $projectRoot 'gradlew.bat'
        [IO.File]::WriteAllText($wrapper,'@echo off', [Text.UTF8Encoding]::new($false))
        $jdk=Join-Path $Root 'jdk17'
        New-LaunchCheckTestJavaHome -Root $jdk -Major 17
        $candidate=@($Target.loaderVersionCandidates | ForEach-Object { if($_ -is [string]){$_}elseif($_.version){[string]$_.version}else{[string]$_.loaderVersion} })[0]
        $project=[pscustomobject]@{
            RepositoryRoot=$Root;Root=$projectRoot;MinecraftVersion=[string]$Target.minecraftId;Loader=[string]$Target.loaderId;LoaderVersion=$candidate;ModId='mmtl_launchcheck_fixture'
            LoaderStack=[pscustomobject]@{primaryLoader=[pscustomobject]@{id=[string]$Target.loaderId;version=$candidate};overlayLoaders=@()}
            Toolchain=[pscustomobject]@{id='FabricLoom';version='test'};BuildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'}
            BuildTask='build';Wrapper=$true;WrapperPath=$wrapper
            BuildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=17;minimumMajor=17;preferredMajor=$null;exactMajor=$null;requirementKind='Minimum';source='Fixture';confidence='High';reason='test'}
            RuntimeJavaRequirement=[pscustomobject]@{purpose='RuntimeJava';major=17;requirementKind='Exact';source='Fixture';confidence='High';component='test-runtime'}
        }
        $profile=[pscustomobject]@{project=$projectRoot;linkedProjects=@();mode='Single';players=1;hostUsername='Fixture';clientPrefix='Fixture_';autoBuild=$true;cleanBuild=$false;acceptEula=$false;port='Auto';memoryMb=2048;hostMemoryMb=2048;clientMemoryMb=2048;serverMemoryMb=2048;jvmArgs=@();gameArgs=@();extraMods=@();resolution='1280x720';guiScale='Auto';windowLayout='None'}
        $config=[pscustomobject]@{defaultProfile='fixture';javaHomes=[pscustomobject]@{'17'=$jdk};javaHomesByPlatform=[pscustomobject]@{Windows=[pscustomobject]@{};Linux=[pscustomobject]@{};MacOS=[pscustomobject]@{}}}
        $platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false;capabilities=[pscustomobject]@{Build='Native';Launch='Native'}}
        $adapterEvidence=if($Blocked){$null}else{[pscustomobject]@{runtimeJavaBindingMode='Direct';runtimeJavaBindingEvidence='Fixture runtime java launcher binding'}}
        New-MmtlExecutionPlan -Project $project -Profile $profile -Config $config -Platform $platform -RuntimeRoot (Join-Path $Root 'runtime') -ProfileName 'fixture' -CatalogEntry ([pscustomobject]@{id=[string]$Target.minecraftId;metadataStatus='VERIFIED_NO_JAVA_VERSION'}) -AdapterEvidence $adapterEvidence -PhysicalMemoryMb 16384 -BuildRequired
    }
}

Describe 'LaunchCheck evidence conversion' {
    It 'converts a valid exact-target execution plan to sanitized, schema-valid evidence' {
        $target=$script:universe.targets | Where-Object targetId -CEQ 'Fabric@1.20.1' | Select-Object -First 1
        $plan=New-ReadyLaunchCheckPlan -Target $target -Root (Join-Path $TestDrive 'ready')
        $plan.capabilityGates.launchReady | Should -BeTrue
        $planPath=Join-Path $TestDrive 'ready-plan.json'
        $outputPath=Join-Path $TestDrive 'ready-evidence.json'
        [IO.File]::WriteAllText($planPath,(ConvertTo-Json -InputObject $plan -Depth 100),[Text.UTF8Encoding]::new($false))

        & $script:convertScript -TargetId 'Fabric@1.20.1' -ExecutionPlanPath $planPath -UniversePath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -OutputPath $outputPath -ObservedAt '2026-10-15T00:00:00Z' | Out-Null
        $raw=[IO.File]::ReadAllText($outputPath)
        $evidence=$raw | ConvertFrom-Json

        (Test-Json -Json $raw -SchemaFile (Join-Path $script:repoRoot 'common/schemas/launch-check-evidence.schema.json')) | Should -BeTrue
        $evidence.targetId | Should -BeExactly 'Fabric@1.20.1'
        $evidence.executionPlanDigest | Should -BeExactly $plan.semanticDigest
        $raw | Should -Not -Match '[A-Za-z]:\\|/home/|/Users/|Fixture' # public-hygiene: allow-synthetic-path
    }

    It 'rejects a plan whose Loader/Minecraft identity does not match the requested exact target' {
        $target=$script:universe.targets | Where-Object targetId -CEQ 'Fabric@1.20.1' | Select-Object -First 1
        $plan=New-ReadyLaunchCheckPlan -Target $target -Root (Join-Path $TestDrive 'mismatch')
        $planPath=Join-Path $TestDrive 'mismatch-plan.json'
        $outputPath=Join-Path $TestDrive 'mismatch-evidence.json'
        [IO.File]::WriteAllText($planPath,(ConvertTo-Json -InputObject $plan -Depth 100),[Text.UTF8Encoding]::new($false))

        { & $script:convertScript -TargetId 'Fabric@1.21.8' -ExecutionPlanPath $planPath -UniversePath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -OutputPath $outputPath -ObservedAt '2026-10-15T00:00:00Z' } | Should -Throw '*LAUNCH_CHECK_TARGET_IDENTITY_MISMATCH*'
        (Test-Path -LiteralPath $outputPath) | Should -BeFalse
    }

    It 'rejects a plan with unresolved launch gates and does not write evidence' {
        $target=$script:universe.targets | Where-Object targetId -CEQ 'Fabric@1.20.1' | Select-Object -First 1
        $plan=New-ReadyLaunchCheckPlan -Target $target -Root (Join-Path $TestDrive 'blocked') -Blocked
        $plan.capabilityGates.launchReady | Should -BeFalse
        $planPath=Join-Path $TestDrive 'blocked-plan.json'
        $outputPath=Join-Path $TestDrive 'blocked-evidence.json'
        [IO.File]::WriteAllText($planPath,(ConvertTo-Json -InputObject $plan -Depth 100),[Text.UTF8Encoding]::new($false))

        { & $script:convertScript -TargetId 'Fabric@1.20.1' -ExecutionPlanPath $planPath -UniversePath (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -OutputPath $outputPath -ObservedAt '2026-10-15T00:00:00Z' } | Should -Throw '*LAUNCH_CHECK_NOT_READY*'
        (Test-Path -LiteralPath $outputPath) | Should -BeFalse
    }
}
