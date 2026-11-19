function ConvertTo-MmtlIsoTimestamp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)

    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [DateTimeOffset]) { return $Value.ToString('o', $culture) }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToString('o', $culture) }

    $text = [string]$Value
    if ($text -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$') { return $text }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($text, $culture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        throw 'EVIDENCE_TIMESTAMP_INVALID'
    }
    return $parsed.ToString('o', $culture)
}

Export-ModuleMember -Function ConvertTo-MmtlIsoTimestamp
