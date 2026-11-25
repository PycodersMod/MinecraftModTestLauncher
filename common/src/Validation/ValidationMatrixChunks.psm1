Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TargetIdentity.psm1') -Force

function New-MmtlValidationMatrixChunks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][object]$Universe,
        [Parameter(Mandatory)][object]$FamilyManifest,
        [Parameter(Mandatory)][int]$ChunkSize
    )

    if ($ChunkSize -lt 1 -or $ChunkSize -gt 100) { throw 'CHUNK_SIZE_INVALID:must be between 1 and 100' }
    Import-Module (Join-Path $PSScriptRoot '../Compatibility/FullCompatibilityLedger.psm1') -Force
    $validation = Test-MmtlFullCompatibilityLedger -Ledger $Ledger -Universe $Universe -FamilyManifest $FamilyManifest -RequireFamilies
    if (-not $validation.isValid) {
        throw "VALIDATION_MATRIX_LEDGER_INVALID:$($validation.errors -join ';')"
    }
    if ([string]$Ledger.universeHash -cne [string]$Universe.catalogHash) {
        throw 'VALIDATION_MATRIX_UNIVERSE_HASH_MISMATCH'
    }

    $ledgerById = @{}
    foreach ($row in @($Ledger.targets)) { $ledgerById[[string]$row.targetId] = $row }
    $universeById = @{}
    foreach ($row in @($Universe.targets | Where-Object { [string]$_.availability -ceq 'Available' })) { $universeById[[string]$row.targetId] = $row }
    $targetIds = [string[]]@($Universe.targets | Where-Object { [string]$_.availability -ceq 'Available' } | ForEach-Object { [string]$_.targetId })
    [Array]::Sort($targetIds, [StringComparer]::Ordinal)

    $groups = @{}
    foreach ($targetId in $targetIds) {
        if (-not $ledgerById.ContainsKey($targetId)) { throw "VALIDATION_MATRIX_LEDGER_TARGET_MISSING:$targetId" }
        $row = $ledgerById[$targetId]
        $familyId = [string]$row.familyId
        if ([string]::IsNullOrWhiteSpace($familyId)) { throw "VALIDATION_MATRIX_FAMILY_UNASSIGNED:$targetId" }
        $key = [string]$row.loaderId + [char]0 + $familyId
        if (-not $groups.ContainsKey($key)) { $groups[$key] = [Collections.Generic.List[object]]::new() }

        if (-not $universeById.ContainsKey($targetId)) { throw "VALIDATION_MATRIX_UNIVERSE_TARGET_NOT_UNIQUE:$targetId" }
        $sourceTarget = $universeById[$targetId]
        $candidateIds = [string[]]@(Get-MmtlLoaderVersionCandidateValues -Candidates $sourceTarget.loaderVersionCandidates)
        $groups[$key].Add([pscustomobject][ordered]@{
            targetId = $targetId
            minecraftId = [string]$sourceTarget.minecraftId
            loaderVersionCandidates = @($candidateIds)
            sourceHash = [string]$sourceTarget.sourceHash
            candidateSourceUrl = [string]$sourceTarget.candidateSourceUrl
            candidateSourceHash = [string]$sourceTarget.candidateSourceHash
            toolchainHash = [string]$row.toolchainHash
            targetSpecHash = [string]$row.targetSpecHash
        })
    }

    $groupKeys = [string[]]@($groups.Keys)
    [Array]::Sort($groupKeys, [StringComparer]::Ordinal)
    $chunks = [Collections.Generic.List[object]]::new()
    foreach ($key in $groupKeys) {
        $separator = $key.IndexOf([char]0)
        $loaderId = $key.Substring(0, $separator)
        $familyId = $key.Substring($separator + 1)
        $groupTargets = @($groups[$key].ToArray())
        for ($offset = 0; $offset -lt $groupTargets.Count; $offset += $ChunkSize) {
            $end = [Math]::Min($offset + $ChunkSize, $groupTargets.Count)
            $chunkTargets = @($groupTargets[$offset..($end - 1)])
            $ordinal = [int]($offset / $ChunkSize)
            $hashInput = [pscustomobject][ordered]@{ loaderId = $loaderId; familyId = $familyId; ordinal = $ordinal; targets = $chunkTargets }
            $payload = ConvertTo-Json -InputObject $hashInput -Depth 20 -Compress
            $chunkHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload))).ToLowerInvariant()
            $chunks.Add([pscustomobject][ordered]@{
                chunkId = "chunk-$chunkHash"
                loaderId = $loaderId
                familyId = $familyId
                ordinal = $ordinal
                targetCount = $chunkTargets.Count
                chunkHash = $chunkHash
                targets = $chunkTargets
            })
        }
    }

    $core = [pscustomobject][ordered]@{
        schemaVersion = 1
        universeHash = [string]$Universe.catalogHash
        targetCount = $targetIds.Count
        chunkSize = $ChunkSize
        chunkCount = $chunks.Count
        chunks = @($chunks.ToArray())
    }
    $manifestPayload = ConvertTo-Json -InputObject $core -Depth 30 -Compress
    $manifestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifestPayload))).ToLowerInvariant()
    $core | Add-Member -NotePropertyName manifestHash -NotePropertyValue $manifestHash
    return $core
}

function Test-MmtlValidationMatrixChunkManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][object]$Universe,
        [Parameter(Mandatory)][object]$FamilyManifest
    )

    $errors = [Collections.Generic.List[string]]::new()
    try {
        $expected = New-MmtlValidationMatrixChunks -Ledger $Ledger -Universe $Universe -FamilyManifest $FamilyManifest -ChunkSize ([int]$Manifest.chunkSize)
        $expectedJson = ConvertTo-Json -InputObject $expected -Depth 30 -Compress
        $actualJson = ConvertTo-Json -InputObject $Manifest -Depth 30 -Compress
        if ($actualJson -cne $expectedJson) { $errors.Add('VALIDATION_MATRIX_CHUNK_MANIFEST_MISMATCH') }
    } catch {
        $errors.Add([string]$_.Exception.Message)
    }
    [pscustomobject][ordered]@{ isValid = ($errors.Count -eq 0); errors = @($errors.ToArray()) }
}

function Get-MmtlValidationMatrixShard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][object]$Ledger,
        [Parameter(Mandatory)][object]$Universe,
        [Parameter(Mandatory)][object]$FamilyManifest,
        [Parameter(Mandatory)][int]$ShardIndex,
        [Parameter(Mandatory)][int]$ShardCount
    )

    if ($ShardCount -lt 1) { throw 'SHARD_COUNT_INVALID:must be positive' }
    if ($ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount) { throw 'SHARD_INDEX_INVALID:must be within shard count' }
    $sourceValidation = Test-MmtlValidationMatrixChunkManifest -Manifest $Manifest -Ledger $Ledger -Universe $Universe -FamilyManifest $FamilyManifest
    if (-not $sourceValidation.isValid) { throw "CHUNK_MANIFEST_INVALID:$($sourceValidation.errors -join ';')" }
    if ([int]$Manifest.schemaVersion -ne 1 -or [int]$Manifest.chunkSize -lt 1 -or [int]$Manifest.chunkSize -gt 100) {
        throw 'CHUNK_MANIFEST_INVALID:unsupported schema or chunk size'
    }

    $chunks = @($Manifest.chunks)
    if ([int]$Manifest.chunkCount -ne $chunks.Count) { throw 'CHUNK_MANIFEST_INVALID:chunk count mismatch' }
    $targetIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($chunk in $chunks) {
        $chunkTargets = @($chunk.targets)
        if ([int]$chunk.targetCount -ne $chunkTargets.Count -or $chunkTargets.Count -lt 1 -or $chunkTargets.Count -gt [int]$Manifest.chunkSize) {
            throw 'CHUNK_MANIFEST_INVALID:target count or chunk bound mismatch'
        }
        foreach ($target in $chunkTargets) {
            if ([string]::IsNullOrWhiteSpace([string]$target.targetId) -or -not $targetIds.Add([string]$target.targetId)) {
                throw 'CHUNK_MANIFEST_INVALID:empty or duplicate target id'
            }
        }
        $hashInput = [pscustomobject][ordered]@{
            loaderId = [string]$chunk.loaderId
            familyId = [string]$chunk.familyId
            ordinal = [int]$chunk.ordinal
            targets = $chunkTargets
        }
        $payload = ConvertTo-Json -InputObject $hashInput -Depth 20 -Compress
        $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload))).ToLowerInvariant()
        if ([string]$chunk.chunkHash -cne $expectedHash -or [string]$chunk.chunkId -cne "chunk-$expectedHash") {
            throw 'CHUNK_MANIFEST_INVALID:chunk hash mismatch'
        }
    }
    if ([int]$Manifest.targetCount -ne $targetIds.Count) { throw 'CHUNK_MANIFEST_INVALID:target total mismatch' }

    $core = [pscustomobject][ordered]@{
        schemaVersion = [int]$Manifest.schemaVersion
        universeHash = [string]$Manifest.universeHash
        targetCount = [int]$Manifest.targetCount
        chunkSize = [int]$Manifest.chunkSize
        chunkCount = [int]$Manifest.chunkCount
        chunks = $chunks
    }
    $manifestPayload = ConvertTo-Json -InputObject $core -Depth 30 -Compress
    $expectedManifestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifestPayload))).ToLowerInvariant()
    if ([string]$Manifest.manifestHash -cne $expectedManifestHash) { throw 'CHUNK_MANIFEST_INVALID:manifest hash mismatch' }

    $selected = [Collections.Generic.List[object]]::new()
    for ($index = $ShardIndex; $index -lt $chunks.Count; $index += $ShardCount) { $selected.Add($chunks[$index]) }
    $selectedTargetCount = 0
    foreach ($chunk in $selected) { $selectedTargetCount += [int]$chunk.targetCount }
    [pscustomobject][ordered]@{
        schemaVersion = 1
        universeHash = [string]$Manifest.universeHash
        manifestHash = [string]$Manifest.manifestHash
        shardIndex = $ShardIndex
        shardCount = $ShardCount
        targetCount = $selectedTargetCount
        chunkCount = $selected.Count
        chunks = @($selected.ToArray())
    }
}

Export-ModuleMember -Function New-MmtlValidationMatrixChunks, Test-MmtlValidationMatrixChunkManifest, Get-MmtlValidationMatrixShard
