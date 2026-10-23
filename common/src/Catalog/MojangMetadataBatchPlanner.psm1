function Get-MmtlMojangMetadataDownloadBatches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$AvailableIds,
        [ValidateRange(1, 32)][int]$MaxConcurrency = 12
    )

    $available = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $AvailableIds) { $null = $available.Add($id) }

    $batches = [Collections.Generic.List[object]]::new()
    $batch = [Collections.Generic.List[object]]::new()
    foreach ($entry in $Entries) {
        if ($available.Contains([string]$entry.id)) { continue }
        $batch.Add($entry)
        if ($batch.Count -eq $MaxConcurrency) {
            $batches.Add([pscustomobject]@{ entries = [object[]]$batch.ToArray() })
            $batch.Clear()
        }
    }
    if ($batch.Count -gt 0) { $batches.Add([pscustomobject]@{ entries = [object[]]$batch.ToArray() }) }
    return $batches.ToArray()
}

Export-ModuleMember -Function Get-MmtlMojangMetadataDownloadBatches
