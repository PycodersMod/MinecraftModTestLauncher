BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
    $script:ledger = Get-Content (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -Raw | ConvertFrom-Json
    $script:families = Get-Content (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
    Import-Module (Join-Path $script:repoRoot 'common/src/Validation/ValidationMatrixChunks.psm1') -Force
}

Describe 'Frozen compatibility matrix chunks' {
    It 'includes every exact Available target exactly once in bounded family chunks' {
        $chunkSize = 37
        $manifest = New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize $chunkSize
        $actual = @($manifest.chunks | ForEach-Object { $_.targets } | ForEach-Object targetId | Sort-Object -CaseSensitive)
        $expected = @($script:universe.targets | Where-Object availability -CEQ 'Available' | ForEach-Object targetId | Sort-Object -CaseSensitive)

        $manifest.targetCount | Should -Be $expected.Count
        $manifest.chunkCount | Should -Be $manifest.chunks.Count
        $actual | Should -Be $expected
        @($actual | Select-Object -Unique).Count | Should -Be $actual.Count
        @($manifest.chunks | Where-Object targetCount -GT $chunkSize).Count | Should -Be 0
        foreach ($chunk in $manifest.chunks) {
            foreach ($target in $chunk.targets) {
                $sourceRow = @($script:ledger.targets | Where-Object targetId -CEQ $target.targetId)
                $sourceRow.Count | Should -Be 1
                $chunk.loaderId | Should -BeExactly $sourceRow[0].loaderId
                $chunk.familyId | Should -BeExactly $sourceRow[0].familyId
            }
        }
    }

    It 'creates identical chunk IDs and hashes for identical frozen inputs' {
        $first = New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 64
        $second = New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 64

        @($first.chunks | ForEach-Object { "$($_.chunkId):$($_.chunkHash)" }) | Should -Be @($second.chunks | ForEach-Object { "$($_.chunkId):$($_.chunkHash)" })
        $first.universeHash | Should -BeExactly $script:universe.catalogHash
        $first.manifestHash | Should -BeExactly $second.manifestHash
    }

    It 'verifies the complete chunk manifest against the frozen inputs' {
        $manifest = New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 100

        (Test-MmtlValidationMatrixChunkManifest -Manifest $manifest -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families).isValid | Should -BeTrue
    }

    It 'rejects a chunk manifest with modified family metadata' {
        $manifest = New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 100
        $tampered = $manifest | ConvertTo-Json -Depth 40 | ConvertFrom-Json
        $tampered.chunks[0].familyId = 'Fabric'

        $validation = Test-MmtlValidationMatrixChunkManifest -Manifest $tampered -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families
        $validation.isValid | Should -BeFalse
        $validation.errors | Should -Contain 'VALIDATION_MATRIX_CHUNK_MANIFEST_MISMATCH'
    }

    It 'rejects a non-positive chunk size' {
        { New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 0 } | Should -Throw '*CHUNK_SIZE_INVALID*'
    }

    It 'rejects a ledger that omits an available exact target' {
        $tampered = $script:ledger | ConvertTo-Json -Depth 60 | ConvertFrom-Json
        $tampered.targets = @($tampered.targets | Select-Object -Skip 1)

        { New-MmtlValidationMatrixChunks -Ledger $tampered -Universe $script:universe -FamilyManifest $script:families -ChunkSize 50 } | Should -Throw
    }

    It 'writes a reusable full-universe chunk manifest from the repository inputs' {
        $outputPath = Join-Path $TestDrive 'matrix-chunks.json'
        $scriptPath = Join-Path $script:repoRoot 'tools/New-CompatibilityMatrixChunks.ps1'

        $summary = & $scriptPath -ChunkSize 75 -OutputPath $outputPath
        $written = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

        $summary.targetCount | Should -Be 1631
        $written.targetCount | Should -Be 1631
        $written.chunkSize | Should -Be 75
        @($written.chunks | ForEach-Object targets | ForEach-Object targetId | Select-Object -Unique).Count | Should -Be 1631
    }
}
