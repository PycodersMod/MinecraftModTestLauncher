BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repoRoot 'common/src/Validation/TargetIdentity.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'common/src/Validation/ValidationMatrixChunks.psm1') -Force
    $script:universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
    $script:ledger = Get-Content (Join-Path $script:repoRoot 'compatibility/ledger-template.json') -Raw | ConvertFrom-Json
    $script:families = Get-Content (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
}

Describe 'Loader version candidate normalization' {
    It 'writes exact loader versions for structured official archive candidates into matrix chunks' {
        $manifest = New-MmtlValidationMatrixChunks -Ledger $script:ledger -Universe $script:universe -FamilyManifest $script:families -ChunkSize 64
        foreach ($targetId in @('ModLoader@1.0.0','Rift@1.13')) {
            $sourceTarget = @($script:universe.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1)[0]
            $chunkTarget = @($manifest.chunks.targets | Where-Object targetId -CEQ $targetId | Select-Object -First 1)[0]
            $expected = @($sourceTarget.loaderVersionCandidates | ForEach-Object {
                if ($_ -is [string]) { [string]$_ } elseif ($_.PSObject.Properties['loaderVersion']) { [string]$_.loaderVersion } else { [string]$_.version }
            })

            @($chunkTarget.loaderVersionCandidates).Count | Should -Be $expected.Count
            for ($index = 0; $index -lt $expected.Count; $index++) {
                $chunkTarget.loaderVersionCandidates[$index] | Should -BeExactly $expected[$index]
            }
        }
    }
}
