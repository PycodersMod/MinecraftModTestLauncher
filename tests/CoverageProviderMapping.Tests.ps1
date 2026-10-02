BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/Fabric.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/NeoForge.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/Quilt.psm1') -Force
    $script:catalogIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    @('1.20.1','1.20.2','1.21.1','26.3')|ForEach-Object{[void]$script:catalogIds.Add($_)}
}

Describe 'Exact release mapping for full coverage' {
    It 'matches Fabric stable release IDs exactly and leaves prerelease aliases unmapped' {
        $snapshot=[pscustomobject]@{providerStatus='Available';supportedVersions=@([pscustomobject]@{version='1.20.1';stable=$true},[pscustomobject]@{version='1.20.1-pre1';stable=$false});sourceUrl='https://meta.fabricmc.net/v2/versions/game';validatedAt='2026-10-02T00:00:00Z';cacheStatus='Fresh';error=$null}
        (Get-MmtlFabricAvailability -MinecraftId '1.20.1' -Snapshot $snapshot).availability | Should -BeExactly 'Available'
        (Get-MmtlFabricAvailability -MinecraftId '1.20' -Snapshot $snapshot).availability | Should -BeExactly 'Unavailable'
        @($snapshot.supportedVersions|Where-Object version -CEQ '1.20.1').Count | Should -Be 1
    }

    It 'maps each documented NeoForge naming era without collapsing neighboring releases' {
        (Resolve-MmtlNeoForgeVersionMapping -Version '1.20.1-47.1.106' -CatalogEntrySet $script:catalogIds -ArtifactFamily NeoForgedForgeTransition).minecraftId | Should -BeExactly '1.20.1'
        (Resolve-MmtlNeoForgeVersionMapping -Version '20.2.59' -CatalogEntrySet $script:catalogIds -ArtifactFamily NeoForge).minecraftId | Should -BeExactly '1.20.2'
        (Resolve-MmtlNeoForgeVersionMapping -Version '21.1.180' -CatalogEntrySet $script:catalogIds -ArtifactFamily NeoForge).minecraftId | Should -BeExactly '1.21.1'
        (Resolve-MmtlNeoForgeVersionMapping -Version '26.3.0.1' -CatalogEntrySet $script:catalogIds -ArtifactFamily NeoForge).minecraftId | Should -BeExactly '26.3'
        Resolve-MmtlNeoForgeVersionMapping -Version '20.3.59' -CatalogEntrySet $script:catalogIds -ArtifactFamily NeoForge | Should -BeNullOrEmpty
    }

    It 'treats Quilt game support and loader candidates as separate evidence' {
        $http={param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes('[]');ResponseUri=$Uri}}
        $candidateSet=Get-MmtlQuiltCandidateSet -MinecraftId '1.20.1' -RuntimeRoot (Join-Path $TestDrive 'quilt-empty-candidates') -HttpGet $http
        $candidateSet.providerStatus | Should -BeExactly 'Available'
        @($candidateSet.candidates).Count | Should -Be 0
    }
}
