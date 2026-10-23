BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Catalog/MojangMetadataBatchPlanner.psm1') -Force
}

Describe 'Mojang metadata download batching' {
    It 'plans every target when the cache is empty' {
        $entries = @([pscustomobject]@{ id = '1.0' }, [pscustomobject]@{ id = '1.1' })

        $batches = @(Get-MmtlMojangMetadataDownloadBatches -Entries $entries -AvailableIds @() -MaxConcurrency 4)

        @($batches | ForEach-Object { $_.entries } | ForEach-Object { $_.id }) | Should -Be @('1.0', '1.1')
    }

    It 'skips cached IDs and emits every missing ID exactly once in bounded batches' {
        $entries = @(
            [pscustomobject]@{ id = '1.0' }, [pscustomobject]@{ id = '1.1' },
            [pscustomobject]@{ id = '1.2' }, [pscustomobject]@{ id = '1.3' },
            [pscustomobject]@{ id = '1.4' }, [pscustomobject]@{ id = '1.5' }
        )

        $batches = @(Get-MmtlMojangMetadataDownloadBatches -Entries $entries -AvailableIds @('1.1', '1.4') -MaxConcurrency 2)

        $batches.Count | Should -Be 2
        @($batches | ForEach-Object { @($_.entries).Count } | Sort-Object -Unique) | Should -Be @(2)
        $ids = @($batches | ForEach-Object { $_.entries } | ForEach-Object { $_.id })
        $ids | Should -Be @('1.0', '1.2', '1.3', '1.5')
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }
}
