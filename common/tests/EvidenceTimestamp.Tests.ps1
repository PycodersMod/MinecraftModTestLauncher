BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/Compatibility/EvidenceTimestamp.psm1') -Force
}

Describe 'Compatibility evidence timestamps' {
    It 'serializes JSON-parsed timestamps as invariant ISO 8601 while preserving the instant' {
        $jsonParsedValue = [DateTime]::Parse('2026-10-07T06:05:15+08:00', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)

        $result = ConvertTo-MmtlIsoTimestamp -Value $jsonParsedValue

        $result | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$'
        ([DateTimeOffset]::Parse($result, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime) | Should -Be $jsonParsedValue.ToUniversalTime()
    }

    It 'preserves valid timestamp text without converting it through the current culture' {
        $inputText = '2026-10-07T06:05:15.1234567+08:00'

        $result = ConvertTo-MmtlIsoTimestamp -Value $inputText

        $result | Should -BeExactly $inputText
    }
}
