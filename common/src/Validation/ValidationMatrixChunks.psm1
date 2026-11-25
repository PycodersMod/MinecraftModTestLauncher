Set-StrictMode -Version Latest

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
        $candidateIds = [string[]]@($sourceTarget.loaderVersionCandidates | ForEach-Object { [string]$_ })
        $groups[$key].Add([pscustomobject][ordered]@{
            targetId = $targetId
            minecraftId = [string]$sourceTarget.minecraftId
            loaderVersionCandidates = @($candidateIds)
            sourceHash = [string]$sourceTarget.sourceHash
            candidateSourceUrl = [string]$sourceTarget.candidateSourceUrl
            candidateSourceHash = [string]$sourceTarget.candidateSourceHash
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

Export-ModuleMember -Function New-MmtlValidationMatrixChunks, Test-MmtlValidationMatrixChunkManifest
