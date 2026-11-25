BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $modulePath = Join-Path $repoRoot 'common/src/Compatibility/HistoricalMcpBackendCatalog.psm1'
    if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force }

    $script:catalogFixture = [pscustomobject][ordered]@{
        schemaVersion = 1
        universeHash = '0b394322e696d12e393a02baacdf42f164de563e2a9d936f706fbe1ff89c7606'
        backendId = 'retromcp-java'
        backendSource = [pscustomobject]@{
            repositoryUrl = 'https://github.com/MCPHackers/RetroMCP-Java'
            releaseTag = 'v1.2'
            commit = 'ec16b2a8c5907429ac59f7ebe13f28c4cf8052bd'
            runtimeJavaMajor = 8
        }
        versionRegistry = [pscustomobject]@{
            url = 'https://mcphackers.org/versionsV3/versions.json'
            sha256 = '0513d84d885acbfcca81e820410bac8c8dbca90aa73e1b7434bd3c9ddd3a61fa'
            byteLength = 40883
            recordCount = 132
            retrievedAt = '2026-10-08T05:35:00Z'
        }
        executionPolicy = [pscustomobject]@{ automaticDownloadAllowed = $false; automaticExecutionAllowed = $false; reason = 'Catalog only.' }
        targetPairs = @(
            [pscustomobject]@{ loaderId = 'ModLoader'; minecraftId = '1.5.2'; evidenceRefs = @('version-registry-id:1.5.2') }
            [pscustomobject]@{ loaderId = 'ModLoaderMP'; minecraftId = 'b1.7.3'; evidenceRefs = @('version-registry-id:b1.7.3') }
        )
    }
}

Describe 'Historical MCP backend catalog' {
    It 'resolves an exact ModLoader pair as catalogued only' {
        $result = Resolve-MmtlHistoricalMcpBackend -Catalog $script:catalogFixture -LoaderId 'ModLoader' -MinecraftId '1.5.2'

        $result.status | Should -BeExactly 'CataloguedOnly' -Because ($result.errors -join ',')
        $result.targetId | Should -BeExactly 'ModLoader@1.5.2'
        $result.backendId | Should -BeExactly 'retromcp-java'
        $result.evidenceRefs | Should -Contain 'version-registry-id:1.5.2'
        $result.automaticDownloadAllowed | Should -BeFalse
        $result.automaticExecutionAllowed | Should -BeFalse
    }

    It 'does not cross-resolve ModLoaderMP to a ModLoader row' {
        $result = Resolve-MmtlHistoricalMcpBackend -Catalog $script:catalogFixture -LoaderId 'ModLoaderMP' -MinecraftId '1.5.2'

        $result.status | Should -BeExactly 'NoBackendCandidate'
        $result.backendId | Should -BeNullOrEmpty
    }

    It 'resolves ModLoaderMP only from its own exact pair' {
        $result = Resolve-MmtlHistoricalMcpBackend -Catalog $script:catalogFixture -LoaderId 'ModLoaderMP' -MinecraftId 'b1.7.3'

        $result.status | Should -BeExactly 'CataloguedOnly'
        $result.targetId | Should -BeExactly 'ModLoaderMP@b1.7.3'
        $result.automaticExecutionAllowed | Should -BeFalse
    }

    It 'does not fall back from an unlisted version to a neighboring profile' {
        $result = Resolve-MmtlHistoricalMcpBackend -Catalog $script:catalogFixture -LoaderId 'ModLoader' -MinecraftId '1.6.2'

        $result.status | Should -BeExactly 'NoBackendCandidate'
        $result.targetId | Should -BeExactly 'ModLoader@1.6.2'
        $result.backendId | Should -BeNullOrEmpty
    }

    It 'rejects duplicate target pairs and malformed source hashes' {
        $duplicate = $script:catalogFixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $duplicate.targetPairs = @($duplicate.targetPairs) + @($duplicate.targetPairs[0])
        (Test-MmtlHistoricalMcpBackendCatalog -Catalog $duplicate).isValid | Should -BeFalse

        $badHash = $script:catalogFixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $badHash.versionRegistry.sha256 = 'not-a-sha256'
        (Test-MmtlHistoricalMcpBackendCatalog -Catalog $badHash).isValid | Should -BeFalse
    }

    It 'returns a validation result for a catalog with required fields missing' {
        $incomplete = [pscustomobject]@{ schemaVersion = 1; targetPairs = @() }

        { Test-MmtlHistoricalMcpBackendCatalog -Catalog $incomplete } | Should -Not -Throw
        (Test-MmtlHistoricalMcpBackendCatalog -Catalog $incomplete).isValid | Should -BeFalse
    }

    It 'reports the frozen real catalog coverage without network access' {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $catalogPath = Join-Path $repoRoot 'compatibility/mcp-backend-catalog.json'
        $universePath = Join-Path $repoRoot 'compatibility/universe-preview.json'
        if (-not (Test-Path -LiteralPath $catalogPath)) { throw 'Expected frozen MCP backend catalog fixture has not been added.' }

        $audit = & (Join-Path $repoRoot 'tools/Test-HistoricalMcpBackendCatalog.ps1') -CatalogPath $catalogPath -UniversePath $universePath

        $audit.universeHash | Should -BeExactly '0b394322e696d12e393a02baacdf42f164de563e2a9d936f706fbe1ff89c7606'
        $audit.targetCount | Should -Be 1631
        $audit.loaders.ModLoader.candidateCount | Should -Be 23
        $audit.loaders.ModLoader.missingCount | Should -Be 19
        $audit.loaders.ModLoaderMP.candidateCount | Should -Be 16
        $audit.loaders.ModLoaderMP.missingCount | Should -Be 4
        $audit.candidatePairCount | Should -Be 39
        $audit.automaticExecutionAllowed | Should -BeFalse
    }
}
