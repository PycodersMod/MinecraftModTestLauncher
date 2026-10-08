BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
    $script:families = Get-Content (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
    $script:targets = @($script:universe.targets | Where-Object { $_.loaderId -CEQ 'LegacyFabric' -and $_.availability -CEQ 'Available' })
    Import-Module (Join-Path $script:repoRoot 'common/src/ProjectDetector.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'common/src/Platform/Platform.psm1') -Force
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        Import-Module (Join-Path $script:repoRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
        Register-MmtlWindowsPlatform -RepositoryRoot $script:repoRoot
    } elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) {
        Import-Module (Join-Path $script:repoRoot 'linux/src/LinuxPlatformProvider.psm1') -Force
        Register-MmtlLinuxPlatform -RepositoryRoot $script:repoRoot
    } else {
        Import-Module (Join-Path $script:repoRoot 'macos/src/MacOSPlatformProvider.psm1') -Force
        Register-MmtlMacOSPlatform -RepositoryRoot $script:repoRoot
    }
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/LegacyFabric.psm1') -Force
}

Describe 'LegacyFabric exact-target Build and Launch plans' {
    It 'detects and plans every frozen LegacyFabric target without making plans executable' {
        $projectRoot = Join-Path $TestDrive 'legacyfabric-all-targets'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        "plugins { id 'legacy-looming' version '1.9-SNAPSHOT' }" | Set-Content (Join-Path $projectRoot 'build.gradle')
        $wrapperName = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { 'gradlew.bat' } else { 'gradlew' }
        Set-Content -LiteralPath (Join-Path $projectRoot $wrapperName) -Value ''
        $failures = [Collections.Generic.List[string]]::new()

        foreach ($target in $script:targets) {
            @("minecraft_version=$($target.minecraftId)", "loader_version=$($target.loaderVersionCandidates[0])", 'mod_id=fixture') -join [Environment]::NewLine | Set-Content (Join-Path $projectRoot 'gradle.properties')
            $project = Get-MmtlProject -Path $projectRoot
            try { $plans = New-MmtlLegacyFabricAdapterPlans -Project $project -Universe $script:universe }
            catch { $failures.Add("$($target.targetId):$($_.Exception.Message)"); continue }
            if ($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'LegacyFabric' -or $plans.targetId -cne [string]$target.targetId -or $plans.buildPlan.task -cne 'build' -or $plans.launchPlan.task -cne 'runClient' -or $plans.buildPlan.isExecutablePlan -or $plans.launchPlan.isExecutablePlan -or $plans.buildPlan.executionGate -cne 'TRUSTED_VALIDATION_RUNNER_REQUIRED' -or $plans.launchPlan.executionGate -cne 'TRUSTED_VALIDATION_RUNNER_REQUIRED') {
                $failures.Add("$($target.targetId):PLAN_CONTRACT_MISMATCH")
            }
        }

        $failures | Should -BeNullOrEmpty
        $script:targets.Count | Should -Be 76
    }

    It 'rejects a loader version that is not an exact frozen candidate' {
        $target = $script:targets | Select-Object -First 1
        $projectRoot = Join-Path $TestDrive 'legacyfabric-invalid-candidate'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        $wrapperPath = Join-Path $projectRoot 'gradlew.bat'
        Set-Content -LiteralPath $wrapperPath -Value ''
        $project = [pscustomobject]@{ Loader='LegacyFabric'; DetectionStatus='Resolved'; MinecraftVersion=$target.minecraftId; LoaderVersion='not-a-candidate'; Toolchain=[pscustomobject]@{id='LegacyLooming';ecosystem='LegacyFabric'}; BuildSystem=[pscustomobject]@{id='GradleWrapper'}; WrapperPath=$wrapperPath; Root=$projectRoot; BuildJavaRequirement=$null }

        { New-MmtlLegacyFabricAdapterPlans -Project $project -Universe $script:universe } | Should -Throw '*LEGACYFABRIC_TARGET_UNRESOLVED:LOADER_VERSION_NOT_IN_FROZEN_CANDIDATES*'
    }

    It 'rejects a different Loader, toolchain, or unsafe wrapper' {
        $projectRoot = Join-Path $TestDrive 'legacyfabric-invalid-project'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        $wrapperPath = Join-Path $projectRoot 'gradlew.bat'
        Set-Content -LiteralPath $wrapperPath -Value ''
        $project = [pscustomobject]@{ Loader='Fabric'; DetectionStatus='Resolved'; MinecraftVersion='1.13.2'; LoaderVersion='1.0.0'; Toolchain=[pscustomobject]@{id='LegacyLooming';ecosystem='LegacyFabric'}; BuildSystem=[pscustomobject]@{id='GradleWrapper'}; WrapperPath=$wrapperPath; Root=$projectRoot; BuildJavaRequirement=$null }
        { New-MmtlLegacyFabricAdapterPlans -Project $project -Universe $script:universe } | Should -Throw '*LEGACYFABRIC_PROJECT_REQUIRED*'
        $project.Loader = 'LegacyFabric'
        $project.Toolchain = [pscustomobject]@{id='FabricLoom';ecosystem='Fabric'}
        { New-MmtlLegacyFabricAdapterPlans -Project $project -Universe $script:universe } | Should -Throw '*LEGACYFABRIC_LOOMING_REQUIRED*'
        $project.Toolchain = [pscustomobject]@{id='LegacyLooming';ecosystem='LegacyFabric'}
        $project.WrapperPath = Join-Path $projectRoot '..\outside\gradlew.bat'
        { New-MmtlLegacyFabricAdapterPlans -Project $project -Universe $script:universe } | Should -Throw '*LEGACYFABRIC_GRADLE_WRAPPER_UNSAFE*'
    }

    It 'declares BuildPlan and LaunchPlan for the 76-target family while execution evidence remains pending' {
        $family = $script:families.families | Where-Object familyId -CEQ 'legacyfabric-looming-build-launch-plan-v1' | Select-Object -First 1
        $family.capabilities.BuildPlan.status | Should -BeExactly 'Supported'
        $family.capabilities.LaunchPlan.status | Should -BeExactly 'Supported'
        $ledger = Get-Content (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -Raw | ConvertFrom-Json
        $rows = @($ledger.targets | Where-Object loaderId -CEQ 'LegacyFabric')
        @($rows | Where-Object { $_.dimensions.BuildPlan.status -cne 'Supported' }).Count | Should -Be 0
        @($rows | Where-Object { $_.dimensions.LaunchPlan.status -cne 'Supported' }).Count | Should -Be 0
        @($rows | Where-Object { $_.dimensions.BuildVerified.status -cne 'PendingImplementation' }).Count | Should -Be 0
        @($rows | Where-Object { $_.dimensions.LaunchCheck.status -cne 'PendingImplementation' }).Count | Should -Be 0
    }
}
