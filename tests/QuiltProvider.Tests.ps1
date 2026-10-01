BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/Quilt.psm1') -Force
    $script:game='[{"version":"1.20.1","stable":true},{"version":"26.3","stable":true}]'
    $script:loaders='[{"loader":{"maven":"org.quiltmc:quilt-loader:0.20.0-beta.9","version":"0.20.0-beta.9","build":9,"separator":".","hashes":{"sha1":"abc","sha256":"def"}},"hashed":{"maven":"org.quiltmc:hashed:1.20.1","version":"1.20.1"},"intermediary":{"maven":"net.fabricmc:intermediary:1.20.1","version":"1.20.1"},"launcherMeta":{"version":1}},{"loader":{"maven":"org.quiltmc:quilt-loader:0.19.3","version":"0.19.3","build":3,"separator":"."},"quilt-mappings":{"maven":"org.quiltmc:quilt-mappings:1.20.1+build.2","version":"1.20.1+build.2"}}]'
    $script:detail='{"loader":{"maven":"org.quiltmc:quilt-loader:0.20.0-beta.9","version":"0.20.0-beta.9","build":9,"separator":"."},"intermediary":{"maven":"net.fabricmc:intermediary:1.20.1","version":"1.20.1"},"hashed":{"maven":"org.quiltmc:hashed:1.20.1","version":"1.20.1"}}'
    $game=$script:game;$loaders=$script:loaders;$detail=$script:detail
    $script:http={param($Uri,$Headers,$TimeoutSeconds)if($Uri -match '/versions/game$'){$body=$game}elseif($Uri -match '/loader/1\.20\.1/0\.20\.0-beta\.9$'){$body=$detail}else{$body=$loaders};[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($body);ResponseUri=$Uri}}.GetNewClosure()
}

Describe 'Quilt official Meta v3 provider' {
    It 'reads v3 game and loader metadata while preserving distinct mappings references' {
        $snapshot=Get-MmtlQuiltProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'quilt') -HttpGet $script:http
        $snapshot.apiVersion | Should -Be 'v3'
        (Get-MmtlQuiltAvailability -MinecraftId '1.20.1' -Snapshot $snapshot).availability | Should -Be 'Available'
        (Get-MmtlQuiltAvailability -MinecraftId '1.12.2' -Snapshot $snapshot).availability | Should -Be 'Unavailable'
        $set=Get-MmtlQuiltCandidateSet -MinecraftId '1.20.1' -RuntimeRoot (Join-Path $TestDrive 'quilt') -HttpGet $script:http
        $set.providerStatus | Should -Be 'Available'
        @($set.candidates).Count | Should -Be 2
        $set.candidates[0].loader.version | Should -BeExactly '0.20.0-beta.9'
        $set.candidates[0].loader.stable | Should -BeNullOrEmpty
        $set.candidates[0].hashed.maven | Should -BeExactly 'org.quiltmc:hashed:1.20.1'
        $set.candidates[0].intermediary.maven | Should -BeExactly 'net.fabricmc:intermediary:1.20.1'
        $set.candidates[1].quiltMappings.version | Should -BeExactly '1.20.1+build.2'
        $set.candidates[0].artifact.coordinate | Should -BeExactly 'org.quiltmc:quilt-loader:0.20.0-beta.9'
    }

    It 'uses Quilt fields as published and fetches selected candidate details lazily' {
        $set=Get-MmtlQuiltCandidateSet -MinecraftId '1.20.1' -RuntimeRoot (Join-Path $TestDrive 'quilt-detail') -HttpGet $script:http
        $preferred=Get-MmtlQuiltPreferredCandidate -MinecraftId '1.20.1' -Candidates $set.candidates
        $preferred.candidate.loader.version | Should -BeExactly '0.20.0-beta.9'
        $preferred.policy | Should -Be 'FirstUpstreamCandidate'
        $preferred.reason | Should -Match 'stable|recommended|upstream order'
        $detail=Get-MmtlQuiltVersionMetadata -MinecraftId '1.20.1' -LoaderVersion '0.20.0-beta.9' -RuntimeRoot (Join-Path $TestDrive 'quilt-detail') -HttpGet $script:http
        $detail.providerStatus | Should -Be 'Available'
        $detail.metadata.loader.version | Should -BeExactly '0.20.0-beta.9'
        $detail.metadata.hashed.version | Should -BeExactly '1.20.1'
    }

    It 'returns Unknown on request failure and rejects malformed loader responses' {
        $down=Get-MmtlQuiltProviderSnapshot -RuntimeRoot (Join-Path $TestDrive 'quilt-down') -HttpGet {throw 'network down'}
        (Get-MmtlQuiltAvailability -MinecraftId '26.3' -Snapshot $down).availability | Should -Be 'Unknown'
        $bad=Get-MmtlQuiltCandidateSet -MinecraftId '1.20.1' -RuntimeRoot (Join-Path $TestDrive 'quilt-bad') -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes('[{"wrong":true}]');ResponseUri=$Uri}}
        $bad.providerStatus | Should -Be 'Unavailable'
        $bad.availability | Should -Be 'Unknown'
    }
}
