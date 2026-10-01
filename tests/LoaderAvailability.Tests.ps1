BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/LoaderAvailability.psm1') -Force
    $script:catalog=[pscustomobject]@{schemaVersion=1;manifestHash='fixture-mojang-hash';latestRelease='26.3';entries=@('1.20.1','1.20.2','26.3','1.19.4')|ForEach-Object{[pscustomobject]@{id=$_;type='release'}}}
    $script:docs=@{
        forgePromotions='{"promos":{"1.20.1-recommended":"47.2.0","1.20.1-latest":"47.3.0"}}'
        forge='<metadata><groupId>net.minecraftforge</groupId><artifactId>forge</artifactId><versioning><versions><version>1.20.1-47.2.0</version><version>1.20.1-47.3.0</version><version>1.20.2-48.0.0</version><version>26.3-66.0.9</version></versions></versioning></metadata>'
        fabricGame='[{"version":"1.20.1","stable":true},{"version":"1.20.2","stable":true},{"version":"26.3","stable":true}]'
        quiltGame='[{"version":"1.20.1","stable":true},{"version":"26.3","stable":true}]'
        neo='<metadata><groupId>net.neoforged</groupId><artifactId>neoforge</artifactId><versioning><versions><version>20.2.59</version><version>26.3.0.39-beta</version></versions></versioning></metadata>'
        transition='<metadata><groupId>net.neoforged</groupId><artifactId>forge</artifactId><versioning><versions><version>1.20.1-47.1.106</version></versions></versioning></metadata>'
    }
    $docs=$script:docs
    $script:http={param($Uri,$Headers,$TimeoutSeconds)
        $parsed=[Uri]$Uri
        if($parsed.Host -eq 'files.minecraftforge.net'){$body=$docs.forgePromotions}
        elseif($parsed.Host -eq 'maven.minecraftforge.net'){$body=$docs.forge}
        elseif($parsed.Host -eq 'meta.fabricmc.net'){$body=$docs.fabricGame}
        elseif($parsed.Host -eq 'meta.quiltmc.org'){$body=$docs.quiltGame}
        elseif($parsed.Host -eq 'maven.neoforged.net' -and $parsed.AbsolutePath -match '/neoforge/maven-metadata'){$body=$docs.neo}
        elseif($parsed.Host -eq 'maven.neoforged.net' -and $parsed.AbsolutePath -match '/forge/maven-metadata'){$body=$docs.transition}
        else{throw "Unexpected endpoint in availability-only test: $Uri"}
        [pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($body);ResponseUri=$Uri}
    }.GetNewClosure()
}

Describe 'Loader availability index' {
    It 'combines official global metadata per release without fetching per-version candidates' {
        $runtime=Join-Path $TestDrive 'runtime'
        $index=Get-MmtlLoaderAvailabilityIndex -Catalog $script:catalog -RuntimeRoot $runtime -HttpGet $script:http
        $index.schemaVersion | Should -Be 1
        $index.minecraftCatalogHash | Should -BeExactly 'fixture-mojang-hash'
        @($index.entries.minecraftId) | Should -Be @('1.20.1','1.20.2','26.3','1.19.4')
        $entry=$index.entries|Where-Object minecraftId -eq '1.20.1'
        $entry.loaders.Forge.availability | Should -Be 'Available'
        $entry.loaders.Fabric.availability | Should -Be 'Available'
        $entry.loaders.NeoForge.availability | Should -Be 'Available'
        $entry.loaders.Quilt.availability | Should -Be 'Available'
        $old=$index.entries|Where-Object minecraftId -eq '1.19.4'
        $old.loaders.Forge.availability | Should -Be 'Unavailable'
        @($old.loaders.Forge.notes).Count | Should -Be 0
        (Test-Path (Join-Path $runtime 'metadata/loaders/availability-index.json')) | Should -BeTrue
        $cacheFiles=Get-ChildItem (Join-Path $runtime 'metadata/loaders') -Recurse -File -Filter '*.json'
        @($cacheFiles|Where-Object FullName -Match 'loader-1\.20\.1').Count | Should -Be 0
    }

    It 'isolates provider failure as Unknown and preserves other results' {
        $baseHttp=$script:http
        $http={param($Uri,$Headers,$TimeoutSeconds)if($Uri -match 'forge'){throw 'forge isolated outage'};& $baseHttp $Uri $Headers $TimeoutSeconds}.GetNewClosure()
        $index=Get-MmtlLoaderAvailabilityIndex -Catalog $script:catalog -RuntimeRoot (Join-Path $TestDrive 'partial') -HttpGet $http
        $row=$index.entries|Where-Object minecraftId -eq '1.20.1'
        $row.loaders.Forge.availability | Should -Be 'Unknown'
        $row.loaders.Fabric.availability | Should -Be 'Available'
        $row.loaders.Quilt.availability | Should -Be 'Available'
        $index.providerStatuses.Forge.status | Should -Be 'Unavailable'
    }

    It 'rebuilds the index offline from independent provider caches without HTTP' {
        $runtime=Join-Path $TestDrive 'offline'
        $null=Get-MmtlLoaderAvailabilityIndex -Catalog $script:catalog -RuntimeRoot $runtime -HttpGet $script:http
        $offline=Get-MmtlLoaderAvailabilityIndex -Catalog $script:catalog -RuntimeRoot $runtime -Offline -HttpGet {throw 'offline index must not call upstream'}
        $offline.cacheStatus | Should -Be 'OfflineCache'
        ($offline.entries|Where-Object minecraftId -eq '1.20.1').loaders.Forge.availability | Should -Be 'Available'
    }
}
