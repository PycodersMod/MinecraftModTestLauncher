BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:modulePath = Join-Path $script:repoRoot 'common/src/Compatibility/LiteLoaderArtifactCatalog.psm1'
    $script:universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
    $script:catalogPath = Join-Path $script:repoRoot 'compatibility/liteloader-artifact-pins.json'
    if (Test-Path -LiteralPath $script:modulePath) { Import-Module $script:modulePath -Force }
}

Describe 'LiteLoader exact artifact pins' {
    It 'resolves only frozen exact target artifact pins over HTTPS' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $pin = Get-MmtlLiteLoaderArtifactPin -TargetId 'LiteLoader@1.7.10' -Universe $script:universe -Catalog $catalog

        $pin.targetId | Should -BeExactly 'LiteLoader@1.7.10'
        $pin.loaderVersion | Should -BeExactly '1.7.10_04'
        ([uri]$pin.artifactUrl).Scheme | Should -BeExactly 'https'
        $pin.sourceSha256 | Should -BeExactly '778a68d6c54bfe73f89204b0306cb004c04bcb8054dbbdaad861969f37210489'
        $pin.sha256 | Should -Match '^[a-f0-9]{64}$'
        @($catalog.pins).Count | Should -Be 6
        foreach ($catalogPin in $catalog.pins) {
            $resolved = Get-MmtlLiteLoaderArtifactPin -TargetId ([string]$catalogPin.targetId) -Universe $script:universe -Catalog $catalog
            $resolved.sha256 | Should -BeExactly ([string]$catalogPin.sha256)
        }
    }

    It 'does not infer pins for exact targets whose upstream bytes failed the frozen checksum' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        { Get-MmtlLiteLoaderArtifactPin -TargetId 'LiteLoader@1.10.2' -Universe $script:universe -Catalog $catalog } | Should -Throw '*LITELOADER_ARTIFACT_PIN_NOT_FOUND*'
    }

    It 'rejects an artifact file unless SHA-256, MD5 and byte length all match the pin' {
        $path = Join-Path $TestDrive 'liteloader.jar'
        [IO.File]::WriteAllBytes($path, [byte[]](1,2,3,4,5))
        $pin = [pscustomobject]@{
            sha256 = '74f81fe167d99b4cb41d6d0ccda82278caee9f3e2f7b6f5c9a80f8d1e9e1d32f'
            officialMd5 = '7cfdd07889b3295d6a550914ab35e068'
            bytes = 5
        }
        { Test-MmtlLiteLoaderArtifactFile -Path $path -Pin $pin } | Should -Throw '*LITELOADER_ARTIFACT_SHA256_MISMATCH*'
        $pin.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        (Test-MmtlLiteLoaderArtifactFile -Path $path -Pin $pin) | Should -BeTrue
    }
}
