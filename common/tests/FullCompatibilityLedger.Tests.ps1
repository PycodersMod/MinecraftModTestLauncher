BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Compatibility/FullCompatibilityLedger.psm1'
    Import-Module $modulePath -Force
}

Describe 'Full compatibility ledger' {
    BeforeAll {
        $script:universe = [pscustomobject]@{
            schemaVersion = 1; auditStatus = 'IN_PROGRESS'; generatedAt = '2026-10-07T00:00:00Z'
            catalogHash = 'a' * 64; candidateCatalogHash = 'b' * 64; minecraftReleaseCount = 1; loaderCount = 2
            targets = @(
                [pscustomobject]@{ targetId = 'Fabric@1.20.1'; loaderId = 'Fabric'; minecraftId = '1.20.1'; minecraftType = 'release'; loaderVersionCandidates = @('0.16.9'); candidateStatus = 'Resolved'; candidateSourceUrl = 'https://meta.fabricmc.net/v2/versions/loader/1.20.1'; candidateSourceHash = 'c' * 64; sourceHash = 'd' * 64; authoritativeSource = 'https://meta.fabricmc.net/v2/versions/game'; sourceClass = 'ActiveOfficial'; trustClass = 'TrustedOfficial'; transportSecurity = 'HTTPS'; availability = 'Available' }
                [pscustomobject]@{ targetId = 'Legacy@old-beta-1.7.3'; loaderId = 'Legacy'; minecraftId = 'old-beta-1.7.3'; minecraftType = 'Unknown'; loaderVersionCandidates = @(); candidateStatus = 'Unknown'; candidateSourceUrl = $null; candidateSourceHash = $null; sourceHash = 'e' * 64; authoritativeSource = 'https://archive.example.invalid/versions'; sourceClass = 'VerifiedCommunityArchive'; trustClass = 'VerifiedHistorical'; transportSecurity = 'HTTPS'; availability = 'Available' }
            )
            issues = @()
        }
    }

    It 'creates exactly one row per exact available target without a Cartesian product' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')

        @($ledger.targets).Count | Should -Be 2
        @($ledger.targets | ForEach-Object targetId) | Should -Be @('Fabric@1.20.1', 'Legacy@old-beta-1.7.3')
        $ledger.targets[0].dimensions.Catalogued.status | Should -Be 'Supported'
        $ledger.targets[0].dimensions.LoaderResolved.status | Should -Be 'Supported'
        $ledger.targets[0].dimensions.BuildVerified.status | Should -Be 'PendingImplementation'
        $ledger.targets[1].dimensions.Catalogued.status | Should -Be 'Supported'
        $ledger.targets[1].dimensions.LoaderResolved.status | Should -Be 'Unknown'
        $ledger.targets[1].status | Should -Be 'Unknown'
    }

    It 'validates exact target correspondence and reports unknown and pending work' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $result = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $script:universe

        $result.isValid | Should -BeTrue
        $result.summary.targetCount | Should -Be 2
        $result.summary.unknownTargetCount | Should -Be 1
        $result.summary.pendingImplementationDimensionCount | Should -BeGreaterThan 0
        $result.summary.unassignedFamilyCount | Should -Be 2
    }

    It 'supports Runtime Java only when an exact positive requirement has URL and hash evidence' {
        $universe = $script:universe | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $universe.targets[0] | Add-Member -NotePropertyName runtimeJavaRequirement -NotePropertyValue ([pscustomobject]@{
            major = 21; source = 'MojangVersionMetadata'; confidence = 'High'; requirementKind = 'AuthoritativeMetadata'; metadataStatus = 'VERIFIED'
            provenance = [pscustomobject]@{ url = 'https://piston-meta.mojang.com/v1/packages/example.json'; hash = 'f' * 40 }
        })

        $ledger = New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')

        $ledger.targets[0].dimensions.RuntimeJava.status | Should -BeExactly 'Supported'
        $ledger.targets[0].dimensions.RuntimeJava.evidenceRefs | Should -Contain ('runtime-java-sha1:' + ('f' * 40))
        $ledger.targets[1].dimensions.RuntimeJava.status | Should -BeExactly 'PendingImplementation'
    }

    It 'rejects omitted targets and external blockers without evidence' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $ledger.targets = @($ledger.targets | Select-Object -First 1)
        $omitted = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $script:universe
        $omitted.isValid | Should -BeFalse
        $omitted.errors | Should -Contain 'LEDGER_TARGET_SET_MISMATCH'

        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $ledger.targets[0].dimensions.AgentBuild.status = 'ExternallyBlocked'
        $blocked = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $script:universe
        $blocked.isValid | Should -BeFalse
        $blocked.errors | Should -Contain 'EXTERNAL_BLOCKER_EVIDENCE_MISSING:Fabric@1.20.1:AgentBuild'
    }

    It 'rejects duplicate targets and hashes each exact target specification deterministically' {
        $first = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $second = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-08T12:00:00Z')

        $first.targets[0].targetSpecHash | Should -Match '^[a-f0-9]{64}$'
        $first.targets[0].targetSpecHash | Should -Be $second.targets[0].targetSpecHash
        $first.targets[0].sourceHash | Should -Be ('d' * 64)

        $first.targets = @($first.targets) + @($first.targets[0])
        $duplicate = Test-MmtlFullCompatibilityLedger -Ledger $first -Universe $script:universe
        $duplicate.isValid | Should -BeFalse
        $duplicate.errors | Should -Contain 'LEDGER_DUPLICATE_TARGET:Fabric@1.20.1'
    }

    It 'emits a schema-valid ledger with all independent dimensions and no guessed family' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/full-compatibility-ledger.schema.json'
        $names = @('Catalogued','LoaderResolved','ProjectDetection','BuildPlan','BuildJava','RuntimeJava','RuntimeBinding','BuildVerified','LaunchPlan','LaunchCheck','AgentBuild','AgentInjection','SingleCapability','IntegratedLANCapability','DedicatedCapability','LogObservation','EvidenceLevel')

        @($ledger.targets[0].dimensions.PSObject.Properties.Name) | Should -Be $names
        $ledger.targets[0].familyId | Should -BeNullOrEmpty
        (Test-Json -Json ($ledger | ConvertTo-Json -Depth 40 -Compress) -SchemaFile $schemaPath) | Should -BeTrue
    }

    It 'generates the exact public universe template through the repository command' {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $outputPath = Join-Path $TestDrive 'ledger-template.json'
        $generated = & (Join-Path $repoRoot 'tools/Generate-FullCompatibilityLedger.ps1') -OutputPath $outputPath -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $template = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $schemaPath = Join-Path $repoRoot 'common/schemas/full-compatibility-ledger.schema.json'

        $generated.targetCount | Should -Be 1631
        @($template.targets).Count | Should -Be 1631
        $template.summary.unknownTargetCount | Should -Be 0
        $template.summary.pendingImplementationDimensionCount | Should -BeGreaterThan 0
        (Test-Json -Json (Get-Content -LiteralPath $outputPath -Raw) -SchemaFile $schemaPath) | Should -BeTrue
    }

    It 'assigns only exact evidenced family members and does not infer future target coverage' {
        $familyManifest = [pscustomobject]@{
            schemaVersion = 1; auditStatus = 'IN_PROGRESS'; universeHash = 'a' * 64
            unassignedTargetPolicy = 'Exact targets only.'
            families = @([pscustomobject]@{
                familyId = 'fabric-1.20.1'; loaderId = 'Fabric'; minecraftIds = @('1.20.1')
                toolchainHash = 'f' * 64
                toolchain = 'Loom'; buildJava = '17'; runtimeJava = '17'
                projectDetectionStrategy = 'fabric.mod.json'; launchStrategy = 'Loom runClient'
                agentBridge = 'not implemented'; evidence = @('source-snapshots/example.json')
            })
        }
        $familySchema = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/compatibility-families.schema.json'
        (Test-Json -Json ($familyManifest | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $familyManifest
        $validation = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $script:universe -FamilyManifest $familyManifest

        $ledger.targets[0].familyId | Should -Be 'fabric-1.20.1'
        $ledger.targets[1].familyId | Should -BeNullOrEmpty
        $validation.isValid | Should -BeTrue
        $validation.summary.unassignedFamilyCount | Should -Be 1
        {
            $futureFamily = $familyManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $futureFamily.families[0].minecraftIds = @('1.20.2')
            New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $futureFamily
        } | Should -Throw '*FAMILY_TARGET_NOT_IN_UNIVERSE*'
    }

    It 'applies family capability evidence only to explicitly listed exact targets and dimensions' {
        $familyManifest = [pscustomobject]@{
            schemaVersion = 1; auditStatus = 'IN_PROGRESS'; universeHash = $script:universe.catalogHash
            unassignedTargetPolicy = 'Exact targets only.'
            families = @([pscustomobject]@{
                familyId = 'fabric-1.20.1'; loaderId = 'Fabric'; minecraftIds = @('1.20.1')
                toolchainHash = 'f' * 64
                toolchain = 'Loom'; buildJava = '17'; runtimeJava = '17'
                projectDetectionStrategy = 'fabric.mod.json'; launchStrategy = 'Loom runClient'
                agentBridge = 'not implemented'; evidence = @('source-snapshots/example.json')
                capabilities = [pscustomobject]@{
                    ProjectDetection = [pscustomobject]@{status='Supported';evidenceRefs=@('test:exact-detection')}
                    BuildPlan = [pscustomobject]@{status='Supported';evidenceRefs=@('test:exact-build-plan')}
                }
            })
        }
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $familyManifest
        $familySchema = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/compatibility-families.schema.json'
        (Test-Json -Json ($familyManifest | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $validation = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $script:universe -FamilyManifest $familyManifest

        $ledger.targets[0].dimensions.ProjectDetection.status | Should -BeExactly 'Supported'
        $ledger.targets[0].dimensions.BuildPlan.evidenceRefs | Should -Contain 'test:exact-build-plan'
        $ledger.targets[0].toolchainHash | Should -Be ('f' * 64)
        $ledger.targets[0].dimensions.BuildVerified.status | Should -BeExactly 'PendingImplementation'
        $ledger.targets[1].dimensions.ProjectDetection.status | Should -BeExactly 'PendingImplementation'
        $validation.isValid | Should -BeTrue
    }

    It 'requires evidence for supported capability claims and exact family membership at final gate' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $ledger.targets[0].dimensions.AgentBuild.status = 'Supported'
        $ledger.summary.pendingImplementationDimensionCount--
        $withoutEvidence = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $script:universe

        $withoutEvidence.isValid | Should -BeFalse
        $withoutEvidence.errors | Should -Contain 'LEDGER_CAPABILITY_EVIDENCE_MISSING:Fabric@1.20.1:AgentBuild'
        $final = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $script:universe -RequireFamilies
        $final.errors | Should -Contain 'LEDGER_FAMILY_UNASSIGNED:Fabric@1.20.1'
    }

    It 'assigns exact Fabric targets to a detection-only family without inheriting build support' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $fabricTargets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Fabric' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'fabric-loom-build-launch-plan-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'Fabric')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/Fabric.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($fabricTargets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $hashBasis="fabric-loom-build-launch-plan-v1`n$($universe.catalogHash)`n$detectorHash`n$adapterHash`n$($orderedIds -join "`n")"
        $expectedToolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()

        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $family | Should -Not -BeNullOrEmpty
        $family.toolchainHash | Should -BeExactly $expectedToolchainHash
        @($family.minecraftIds).Count | Should -Be $fabricTargets.Count
        @($family.minecraftIds|Sort-Object -Unique).Count | Should -Be $fabricTargets.Count
        @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildPlan.status -ceq 'Supported'}).Count | Should -Be $fabricTargets.Count
        @($rows|Where-Object{$_.dimensions.LaunchPlan.status -ceq 'Supported'}).Count | Should -Be $fabricTargets.Count
        @($rows|Where-Object{$_.dimensions.AgentBuild.status -ceq 'PendingImplementation'}).Count | Should -Be $fabricTargets.Count
        @($rows|Where-Object{$_.familyId -cne 'fabric-loom-build-launch-plan-v1'}).Count | Should -Be 0
    }

    It 'assigns exact NeoForge targets to a gated Build and Launch planning family' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'NeoForge' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'neoforge-gradle-build-launch-plan-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'NeoForge')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/NeoForge.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $hashBasis="neoforge-gradle-build-launch-plan-v1`n$($universe.catalogHash)`n$detectorHash`n$adapterHash`n$($orderedIds -join "`n")"
        $expectedToolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()

        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $family | Should -Not -BeNullOrEmpty
        $family.toolchainHash | Should -BeExactly $expectedToolchainHash
        @($family.minecraftIds).Count | Should -Be $targets.Count
        @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildPlan.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.LaunchPlan.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildVerified.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'neoforge-gradle-build-launch-plan-v1'}).Count | Should -Be 0
    }

    It 'assigns exact Quilt targets to a gated Build and Launch planning family' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Quilt' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'quilt-loom-build-launch-plan-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'Quilt')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/Quilt.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $lf=[string][char]10
        $hashBasis=(@('quilt-loom-build-launch-plan-v1',[string]$universe.catalogHash,$detectorHash,$adapterHash)+$orderedIds) -join $lf
        $expectedToolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()

        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $family | Should -Not -BeNullOrEmpty
        $family.toolchainHash | Should -BeExactly $expectedToolchainHash
        @($family.minecraftIds).Count | Should -Be $targets.Count
        @($family.minecraftIds|Sort-Object -Unique).Count | Should -Be $targets.Count
        @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildPlan.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.LaunchPlan.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildVerified.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'quilt-loom-build-launch-plan-v1'}).Count | Should -Be 0
    }

    It 'assigns exact Forge targets to a detection-only family' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Forge' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'forge-project-metadata-detection-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'Forge')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/Forge.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $lf=[string][char]10
        $hashBasis=(@('forge-project-metadata-detection-v1',[string]$universe.catalogHash,$detectorHash,$adapterHash)+$orderedIds) -join $lf
        $expectedToolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()

        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $family | Should -Not -BeNullOrEmpty
        $family.toolchainHash | Should -BeExactly $expectedToolchainHash
        @($family.minecraftIds).Count | Should -Be $targets.Count
        @($family.minecraftIds|Sort-Object -Unique).Count | Should -Be $targets.Count
        @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildPlan.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.LaunchPlan.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.AgentBuild.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'forge-project-metadata-detection-v1'}).Count | Should -Be 0
    }

    It 'assigns exact LegacyFabric targets to a detection-only family' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'LegacyFabric' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'legacyfabric-looming-project-detection-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'LegacyFabric')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/ContractV2.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $lf=[string][char]10
        $hashBasis=(@('legacyfabric-looming-project-detection-v1',[string]$universe.catalogHash,$detectorHash,$adapterHash)+$orderedIds) -join $lf
        $expectedToolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()

        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $family | Should -Not -BeNullOrEmpty
        $family.toolchainHash | Should -BeExactly $expectedToolchainHash
        @($family.minecraftIds).Count | Should -Be $targets.Count
        @($family.minecraftIds|Sort-Object -Unique).Count | Should -Be $targets.Count
        @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildPlan.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.LaunchPlan.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.AgentBuild.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'legacyfabric-looming-project-detection-v1'}).Count | Should -Be 0
    }

    It 'assigns exact OrnitheLoader targets to a detection-only family' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'OrnitheLoader' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'ornithemc-ploceus-project-detection-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'OrnitheLoader')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/ContractV2.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $lf=[string][char]10
        $hashBasis=(@('ornithemc-ploceus-project-detection-v1',[string]$universe.catalogHash,$detectorHash,$adapterHash)+$orderedIds) -join $lf
        $expectedToolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()

        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $family | Should -Not -BeNullOrEmpty
        $family.toolchainHash | Should -BeExactly $expectedToolchainHash
        @($family.minecraftIds).Count | Should -Be $targets.Count
        @($family.minecraftIds|Sort-Object -Unique).Count | Should -Be $targets.Count
        @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildPlan.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.LaunchPlan.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.AgentBuild.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'ornithemc-ploceus-project-detection-v1'}).Count | Should -Be 0
    }
}
