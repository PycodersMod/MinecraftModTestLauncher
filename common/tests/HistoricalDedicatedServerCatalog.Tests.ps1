BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'src/Compatibility/HistoricalDedicatedServerCatalog.psm1'
    if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force }
    $script:officialServerPath = if ([string]::IsNullOrWhiteSpace($env:MMTL_HISTORICAL_SERVER_FIXTURE_PATH)) {
        Join-Path $env:TEMP 'mmtl-optional-unavailable-server-fixture.jar'
    } else {
        $env:MMTL_HISTORICAL_SERVER_FIXTURE_PATH
    }
}

Describe 'Historical Dedicated Server artifact trust catalog' {
    It 'exposes a catalog validator and resolver' {
        (Get-Command Test-MmtlHistoricalDedicatedServerCatalog -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        (Get-Command Resolve-MmtlHistoricalDedicatedServerArtifact -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }

    It 'trusts only the exact Mojang-pinned 1.2.5 artifact for an exact target' {
        if (-not $script:officialServerPath -or -not (Test-Path -LiteralPath $script:officialServerPath -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'Set MMTL_HISTORICAL_SERVER_FIXTURE_PATH to the locally verified official fixture to run this artifact-positive check.'
            return
        }
        (Get-FileHash -LiteralPath $script:officialServerPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly '19285d7d16aee740f5a0584f0d80a4940f273a97f5a3eaf251fc1c6c3f2982d1'

        $validation = Test-MmtlHistoricalDedicatedServerCatalog
        $validation.isValid | Should -BeTrue -Because ($validation.errors -join ',')
        $validation.catalogSha256 | Should -BeExactly 'e6c9b6c53ea88be0681a9e17660198fcc5914e8d0635f9b57426c3f3f63c6c57'

        $resolved = Resolve-MmtlHistoricalDedicatedServerArtifact -TargetId 'Forge@1.2.5' -MinecraftId '1.2.5' -ArtifactPath $script:officialServerPath
        $resolved.status | Should -BeExactly 'BaseArtifactVerified'
        $resolved.targetId | Should -BeExactly 'Forge@1.2.5'
        $resolved.minecraftId | Should -BeExactly '1.2.5'
        $resolved.sourceType | Should -BeExactly 'OfficialManifest'
        $resolved.artifactRole | Should -BeExactly 'VanillaBase'
        $resolved.exactLoaderServerReady | Should -BeFalse
        $resolved.automaticDownloadAllowed | Should -BeFalse
        $resolved.automaticExecutionAllowed | Should -BeFalse
        $resolved.sha1 | Should -BeExactly 'd8321edc9470e56b8ad5c67bbd16beba25843336'
        $resolved.sha256 | Should -BeExactly '19285d7d16aee740f5a0584f0d80a4940f273a97f5a3eaf251fc1c6c3f2982d1'
    }

    It 'rejects a mismatched target identity and versions without official server entries' {
        (Resolve-MmtlHistoricalDedicatedServerArtifact -TargetId 'Forge@1.2.4' -MinecraftId '1.2.5' -ArtifactPath $script:officialServerPath).status | Should -BeExactly 'TargetIdentityMismatch'
        (Resolve-MmtlHistoricalDedicatedServerArtifact -TargetId 'Forge@1.2.4' -MinecraftId '1.2.4' -ArtifactPath $script:officialServerPath).status | Should -BeExactly 'OfficialServerEntryAbsent'
    }

    It 'fails closed for missing or altered local artifacts without downloading or executing them' {
        (Resolve-MmtlHistoricalDedicatedServerArtifact -TargetId 'Forge@1.2.5' -MinecraftId '1.2.5' -ArtifactPath (Join-Path $TestDrive 'missing-server.jar')).status | Should -BeExactly 'LocalArtifactMissing'

        $altered = Join-Path $TestDrive 'altered-server.jar'
        [IO.File]::WriteAllBytes($altered, [byte[]]@(0, 1, 2, 3, 4))
        $result = Resolve-MmtlHistoricalDedicatedServerArtifact -TargetId 'Forge@1.2.5' -MinecraftId '1.2.5' -ArtifactPath $altered
        $result.status | Should -BeExactly 'ArtifactHashMismatch'
        $result.automaticDownloadAllowed | Should -BeFalse
        $result.automaticExecutionAllowed | Should -BeFalse
    }
}
