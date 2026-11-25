BeforeAll {
    $script:modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Compatibility/CompatibilityDrift.psm1'
    if (Test-Path -LiteralPath $script:modulePath) { Import-Module $script:modulePath -Force }
}

Describe 'Frozen compatibility universe drift comparison' {
    It 'reports added targets as NewUnverified and separates removed and changed targets' {
        $frozen = [pscustomobject]@{
            auditStatus='FROZEN'; catalogHash='frozen-hash'; targets=@(
                [pscustomobject]@{targetId='Fabric@1.21.1';minecraftId='1.21.1';loaderId='Fabric';availability='Available';sourceHash='fabric-old';loaderVersionCandidates=@('0.15.11')},
                [pscustomobject]@{targetId='Forge@1.12.2';minecraftId='1.12.2';loaderId='Forge';availability='Available';sourceHash='forge-old';loaderVersionCandidates=@('14.23.5')},
                [pscustomobject]@{targetId='Rift@1.13';minecraftId='1.13';loaderId='Rift';availability='Available';sourceHash='rift-old';loaderVersionCandidates=@('1.0.4')}
            )
        }
        $current = [pscustomobject]@{
            auditStatus='CANDIDATE'; catalogHash='current-hash'; targets=@(
                [pscustomobject]@{targetId='Fabric@1.21.1';minecraftId='1.21.1';loaderId='Fabric';availability='Available';sourceHash='fabric-old';loaderVersionCandidates=@('0.15.11')},
                [pscustomobject]@{targetId='Forge@1.12.2';minecraftId='1.12.2';loaderId='Forge';availability='Available';sourceHash='forge-new';loaderVersionCandidates=@('14.23.5')},
                [pscustomobject]@{targetId='Fabric@26.4';minecraftId='26.4';loaderId='Fabric';availability='Available';sourceHash='fabric-new';loaderVersionCandidates=@('0.19.5')}
            )
        }

        $report = Compare-MmtlCompatibilityUniverseDrift -FrozenUniverse $frozen -CurrentUniverse $current -GeneratedAt ([DateTimeOffset]'2026-10-11T00:00:00Z')

        $report.frozenCatalogHash | Should -BeExactly 'frozen-hash'
        $report.currentCatalogHash | Should -BeExactly 'current-hash'
        $report.addedTargets.Count | Should -Be 1
        $report.addedTargets[0].targetId | Should -BeExactly 'Fabric@26.4'
        $report.addedTargets[0].status | Should -BeExactly 'NewUnverified'
        $report.removedTargets[0].targetId | Should -BeExactly 'Rift@1.13'
        $report.changedTargets.Count | Should -Be 1
        $report.changedTargets[0].targetId | Should -BeExactly 'Forge@1.12.2'
        $report.changedTargets[0].changedFields | Should -Contain 'sourceHash'
        $report.driftStatus | Should -BeExactly 'DRIFT_DETECTED'
        $frozen.targets.Count | Should -Be 3
        $current.targets.Count | Should -Be 3
    }

    It 'reports no drift when exact source and target contract inputs match' {
        $target = [pscustomobject]@{targetId='Fabric@1.21.1';minecraftId='1.21.1';loaderId='Fabric';availability='Available';sourceHash='same';loaderVersionCandidates=@('0.15.11')}
        $universe = [pscustomobject]@{auditStatus='FROZEN';catalogHash='same-hash';targets=@($target)}

        $report = Compare-MmtlCompatibilityUniverseDrift -FrozenUniverse $universe -CurrentUniverse $universe

        $report.driftStatus | Should -BeExactly 'NO_DRIFT'
        $report.addedTargets.Count | Should -Be 0
        $report.removedTargets.Count | Should -Be 0
        $report.changedTargets.Count | Should -Be 0
    }

    It 'marks an incomplete current audit indeterminate instead of reporting false removals' {
        $frozen = [pscustomobject]@{auditStatus='FROZEN';catalogHash='f';targets=@([pscustomobject]@{targetId='Fabric@1.21.1';minecraftId='1.21.1';loaderId='Fabric'})}
        $current = [pscustomobject]@{auditStatus='IN_PROGRESS';catalogHash='c';targets=@();issues=@([pscustomobject]@{loaderId='Fabric';status='Unavailable';reason='PROVIDER_REFRESH_FAILED';evidence='private detail omitted'})}

        $report = Compare-MmtlCompatibilityUniverseDrift -FrozenUniverse $frozen -CurrentUniverse $current

        $report.driftStatus | Should -BeExactly 'INDETERMINATE'
        $report.removedTargets.Count | Should -Be 0
        $report.unresolvedIssues.Count | Should -Be 1
        $report.unresolvedIssues[0].reason | Should -BeExactly 'PROVIDER_REFRESH_FAILED'
        $report.unresolvedIssues[0].PSObject.Properties.Name | Should -Not -Contain 'evidence'
    }

    It 'rejects duplicate exact target IDs rather than hiding ambiguous drift' {
        $duplicate = [pscustomobject]@{targetId='Fabric@1.21.1';minecraftId='1.21.1';loaderId='Fabric'}
        $frozen = [pscustomobject]@{auditStatus='FROZEN';catalogHash='f';targets=@($duplicate)}
        $current = [pscustomobject]@{auditStatus='CANDIDATE';catalogHash='c';targets=@($duplicate,$duplicate)}

        { Compare-MmtlCompatibilityUniverseDrift -FrozenUniverse $frozen -CurrentUniverse $current } | Should -Throw '*DUPLICATE_TARGET_ID*'
    }

    It 'produces a schema-valid report for the full frozen Universe without mutating it' {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universePath = Join-Path $repo 'compatibility/universe-preview.json'
        $universe = Get-Content -LiteralPath $universePath -Raw | ConvertFrom-Json
        $report = Compare-MmtlCompatibilityUniverseDrift -FrozenUniverse $universe -CurrentUniverse $universe -GeneratedAt ([DateTimeOffset]'2026-10-11T00:00:00Z')
        $json = ConvertTo-Json -InputObject $report -Depth 30
        $schemaPath = Join-Path $repo 'common/schemas/compatibility-drift.schema.json'

        (Test-Json -Json $json -SchemaFile $schemaPath) | Should -BeTrue
        $report.driftStatus | Should -BeExactly 'NO_DRIFT'
        $report.frozenTargetCount | Should -Be 1631
        $report.currentTargetCount | Should -Be 1631
        $universe.targets.Count | Should -Be 1631
    }
}
