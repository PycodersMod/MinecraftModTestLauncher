BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $modulePath = Join-Path $repoRoot 'common/src/Compatibility/HistoricalMcpArtifactMetadata.psm1'
    if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force }

    $script:metadataRoot = Join-Path $TestDrive 'metadata'
    New-Item -ItemType Directory -Path $script:metadataRoot -Force | Out-Null
    $script:goodSnapshot = [ordered]@{
        id = '1.5.2'
        downloads = [ordered]@{
            client = [ordered]@{ url = 'https://launcher.mojang.com/client.jar'; sha1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
            server = [ordered]@{ url = 'https://launcher.mojang.com/server.jar'; sha1 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    $script:retroServerWithoutOfficialSnapshot = [ordered]@{
        id = '1.1'
        downloads = [ordered]@{
            client = [ordered]@{ url = 'https://launcher.mojang.com/client.jar'; sha1 = 'cccccccccccccccccccccccccccccccccccccccc' }
            server = [ordered]@{ url = 'https://vault.omniarchive.uk/archive/java/server-release/1.1/1.1.jar'; sha1 = '3333333333333333333333333333333333333333' }
        }
    } | ConvertTo-Json -Depth 8 -Compress
    Set-Content -LiteralPath (Join-Path $script:metadataRoot '1.5.2.json') -Value $script:goodSnapshot -NoNewline -Encoding utf8
    Set-Content -LiteralPath (Join-Path $script:metadataRoot '1.1.json') -Value $script:retroServerWithoutOfficialSnapshot -NoNewline -Encoding utf8
}

Describe 'Historical MCP downstream artifact metadata' {
    It 'distinguishes an absent official server entry from a hash mismatch' {
        $snapshotPath = Join-Path $script:metadataRoot '1.1.json'
        $hash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $catalog = [pscustomobject]@{
            schemaVersion = 1
            universeHash = 'c15c01a750f74971a1b322cd3d5c2366a2ac05394a3ad56563fde0f75764241c'
            automaticDownloadAllowed = $false
            automaticExecutionAllowed = $false
            entries = @([pscustomobject]@{
                minecraftId = '1.1'
                sourceUrl = 'https://mcphackers.org/BetterJSONs/jsons/1.1.json'
                snapshotPath = '1.1.json'
                snapshotSha256 = $hash
                snapshotByteLength = (Get-Item -LiteralPath $snapshotPath).Length
                officialMetadataUrl = 'https://piston-meta.mojang.com/v1/packages/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.1.json'
                officialMetadataSha256 = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
                clientComparison = [pscustomobject]@{ status = 'Match'; officialSha1 = 'cccccccccccccccccccccccccccccccccccccccc' }
                serverComparison = [pscustomobject]@{ status = 'OfficialEntryAbsent'; officialSha1 = $null }
            })
        }

        $result = Resolve-MmtlHistoricalMcpArtifactMetadata -Catalog $catalog -MinecraftId '1.1' -SnapshotRoot $script:metadataRoot

        $result.status | Should -BeExactly 'MetadataReviewed'
        $result.serverComparisonStatus | Should -BeExactly 'OfficialEntryAbsent'
        $result.automaticDownloadAllowed | Should -BeFalse
        $result.automaticExecutionAllowed | Should -BeFalse
    }

    It 'keeps a client artifact hash conflict unresolved' {
        $snapshotPath = Join-Path $script:metadataRoot '1.5.2.json'
        $hash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $catalog = [pscustomobject]@{
            schemaVersion = 1
            universeHash = 'c15c01a750f74971a1b322cd3d5c2366a2ac05394a3ad56563fde0f75764241c'
            automaticDownloadAllowed = $false
            automaticExecutionAllowed = $false
            entries = @([pscustomobject]@{
                minecraftId = '1.5.2'
                sourceUrl = 'https://mcphackers.org/BetterJSONs/jsons/1.5.2.json'
                snapshotPath = '1.5.2.json'
                snapshotSha256 = $hash
                snapshotByteLength = (Get-Item -LiteralPath $snapshotPath).Length
                officialMetadataUrl = 'https://piston-meta.mojang.com/v1/packages/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.5.2.json'
                officialMetadataSha256 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
                clientComparison = [pscustomobject]@{ status = 'Mismatch'; officialSha1 = 'ffffffffffffffffffffffffffffffffffffffff' }
                serverComparison = [pscustomobject]@{ status = 'Match'; officialSha1 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
            })
        }

        $result = Resolve-MmtlHistoricalMcpArtifactMetadata -Catalog $catalog -MinecraftId '1.5.2' -SnapshotRoot $script:metadataRoot

        $result.status | Should -BeExactly 'ArtifactMetadataConflict'
        $result.clientComparisonStatus | Should -BeExactly 'Mismatch'
        $result.automaticDownloadAllowed | Should -BeFalse
        $result.automaticExecutionAllowed | Should -BeFalse
    }

    It 'rejects snapshots whose bytes no longer match the frozen digest' {
        $snapshotPath = Join-Path $script:metadataRoot '1.5.2.json'
        $catalog = [pscustomobject]@{
            schemaVersion = 1
            universeHash = 'c15c01a750f74971a1b322cd3d5c2366a2ac05394a3ad56563fde0f75764241c'
            automaticDownloadAllowed = $false
            automaticExecutionAllowed = $false
            entries = @([pscustomobject]@{
                minecraftId = '1.5.2'
                sourceUrl = 'https://mcphackers.org/BetterJSONs/jsons/1.5.2.json'
                snapshotPath = '1.5.2.json'
                snapshotSha256 = ('0' * 64)
                snapshotByteLength = (Get-Item -LiteralPath $snapshotPath).Length
                officialMetadataUrl = 'https://piston-meta.mojang.com/v1/packages/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.5.2.json'
                officialMetadataSha256 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
                clientComparison = [pscustomobject]@{ status = 'Match'; officialSha1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
                serverComparison = [pscustomobject]@{ status = 'Match'; officialSha1 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
            })
        }

        $validation = Test-MmtlHistoricalMcpArtifactMetadataCatalog -Catalog $catalog -SnapshotRoot $script:metadataRoot

        $validation.isValid | Should -BeFalse
        $validation.errors | Should -Contain 'MCP_ARTIFACT_SNAPSHOT_HASH_MISMATCH:1.5.2'

        $pathTraversal = $catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $pathTraversal.entries[0].snapshotPath = '../1.5.2.json'
        $pathValidation = Test-MmtlHistoricalMcpArtifactMetadataCatalog -Catalog $pathTraversal -SnapshotRoot $script:metadataRoot
        $pathValidation.isValid | Should -BeFalse
        $pathValidation.errors | Should -Contain 'MCP_ARTIFACT_SNAPSHOT_PATH_INVALID:1.5.2'
    }

    It 'rejects metadata artifact URLs outside the audited Mojang and Omniarchive hosts' {
        $metadata = $script:goodSnapshot | ConvertFrom-Json
        $metadata.downloads.client.url = 'https://untrusted.example/client.jar'
        $snapshotPath = Join-Path $script:metadataRoot 'untrusted-host.json'
        $snapshotText = $metadata | ConvertTo-Json -Depth 8 -Compress
        Set-Content -LiteralPath $snapshotPath -Value $snapshotText -NoNewline -Encoding utf8
        $catalog = [pscustomobject]@{
            schemaVersion = 1
            universeHash = 'c15c01a750f74971a1b322cd3d5c2366a2ac05394a3ad56563fde0f75764241c'
            automaticDownloadAllowed = $false
            automaticExecutionAllowed = $false
            entries = @([pscustomobject]@{
                minecraftId = '1.5.2'
                sourceUrl = 'https://mcphackers.org/BetterJSONs/jsons/1.5.2.json'
                snapshotPath = 'untrusted-host.json'
                snapshotSha256 = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
                snapshotByteLength = (Get-Item -LiteralPath $snapshotPath).Length
                officialMetadataUrl = 'https://piston-meta.mojang.com/v1/packages/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.5.2.json'
                officialMetadataSha256 = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
                clientComparison = [pscustomobject]@{ status = 'Match'; officialSha1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
                serverComparison = [pscustomobject]@{ status = 'Match'; officialSha1 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
            })
        }

        $validation = Test-MmtlHistoricalMcpArtifactMetadataCatalog -Catalog $catalog -SnapshotRoot $script:metadataRoot

        $validation.isValid | Should -BeFalse
        $validation.errors | Should -Contain 'MCP_ARTIFACT_HOST_NOT_ALLOWED:client:1.5.2'
    }

    It 'validates every frozen candidate version and leaves b1.2_02 conflicted' {
        $catalogPath = Join-Path $repoRoot 'compatibility/historical-mcp-artifact-metadata-catalog.json'
        $snapshotRoot = Join-Path $repoRoot 'compatibility/snapshots/HistoricalMcp'
        $backendPath = Join-Path $repoRoot 'compatibility/mcp-backend-catalog.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
        $backend = Get-Content -LiteralPath $backendPath -Raw | ConvertFrom-Json

        $validation = Test-MmtlHistoricalMcpArtifactMetadataCatalog -Catalog $catalog -SnapshotRoot $snapshotRoot
        $candidateIds = @($backend.targetPairs | ForEach-Object { [string]$_.minecraftId } | Sort-Object -Unique)
        $metadataIds = @($catalog.entries | ForEach-Object { [string]$_.minecraftId } | Sort-Object -Unique)
        $conflicted = Resolve-MmtlHistoricalMcpArtifactMetadata -Catalog $catalog -MinecraftId 'b1.2_02' -SnapshotRoot $snapshotRoot
        $unverifiedServer = Resolve-MmtlHistoricalMcpArtifactMetadata -Catalog $catalog -MinecraftId '1.1' -SnapshotRoot $snapshotRoot
        $exactCandidate = Resolve-MmtlHistoricalMcpCandidate -BackendCatalog $backend -ArtifactCatalog $catalog -LoaderId 'ModLoader' -MinecraftId '1.5.2' -SnapshotRoot $snapshotRoot
        $crossLoaderCandidate = Resolve-MmtlHistoricalMcpCandidate -BackendCatalog $backend -ArtifactCatalog $catalog -LoaderId 'ModLoaderMP' -MinecraftId '1.5.2' -SnapshotRoot $snapshotRoot
        $mislinkedOfficialCatalog = $catalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        ($mislinkedOfficialCatalog.entries | Where-Object minecraftId -eq '1.5.2').officialMetadataUrl = 'https://piston-meta.mojang.com/v1/packages/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.5.3.json'
        $mislinkedOfficialValidation = Test-MmtlHistoricalMcpArtifactMetadataCatalog -Catalog $mislinkedOfficialCatalog -SnapshotRoot $snapshotRoot

        $validation.isValid | Should -BeTrue -Because ($validation.errors -join ',')
        $catalog.entries.Count | Should -Be 23
        (Compare-Object -ReferenceObject $candidateIds -DifferenceObject $metadataIds).Count | Should -Be 0
        $conflicted.status | Should -BeExactly 'ArtifactMetadataConflict'
        $conflicted.clientComparisonStatus | Should -BeExactly 'Mismatch'
        $unverifiedServer.status | Should -BeExactly 'MetadataReviewed'
        $unverifiedServer.serverComparisonStatus | Should -BeExactly 'OfficialEntryAbsent'
        $exactCandidate.status | Should -BeExactly 'CandidateMetadataReviewed'
        $exactCandidate.targetId | Should -BeExactly 'ModLoader@1.5.2'
        $crossLoaderCandidate.status | Should -BeExactly 'NoBackendCandidate'
        $crossLoaderCandidate.targetId | Should -BeExactly 'ModLoaderMP@1.5.2'
        $mislinkedOfficialValidation.isValid | Should -BeFalse
        $mislinkedOfficialValidation.errors | Should -Contain 'MCP_ARTIFACT_OFFICIAL_SOURCE_URL_INVALID:1.5.2'
    }
}
