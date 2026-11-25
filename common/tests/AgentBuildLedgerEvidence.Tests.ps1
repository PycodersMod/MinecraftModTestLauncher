BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ledgerModule = Join-Path $script:repoRoot 'common/src/Compatibility/FullCompatibilityLedger.psm1'
    Import-Module $script:ledgerModule -Force
    $script:universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
    $script:families = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
    $script:target = $script:universe.targets | Where-Object targetId -CEQ 'Forge@1.20.1' | Select-Object -First 1
    $script:baseLedger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -GeneratedAt ([DateTimeOffset]'2026-10-12T00:00:00Z')
    $script:targetSpecHash = [string]($script:baseLedger.targets | Where-Object targetId -CEQ $script:target.targetId | Select-Object -First 1).targetSpecHash

function New-AgentBuildEvidenceFixture {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$TargetLoaderVersion,[Parameter(Mandatory)][string]$ProviderLoaderVersion)
    [IO.Directory]::CreateDirectory($Root) | Out-Null
    $artifactPath = Join-Path $Root 'agent.jar'
    $artifactStream = [IO.File]::Open($artifactPath, [IO.FileMode]::CreateNew)
    $archive = [IO.Compression.ZipArchive]::new($artifactStream, [IO.Compression.ZipArchiveMode]::Create)
    $archive.CreateEntry('agent/TestAgent.class') | Out-Null
    $archive.Dispose(); $artifactStream.Dispose()
    $artifactHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1; providerId = 'forge-1.20.1'; loaderId = 'Forge'; minecraftVersions = @('1.20.1')
        loaderVersions = @($ProviderLoaderVersion); agentVersion = '0.1.0'; artifact = 'agent.jar'; sha256 = $artifactHash
        minJavaMajor = 17; roles = @('Client','Host','Guest'); capabilities = @('TestCapability')
    }
    $manifestPath = Join-Path $Root 'agent-manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $provider = [pscustomobject][ordered]@{
        providerId = [string]$manifest.providerId; loaderId = [string]$manifest.loaderId
        minecraftVersions = @($manifest.minecraftVersions); loaderVersions = @($manifest.loaderVersions)
        agentVersion = [string]$manifest.agentVersion; manifestPath = 'agent-manifest.json'
        manifestSha256 = $manifestHash; artifactSha256 = $artifactHash
    }
    $evidence = [pscustomobject][ordered]@{
        schemaVersion = 1; targetId = [string]$script:target.targetId; minecraftId = [string]$script:target.minecraftId
        loaderId = [string]$script:target.loaderId; loaderVersion = $TargetLoaderVersion
        providerId = [string]$manifest.providerId; agentVersion = [string]$manifest.agentVersion; provider = $provider
        validationLevel = 'AGENT_BUILD_VERIFIED'; result = 'PASSED'
        source = [pscustomobject]@{ sha256 = 'a' * 64; unchangedDuringBuild = $true }
        buildSystem = [pscustomobject]@{ id = 'Gradle'; version = '8.1.1'; wrapperSha256 = 'b' * 64 }
        java = [pscustomobject]@{ vendor = 'Oracle'; version = '17.0.8'; major = 17; architecture = 'x64' }
        artifact = [pscustomobject]@{ path = 'agent.jar'; sha256 = $artifactHash }
        tests = [pscustomobject]@{ result = 'PASSED'; passed = 1; failed = 0; skipped = 0 }
        logs = @([pscustomobject]@{ sha256 = 'c' * 64 })
    }
    $evidencePath = Join-Path $Root 'agent-build.json'
    [IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $entry = [pscustomobject][ordered]@{
        targetId = [string]$script:target.targetId; dimension = 'AgentBuild'; targetSpecHash = $script:targetSpecHash
        evidencePath = 'agent-build.json'; evidenceSha256 = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $index = [pscustomobject][ordered]@{ schemaVersion = 1; universeHash = [string]$script:universe.catalogHash; entries = @($entry) }
    return [pscustomobject]@{ evidenceRoot = $Root; artifactPath = $artifactPath; evidencePath = $evidencePath; entry = $entry; index = $index }
}
}

Describe 'AgentBuild target evidence in the compatibility ledger' {
    It 'supports AgentBuild only for the exact Loader version in the provider manifest' {
        $fixture = New-AgentBuildEvidenceFixture -Root (Join-Path $TestDrive 'agent-build-evidence') -TargetLoaderVersion ([string]$script:target.loaderVersionCandidates[0]) -ProviderLoaderVersion ([string]$script:target.loaderVersionCandidates[0])

        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -TargetEvidenceIndex $fixture.index -EvidenceRoot $fixture.evidenceRoot -GeneratedAt ([DateTimeOffset]'2026-10-12T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ $script:target.targetId | Select-Object -First 1

        $row.dimensions.AgentBuild.status | Should -BeExactly 'Supported'
        $row.dimensions.AgentBuild.evidenceRefs | Should -Contain "agent-build-evidence-sha256:$($fixture.entry.evidenceSha256)"
    }

    It 'rejects AgentBuild evidence when the provider manifest does not declare the exact target Loader version' {
        $fixture = New-AgentBuildEvidenceFixture -Root (Join-Path $TestDrive 'agent-build-mismatch') -TargetLoaderVersion '1.20.1-47.2.0' -ProviderLoaderVersion '1.20.1-47.4.5'

        { New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -TargetEvidenceIndex $fixture.index -EvidenceRoot $fixture.evidenceRoot -GeneratedAt ([DateTimeOffset]'2026-10-12T00:00:00Z') } | Should -Throw '*TARGET_EVIDENCE_AGENT_PROVIDER_MISMATCH*'
    }

    It 'rejects AgentBuild evidence after the JAR bytes change' {
        $fixture = New-AgentBuildEvidenceFixture -Root (Join-Path $TestDrive 'agent-build-tampered') -TargetLoaderVersion ([string]$script:target.loaderVersionCandidates[0]) -ProviderLoaderVersion ([string]$script:target.loaderVersionCandidates[0])
        [IO.File]::AppendAllText($fixture.artifactPath, 'tampered')

        { New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -TargetEvidenceIndex $fixture.index -EvidenceRoot $fixture.evidenceRoot -GeneratedAt ([DateTimeOffset]'2026-10-12T00:00:00Z') } | Should -Throw '*TARGET_EVIDENCE_AGENT_ARTIFACT_HASH_MISMATCH*'
    }
}
