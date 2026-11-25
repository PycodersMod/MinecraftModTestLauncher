Set-StrictMode -Version Latest

function Get-MmtlSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Assert-MmtlRegularFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Code)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw $Code }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "${Code}_REPARSE_POINT" }
}

function New-MmtlHistoricalJarOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ModLoader','ModLoaderMP')][string]$LoaderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MinecraftId,
        [Parameter(Mandatory)][string]$BaseClientJar,
        [Parameter(Mandatory)][string]$OverlayArchive,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)]$CandidateCatalog,
        [Parameter(Mandatory)]$MetadataCatalog,
        [long]$MaxArchiveBytes = 33554432,
        [long]$MaxUncompressedBytes = 67108864,
        [int]$MaxEntryCount = 10000
    )

    Assert-MmtlRegularFile -Path $BaseClientJar -Code 'BASE_CLIENT_INVALID'
    Assert-MmtlRegularFile -Path $OverlayArchive -Code 'OVERLAY_ARCHIVE_INVALID'
    $basePath = [IO.Path]::GetFullPath($BaseClientJar)
    $overlayPath = [IO.Path]::GetFullPath($OverlayArchive)
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $evidenceFull = [IO.Path]::GetFullPath($EvidencePath)
    if ($outputFull -eq $evidenceFull -or $outputFull -eq $basePath -or $outputFull -eq $overlayPath -or $evidenceFull -eq $basePath -or $evidenceFull -eq $overlayPath) { throw 'OUTPUT_PATH_COLLISION' }
    if (Test-Path -LiteralPath $outputFull) { throw 'OUTPUT_ALREADY_EXISTS' }
    if (Test-Path -LiteralPath $evidenceFull) { throw 'EVIDENCE_ALREADY_EXISTS' }
    $outDir = Split-Path -Parent $outputFull
    $evidenceDir = Split-Path -Parent $evidenceFull
    if (-not (Test-Path -LiteralPath $outDir -PathType Container) -or -not (Test-Path -LiteralPath $evidenceDir -PathType Container)) { throw 'OUTPUT_DIRECTORY_NOT_FOUND' }

    if ([string]$CandidateCatalog.loaderId -cne $LoaderId) { throw 'CANDIDATE_CATALOG_LOADER_MISMATCH' }
    $targetRows = @($CandidateCatalog.results | Where-Object { [string]$_.targetId -ceq "$LoaderId@$MinecraftId" -and [string]$_.minecraftId -ceq $MinecraftId })
    if ($targetRows.Count -ne 1 -or [string]$targetRows[0].candidateStatus -cne 'Resolved') { throw 'EXACT_TARGET_CANDIDATE_NOT_UNIQUE' }
    $candidates = @($targetRows[0].candidates | Where-Object { [string]$_.loaderId -ceq $LoaderId -and [string]$_.minecraftId -ceq $MinecraftId -and [string]$_.artifactType -ceq 'ClientZip' -and [string]$_.artifactFormat -ceq 'ZIP' -and [string]$_.hashAlgorithm -ceq 'SHA256' })
    if ($candidates.Count -ne 1) { throw 'EXACT_CLIENT_ZIP_CANDIDATE_NOT_UNIQUE' }
    if ((Get-MmtlSha256Hex $overlayPath) -cne ([string]$candidates[0].sha256).ToLowerInvariant()) { throw 'CANDIDATE_HASH_MISMATCH' }

    $metadataEntries = @($MetadataCatalog.entries | Where-Object { [string]$_.minecraftId -ceq $MinecraftId })
    if ($metadataEntries.Count -ne 1 -or [string]$metadataEntries[0].clientComparison.status -cne 'Match') { throw 'OFFICIAL_CLIENT_METADATA_NOT_EXACT_MATCH' }
    $officialSha1 = ([string]$metadataEntries[0].clientComparison.officialSha1).ToLowerInvariant()
    if ($officialSha1 -notmatch '^[a-f0-9]{40}$') { throw 'OFFICIAL_CLIENT_SHA1_INVALID' }
    $actualClientSha1 = (Get-FileHash -LiteralPath $basePath -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($actualClientSha1 -cne $officialSha1) { throw 'BASE_CLIENT_HASH_MISMATCH' }
    if ((Get-Item -LiteralPath $overlayPath).Length -gt $MaxArchiveBytes) { throw 'ARCHIVE_BYTE_LIMIT_EXCEEDED' }

    Add-Type -AssemblyName System.IO.Compression
    $sourceStream = [IO.File]::Open($overlayPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $tempOutput = Join-Path $outDir ('.' + [IO.Path]::GetFileName($outputFull) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $tempEvidence = Join-Path $evidenceDir ('.' + [IO.Path]::GetFileName($evidenceFull) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $publishedOutput = $false
    $sourceArchive = $null
    try {
        $sourceArchive = [IO.Compression.ZipArchive]::new($sourceStream, [IO.Compression.ZipArchiveMode]::Read, $true)
        if ($sourceArchive.Entries.Count -eq 0 -or $sourceArchive.Entries.Count -gt $MaxEntryCount) { throw 'ARCHIVE_ENTRY_COUNT_INVALID' }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $entries = [Collections.Generic.List[object]]::new()
        [long]$total = 0
        foreach ($entry in $sourceArchive.Entries) {
            $name = [string]$entry.FullName
            $segments = $name -split '/'
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or $segments -contains '..' -or $segments -contains '.' -or $name.EndsWith('/')) { throw 'UNSAFE_ARCHIVE_ENTRY' }
            if (-not $names.Add($name)) { throw 'DUPLICATE_ARCHIVE_ENTRY' }
            $unixMode = ([int]$entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixMode -eq 0xA000 -or $unixMode -eq 0x6000 -or $unixMode -eq 0x2000 -or (([int]$entry.ExternalAttributes -band 0x400) -ne 0)) { throw 'UNSAFE_ARCHIVE_ENTRY_TYPE' }
            if ($name -cnotmatch '^(?:[A-Za-z0-9_$.-]+/)*[A-Za-z0-9_$.-]+\.class$') { throw 'NON_CLASS_ARCHIVE_ENTRY' }
            if ($entry.Length -gt $MaxUncompressedBytes -or ($total += [long]$entry.Length) -gt $MaxUncompressedBytes) { throw 'ARCHIVE_UNCOMPRESSED_LIMIT_EXCEEDED' }
            $entries.Add($entry)
        }

        [IO.File]::Copy($basePath, $tempOutput, $false)
        $outStream = [IO.File]::Open($tempOutput, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $outputArchive = [IO.Compression.ZipArchive]::new($outStream, [IO.Compression.ZipArchiveMode]::Update, $false)
            try {
                $replaced = 0
                $added = 0
                foreach ($entry in $entries) {
                    $existing = @($outputArchive.Entries | Where-Object { [string]$_.FullName -ceq [string]$entry.FullName })
                    if ($existing.Count -gt 1) { throw 'BASE_JAR_DUPLICATE_ENTRY' }
                    if ($existing.Count -eq 1) { $existing[0].Delete(); $replaced++ } else { $added++ }
                    $newEntry = $outputArchive.CreateEntry([string]$entry.FullName, [IO.Compression.CompressionLevel]::Optimal)
                    $newEntry.LastWriteTime = $entry.LastWriteTime
                    $readStream = $entry.Open(); $writeStream = $newEntry.Open()
                    try { $readStream.CopyTo($writeStream) } finally { $writeStream.Dispose(); $readStream.Dispose() }
                }
            } finally { $outputArchive.Dispose() }
        } finally { $outStream.Dispose() }

        $outputHash = Get-MmtlSha256Hex $tempOutput
        $verifyStream = [IO.File]::Open($tempOutput, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $verifyArchive = [IO.Compression.ZipArchive]::new($verifyStream, [IO.Compression.ZipArchiveMode]::Read, $false)
            try {
                foreach ($entry in $entries) {
                    $matches = @($verifyArchive.Entries | Where-Object { [string]$_.FullName -ceq [string]$entry.FullName })
                    if ($matches.Count -ne 1) { throw 'OUTPUT_ENTRY_VERIFICATION_FAILED' }
                    $expectedHash = [Security.Cryptography.SHA256]::HashData((Read-MmtlZipEntryBytes $entry))
                    $actualHash = [Security.Cryptography.SHA256]::HashData((Read-MmtlZipEntryBytes $matches[0]))
                    if ([Convert]::ToHexString($expectedHash) -cne [Convert]::ToHexString($actualHash)) { throw 'OUTPUT_ENTRY_VERIFICATION_FAILED' }
                }
            } finally { $verifyArchive.Dispose() }
        } finally { $verifyStream.Dispose() }

        $evidence = [pscustomobject][ordered]@{
            schemaVersion = 1; status = 'Staged'; targetId = "$LoaderId@$MinecraftId"; loaderId = $LoaderId; minecraftId = $MinecraftId
            candidateArtifactSha256 = ([string]$candidates[0].sha256).ToLowerInvariant(); baseClientOfficialSha1 = $officialSha1
            outputSha256 = $outputHash; overlayEntryCount = $entries.Count; replacedClassCount = $replaced; addedClassCount = $added
            executionPerformed = $false; buildPlanSupported = $false; runtimeSupported = $false
            assurance = 'LOCAL_CLASS_OVERLAY_ONLY'; automaticDownloadAllowed = $false; automaticExecutionAllowed = $false
        }
        $json = ConvertTo-Json -InputObject $evidence -Depth 8
        [IO.File]::WriteAllText($tempEvidence, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tempOutput, $outputFull)
        $publishedOutput = $true
        [IO.File]::Move($tempEvidence, $evidenceFull)
        [pscustomobject]$evidence
    }
    catch {
        if ($publishedOutput -and (Test-Path -LiteralPath $outputFull)) { Remove-Item -LiteralPath $outputFull -Force }
        throw
    }
    finally {
        if ($null -ne $sourceArchive) { $sourceArchive.Dispose() }
        $sourceStream.Dispose()
        foreach ($temp in @($tempOutput, $tempEvidence)) { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    }
}

function Read-MmtlZipEntryBytes {
    param([Parameter(Mandatory)][IO.Compression.ZipArchiveEntry]$Entry)
    $stream = $Entry.Open()
    try {
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); return ,$memory.ToArray() } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
}

Export-ModuleMember -Function New-MmtlHistoricalJarOverlay
