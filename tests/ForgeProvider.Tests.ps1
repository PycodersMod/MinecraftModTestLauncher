BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/Forge.psm1') -Force
    $script:catalog=[pscustomobject]@{manifestHash='fixture-catalog-hash';entries=@([pscustomobject]@{id='1.20.1'},[pscustomobject]@{id='1.20'},[pscustomobject]@{id='26.3'},[pscustomobject]@{id='1.0'})}
    $script:promotions='{"homepage":"https://files.minecraftforge.net/net/minecraftforge/forge/","promos":{"1.20.1-recommended":"47.2.0","1.20.1-latest":"47.3.0","1.20-latest":"46.0.14","26.3-latest":"66.0.9"}}'
    $script:maven='<metadata><groupId>net.minecraftforge</groupId><artifactId>forge</artifactId><versioning><latest>26.3-66.0.9</latest><release>26.3-66.0.9</release><versions><version>1.20.1-47.2.0</version><version>1.20.1-47.3.0</version><version>1.20.1-47.1.106</version><version>1.20-46.0.14</version><version>26.3-66.0.9</version><version>1.20.1-47.2.0-rc1</version><version>orphan-1.0</version></versions></versioning></metadata>'
    $promotions=$script:promotions;$maven=$script:maven
    $script:http={param($Uri,$Headers,$TimeoutSeconds)if($Uri -match 'promotions_slim'){ $body=$promotions }else{$body=$maven};[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($body);ResponseUri=$Uri}}.GetNewClosure()
}

Describe 'Forge official metadata provider' {
    It 'maps exact Mojang IDs, retains canonical Maven versions and promotion semantics' {
        $snapshot=Get-MmtlForgeProviderSnapshot -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'forge') -HttpGet $script:http
        $snapshot.providerStatus | Should -Be 'Available'
        $oneTwenty=Get-MmtlForgeCandidates -MinecraftId '1.20.1' -Snapshot $snapshot
        @($oneTwenty).Count | Should -Be 4
        $oneTwenty[0].minecraftId | Should -BeExactly '1.20.1'
        $oneTwenty[0].version | Should -BeExactly '47.2.0'
        $oneTwenty[0].fullMavenVersion | Should -BeExactly '1.20.1-47.2.0'
        $oneTwenty[0].artifact.coordinate | Should -BeExactly 'net.minecraftforge:forge:1.20.1-47.2.0'
        ($oneTwenty|Where-Object recommended).version | Should -BeExactly '47.2.0'
        ($oneTwenty|Where-Object latest).version | Should -BeExactly '47.3.0'
        ($oneTwenty|Where-Object {$_.fullMavenVersion -eq '1.20.1-47.2.0-rc1'}).minecraftId | Should -BeExactly '1.20.1'
        (Get-MmtlForgeCandidates -MinecraftId '1.20' -Snapshot $snapshot)[0].minecraftId | Should -BeExactly '1.20'
        (Get-MmtlForgeCandidates -MinecraftId '1.0' -Snapshot $snapshot).Count | Should -Be 0
    }

    It 'does not copy latest into missing recommended and distinguishes promotions from Maven availability' {
        $snapshot=Get-MmtlForgeProviderSnapshot -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'forge-latest-only') -HttpGet $script:http
        $candidates=Get-MmtlForgeCandidates -MinecraftId '1.20' -Snapshot $snapshot
        $candidates[0].latest | Should -BeTrue
        $candidates[0].recommended | Should -BeFalse
        (Get-MmtlForgePreferredCandidate -MinecraftId '1.20' -Candidates $candidates).candidate.version | Should -BeExactly '46.0.14'
        $candidates[0].promotionStatus | Should -Be 'latest'
    }

    It 'returns Unknown for provider failure and does not call HTTP in offline mode' {
        $snapshot=Get-MmtlForgeProviderSnapshot -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'forge-down') -HttpGet {throw 'simulated outage'}
        $snapshot.providerStatus | Should -Be 'Unavailable'
        $snapshot.availability | Should -Be 'Unknown'
        $offline=Get-MmtlForgeProviderSnapshot -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'forge-down') -Offline -HttpGet {throw 'offline must not call HTTP'}
        $offline.providerStatus | Should -Be 'Unavailable'
        $offline.availability | Should -Be 'Unknown'
    }
}
