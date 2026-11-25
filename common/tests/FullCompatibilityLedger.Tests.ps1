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

    It 'keeps preview runtime Java requirements aligned with the verified runtime catalog' {
        $repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $preview = Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json') | ConvertFrom-Json
        $catalog = Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/runtime-java-catalog.json') | ConvertFrom-Json
        $requirementByVersion = @{}
        foreach ($entry in $catalog.entries) { $requirementByVersion[[string]$entry.minecraftId] = ConvertTo-Json -InputObject $entry.requirement -Depth 30 -Compress }
        foreach ($target in $preview.targets) {
            $version = [string]$target.minecraftId
            $requirementByVersion.ContainsKey($version) | Should -BeTrue -Because $version
            (ConvertTo-Json -InputObject $target.runtimeJavaRequirement -Depth 30 -Compress) | Should -BeExactly $requirementByVersion[$version] -Because $version
        }
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

    It 'attaches universal structured-log observation evidence to every exact available target' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-08T12:00:00Z') -FamilyManifest $families
        $sourceHash=(Get-FileHash (Join-Path $repositoryRoot 'common/src/Logs/StructuredLogWorkspace.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $fixtureHash=(Get-FileHash (Join-Path $repositoryRoot 'common/tests/StructuredLogs.Tests.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $expected=@($universe.targets|Where-Object availability -CEQ 'Available')

        @($ledger.targets).Count | Should -Be $expected.Count
        @($ledger.targets|Where-Object{$_.dimensions.LogObservation.status -cne 'Supported'}).Count | Should -Be 0
        @($ledger.targets|Where-Object{
            $refs=@($_.dimensions.LogObservation.evidenceRefs)
            "structured-log-source-sha256:$sourceHash" -notin $refs -or
            "structured-log-fixture-sha256:$fixtureHash" -notin $refs -or
            'test:StructuredLogs.Tests.ps1:observes-every-exact-available-target' -notin $refs
        }).Count | Should -Be 0
        $validation=Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $universe -FamilyManifest $families
        $validation.isValid | Should -BeTrue -Because ($validation.errors -join ', ')

        $tampered=$ledger|ConvertTo-Json -Depth 40|ConvertFrom-Json
        $targetId=[string]$tampered.targets[0].targetId
        $tampered.targets[0].dimensions.LogObservation.evidenceRefs=@($tampered.targets[0].dimensions.LogObservation.evidenceRefs|Where-Object{$_ -ne "structured-log-source-sha256:$sourceHash"})
        $invalid=Test-MmtlFullCompatibilityLedger -Ledger $tampered -Universe $universe -FamilyManifest $families
        $invalid.isValid | Should -BeFalse
        $invalid.errors | Should -Contain "LOG_OBSERVATION_EVIDENCE_INVALID:$targetId"
    }

    It 'classifies exact Mojang manifest omissions as evidenced RuntimeJava external blockers' {
        $universe = $script:universe | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $universe.targets[1] | Add-Member -NotePropertyName runtimeJavaRequirement -NotePropertyValue ([pscustomobject]@{
            major=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';metadataStatus='NOT_IN_MOJANG_MANIFEST'
            provenance=[pscustomobject]@{sourceType='official-manifest-absence';url='https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';manifestSha256='a'*64;minecraftId='old-beta-1.7.3';reasonCode='MOJANG_TARGET_NOT_IN_VERSION_MANIFEST'}
        })
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $row=$ledger.targets|Where-Object targetId -CEQ 'Legacy@old-beta-1.7.3'
        $row.dimensions.RuntimeJava.status|Should -BeExactly 'ExternallyBlocked'
        $row.dimensions.RuntimeJava.reasonCode|Should -BeExactly 'MOJANG_RUNTIME_JAVA_METADATA_UNAVAILABLE'
        $row.dimensions.RuntimeJava.evidenceRefs|Should -Contain ('runtime-java-manifest-sha256:'+('a'*64))
        $row.dimensions.RuntimeJava.evidence|Should -Match 'old-beta-1.7.3'
        (Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $universe).isValid|Should -BeTrue
    }

    It 'classifies a hash-verified version JSON without javaVersion as an exact external blocker' {
        $universe = $script:universe | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $universe.targets[0] | Add-Member -NotePropertyName runtimeJavaRequirement -NotePropertyValue ([pscustomobject]@{
            major=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';metadataStatus='VERIFIED_NO_JAVA_VERSION'
            provenance=[pscustomobject]@{sourceType='official-version-json-absence';url='https://piston-meta.mojang.com/v1/packages/'+('b'*40)+'/1.20.1.json';manifestSha1='b'*40;snapshotSha256='c'*64;minecraftId='1.20.1';reasonCode='MOJANG_JAVA_VERSION_FIELD_ABSENT'}
        })
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $row=$ledger.targets|Where-Object targetId -CEQ 'Fabric@1.20.1'
        $row.dimensions.RuntimeJava.status|Should -BeExactly 'ExternallyBlocked'
        $row.dimensions.RuntimeJava.evidenceRefs|Should -Contain ('runtime-java-snapshot-sha256:'+('c'*64))
        (Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $universe).isValid|Should -BeTrue
    }

    It 'keeps missing or malformed upstream absence evidence PendingImplementation' {
        $universe = $script:universe | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $universe.targets[1] | Add-Member -NotePropertyName runtimeJavaRequirement -NotePropertyValue ([pscustomobject]@{
            major=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';metadataStatus='NOT_IN_MOJANG_MANIFEST'
            provenance=[pscustomobject]@{sourceType='official-manifest-absence';url='http://example.invalid/manifest.json';manifestSha256='invalid';minecraftId='wrong-id';reasonCode='UNTRUSTED'}
        })
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z')
        $row=$ledger.targets|Where-Object targetId -CEQ 'Legacy@old-beta-1.7.3'
        $row.dimensions.RuntimeJava.status|Should -BeExactly 'PendingImplementation'
        $row.dimensions.RuntimeJava.evidenceRefs|Should -BeNullOrEmpty
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

    It 'preserves structured family external blockers for non-RuntimeJava dimensions' {
        $familyManifest = [pscustomobject]@{
            schemaVersion = 1
            universeHash = [string]$script:universe.catalogHash
            families = @([pscustomobject]@{
                familyId = 'fabric-test-family'
                loaderId = 'Fabric'
                minecraftIds = @('1.20.1')
                toolchain = [pscustomobject]@{ id = 'Fabric Loom'; version = 'test' }
                buildJava = [pscustomobject]@{ status = 'PartiallySupported' }
                runtimeJava = [pscustomobject]@{ major = 17 }
                projectDetectionStrategy = 'Test exact project markers.'
                launchStrategy = 'Test launch strategy.'
                agentBridge = 'Test agent bridge.'
                evidence = @('test:family-evidence')
                capabilities = [pscustomobject]@{
                    BuildPlan = [pscustomobject]@{
                        status = 'ExternallyBlocked'
                        evidenceRefs = @('source:official-repository')
                        reasonCode = 'UPSTREAM_SOURCE_UNAVAILABLE'
                        source = 'https://example.invalid/source'
                        evidence = 'The exact target build source is unavailable.'
                        attemptedRemediation = 'Checked the official archive and source API.'
                    }
                }
            })
        }

        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $familyManifest
        $dimension = $ledger.targets | Where-Object targetId -CEQ 'Fabric@1.20.1' | Select-Object -ExpandProperty dimensions | Select-Object -ExpandProperty BuildPlan

        $dimension.status | Should -BeExactly 'ExternallyBlocked'
        $dimension.reasonCode | Should -BeExactly 'UPSTREAM_SOURCE_UNAVAILABLE'
        $dimension.source | Should -BeExactly 'https://example.invalid/source'
        $dimension.evidence | Should -BeExactly 'The exact target build source is unavailable.'
        $dimension.attemptedRemediation | Should -BeExactly 'Checked the official archive and source API.'
        $dimension.evidenceRefs | Should -Contain 'source:official-repository'
        (Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $script:universe -FamilyManifest $familyManifest).isValid | Should -BeTrue

        $incompleteFamilyManifest = $familyManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $incompleteFamilyManifest.families[0].capabilities.BuildPlan.PSObject.Properties.Remove('attemptedRemediation')
        { New-MmtlFullCompatibilityLedger -Universe $script:universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $incompleteFamilyManifest } | Should -Throw '*FAMILY_MANIFEST_INVALID:EXTERNAL_BLOCKER_EVIDENCE_MISSING:fabric-test-family:BuildPlan:attemptedRemediation*'
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
        $loomFamilies=@($families.families|Where-Object familyId -in @('fabric-loom-remap-build-launch-plan-v1','fabric-loom-unobfuscated-build-launch-plan-v1'))
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'Fabric')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/Fabric.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $buildJavaResolverHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/BuildJavaResolver.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $loomFamilies | Should -HaveCount 2
        foreach($family in $loomFamilies){
            $orderedIds=[string[]]@($family.minecraftIds);[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
            $hashBasis="$($family.familyId)`n$($universe.catalogHash)`n$detectorHash`n$adapterHash`n$buildJavaResolverHash`n$($orderedIds -join "`n")"
            $expectedToolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()
            $family.toolchainHash | Should -BeExactly $expectedToolchainHash
            @($family.minecraftIds|Sort-Object -Unique).Count | Should -Be @($family.minecraftIds).Count
            $family.evidence | Should -Contain 'https://docs.fabricmc.net/develop/loom'
        }
        @($loomFamilies.minecraftIds|ForEach-Object{$_}).Count | Should -Be $fabricTargets.Count
        @($loomFamilies.minecraftIds|ForEach-Object{$_}|Sort-Object -Unique).Count | Should -Be $fabricTargets.Count
        @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildPlan.status -ceq 'Supported'}).Count | Should -Be $fabricTargets.Count
        @($rows|Where-Object{$_.dimensions.LaunchPlan.status -ceq 'Supported'}).Count | Should -Be $fabricTargets.Count
        @($rows|Where-Object{$_.dimensions.AgentBuild.status -ceq 'PendingImplementation'}).Count | Should -Be $fabricTargets.Count
        @($rows|Where-Object{$_.familyId -notin @('fabric-loom-remap-build-launch-plan-v1','fabric-loom-unobfuscated-build-launch-plan-v1')}).Count | Should -Be 0
    }

    It 'partitions Fabric exact targets at the official Loom plugin id generation boundary' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $fabricTargets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Fabric' -and $_.availability -ceq 'Available'})
        $remap=$families.families|Where-Object familyId -CEQ 'fabric-loom-remap-build-launch-plan-v1'
        $unobfuscated=$families.families|Where-Object familyId -CEQ 'fabric-loom-unobfuscated-build-launch-plan-v1'

        $remap | Should -Not -BeNullOrEmpty
        $unobfuscated | Should -Not -BeNullOrEmpty
        @($remap.minecraftIds|Where-Object {$_ -match '^26\.'}).Count | Should -Be 0
        @($unobfuscated.minecraftIds|Where-Object {$_ -notmatch '^26\.'}).Count | Should -Be 0
        @($remap.minecraftIds).Count + @($unobfuscated.minecraftIds).Count | Should -Be $fabricTargets.Count
        @($remap.minecraftIds + $unobfuscated.minecraftIds|Sort-Object -Unique).Count | Should -Be $fabricTargets.Count
        $remap.evidence | Should -Contain 'https://docs.fabricmc.net/develop/loom'
        $unobfuscated.evidence | Should -Contain 'https://docs.fabricmc.net/develop/loom'
        $remap.toolchain.id | Should -BeExactly 'net.fabricmc.fabric-loom-remap'
        $unobfuscated.toolchain.id | Should -BeExactly 'net.fabricmc.fabric-loom'
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
        $buildJavaResolverHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/BuildJavaResolver.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $hashBasis="neoforge-gradle-build-launch-plan-v1`n$($universe.catalogHash)`n$detectorHash`n$adapterHash`n$buildJavaResolverHash`n$($orderedIds -join "`n")"
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
        $buildJavaResolverHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/BuildJavaResolver.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $lf=[string][char]10
        $hashBasis=(@('quilt-loom-build-launch-plan-v1',[string]$universe.catalogHash,$detectorHash,$adapterHash,$buildJavaResolverHash)+$orderedIds) -join $lf
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

    It 'assigns exact Forge targets to a BuildPlan and LaunchPlan family' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Forge' -and $_.availability -ceq 'Available'})
        $catalog=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/forge-mdk-generations.json')|ConvertFrom-Json
        $forgeFamilies=@($families.families|Where-Object{$_.loaderId -ceq 'Forge'})
        $availableGroups=@($catalog.targets|Where-Object status -CEQ 'Available'|Group-Object forgeGradleSpec)
        $sourceGradleGroups=@($catalog.targets|Where-Object sourceProjectType -CEQ 'GradleProject'|Group-Object {"$($_.alternateForgeGradleSpec)|$($_.alternateGradleDistributionUrl)"})
        $sourceOverlayRows=@($catalog.targets|Where-Object sourceProjectType -CEQ 'ForgeSourceOverlay')
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'Forge')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/Forge.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $buildJavaResolverHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/BuildJavaResolver.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $forgeFamilies.Count | Should -Be ($availableGroups.Count + $sourceGradleGroups.Count + 1)
        foreach($group in $availableGroups){
            $spec=[string]$group.Name
            $familyId='forge-gradle-spec-'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($spec))).ToLowerInvariant().Substring(0,12))
            $family=@($forgeFamilies|Where-Object familyId -CEQ $familyId)
            $family.Count | Should -Be 1
            $expectedIds=[string[]]@($group.Group|ForEach-Object{([string]$_.targetId -split '@',2)[1]});[Array]::Sort($expectedIds,[StringComparer]::Ordinal)
            @($family[0].minecraftIds) | Should -Be $expectedIds
            $family[0].toolchain.id | Should -BeExactly "ForgeGradleSpec:$spec"
            $family[0].evidence | Should -Contain "forge-mdk-catalog-sha256:$($catalog.catalogHash)"
            $basisRows=@($group.Group|Sort-Object targetId|ForEach-Object{"$($_.targetId)|$($_.forgeCoordinate)|$($_.archiveSha256)|$($_.buildGradleSha256)|$($_.forgeGradleSpec)|$($_.gradleDistributionUrl)|$($_.buildJavaMajor)"})
            $hashBasis=(@($familyId,[string]$universe.catalogHash,[string]$catalog.catalogHash,$detectorHash,$adapterHash,$buildJavaResolverHash)+$basisRows) -join "`n"
            $expectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()
            $family[0].toolchainHash | Should -BeExactly $expectedHash
        }
        foreach($group in $sourceGradleGroups){
            $first=$group.Group[0]
            $sourceKey="$($first.alternateForgeGradleSpec)|$($first.alternateGradleDistributionUrl)"
            $familyId='forge-gradle-source-'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceKey))).ToLowerInvariant().Substring(0,12))
            $family=@($forgeFamilies|Where-Object familyId -CEQ $familyId)
            $family.Count | Should -Be 1
            $expectedIds=[string[]]@($group.Group|ForEach-Object{([string]$_.targetId -split '@',2)[1]});[Array]::Sort($expectedIds,[StringComparer]::Ordinal)
            @($family[0].minecraftIds) | Should -Be $expectedIds
            $family[0].toolchain.id | Should -BeExactly "ForgeGradleSpec:$($first.alternateForgeGradleSpec)"
            $family[0].toolchain.version | Should -Match ([regex]::Escape([string]$first.alternateGradleDistributionUrl))
            $sourceBasisRows=@($group.Group|Sort-Object targetId|ForEach-Object{"$($_.targetId)|$($_.forgeCoordinate)|$($_.alternateArchiveSha256)|$($_.alternateBuildGradleSha256)|$($_.alternateForgeGradleSpec)|$($_.alternateGradleDistributionUrl)|$($_.alternateBuildJavaMajor)"})
            $sourceBasis=(@($familyId,[string]$universe.catalogHash,[string]$catalog.catalogHash,$detectorHash,$adapterHash,$buildJavaResolverHash)+$sourceBasisRows) -join "`n"
            $sourceExpectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceBasis))).ToLowerInvariant()
            $family[0].toolchainHash | Should -BeExactly $sourceExpectedHash
        }
        $overlayFamily=@($forgeFamilies|Where-Object familyId -CEQ 'forge-legacy-source-overlay-v1')
        $overlayFamily.Count | Should -Be 1
        @($overlayFamily[0].minecraftIds).Count | Should -Be $sourceOverlayRows.Count
        $overlayFamily[0].capabilities.ProjectDetection.status | Should -BeExactly 'Supported'
        $overlayFamily[0].capabilities.ProjectDetection.evidenceRefs | Should -Contain 'test:ProjectDetectorV2.Tests.ps1:detects-every-forge-source-overlay-minecraft-target-from-forge-api-imports-in-mcp-projects'
        $overlayFamily[0].capabilities.BuildJava.status | Should -BeExactly 'PendingImplementation'
        $overlayFamily[0].capabilities.BuildPlan.status | Should -BeExactly 'PendingImplementation'
        $overlayFamily[0].capabilities.LaunchPlan.status | Should -BeExactly 'PendingImplementation'
        @($overlayFamily[0].minecraftIds|Sort-Object -Unique).Count | Should -Be $sourceOverlayRows.Count
        $assigned=@($forgeFamilies|ForEach-Object{@($_.minecraftIds)})
        $assigned.Count | Should -Be $targets.Count
        @($assigned|Sort-Object -Unique).Count | Should -Be $targets.Count
        @($rows|Where-Object{$_.familyId -cne 'forge-legacy-source-overlay-v1' -and $_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'forge-legacy-source-overlay-v1' -and $_.dimensions.BuildPlan.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'forge-legacy-source-overlay-v1' -and $_.dimensions.LaunchPlan.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -ceq 'forge-legacy-source-overlay-v1' -and $_.dimensions.BuildPlan.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildVerified.status -ne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.LaunchCheck.status -ne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.AgentBuild.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -notin @($forgeFamilies|ForEach-Object familyId)}).Count | Should -Be 0
    }

    It 'assigns exact LegacyFabric targets to a BuildPlan and LaunchPlan family' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'LegacyFabric' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'legacyfabric-looming-build-launch-plan-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'LegacyFabric')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/LegacyFabric.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $buildJavaResolverHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/BuildJavaResolver.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $lf=[string][char]10
        $hashBasis=(@('legacyfabric-looming-build-launch-plan-v1',[string]$universe.catalogHash,$detectorHash,$adapterHash,$buildJavaResolverHash,'422896c188108632da97825f801719f0015b1b32','d0842b87a7fa6c1a74a0f16f7be6aaaa9bee4c79')+$orderedIds) -join $lf
        $expectedToolchainHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashBasis))).ToLowerInvariant()

        (Test-Json -Json ($families|ConvertTo-Json -Depth 30 -Compress) -SchemaFile $familySchema) | Should -BeTrue
        $family | Should -Not -BeNullOrEmpty
        $family.toolchainHash | Should -BeExactly $expectedToolchainHash
        @($family.minecraftIds).Count | Should -Be $targets.Count
        @($family.minecraftIds|Sort-Object -Unique).Count | Should -Be $targets.Count
        @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
        $family.capabilities.BuildPlan.status | Should -BeExactly 'Supported'
        $family.capabilities.LaunchPlan.status | Should -BeExactly 'Supported'
        @($rows|Where-Object{$_.dimensions.BuildPlan.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.LaunchPlan.status -cne 'Supported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildVerified.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.LaunchCheck.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.AgentBuild.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'legacyfabric-looming-build-launch-plan-v1'}).Count | Should -Be 0
    }

    It 'assigns exact OrnitheLoader targets to BuildPlan and LaunchPlan' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'OrnitheLoader' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'ornithemc-ploceus-project-detection-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'OrnitheLoader')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/Ornithe.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $buildJavaResolverHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/BuildJavaResolver.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $orderedIds=[string[]]@($targets|ForEach-Object{[string]$_.minecraftId});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
        $lf=[string][char]10
        $hashBasis=(@('ornithemc-ploceus-project-detection-v1',[string]$universe.catalogHash,$detectorHash,$adapterHash,$buildJavaResolverHash)+$orderedIds) -join $lf
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
        @($rows|Where-Object{$_.dimensions.LaunchCheck.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.AgentBuild.status -cne 'PendingImplementation'}).Count | Should -Be 0
        @($rows|Where-Object{$_.familyId -cne 'ornithemc-ploceus-project-detection-v1'}).Count | Should -Be 0
    }

    It 'assigns exact LiteLoader targets to a detection-only family' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'LiteLoader' -and $_.availability -ceq 'Available'})
        $family=$families.families|Where-Object familyId -CEQ 'liteloader-project-metadata-detection-v1'|Select-Object -First 1
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $rows=@($ledger.targets|Where-Object loaderId -CEQ 'LiteLoader')
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $adapterHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/Adapters/ContractV2.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $hashLines=[Collections.Generic.List[string]]::new()
        foreach($value in @('liteloader-project-metadata-detection-v1',[string]$universe.catalogHash,$detectorHash,$adapterHash)){$hashLines.Add([string]$value)}
        foreach($target in @($targets|Sort-Object targetId)){$hashLines.Add("$($target.targetId)|$($target.candidateSourceHash)|$(@($target.loaderVersionCandidates) -join ',')")}
        $hashBasis=$hashLines -join [string][char]10
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
        @($rows|Where-Object{$_.familyId -cne 'liteloader-project-metadata-detection-v1'}).Count | Should -Be 0
        $targets.Count | Should -Be 16
        @($targets|Where-Object{$_.candidateSourceUrl -cne 'https://dl.liteloader.com/versions/versions.json'}).Count | Should -Be 0
        @($targets|Where-Object{$_.candidateSourceHash -notmatch '^(?i:[a-f0-9]{64})$'}).Count | Should -Be 0
    }

    It 'assigns exact MCP ModLoader targets to detection-only families with hash-bound provenance' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-08T00:00:00Z') -FamilyManifest $families
        $detectorHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/ProjectDetector.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach($loaderId in @('ModLoader','ModLoaderMP')){
            $targets=@($universe.targets|Where-Object{$_.loaderId -ceq $loaderId -and $_.availability -ceq 'Available'})
            $catalog=Get-Content -Raw (Join-Path $repositoryRoot "compatibility/candidate-catalogs/$loaderId.json")|ConvertFrom-Json
            $family=$families.families|Where-Object{$_.loaderId -ceq $loaderId}|Select-Object -First 1
            $rows=@($ledger.targets|Where-Object loaderId -CEQ $loaderId)
            $expectedFamilyId=if($loaderId -ceq 'ModLoader'){'modloader-mcp-source-project-detection-v1'}else{'modloadermp-mcp-source-project-detection-v1'}
            $hashLines=[Collections.Generic.List[string]]::new()
            foreach($part in @($expectedFamilyId,[string]$universe.catalogHash,$detectorHash)){[void]$hashLines.Add([string]$part)}
            foreach($target in @($targets|Sort-Object targetId)){
                $record=$catalog.results|Where-Object targetId -CEQ $target.targetId|Select-Object -First 1
                $record | Should -Not -BeNullOrEmpty
                $targetCandidateRows=@($target.loaderVersionCandidates|ForEach-Object{"$($_.loaderVersion)|$($_.artifactFilename)|$($_.sha256)"})
                $catalogCandidateRows=@($record.candidates|ForEach-Object{"$($_.loaderVersion)|$($_.artifactFilename)|$($_.sha256)"})
                ($targetCandidateRows -join "`n") | Should -BeExactly ($catalogCandidateRows -join "`n")
                $versionLabels=@($target.loaderVersionCandidates|ForEach-Object{[string]$_.loaderVersion})
                [void]$hashLines.Add("$($target.targetId)|$([string]$target.candidateSourceHash)|$([string]$record.sourceHash)|$($versionLabels -join ',')")
            }
            $expectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($hashLines -join [string][char]10))).ToLowerInvariant()
            $family | Should -Not -BeNullOrEmpty
            $family.familyId | Should -BeExactly $expectedFamilyId
            $family.toolchainHash | Should -BeExactly $expectedHash
            $family.minecraftIds.Count | Should -Be $targets.Count
            @($family.minecraftIds|Sort-Object -Unique).Count | Should -Be $targets.Count
            @($rows|Where-Object{$_.familyId -cne [string]$family.familyId}).Count | Should -Be 0
            @($rows|Where-Object{$_.dimensions.ProjectDetection.status -cne 'Supported'}).Count | Should -Be 0
            @($rows|Where-Object{$_.dimensions.BuildPlan.status -cne 'PendingImplementation' -or $_.dimensions.LaunchPlan.status -cne 'PendingImplementation' -or $_.dimensions.BuildVerified.status -cne 'PendingImplementation'}).Count | Should -Be 0
            foreach($target in $targets){
                $family.minecraftIds | Should -Contain ([string]$target.minecraftId)
                $row=$rows|Where-Object targetId -CEQ ([string]$target.targetId)|Select-Object -First 1
                $row.dimensions.ProjectDetection.evidenceRefs | Should -Contain "project-detector-sha256:$detectorHash"
            }
            $family.capabilities.PSObject.Properties.Name | Should -Be @('ProjectDetection')
        }
        $familySchema=Join-Path $repositoryRoot 'common/schemas/compatibility-families.schema.json'
        (Test-Json -Json ($families|ConvertTo-Json -Depth 50 -Compress) -SchemaFile $familySchema) | Should -BeTrue
    }

    It 'audits every frozen family as an exact non-overlapping target set with no future-version inheritance' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-09T00:00:00Z') -FamilyManifest $families
        $validation=Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $universe -FamilyManifest $families -RequireFamilies

        $validation.isValid | Should -BeTrue
        $validation.summary.targetCount | Should -Be 1631
        $validation.summary.unassignedFamilyCount | Should -Be 0
        @($families.families|ForEach-Object{$_.familyId}|Sort-Object -Unique).Count | Should -Be $families.families.Count
        @($ledger.targets|ForEach-Object{$_.targetId}|Sort-Object -Unique).Count | Should -Be $universe.targets.Count

        foreach($family in $families.families){
            $familyTargets=@($universe.targets|Where-Object{$_.availability -ceq 'Available' -and $_.loaderId -ceq $family.loaderId -and $_.minecraftId -in @($family.minecraftIds)})
            $listedTargetIds=[string[]]@($family.minecraftIds|ForEach-Object{"$($family.loaderId)@$($_)"}|Sort-Object)
            $actualTargetIds=[string[]]@($ledger.targets|Where-Object familyId -CEQ $family.familyId|ForEach-Object{$_.targetId}|Sort-Object)
            ($listedTargetIds -join "`n") | Should -BeExactly ($actualTargetIds -join "`n")
            $familyTargets.Count | Should -Be $actualTargetIds.Count
            $boundaryIds=@($family.minecraftIds|Sort-Object -Unique)
            foreach($boundaryId in @($boundaryIds[0],$boundaryIds[-1])){
                $boundaryTargetId="$($family.loaderId)@$boundaryId"
                @($ledger.targets|Where-Object targetId -CEQ $boundaryTargetId|Where-Object familyId -CEQ $family.familyId).Count | Should -Be 1
            }

            $futureManifest=$families|ConvertTo-Json -Depth 50|ConvertFrom-Json
            $futureFamily=$futureManifest.families|Where-Object familyId -CEQ $family.familyId|Select-Object -First 1
            $futureFamily.minecraftIds=@($futureFamily.minecraftIds)+@('__future_unverified__')
            { New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-09T00:00:00Z') -FamilyManifest $futureManifest } | Should -Throw '*FAMILY_TARGET_NOT_IN_UNIVERSE*'
        }
    }

    It 'records project-evidence BuildJava resolution as partial without promoting BuildVerified' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $families=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/families.json')|ConvertFrom-Json
        $expectedFamilyIds=@('fabric-loom-remap-build-launch-plan-v1','fabric-loom-unobfuscated-build-launch-plan-v1','legacyfabric-looming-build-launch-plan-v1','neoforge-gradle-build-launch-plan-v1','ornithemc-ploceus-project-detection-v1','quilt-loom-build-launch-plan-v1')+@($families.families|Where-Object{$_.familyId -like 'forge-gradle-spec-*' -or $_.familyId -like 'forge-gradle-source-*'}|ForEach-Object familyId)
        $resolverHash=(Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'common/src/BuildJavaResolver.psm1') -Algorithm SHA256).Hash.ToLowerInvariant()
        $ledger=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-09T00:00:00Z') -FamilyManifest $families
        $eligibleFamilies=@($families.families|Where-Object{$_.familyId -in $expectedFamilyIds})
        $rows=@($ledger.targets|Where-Object{$_.familyId -in $expectedFamilyIds})

        $eligibleFamilies.Count | Should -Be $expectedFamilyIds.Count
        @($rows|Where-Object{$_.dimensions.BuildJava.status -cne 'PartiallySupported'}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildJava.evidenceRefs -notcontains "build-java-resolver-sha256:$resolverHash"}).Count | Should -Be 0
        @($rows|Where-Object{$_.dimensions.BuildVerified.status -cne 'PendingImplementation'}).Count | Should -Be 0
        foreach($family in $eligibleFamilies){
            $family.capabilities.BuildJava.status | Should -BeExactly 'PartiallySupported'
            $family.capabilities.BuildJava.evidenceRefs | Should -Contain "build-java-resolver-sha256:$resolverHash"
            $family.capabilities.BuildJava.evidenceRefs | Should -Contain 'test:JavaEvidence.Tests.ps1:wrapper-minimum-and-compiler-target'
        }
    }

    It 'applies verified Runner evidence to one exact target without promoting its family siblings' {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe = Get-Content (Join-Path $repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
        $families = Get-Content (Join-Path $repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
        $sourceEvidence = Join-Path $repoRoot 'compatibility/evidence/build/Forge-1.8.9-Windows-x64.json'
        $evidenceRoot = Join-Path $TestDrive 'target-evidence'
        $null = New-Item -ItemType Directory -Path $evidenceRoot -Force
        $evidencePath = Join-Path $evidenceRoot 'forge-1.8.9.json'
        Copy-Item -LiteralPath $sourceEvidence -Destination $evidencePath
        $baseline = New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $row = @($baseline.targets | Where-Object targetId -CEQ 'Forge@1.8.9')[0]
        $evidenceHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $index = [pscustomobject][ordered]@{
            schemaVersion = 1
            universeHash = [string]$universe.catalogHash
            entries = @([pscustomobject][ordered]@{targetId='Forge@1.8.9';dimension='BuildVerified';targetSpecHash=[string]$row.targetSpecHash;evidencePath='forge-1.8.9.json';evidenceSha256=$evidenceHash})
        }

        $ledger = New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families -TargetEvidenceIndex $index -EvidenceRoot $evidenceRoot
        $validation = Test-MmtlFullCompatibilityLedger -Ledger $ledger -Universe $universe -FamilyManifest $families -TargetEvidenceIndex $index -EvidenceRoot $evidenceRoot

        ($ledger.targets | Where-Object targetId -CEQ 'Forge@1.8.9').dimensions.BuildVerified.status | Should -BeExactly 'Supported'
        ($ledger.targets | Where-Object targetId -CEQ 'Forge@1.8.9').dimensions.BuildJava.status | Should -BeExactly 'Supported'
        ($ledger.targets | Where-Object targetId -CEQ 'Forge@1.8.9').dimensions.BuildJava.evidenceRefs | Should -Contain "target-runner-evidence-sha256:$evidenceHash"
        @($ledger.targets | Where-Object targetId -in @('Forge@1.8.8','Forge@1.9') | Where-Object {$_.dimensions.BuildJava.status -cne 'PartiallySupported'}).Count | Should -Be 0
        ($ledger.targets | Where-Object targetId -CEQ 'Forge@1.8.9').dimensions.BuildVerified.evidenceRefs | Should -Contain "target-runner-evidence-sha256:$evidenceHash"
        @($ledger.targets | Where-Object targetId -in @('Forge@1.8.8','Forge@1.9') | Where-Object {$_.dimensions.BuildVerified.status -ne 'PendingImplementation'}).Count | Should -Be 0
        $validation.isValid | Should -BeTrue
    }

    It 'accepts evidence when an exact loader version candidate is a structured catalog record' {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe = Get-Content (Join-Path $repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
        $families = Get-Content (Join-Path $repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
        $checkedInIndex = Get-Content (Join-Path $repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
        $riftClaim = @($checkedInIndex.entries | Where-Object { $_.targetId -CEQ 'Rift@1.13' -and $_.dimension -CEQ 'BuildVerified' })[0]
        $riftClaim | Should -Not -BeNullOrEmpty
        $base = New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-14T00:00:00Z') -FamilyManifest $families
        $riftTarget = @($universe.targets | Where-Object targetId -CEQ 'Rift@1.13')[0]
        $riftTarget.loaderVersionCandidates[0].loaderVersion | Should -BeExactly '1.0.4'
        $index = [pscustomobject][ordered]@{
            schemaVersion = 1
            universeHash = [string]$universe.catalogHash
            entries = @([pscustomobject][ordered]@{
                targetId = [string]$riftClaim.targetId
                dimension = [string]$riftClaim.dimension
                targetSpecHash = [string](@($base.targets | Where-Object targetId -CEQ 'Rift@1.13')[0].targetSpecHash)
                evidencePath = [string]$riftClaim.evidencePath
                evidenceSha256 = [string]$riftClaim.evidenceSha256
            })
        }

        $ledger = New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-14T00:00:00Z') -FamilyManifest $families -TargetEvidenceIndex $index -EvidenceRoot $repoRoot

        ($ledger.targets | Where-Object targetId -CEQ 'Rift@1.13').dimensions.BuildVerified.status | Should -BeExactly 'Supported'
    }

    It 'rejects stale universe claims, duplicate dimensions, tampered evidence and unsafe paths' {
        $repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content (Join-Path $repoRoot 'compatibility/compatibility-universe.json') -Raw|ConvertFrom-Json
        $families=Get-Content (Join-Path $repoRoot 'compatibility/families.json') -Raw|ConvertFrom-Json
        $root=Join-Path $TestDrive 'invalid-target-evidence';$null=New-Item -ItemType Directory -Path $root -Force
        $path=Join-Path $root 'forge.json';Copy-Item (Join-Path $repoRoot 'compatibility/evidence/build/Forge-1.8.9-Windows-x64.json') $path
        $base=New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families
        $row=@($base.targets|Where-Object targetId -CEQ 'Forge@1.8.9')[0]
        $hash=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $entry=[pscustomobject][ordered]@{targetId='Forge@1.8.9';dimension='BuildVerified';targetSpecHash=[string]$row.targetSpecHash;evidencePath='forge.json';evidenceSha256=$hash}
        $index=[pscustomobject][ordered]@{schemaVersion=1;universeHash=[string]$universe.catalogHash;entries=@($entry)}

        $stale=$index|ConvertTo-Json -Depth 10|ConvertFrom-Json;$stale.universeHash='0'*64
        { New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families -TargetEvidenceIndex $stale -EvidenceRoot $root } | Should -Throw '*TARGET_EVIDENCE_UNIVERSE_MISMATCH*'
        $duplicate=$index|ConvertTo-Json -Depth 10|ConvertFrom-Json;$duplicate.entries=@($entry,$entry)
        { New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families -TargetEvidenceIndex $duplicate -EvidenceRoot $root } | Should -Throw '*TARGET_EVIDENCE_DUPLICATE_CLAIM*'
        $unsafe=$index|ConvertTo-Json -Depth 10|ConvertFrom-Json;$unsafe.entries[0].evidencePath='../forge.json'
        { New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families -TargetEvidenceIndex $unsafe -EvidenceRoot $root } | Should -Throw '*TARGET_EVIDENCE_INDEX_SCHEMA_INVALID*'
        $tampered=$index|ConvertTo-Json -Depth 10|ConvertFrom-Json;$tampered.entries[0].evidenceSha256=('0'*64)
        { New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families -TargetEvidenceIndex $tampered -EvidenceRoot $root } | Should -Throw '*TARGET_EVIDENCE_HASH_MISMATCH:Forge@1.8.9*'
        $wrongEvidence=Get-Content $path -Raw|ConvertFrom-Json;$wrongEvidence.targetId='Forge@1.8.8';[IO.File]::WriteAllText($path,($wrongEvidence|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        $mismatch=$index|ConvertTo-Json -Depth 10|ConvertFrom-Json;$mismatch.entries[0].evidenceSha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
        { New-MmtlFullCompatibilityLedger -Universe $universe -GeneratedAt ([DateTimeOffset]'2026-10-07T12:00:00Z') -FamilyManifest $families -TargetEvidenceIndex $mismatch -EvidenceRoot $root } | Should -Throw '*TARGET_EVIDENCE_IDENTITY_MISMATCH:Forge@1.8.9*'
    }
}
