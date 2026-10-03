BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/Fabric.psm1') -Force
    $script:game='[{"version":"1.20.1","stable":true},{"version":"1.20.1-pre1","stable":false},{"version":"26.3","stable":true}]'
    $script:loaders='[{"loader":{"separator":".","build":900,"maven":"net.fabricmc:fabric-loader:0.16.0","version":"0.16.0","stable":false},"intermediary":{"maven":"net.fabricmc:intermediary:1.20.1","version":"1.20.1","stable":true}},{"loader":{"separator":".","build":899,"maven":"net.fabricmc:fabric-loader:0.15.11","version":"0.15.11","stable":true},"intermediary":{"maven":"net.fabricmc:intermediary:1.20.1","version":"1.20.1","stable":true}}]'
    $game=$script:game;$loaders=$script:loaders
    $script:http={param($Uri,$Headers,$TimeoutSeconds)if($Uri -match '/game$'){$body=$game}else{$body=$loaders};[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($body);ResponseUri=$Uri}}.GetNewClosure()
}

Describe 'Fabric official Meta v2 provider' {
    It 'preserves game stable and loader/intermediary metadata without conflating Fabric API' {
        $index=Get-MmtlFabricProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'fabric') -HttpGet $script:http
        $index.providerStatus | Should -Be 'Available'
        (Get-MmtlFabricAvailability -MinecraftId '1.20.1' -Snapshot $index).availability | Should -Be 'Available'
        (Get-MmtlFabricAvailability -MinecraftId '1.20' -Snapshot $index).availability | Should -Be 'Unavailable'
        $candidates=Get-MmtlFabricCandidates -MinecraftId '1.20.1' -RuntimeRoot (Join-Path $TestDrive 'fabric') -HttpGet $script:http
        @($candidates).Count | Should -Be 2
        $candidates[0].loaderVersion | Should -BeExactly '0.16.0'
        $candidates[0].stable | Should -BeFalse
        $candidates[0].artifact.coordinate | Should -BeExactly 'net.fabricmc:fabric-loader:0.16.0'
        $candidates[0].intermediary.version | Should -BeExactly '1.20.1'
        $candidates[0].intermediary.stable | Should -BeTrue
        $candidates[0].loaderApi | Should -BeNullOrEmpty
    }

    It 'chooses the first stable in official newest-first order and marks no-stable fallback' {
        $candidates=Get-MmtlFabricCandidates -MinecraftId '1.20.1' -RuntimeRoot (Join-Path $TestDrive 'fabric-policy') -HttpGet $script:http
        $preferred=Get-MmtlFabricPreferredCandidate -MinecraftId '1.20.1' -Candidates $candidates
        $preferred.candidate.loaderVersion | Should -BeExactly '0.15.11'
        $preferred.policy | Should -Be 'FirstStableNewestFirst'
        $unstable=@($candidates|ForEach-Object{$copy=$_|ConvertTo-Json -Depth 10|ConvertFrom-Json;$copy.loader.stable=$false;$copy.stable=$false;$copy})
        $fallback=Get-MmtlFabricPreferredCandidate -MinecraftId '1.20.1' -Candidates $unstable
        $fallback.candidate.loaderVersion | Should -BeExactly '0.16.0'
        $fallback.status | Should -Be 'NoStableCandidate'
    }

    It 'returns Unknown on upstream failure and does not misreport game absence' {
        $index=Get-MmtlFabricProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'fabric-failure') -HttpGet {throw 'simulated outage'}
        (Get-MmtlFabricAvailability -MinecraftId '1.20.1' -Snapshot $index).availability | Should -Be 'Unknown'
        $bad=Get-MmtlFabricProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'fabric-malformed') -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes('{bad');ResponseUri=$Uri}}
        $bad.providerStatus | Should -Be 'Unavailable'
        (Get-MmtlFabricAvailability -MinecraftId '1.20.1' -Snapshot $bad).availability | Should -Be 'Unknown'
    }
}
