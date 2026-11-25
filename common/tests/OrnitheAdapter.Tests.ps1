BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
    $script:families = Get-Content (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
    $script:targets = @($script:universe.targets | Where-Object { $_.loaderId -CEQ 'OrnitheLoader' -and $_.availability -CEQ 'Available' })
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
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/Ornithe.psm1') -Force
}

Describe 'Ornithe exact-target Build and Launch plans' {
    It 'detects and plans every frozen Ornithe target without making plans executable' {
        $projectRoot = Join-Path $TestDrive 'ornithe-all-targets'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        @("plugins { id 'ploceus' version '1.18-SNAPSHOT' }", "dependencies { modImplementation 'net.ornithemc:ornithe-loader:0.1.2' }") -join [Environment]::NewLine | Set-Content (Join-Path $projectRoot 'build.gradle')
        $wrapperName = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { 'gradlew.bat' } else { 'gradlew' }
        Set-Content -LiteralPath (Join-Path $projectRoot $wrapperName) -Value ''
        $failures = [Collections.Generic.List[string]]::new()

        foreach ($target in $script:targets) {
            @("minecraft_version=$($target.minecraftId)", "loader_version=$($target.loaderVersionCandidates[0])", 'mod_id=fixture') -join [Environment]::NewLine | Set-Content (Join-Path $projectRoot 'gradle.properties')
            $project = Get-MmtlProject -Path $projectRoot
            try { $plans = New-MmtlOrnitheAdapterPlans -Project $project -Universe $script:universe }
            catch { $failures.Add("$($target.targetId):$($_.Exception.Message)"); continue }
            if ($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'OrnitheLoader' -or $plans.targetId -cne [string]$target.targetId -or $plans.buildPlan.task -cne 'build' -or $plans.launchPlan.task -cne 'runClient' -or $plans.buildPlan.isExecutablePlan -or $plans.launchPlan.isExecutablePlan -or $plans.buildPlan.executionGate -cne 'TRUSTED_VALIDATION_RUNNER_REQUIRED' -or $plans.launchPlan.executionGate -cne 'TRUSTED_VALIDATION_RUNNER_REQUIRED') {
                $failures.Add("$($target.targetId):PLAN_CONTRACT_MISMATCH")
            }
        }

        $failures | Should -BeNullOrEmpty
        $script:targets.Count | Should -Be 406
    }

    It 'rejects a loader version that is not an exact frozen candidate' {
        $target = $script:targets | Where-Object minecraftId -CEQ '1.13.2' | Select-Object -First 1
        $projectRoot = Join-Path $TestDrive 'ornithe-invalid-candidate'
        New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
        $wrapperPath = Join-Path $projectRoot 'gradlew.bat'
        Set-Content -LiteralPath $wrapperPath -Value ''
        $project = [pscustomobject]@{ Loader='OrnitheLoader'; DetectionStatus='Resolved'; MinecraftVersion=$target.minecraftId; LoaderVersion='not-a-candidate'; Toolchain=[pscustomobject]@{id='Ploceus';ecosystem='Ornithe'}; BuildSystem=[pscustomobject]@{id='GradleWrapper'}; WrapperPath=$wrapperPath; Root=$projectRoot; BuildJavaRequirement=$null }

        { New-MmtlOrnitheAdapterPlans -Project $project -Universe $script:universe } | Should -Throw '*ORNITHE_TARGET_UNRESOLVED:LOADER_VERSION_NOT_IN_FROZEN_CANDIDATES*'
    }

    It 'rejects a project with another Loader or without a Gradle Wrapper' {
        $project = [pscustomobject]@{ Loader='Fabric'; DetectionStatus='Resolved'; MinecraftVersion='1.13.2'; LoaderVersion='0.1.2'; Toolchain=[pscustomobject]@{id='Ploceus';ecosystem='Ornithe'}; BuildSystem=[pscustomobject]@{id='Custom'}; WrapperPath=''; Root='fixture'; BuildJavaRequirement=$null }

        { New-MmtlOrnitheAdapterPlans -Project $project -Universe $script:universe } | Should -Throw '*ORNITHE_PROJECT_REQUIRED*'
        $project.Loader = 'OrnitheLoader'
        { New-MmtlOrnitheAdapterPlans -Project $project -Universe $script:universe } | Should -Throw '*ORNITHE_GRADLE_WRAPPER_REQUIRED*'
    }

    It 'declares only BuildPlan and LaunchPlan for the 406-target family' {
        $family = $script:families.families | Where-Object familyId -CEQ 'ornithemc-ploceus-project-detection-v1' | Select-Object -First 1

        $family.capabilities.BuildPlan.status | Should -BeExactly 'Supported'
        $family.capabilities.LaunchPlan.status | Should -BeExactly 'Supported'
        $family.capabilities.BuildVerified | Should -BeNullOrEmpty
        $family.capabilities.LaunchCheck | Should -BeNullOrEmpty
        $ledger = Get-Content (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -Raw | ConvertFrom-Json
        $rows = @($ledger.targets | Where-Object loaderId -CEQ 'OrnitheLoader')
        @($rows | Where-Object { $_.dimensions.BuildPlan.status -cne 'Supported' }).Count | Should -Be 0
        @($rows | Where-Object { $_.dimensions.LaunchPlan.status -cne 'Supported' }).Count | Should -Be 0
        @($rows | Where-Object { $_.dimensions.BuildVerified.status -cne 'PendingImplementation' }).Count | Should -Be 0
        @($rows | Where-Object { $_.dimensions.LaunchCheck.status -cne 'PendingImplementation' }).Count | Should -Be 0
    }
}
