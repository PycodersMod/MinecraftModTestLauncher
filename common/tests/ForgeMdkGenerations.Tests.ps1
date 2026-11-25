BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:universe = Get-Content (Join-Path $script:repoRoot 'compatibility/universe-preview.json') -Raw | ConvertFrom-Json
    $script:catalogPath = Join-Path $script:repoRoot 'compatibility/forge-mdk-generations.json'
    $script:schemaPath = Join-Path $script:repoRoot 'common/schemas/forge-mdk-generations.schema.json'
}

Describe 'Frozen Forge canonical MDK generation evidence' {
    It 'records Forge 1.8 active stable Plugins DSL version instead of its commented Snapshot fallback' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $row = @($catalog.targets | Where-Object targetId -CEQ 'Forge@1.8')

        $row.Count | Should -Be 1
        $row[0].forgeGradleSpec | Should -BeExactly '2.0.2'
    }

    It 'covers every available Forge exact target once and binds the first frozen candidate' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $expected = @($script:universe.targets | Where-Object { $_.loaderId -ceq 'Forge' -and $_.availability -ceq 'Available' } | Sort-Object targetId | ForEach-Object targetId)
        $actual = @($catalog.targets | Sort-Object targetId | ForEach-Object targetId)

        $catalog.universeHash | Should -BeExactly $script:universe.catalogHash
        $catalog.targetCount | Should -Be 76
        $core = [pscustomobject][ordered]@{schemaVersion=[int]$catalog.schemaVersion;generatedAt=[string]$catalog.generatedAt;auditStatus=[string]$catalog.auditStatus;universeHash=[string]$catalog.universeHash;targetCount=[int]$catalog.targetCount;targets=@($catalog.targets)}
        $expectedCatalogHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 20 -Compress)))).ToLowerInvariant()
        $catalog.catalogHash | Should -BeExactly $expectedCatalogHash
        $actual | Should -Be $expected
        @($actual | Select-Object -Unique).Count | Should -Be $actual.Count
        foreach ($row in $catalog.targets) {
            $target = @($script:universe.targets | Where-Object targetId -CEQ $row.targetId)
            $target.Count | Should -Be 1
            $row.minecraftId | Should -BeExactly $target[0].minecraftId
            $row.sourceHash | Should -BeExactly $target[0].sourceHash
            $row.candidateSourceHash | Should -BeExactly $target[0].candidateSourceHash
            $row.forgeCoordinate | Should -BeExactly $target[0].loaderVersionCandidates[0]
            $row.mdkUrl | Should -BeExactly "https://maven.minecraftforge.net/net/minecraftforge/forge/$($row.forgeCoordinate)/forge-$($row.forgeCoordinate)-mdk.zip"
        }
    }

    It 'records hashes and declared toolchain metadata for downloadable official MDKs' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $json = ConvertTo-Json -InputObject $catalog -Depth 20
        Test-Json -Json $json -SchemaFile $script:schemaPath | Should -BeTrue
        $available = @($catalog.targets | Where-Object status -CEQ 'Available')

        $available.Count | Should -Be 55
        foreach ($row in $available) {
            $row.httpStatus | Should -Be 200
            $row.archiveSha256 | Should -Match '^[a-f0-9]{64}$'
            $row.buildGradleSha256 | Should -Match '^[a-f0-9]{64}$'
            $row.forgeGradleSpec | Should -Not -BeNullOrEmpty
            $row.gradleDistributionUrl | Should -Match '^https://services\.gradle\.org/distributions/'
        }
        @($available | Where-Object { $_.forgeGradleSpec -match '^(?:2\.|3\.)' }).Count | Should -Be 23
        @($available | Where-Object { $_.forgeGradleSpec -match '^5\.' }).Count | Should -Be 6
        @($available | Where-Object { $_.forgeGradleSpec -match '^\[6\.' }).Count | Should -Be 21
        @($available | Where-Object { $_.forgeGradleSpec -match '^\[7\.' }).Count | Should -Be 5
    }

    It 'records official source archive alternatives for every canonical MDK miss' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $families = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/families.json') -Raw | ConvertFrom-Json
        $missing = @($catalog.targets | Where-Object status -CEQ 'CanonicalCandidateMdkUnavailable')
        $sourceFamilies = @($families.families | Where-Object{$_.familyId -like 'forge-gradle-source-*' -or $_.familyId -ceq 'forge-legacy-source-overlay-v1'})

        $catalog.auditStatus | Should -BeExactly 'PARTIAL'
        $missing.Count | Should -Be 21
        foreach ($row in $missing) {
            $row.httpStatus | Should -Be 404
            $row.alternateSourceUrl | Should -BeExactly "https://maven.minecraftforge.net/net/minecraftforge/forge/$($row.forgeCoordinate)/forge-$($row.forgeCoordinate)-src.zip"
            $row.alternateSourceHttpStatus | Should -Be 200
            $row.alternateArchiveSha256 | Should -Match '^[a-f0-9]{64}$'
            $row.alternateArchiveBytes | Should -BeGreaterThan 0
            $row.sourceProjectType | Should -BeIn @('GradleProject','ForgeSourceOverlay')
        }
        @($missing | Where-Object sourceProjectType -CEQ 'GradleProject').Count | Should -Be 2
        @($missing | Where-Object sourceProjectType -CEQ 'ForgeSourceOverlay').Count | Should -Be 19
        @($missing | Where-Object {$_.sourceProjectType -ceq 'ForgeSourceOverlay' -and ($_.alternateBuildGradleSha256 -or $_.alternateGradleDistributionUrl -or $_.alternateForgeGradleSpec)}).Count | Should -Be 0
        @($sourceFamilies|Where-Object familyId -like 'forge-gradle-source-*').Count | Should -Be 2
        @($sourceFamilies|Where-Object familyId -CEQ 'forge-legacy-source-overlay-v1').Count | Should -Be 1
        foreach($row in $missing){
            $minecraftId=([string]$row.targetId -split '@',2)[1]
            $sourceFamily=@($sourceFamilies|Where-Object{$_.minecraftIds -contains $minecraftId})
            $sourceFamily.Count | Should -Be 1
            $sourceFamily[0].evidence | Should -Contain "forge-mdk-catalog-sha256:$($catalog.catalogHash)"
            $sourceFamily[0].evidence | Should -Contain "forge-source-archive-target:$($row.targetId):coordinate=$($row.forgeCoordinate);archive-sha256=$($row.alternateArchiveSha256);type=$($row.sourceProjectType);build-gradle-sha256=$($row.alternateBuildGradleSha256);spec=$($row.alternateForgeGradleSpec);wrapper=$($row.alternateGradleDistributionUrl);build-java=$($row.alternateBuildJavaMajor)"
        }
    }
}
