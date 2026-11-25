BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $modulePath = Join-Path $repoRoot 'common/src/Compatibility/HistoricalJarOverlay.psm1'
    if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:root = Join-Path $TestDrive 'overlay'
    New-Item -ItemType Directory -Path $script:root -Force | Out-Null
    $script:baseJar = Join-Path $script:root 'client.jar'
    $script:zipPath = Join-Path $script:root 'loader.zip'

    function New-TestZip([string]$Path, [hashtable]$Entries) {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
        try {
            $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                foreach ($key in $Entries.Keys) {
                    $entry = $archive.CreateEntry([string]$key)
                    $entryStream = $entry.Open()
                    try {
                        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Entries[$key])
                        $entryStream.Write($bytes, 0, $bytes.Length)
                    } finally { $entryStream.Dispose() }
                }
            } finally { $archive.Dispose() }
        } finally { $stream.Dispose() }
    }

    New-TestZip $script:baseJar @{ 'net/minecraft/Base.class' = 'vanilla'; 'keep.txt' = 'keep' }
    New-TestZip $script:zipPath @{ 'net/minecraft/Base.class' = 'patched'; 'mod/Loader.class' = 'new' }
    $script:baseSha1 = (Get-FileHash -LiteralPath $script:baseJar -Algorithm SHA1).Hash.ToLowerInvariant()
    $script:artifactSha = (Get-FileHash -LiteralPath $script:zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:candidateCatalog = [pscustomobject]@{ loaderId='ModLoader'; results=@([pscustomobject]@{ targetId='ModLoader@1.5.2'; minecraftId='1.5.2'; candidateStatus='Resolved'; candidates=@([pscustomobject]@{ loaderId='ModLoader'; minecraftId='1.5.2'; artifactType='ClientZip'; artifactFormat='ZIP'; hashAlgorithm='SHA256'; sha256=$script:artifactSha }) }) }
    $script:metadataCatalog = [pscustomobject]@{ entries=@([pscustomobject]@{ minecraftId='1.5.2'; clientComparison=[pscustomobject]@{ status='Match'; officialSha1=$script:baseSha1 } }) }
}

Describe 'Historical client JAR overlay staging' {
    It 'overlays only exact-target class entries and writes non-executable evidence' {
        $output = Join-Path $script:root 'staged.jar'
        $evidence = Join-Path $script:root 'evidence.json'
        $result = New-MmtlHistoricalJarOverlay -LoaderId ModLoader -MinecraftId '1.5.2' -BaseClientJar $script:baseJar -OverlayArchive $script:zipPath -OutputPath $output -EvidencePath $evidence -CandidateCatalog $script:candidateCatalog -MetadataCatalog $script:metadataCatalog

        $result.status | Should -BeExactly 'Staged'
        $result.replacedClassCount | Should -Be 1
        $result.addedClassCount | Should -Be 1
        $result.executionPerformed | Should -BeFalse
        (Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $result.outputSha256
        $resultJson = Get-Content $evidence -Raw | ConvertFrom-Json
        $resultJson.executionPerformed | Should -BeFalse
        $resultJson.buildPlanSupported | Should -BeFalse
        $resultJson.runtimeSupported | Should -BeFalse
    }

    It 'rejects an artifact whose bytes do not match the exact target candidate hash' {
        $wrong = [pscustomobject]@{ loaderId='ModLoader'; results=@([pscustomobject]@{ targetId='ModLoader@1.5.2'; minecraftId='1.5.2'; candidateStatus='Resolved'; candidates=@([pscustomobject]@{ loaderId='ModLoader'; minecraftId='1.5.2'; artifactType='ClientZip'; artifactFormat='ZIP'; hashAlgorithm='SHA256'; sha256=('0' * 64) }) }) }
        { New-MmtlHistoricalJarOverlay -LoaderId ModLoader -MinecraftId '1.5.2' -BaseClientJar $script:baseJar -OverlayArchive $script:zipPath -OutputPath (Join-Path $script:root 'bad.jar') -EvidencePath (Join-Path $script:root 'bad.json') -CandidateCatalog $wrong -MetadataCatalog $script:metadataCatalog } | Should -Throw '*CANDIDATE_HASH_MISMATCH*'
    }

    It 'produces the same output hash for repeated staging of identical inputs' {
        $outputOne = Join-Path $script:root 'repeat-one.jar'
        $outputTwo = Join-Path $script:root 'repeat-two.jar'
        $evidenceOne = Join-Path $script:root 'repeat-one.json'
        $evidenceTwo = Join-Path $script:root 'repeat-two.json'
        $first = New-MmtlHistoricalJarOverlay -LoaderId ModLoader -MinecraftId '1.5.2' -BaseClientJar $script:baseJar -OverlayArchive $script:zipPath -OutputPath $outputOne -EvidencePath $evidenceOne -CandidateCatalog $script:candidateCatalog -MetadataCatalog $script:metadataCatalog
        $second = New-MmtlHistoricalJarOverlay -LoaderId ModLoader -MinecraftId '1.5.2' -BaseClientJar $script:baseJar -OverlayArchive $script:zipPath -OutputPath $outputTwo -EvidencePath $evidenceTwo -CandidateCatalog $script:candidateCatalog -MetadataCatalog $script:metadataCatalog

        $first.outputSha256 | Should -BeExactly $second.outputSha256
    }

    It 'rejects an overlay archive containing traversal paths and leaves no output' {
        $unsafe = Join-Path $script:root 'unsafe.zip'
        New-TestZip $unsafe @{ '../escape.class'='bad' }
        $hash = (Get-FileHash $unsafe -Algorithm SHA256).Hash.ToLowerInvariant()
        $catalog = [pscustomobject]@{ loaderId='ModLoader'; results=@([pscustomobject]@{ targetId='ModLoader@1.5.2'; minecraftId='1.5.2'; candidateStatus='Resolved'; candidates=@([pscustomobject]@{ loaderId='ModLoader'; minecraftId='1.5.2'; artifactType='ClientZip'; artifactFormat='ZIP'; hashAlgorithm='SHA256'; sha256=$hash }) }) }
        $output = Join-Path $script:root 'unsafe-out.jar'
        { New-MmtlHistoricalJarOverlay -LoaderId ModLoader -MinecraftId '1.5.2' -BaseClientJar $script:baseJar -OverlayArchive $unsafe -OutputPath $output -EvidencePath (Join-Path $script:root 'unsafe.json') -CandidateCatalog $catalog -MetadataCatalog $script:metadataCatalog } | Should -Throw '*UNSAFE_ARCHIVE_ENTRY*'
        Test-Path $output | Should -BeFalse
    }

    It 'rejects a base client JAR that does not match frozen official metadata' {
        $metadata = [pscustomobject]@{ entries=@([pscustomobject]@{ minecraftId='1.5.2'; clientComparison=[pscustomobject]@{ status='Match'; officialSha1=('f' * 40) } }) }
        { New-MmtlHistoricalJarOverlay -LoaderId ModLoader -MinecraftId '1.5.2' -BaseClientJar $script:baseJar -OverlayArchive $script:zipPath -OutputPath (Join-Path $script:root 'wrong-client.jar') -EvidencePath (Join-Path $script:root 'wrong-client.json') -CandidateCatalog $script:candidateCatalog -MetadataCatalog $metadata } | Should -Throw '*BASE_CLIENT_HASH_MISMATCH*'
    }
}
