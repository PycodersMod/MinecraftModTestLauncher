BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Catalog/MojangRuntimeJavaSnapshots.psm1'
    Import-Module $modulePath -Force
}

Describe 'Mojang runtime Java snapshot index recovery' {
    It 'rebuilds an exact source-index record from catalog provenance and verified snapshot bytes' {
        $snapshotRoot = Join-Path $TestDrive 'snapshots'
        $minecraftId = '1.20.1'
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"id":"1.20.1","javaVersion":{"majorVersion":17}}')
        $sha1 = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $directory = Join-Path $snapshotRoot 'MojangVersions'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $directory "$sha256.bin"), $bytes)
        $catalog = [pscustomobject]@{ entries = @([pscustomobject]@{
            minecraftId = $minecraftId
            metadataSource = [pscustomobject]@{
                url = "https://piston-meta.mojang.com/v1/packages/$sha1/$minecraftId.json"
                manifestSha1 = $sha1
                sourceSha1 = $sha1
                snapshotSha256 = $sha256
                retrievedAt = '2026-10-07T06:05:13.3023113Z'
            }
        }) }

        $records = @(Get-MmtlMojangVersionSnapshotIndexRecords -Catalog $catalog -SnapshotRoot $snapshotRoot)

        $records | Should -HaveCount 1
        $records[0].providerId | Should -BeExactly 'MojangVersion'
        $records[0].minecraftId | Should -BeExactly $minecraftId
        $records[0].relativePath | Should -Be "MojangVersions/$sha256.bin"
        $records[0].manifestSha1 | Should -BeExactly $sha1
        $records[0].sha256 | Should -BeExactly $sha256
        $records[0].byteLength | Should -Be $bytes.Length
    }

    It 'rejects a catalog record when exact version identity or content hashes do not match' {
        $snapshotRoot = Join-Path $TestDrive 'tampered-snapshots'
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"id":"1.20.1"}')
        $sha1 = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $directory = Join-Path $snapshotRoot 'MojangVersions'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $directory "$sha256.bin"), $bytes)
        $catalog = [pscustomobject]@{ entries = @([pscustomobject]@{
            minecraftId = '1.20.2'
            metadataSource = [pscustomobject]@{
                url = "https://piston-meta.mojang.com/v1/packages/$sha1/1.20.2.json"
                manifestSha1 = $sha1
                sourceSha1 = $sha1
                snapshotSha256 = $sha256
                retrievedAt = '2026-10-07T06:05:13.3023113Z'
            }
        }) }

        { Get-MmtlMojangVersionSnapshotIndexRecords -Catalog $catalog -SnapshotRoot $snapshotRoot } | Should -Throw '*MOJANG_VERSION_METADATA_ID_MISMATCH*'
    }

    It 'preserves Mojang exact version IDs containing spaces from percent-encoded source URLs' {
        $snapshotRoot = Join-Path $TestDrive 'space-id-snapshots'
        $minecraftId = '1.14 Pre-Release 1'
        $bytes = [Text.Encoding]::UTF8.GetBytes('{"id":"1.14 Pre-Release 1"}')
        $sha1 = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $directory = Join-Path $snapshotRoot 'MojangVersions'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $directory "$sha256.bin"), $bytes)
        $encodedId = [Uri]::EscapeDataString($minecraftId)
        $catalog = [pscustomobject]@{ entries = @([pscustomobject]@{
            minecraftId = $minecraftId
            metadataSource = [pscustomobject]@{
                url = "https://piston-meta.mojang.com/v1/packages/$sha1/$encodedId.json"
                manifestSha1 = $sha1; sourceSha1 = $sha1; snapshotSha256 = $sha256
                retrievedAt = '2026-10-07T06:05:13.3023113Z'
            }
        }) }

        $records = @(Get-MmtlMojangVersionSnapshotIndexRecords -Catalog $catalog -SnapshotRoot $snapshotRoot)

        $records | Should -HaveCount 1
        $records[0].minecraftId | Should -BeExactly $minecraftId
    }
}
