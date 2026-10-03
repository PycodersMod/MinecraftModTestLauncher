BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/NeoForge.psm1') -Force
    $script:catalog=[pscustomobject]@{manifestHash='fixture';entries=@('1.20.1','1.20.2','1.21.1','26.1','26.2')|ForEach-Object{[pscustomobject]@{id=$_}}}
    $script:neo='<metadata><groupId>net.neoforged</groupId><artifactId>neoforge</artifactId><versioning><latest>26.1.0.6-beta</latest><release>26.1.0.6-beta</release><versions><version>20.2.59</version><version>21.1.180</version><version>26.1.0.5-beta</version><version>26.1.0.6-beta</version><version>26.1.0.4</version><version>26.2.0.1</version><version>bad-version</version></versions></versioning></metadata>'
    $script:transition='<metadata><groupId>net.neoforged</groupId><artifactId>forge</artifactId><versioning><latest>1.20.1-47.1.106</latest><release>1.20.1-47.1.106</release><versions><version>1.20.1-47.1.105</version><version>1.20.1-47.1.106</version></versions></versioning></metadata>'
    $neo=$script:neo;$transition=$script:transition
    $script:http={param($Uri,$Headers,$TimeoutSeconds)if($Uri -match '/neoforge/maven-metadata'){ $body=$neo }else{$body=$transition};[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($body);ResponseUri=$Uri}}.GetNewClosure()
}

Describe 'NeoForge official Maven provider' {
    It 'uses separate modern and 1.20.1 transition artifact families with a bounded scheme parser' {
        $snapshot=Get-MmtlNeoForgeProviderSnapshot -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'neo') -HttpGet $script:http
        $snapshot.providerStatus | Should -Be 'Available'
        $modern=Get-MmtlNeoForgeCandidates -MinecraftId '1.20.2' -Snapshot $snapshot
        $modern.artifactFamily | Should -Be 'NeoForge'
        $modern.artifact.coordinate | Should -BeExactly 'net.neoforged:neoforge:20.2.59'
        $modern.versionScheme | Should -Be 'stripped-leading-one-1.20-1.25'
        $modern=Get-MmtlNeoForgeCandidates -MinecraftId '1.21.1' -Snapshot $snapshot
        $modern.version | Should -BeExactly '21.1.180'
        $modern=Get-MmtlNeoForgeCandidates -MinecraftId '26.1' -Snapshot $snapshot
        @($modern).Count | Should -Be 3
        $modern[0].stable | Should -BeFalse
        $modern[0].rawQualifier | Should -Be '-beta'
        $modern[0].version | Should -BeExactly '26.1.0.5-beta'
        $modern[0].versionScheme | Should -Be 'full-minecraft-prefix-26+'
        (Get-MmtlNeoForgeCandidates -MinecraftId '26.2' -Snapshot $snapshot).Count | Should -Be 1
        $transition=Get-MmtlNeoForgeCandidates -MinecraftId '1.20.1' -Snapshot $snapshot
        @($transition).Count | Should -Be 2
        $transition=$transition|Where-Object version -eq '1.20.1-47.1.106'|Select-Object -First 1
        $transition.artifactFamily | Should -Be 'NeoForgedForgeTransition'
        $transition.artifact.coordinate | Should -BeExactly 'net.neoforged:forge:1.20.1-47.1.106'
        $transition.recommendation.id | Should -Be 'PreferForge'
        $transition.provenance | Where-Object sourceUrl -Match 'docs.neoforged.net' | Should -Not -BeNullOrEmpty
        (Get-MmtlNeoForgeCandidates -MinecraftId '1.20.3' -Snapshot $snapshot).Count | Should -Be 0
    }

    It 'prefers stable candidates and labels beta-only sets without stripping qualifiers' {
        $snapshot=Get-MmtlNeoForgeProviderSnapshot -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'neo-policy') -HttpGet $script:http
        $mixed=Get-MmtlNeoForgeCandidates -MinecraftId '26.1' -Snapshot $snapshot
        $preferred=Get-MmtlNeoForgePreferredCandidate -MinecraftId '26.1' -Candidates $mixed
        $preferred.candidate.version | Should -BeExactly '26.1.0.4'
        $preferred.status | Should -Be 'PreferredStable'
        $beta=Get-MmtlNeoForgePreferredCandidate -MinecraftId '1.21.1' -Candidates @( [pscustomobject]@{version='21.1.181-beta';stable=$false;rawQualifier='-beta'} )
        $beta.candidate.version | Should -BeExactly '21.1.181-beta'
        $beta.status | Should -Be 'BetaOnly'
    }

    It 'does not turn endpoint errors or malformed XML into unavailable versions' {
        $down=Get-MmtlNeoForgeProviderSnapshot -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'neo-down') -HttpGet {throw 'network down'}
        $down.providerStatus | Should -Be 'Unavailable'
        (Get-MmtlNeoForgeAvailability -MinecraftId '26.1' -Snapshot $down).availability | Should -Be 'Unknown'
        $bad=Get-MmtlNeoForgeProviderSnapshot -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'neo-bad') -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes('<!DOCTYPE x [<!ENTITY e SYSTEM "file:///secret">]><metadata>&e;</metadata>');ResponseUri=$Uri}}
        (Get-MmtlNeoForgeAvailability -MinecraftId '26.1' -Snapshot $bad).availability | Should -Be 'Unknown'
    }
}
