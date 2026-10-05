BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Validation/HumanValidationPlan.psm1') -Force
}

Describe '人工实机验证计划' {
    BeforeEach {
        $script:portfolio=@(
            [pscustomobject]@{targetId='p-forge-complex';project='forge-complex';projectPath='C:/local/ForgeComplex';minecraftId='1.20.1';loaderId='Forge';loaderVersion='47.2.0';toolchain='ForgeGradle';buildReady=$true;launchReady=$true;historicalClientEvidence=$false;buildSuccessRate=0.5;dependencyCount=14;binding='SameAsBuildJvm'},
            [pscustomobject]@{targetId='p-forge-simple';project='forge-simple';projectPath='C:/local/ForgeSimple';minecraftId='1.20.1';loaderId='Forge';loaderVersion='47.2.0';toolchain='ForgeGradle';buildReady=$true;launchReady=$true;historicalClientEvidence=$false;buildSuccessRate=1.0;dependencyCount=3;binding='SameAsBuildJvm'},
            [pscustomobject]@{targetId='p-fabric';project='fabric';projectPath='C:/local/Fabric';minecraftId='1.21.6';loaderId='Fabric';loaderVersion='0.16.14';toolchain='FabricLoom';buildReady=$true;launchReady=$true;historicalClientEvidence=$false;buildSuccessRate=1.0;dependencyCount=4;binding='SameAsBuildJvm'},
            [pscustomobject]@{targetId='p-neoforge';project='neoforge';projectPath='C:/local/Neo';minecraftId='1.21.1';loaderId='NeoForge';loaderVersion='21.1.238';toolchain='NeoGradle';buildReady=$true;launchReady=$true;historicalClientEvidence=$false;buildSuccessRate=1.0;dependencyCount=6;binding='SameAsBuildJvm'}
        )
    }

    It '按工具链覆盖与易验证性选择代表项目，并严格保持 Tier 顺序' {
        $plan=New-MmtlHumanValidationPlan -Portfolio $script:portfolio -WorkspaceIdentity 'fixture-workspace'
        @($plan.representatives|ForEach-Object project) | Should -Contain 'forge-simple'
        @($plan.representatives|ForEach-Object loaderId|Select-Object -Unique) | Should -Be @('Forge','Fabric','NeoForge')
        @($plan.tiers|ForEach-Object tier) | Should -Be @('Tier1-Single','Tier2-Single-Portfolio','Tier3-Dedicated','Tier4-IntegratedLAN')
        $plan.tiers[2].enabled | Should -BeFalse
        $plan.tiers[3].enabled | Should -BeFalse
        @($plan.checklist).Count | Should -Be 11
        $plan.validationEligible | Should -BeFalse
    }

    It '缺少单人实机 PASS 时绝不建议 Dedicated 或 IntegratedLAN' {
        $plan=New-MmtlHumanValidationPlan -Portfolio @($script:portfolio|ForEach-Object{$_|Select-Object *; $_.launchReady=$false;$_}) -WorkspaceIdentity 'fixture-workspace'
        @($plan.tiers|Where-Object tier -like 'Tier3*'|ForEach-Object enabled) | Should -Be @( $false )
        @($plan.tiers|Where-Object tier -like 'Tier4*'|ForEach-Object enabled) | Should -Be @( $false )
        $plan.tiers[2].blockedReasonCode | Should -Be 'SINGLE_VALIDATION_REQUIRED'
    }

    It 'Portfolio Single 未完成前不开放第二级，全部 Single 未完成前不开放 Dedicated' {
        $plan=New-MmtlHumanValidationPlan -Portfolio $script:portfolio -WorkspaceIdentity 'fixture-workspace'
        $plan.tiers[1].enabled | Should -BeFalse
        $representativeIds=@($plan.representatives|ForEach-Object targetId)
        $tier1Complete=New-MmtlHumanValidationPlan -Portfolio $script:portfolio -WorkspaceIdentity 'fixture-workspace' -CompletedSingleTargetIds $representativeIds
        $tier1Complete.tiers[1].enabled | Should -BeTrue
        $tier1Complete.tiers[2].enabled | Should -BeFalse
        $allSingles=New-MmtlHumanValidationPlan -Portfolio $script:portfolio -WorkspaceIdentity 'fixture-workspace' -CompletedSingleTargetIds @($script:portfolio|ForEach-Object targetId)
        $allSingles.tiers[2].enabled | Should -BeTrue
        $allSingles.tiers[3].enabled | Should -BeFalse
    }

    It '生成的本地 helper 默认只展示计划，真实 Launch 需要显式双重确认' {
        $plan=New-MmtlHumanValidationPlan -Portfolio $script:portfolio -WorkspaceIdentity 'fixture-workspace'
        $output=Join-Path $TestDrive 'manual-validation'
        $bundle=Write-MmtlHumanValidationBundle -Plan $plan -OutputRoot $output -LauncherPath 'C:/local/launcher.ps1'
        Test-Path -LiteralPath $bundle.planPath | Should -BeTrue
        Test-Path -LiteralPath $bundle.helperPath | Should -BeTrue
        $helper=Get-Content -LiteralPath $bundle.helperPath -Raw
        $helper | Should -Match '\[switch\]\$Launch'
        $helper | Should -Match '\[switch\]\$ConfirmRealMinecraftLaunch'
        $helper | Should -Match '默认只显示验证计划'
        $helper | Should -Not -Match '(?i)Start-Process.*java|runClient\s*$'
        $matrix=Get-Content -LiteralPath $bundle.matrixPath -Raw|ConvertFrom-Json
        $matrix.rows.Count | Should -BeGreaterThan 0
        $matrix.rows[0].preflightCommand | Should -Match '-Preflight -TargetId'
        $matrix.rows[0].launchCommand | Should -Match '-Launch -ConfirmRealMinecraftLaunch -TargetId'
        $dedicated=$matrix.rows|Where-Object mode -eq Dedicated|Select-Object -First 1
        $dedicated.launchCommand | Should -Match '-ConfirmEulaAcceptance'
        $helper | Should -Match 'DEDICATED_LAUNCH_REQUIRES_EXPLICIT_EULA_ACCEPTANCE'
        (Get-Content -LiteralPath $bundle.statusPath -Raw|ConvertFrom-Json).validationEligible | Should -BeFalse
    }
}
