BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repoRoot 'common/src/Compatibility/FullCompatibilityLedger.psm1') -Force
    $script:universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
    $script:families = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
    $script:targetSpecHash = [string]((New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')).targets | Where-Object targetId -CEQ 'Fabric@1.21.7' | Select-Object -First 1).targetSpecHash

function New-AgentInjectionEvidenceFixture {
    param([Parameter(Mandatory)][string]$Root)

    $targetId = 'Fabric@1.21.7'
    $indexPath = Join-Path $script:repoRoot 'compatibility/target-validation-evidence.json'
    $sourceIndex = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
    $buildEntry = $sourceIndex.entries | Where-Object { $_.targetId -ceq $targetId -and $_.dimension -ceq 'AgentBuild' } | Select-Object -First 1
    if (-not $buildEntry) { throw 'AGENT_INJECTION_FIXTURE_BUILD_EVIDENCE_MISSING' }
    $buildEntry.targetSpecHash = $script:targetSpecHash

    $buildEvidencePath = Join-Path $script:repoRoot ($buildEntry.evidencePath -replace '/', '\')
    $buildEvidence = Get-Content -LiteralPath $buildEvidencePath -Raw | ConvertFrom-Json
    $providerManifestPath = Join-Path $script:repoRoot ($buildEvidence.provider.manifestPath -replace '/', '\')
    $artifactPath = Join-Path $script:repoRoot ($buildEvidence.artifact.path -replace '/', '\')
    foreach ($relative in @($buildEntry.evidencePath, $buildEvidence.provider.manifestPath, $buildEvidence.artifact.path)) {
        $destination = Join-Path $Root ($relative -replace '/', '\')
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        $source = Join-Path $script:repoRoot ($relative -replace '/', '\')
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $sourceFiles = @(
        'common/src/Agent/AgentProvider.psm1',
        'common/tests/AgentProvider.Tests.ps1'
    ) | ForEach-Object {
        $path = [string]$_
        [pscustomobject][ordered]@{
            path = $path
            sha256 = (Get-FileHash -LiteralPath (Join-Path $script:repoRoot ($path -replace '/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $sourceText = (($sourceFiles | Sort-Object path | ForEach-Object { "$($_.path)`t$($_.sha256)" }) -join "`n") + "`n"
    $sourceSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($sourceText))).ToLowerInvariant()
    $logPath = 'compatibility/evidence/agent-injection/Fabric-1.21.7-Windows-x64/pester.log'
    $logFile = Join-Path $Root ($logPath -replace '/', '\')
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($logFile)) | Out-Null
    [IO.File]::WriteAllText($logFile, "AgentProvider Session injection test passed.`n", [Text.UTF8Encoding]::new($false))

    $jarName = [IO.Path]::GetFileName($artifactPath)
    $copiedArtifactPath = "compatibility/evidence/agent-injection/Fabric-1.21.7-Windows-x64/session/mods/$jarName"
    $copiedArtifactFile = Join-Path $Root ($copiedArtifactPath -replace '/', '\')
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($copiedArtifactFile)) | Out-Null
    Copy-Item -LiteralPath $artifactPath -Destination $copiedArtifactFile -Force
    $evidence = [ordered]@{
        schemaVersion = 1
        targetId = $targetId
        minecraftId = '1.21.7'
        loaderId = 'Fabric'
        loaderVersion = '0.19.5'
        validationLevel = 'AGENT_INJECTION_VERIFIED'
        result = 'PASSED'
        agentBuildEvidenceSha256 = [string]$buildEntry.evidenceSha256
        provider = [ordered]@{
            providerId = [string]$buildEvidence.provider.providerId
            manifestSha256 = [string]$buildEvidence.provider.manifestSha256
            artifactSha256 = [string]$buildEvidence.artifact.sha256
        }
        sessionInjection = [ordered]@{
            method = 'ManagedSessionModJar'
            sourceArtifactSha256 = [string]$buildEvidence.artifact.sha256
            copiedArtifactSha256 = [string]$buildEvidence.artifact.sha256
            copiedArtifactEvidencePath = $copiedArtifactPath
            sessionRelativeArtifactPath = "agent/$jarName"
            runtimeModRelativePath = "agent/$jarName"
            eventSinkRelativePath = 'agent-events/client.jsonl'
            rawTokenInJvmArguments = $false
        }
        source = [ordered]@{ sha256 = $sourceSha; files = @($sourceFiles) }
        tests = [ordered]@{ result = 'PASSED'; passed = 1; failed = 0; skipped = 0 }
        logs = @([ordered]@{ path = $logPath; sha256 = (Get-FileHash -LiteralPath $logFile -Algorithm SHA256).Hash.ToLowerInvariant() })
    }
    $evidencePath = Join-Path $Root 'compatibility/evidence/agent-injection/Fabric-1.21.7-Windows-x64.json'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($evidencePath)) | Out-Null
    [IO.File]::WriteAllText($evidencePath, (ConvertTo-Json -InputObject $evidence -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
    $injectionEntry = [ordered]@{
        targetId = $targetId
        dimension = 'AgentInjection'
        targetSpecHash = $script:targetSpecHash
        evidencePath = 'compatibility/evidence/agent-injection/Fabric-1.21.7-Windows-x64.json'
        evidenceSha256 = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $index = [pscustomobject][ordered]@{
        schemaVersion = 1
        universeHash = [string]$sourceIndex.universeHash
        entries = @($buildEntry, [pscustomobject]$injectionEntry)
    }
    return [pscustomobject]@{
        root = $Root
        index = $index
        evidencePath = $evidencePath
        evidence = $evidence
        injectionEntry = $injectionEntry
        buildEntry = $buildEntry
        buildEvidence = $buildEvidence
    }
}
}

Describe 'AgentInjection exact-target ledger evidence' {
    It 'supports injection only when the exact built artifact is copied and bound into an MMTL Session' {
        $fixture = New-AgentInjectionEvidenceFixture -Root (Join-Path $TestDrive 'agent-injection-valid')
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -TargetEvidenceIndex $fixture.index -EvidenceRoot $fixture.root -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Fabric@1.21.7' | Select-Object -First 1

        $row.dimensions.AgentBuild.status | Should -BeExactly 'Supported'
        $row.dimensions.AgentInjection.status | Should -BeExactly 'Supported'
        $row.dimensions.AgentInjection.evidenceRefs | Should -Contain "agent-injection-build-evidence-sha256:$($fixture.buildEntry.evidenceSha256)"
    }

    It 'rejects injection evidence when the copied Session artifact hash differs from AgentBuild' {
        $fixture = New-AgentInjectionEvidenceFixture -Root (Join-Path $TestDrive 'agent-injection-tampered')
        $fixture.evidence.sessionInjection.copiedArtifactSha256 = '0' * 64
        [IO.File]::WriteAllText($fixture.evidencePath, (ConvertTo-Json -InputObject $fixture.evidence -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
        ($fixture.index.entries | Where-Object dimension -CEQ 'AgentInjection').evidenceSha256 = (Get-FileHash -LiteralPath $fixture.evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()

        { New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -TargetEvidenceIndex $fixture.index -EvidenceRoot $fixture.root -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z') } | Should -Throw '*TARGET_EVIDENCE_AGENT_INJECTION_ARTIFACT_MISMATCH*'
    }

    It 'rejects injection evidence that is not chained to exact-target AgentBuild evidence' {
        $fixture = New-AgentInjectionEvidenceFixture -Root (Join-Path $TestDrive 'agent-injection-unbuilt')
        $fixture.index.entries = @($fixture.index.entries | Where-Object dimension -cne 'AgentBuild')

        { New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -TargetEvidenceIndex $fixture.index -EvidenceRoot $fixture.root -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z') } | Should -Throw '*TARGET_EVIDENCE_AGENT_INJECTION_BUILD_PROOF_MISSING*'
    }

    It 'rejects injection evidence when a claimed source file hash is stale' {
        $fixture = New-AgentInjectionEvidenceFixture -Root (Join-Path $TestDrive 'agent-injection-stale-source')
        $fixture.evidence.source.files[1].sha256 = '0' * 64
        [IO.File]::WriteAllText($fixture.evidencePath, (ConvertTo-Json -InputObject $fixture.evidence -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
        ($fixture.index.entries | Where-Object dimension -CEQ 'AgentInjection').evidenceSha256 = (Get-FileHash -LiteralPath $fixture.evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()

        { New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:families -TargetEvidenceIndex $fixture.index -EvidenceRoot $fixture.root -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z') } | Should -Throw '*TARGET_EVIDENCE_AGENT_INJECTION_SOURCE_HASH_MISMATCH*'
    }
}
