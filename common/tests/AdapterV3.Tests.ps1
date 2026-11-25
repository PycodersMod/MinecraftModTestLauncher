BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:modulePath = Join-Path $script:repoRoot 'common/src/Adapters/ContractV3.psm1'
    $script:universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
    $script:families = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
    $script:ledger = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -Raw | ConvertFrom-Json
    $script:runtimeJavaCatalog = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/runtime-java-catalog.json') -Raw | ConvertFrom-Json
    $script:targetEvidenceIndex = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json') -Raw | ConvertFrom-Json
    if (Test-Path -LiteralPath $script:modulePath) { Import-Module $script:modulePath -Force }
}

Describe 'Adapter Contract v3 exact target resolution' {
    It 'resolves operations only from the exact Universe target, family, and Ledger claims' {
        if (-not (Test-Path -LiteralPath $script:modulePath)) { throw 'ADAPTER_V3_MODULE_MISSING' }
        $target = Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog

        $target.contractVersion | Should -Be 3
        $target.targetId | Should -BeExactly 'Fabric@1.21.8'
        $target.loaderId | Should -BeExactly 'Fabric'
        $target.operations.detect.status | Should -BeExactly 'Supported'
        $target.operations.build.status | Should -BeExactly 'Supported'
        $target.operations.launchPlan.status | Should -BeExactly 'Supported'
        $target.operations.launch.status | Should -BeExactly 'PendingImplementation'
        $target.operations.agent.build.status | Should -BeExactly 'Supported'
        $target.operations.single.status | Should -BeExactly 'PendingImplementation'
        $target.operations.offlineLan.status | Should -BeExactly 'PendingImplementation'
        $target.operations.dedicated.status | Should -BeExactly 'PendingImplementation'
        $target.operations.historicalSafety.status | Should -BeExactly 'NotApplicable'
        $target.runtimeJava.status | Should -BeExactly 'Supported'
        $target.runtimeJava.major | Should -Be 21
        $target.runtimeJava.source | Should -BeExactly 'MojangVersionMetadata'
        $target.runtimeJava.evidenceRefs | Should -Contain 'runtime-java-sha1:b1bb44ad769609925328838694503a8dcac7f529'
        $target.buildJava.status | Should -BeExactly 'Supported'
        $target.buildJava.strategy | Should -BeExactly 'PinnedBuildEvidence'
        $target.buildJava.major | Should -Be 25
        $target.buildJava.observedMajor | Should -Be 25
        $target.buildJava.requirementKind | Should -BeExactly 'Exact'
        $target.buildJava.source | Should -BeExactly 'PinnedFabricBuildPolicy'
        $target.buildJava.evidenceRefs | Should -Contain 'build-java-major:25'
    }

    It 'rejects target aliases, sibling versions, and cross-family mismatches' {
        { Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.x' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog } | Should -Throw '*ADAPTER_V3_TARGET_NOT_EXACT*'

        $badFamilies = $script:families | ConvertTo-Json -Depth 40 | ConvertFrom-Json
        $target = $script:ledger.targets | Where-Object targetId -CEQ 'Fabric@1.21.8' | Select-Object -First 1
        $family = $badFamilies.families | Where-Object familyId -CEQ $target.familyId | Select-Object -First 1
        $family.minecraftIds = @('1.21.11')
        { Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $badFamilies -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog } | Should -Throw '*ADAPTER_V3_FAMILY_TARGET_MISMATCH*'
    }

    It 'refuses stale Universe manifests and mismatched Ledger family assignments' {
        $badUniverse = $script:universe | ConvertTo-Json -Depth 40 | ConvertFrom-Json
        $badUniverse.catalogHash = ('0' * 64)
        { Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $badUniverse -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog } | Should -Throw '*ADAPTER_V3_UNIVERSE_HASH_MISMATCH*'

        $badLedger = $script:ledger | ConvertTo-Json -Depth 40 | ConvertFrom-Json
        ($badLedger.targets | Where-Object targetId -CEQ 'Fabric@1.21.8' | Select-Object -First 1).familyId = 'another-family'
        { Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $script:families -Ledger $badLedger -RuntimeJavaCatalog $script:runtimeJavaCatalog } | Should -Throw '*ADAPTER_V3_LEDGER_FAMILY_MISMATCH*'
    }

    It 'requires exactly one Runtime Java catalog row for the exact Minecraft target' {
        $missing = $script:runtimeJavaCatalog | ConvertTo-Json -Depth 40 | ConvertFrom-Json
        $missing.entries = @($missing.entries | Where-Object minecraftId -CNE '1.21.8')
        { Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $missing } | Should -Throw '*ADAPTER_V3_RUNTIME_JAVA_TARGET_MISSING_OR_DUPLICATE*'

        $duplicate = $script:runtimeJavaCatalog | ConvertTo-Json -Depth 40 | ConvertFrom-Json
        $duplicate.entries = @($duplicate.entries) + @($duplicate.entries | Where-Object minecraftId -CEQ '1.21.8')
        { Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $duplicate } | Should -Throw '*ADAPTER_V3_RUNTIME_JAVA_TARGET_MISSING_OR_DUPLICATE*'
    }

    It 'resolves target Build Java from hash-verified indexed Build evidence' {
        $target = Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog -TargetEvidenceIndex $script:targetEvidenceIndex -EvidenceRoot $script:repoRoot

        $target.buildJava.status | Should -BeExactly 'Supported'
        $target.buildJava.major | Should -Be 25
        $target.buildJava.observedMajor | Should -Be 25
        $target.buildJava.requirementKind | Should -BeExactly 'Exact'
        $target.buildJava.strategy | Should -BeExactly 'PinnedBuildEvidence'
        $target.buildJava.evidenceRefs | Should -Contain 'target-runner-evidence-sha256:ee383f525429d15793275e7675f03a0e5b0e7e2d7b76078abd38dd607d53062d'
        $schemaPath = Join-Path $script:repoRoot 'common/schemas/adapter-contract-v3.schema.json'
        (Test-Json -Json ($target | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath) | Should -BeTrue

        $tamperedIndex = $script:targetEvidenceIndex | ConvertTo-Json -Depth 40 | ConvertFrom-Json
        ($tamperedIndex.entries | Where-Object targetId -CEQ 'Fabric@1.21.8' | Where-Object dimension -CEQ 'BuildVerified').evidenceSha256 = ('0' * 64)
        { Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog -TargetEvidenceIndex $tamperedIndex -EvidenceRoot $script:repoRoot } | Should -Throw '*ADAPTER_V3_BUILD_EVIDENCE_HASH_MISMATCH*'
    }

    It 'uses exact verified Build evidence for Rift while retaining its historical Java range' {
        $target = Resolve-MmtlAdapterV3 -TargetId 'Rift@1.13' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog

        $target.buildJava.status | Should -BeExactly 'Supported'
        $target.buildJava.major | Should -Be 8
        $target.buildJava.observedMajor | Should -Be 8
        $target.buildJava.requirementKind | Should -BeExactly 'Minimum'
        $target.buildJava.source | Should -BeExactly 'Gradle 4.9 官方 JVM 兼容范围 7–10 与 Rift Java 8 编译目标的交集'
        $target.buildJava.minimumMajor | Should -Be 8
        $target.buildJava.maximumMajor | Should -Be 10
        $target.buildJava.preferredMajor | Should -Be 8
        $target.buildJava.evidenceRefs | Should -Contain 'rift-compiler-target-java:8'
        $schemaPath = Join-Path $script:repoRoot 'common/schemas/adapter-contract-v3.schema.json'
        (Test-Json -Json ($target | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath) | Should -BeTrue
    }

    It 'resolves every indexed BuildVerified target without borrowing sibling evidence' {
        $buildEntries = @($script:targetEvidenceIndex.entries | Where-Object dimension -CEQ 'BuildVerified')
        $buildEntries.Count | Should -BeGreaterThan 0
        foreach ($entry in $buildEntries) {
            $target = Resolve-MmtlAdapterV3 -TargetId ([string]$entry.targetId) -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog -TargetEvidenceIndex $script:targetEvidenceIndex -EvidenceRoot $script:repoRoot
            $target.targetSpecHash | Should -BeExactly ([string]$entry.targetSpecHash)
            $target.buildJava.status | Should -BeExactly 'Supported'
            $target.buildJava.evidenceRefs | Should -Contain "target-runner-evidence-sha256:$([string]$entry.evidenceSha256)"
        }
    }

    It 'keeps all exact Ledger Build Java claims aligned with their indexed BuildVerified source evidence' {
        $buildEntries = @($script:targetEvidenceIndex.entries | Where-Object dimension -CEQ 'BuildVerified')
        foreach ($entry in $buildEntries) {
            $evidencePath = Join-Path $script:repoRoot ([string]$entry.evidencePath)
            $sourceEvidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
            $target = Resolve-MmtlAdapterV3 -TargetId ([string]$entry.targetId) -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog -TargetEvidenceIndex $script:targetEvidenceIndex -EvidenceRoot $script:repoRoot

            $target.buildJava.status | Should -BeExactly 'Supported'
            $target.buildJava.major | Should -Be ([int]$sourceEvidence.java.buildRequirement.major)
            $target.buildJava.observedMajor | Should -Be ([int]$sourceEvidence.java.observedBuildJava.major)
            $target.buildJava.requirementKind | Should -BeExactly ([string]$sourceEvidence.java.buildRequirement.kind)
            $target.buildJava.source | Should -BeExactly ([string]$sourceEvidence.java.buildRequirement.source)
            $target.buildJava.evidenceRefs | Should -Contain "target-runner-evidence-sha256:$([string]$entry.evidenceSha256)"
            $schemaPath = Join-Path $script:repoRoot 'common/schemas/adapter-contract-v3.schema.json'
            (Test-Json -Json ($target | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath) | Should -BeTrue
        }
    }

    It 'emits schema-valid capabilities and rejects Supported claims without evidence references' {
        $schemaPath = Join-Path $script:repoRoot 'common/schemas/adapter-contract-v3.schema.json'
        $contract = Resolve-MmtlAdapterV3 -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog

        (Test-Json -Json ($contract | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath) | Should -BeTrue
        $contract.operations.launchPlan.status | Should -BeExactly 'Supported'
        $contract.operations.launch.status | Should -BeExactly 'PendingImplementation'
        $contract.isExecutablePlan | Should -BeFalse
        $tampered = $contract | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $tampered.operations.build.evidenceRefs = @()
        (Test-Json -Json ($tampered | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath -ErrorAction SilentlyContinue) | Should -BeFalse
    }

    It 'binds a V2 project through a compatibility shim without changing the original object' {
        if (-not (Test-Path -LiteralPath $script:modulePath)) { throw 'ADAPTER_V3_MODULE_MISSING' }
        $project = [pscustomobject]@{ contractVersion=2; Loader='Fabric'; MinecraftVersion='1.21.8'; LoaderVersion='0.17.0'; Root='fixture'; Evidence=@('fixture-marker') }
        $result = Resolve-MmtlAdapterV3Project -Project $project -TargetId 'Fabric@1.21.8' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog

        $result.contractVersion | Should -Be 3
        $result.targetId | Should -BeExactly 'Fabric@1.21.8'
        [object]::ReferenceEquals($result.project, $project) | Should -BeTrue
        $project.contractVersion | Should -Be 2
        { Resolve-MmtlAdapterV3Project -Project $project -TargetId 'Fabric@1.21.11' -Universe $script:universe -FamilyManifest $script:families -Ledger $script:ledger -RuntimeJavaCatalog $script:runtimeJavaCatalog } | Should -Throw '*ADAPTER_V3_PROJECT_TARGET_MISMATCH*'
    }
}
