BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Architecture/HistoricalContracts.psm1') -Force
}

Describe 'Historical source, transport and integrity contracts' {
    It 'keeps source class independent from artifact trust' {
        $record = New-MmtlHistoricalSourceRecord -SourceClass VerifiedCommunityArchive -TrustClass VerifiedHistorical -TransportSecurity ArchivedSnapshot -MaintenanceState Archived -Url 'https://archive.example.invalid/project' -RetrievedAt '2026-09-01T00:00:00Z' -LastReviewed '2026-10-02T00:00:00Z'
        $record.sourceClass | Should -Be 'VerifiedCommunityArchive'
        $record.trustClass | Should -Be 'VerifiedHistorical'
        $record.sourceClass | Should -Not -Be $record.trustClass
    }

    It 'classifies HTTP-only and manual sources without changing global network policy' {
        $http = New-MmtlHistoricalSourceRecord -SourceClass HistoricalOfficial -TrustClass VerifiedHistorical -TransportSecurity HTTPOnly -MaintenanceState Archived -Url 'http://legacy.example.invalid/manifest.json' -RetrievedAt '2026-09-01T00:00:00Z' -LastReviewed '2026-10-02T00:00:00Z'
        $manual = New-MmtlHistoricalSourceRecord -SourceClass ManualArtifact -TrustClass UnverifiedHistorical -TransportSecurity LocalManual -MaintenanceState Unknown -RetrievedAt '2026-10-02T00:00:00Z' -LastReviewed '2026-10-02T00:00:00Z'
        $http.transportSecurity | Should -Be 'HTTPOnly'
        $manual.downloadPermission | Should -Be 'RequiresConfirmation'
        $manual.executePermission | Should -Be 'RequiresConfirmation'
        { New-MmtlHistoricalSourceRecord -SourceClass HistoricalOfficial -TrustClass VerifiedHistorical -TransportSecurity HTTPS -MaintenanceState Archived -Url 'http://legacy.example.invalid/manifest.json' -RetrievedAt '2026-09-01T00:00:00Z' -LastReviewed '2026-10-02T00:00:00Z' } | Should -Throw '*TRANSPORT_SCHEME_MISMATCH*'
    }

    It 'classifies SHA-256, SHA-1 and MD5 strength without granting trust or execution' {
        $sha256 = Get-MmtlHistoricalIntegrityAssessment -Algorithm SHA256 -Hash ('a' * 64)
        $sha1 = Get-MmtlHistoricalIntegrityAssessment -Algorithm SHA1 -Hash ('b' * 40)
        $md5 = Get-MmtlHistoricalIntegrityAssessment -Algorithm MD5 -Hash ('c' * 32)
        $sha256.strength | Should -Be 'StrongIntegrity'
        $sha1.strength | Should -Be 'LegacyIntegrity'
        $md5.strength | Should -Be 'CorruptionDetectionOnly'
        $md5.trustClass | Should -BeNullOrEmpty
        $md5.executePermission | Should -Be 'RequiresConfirmation'
        { Get-MmtlHistoricalIntegrityAssessment -Algorithm MD5 -Hash ('c' * 64) } | Should -Throw '*INTEGRITY_HASH_LENGTH_INVALID*'
    }

    It 'accepts no-hash and unknown-integrity records without inventing integrity' {
        (Get-MmtlHistoricalIntegrityAssessment -Algorithm None).strength | Should -Be 'NoIntegrity'
        (Get-MmtlHistoricalIntegrityAssessment -Algorithm Unknown).strength | Should -Be 'Unknown'
    }
}
