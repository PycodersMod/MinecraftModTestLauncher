BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Compatibility/CompatibilityCandidateCatalog.psm1'
    Import-Module $modulePath -Force
}

Describe 'Compatibility candidate catalog' {
    It 'preserves exact loader versions and upstream order with raw source evidence' {
        $provider = [pscustomobject]@{
            providerStatus = 'Available'
            sourceUrl = 'https://meta.example.invalid/loader/1.20.1'
            localHash = 'a' * 64
            candidates = @(
                [pscustomobject]@{ loaderVersion = '0.16.9+build.1'; stable = $true }
                [pscustomobject]@{ loaderVersion = '0.16.9-rc1'; stable = $false }
                [pscustomobject]@{ loaderVersion = '0.16.9+build.1'; stable = $true }
            )
        }

        $result = New-MmtlCompatibilityCandidateResult -LoaderId Fabric -MinecraftId '1.20.1' -ProviderResult $provider

        $result.candidateStatus | Should -Be 'Resolved'
        $result.loaderVersions | Should -Be @('0.16.9+build.1', '0.16.9-rc1')
        $result.sourceHash | Should -Be ('a' * 64)
        $result.sourceUrl | Should -Be 'https://meta.example.invalid/loader/1.20.1'
    }

    It 'distinguishes a successful empty response from an unresolved source' {
        $empty = New-MmtlCompatibilityCandidateResult -LoaderId Quilt -MinecraftId '1.20.1' -ProviderResult ([pscustomobject]@{ providerStatus = 'Available'; sourceUrl = 'https://meta.quiltmc.org/v3/versions/loader/1.20.1'; localHash = 'b' * 64; candidates = @() })
        $failed = New-MmtlCompatibilityCandidateResult -LoaderId Quilt -MinecraftId '1.20.1' -ProviderResult ([pscustomobject]@{ providerStatus = 'Unavailable'; candidates = @(); error = 'HTTP_503' })

        $empty.candidateStatus | Should -Be 'NoCandidatesReturned'
        $failed.candidateStatus | Should -Be 'Unknown'
        $failed.error | Should -Be 'HTTP_503'
    }

    It 'rejects candidate metadata without HTTPS provenance or valid hashes' {
        { New-MmtlCompatibilityCandidateResult -LoaderId Fabric -MinecraftId '1.20.1' -ProviderResult ([pscustomobject]@{ providerStatus = 'Available'; sourceUrl = 'http://example.invalid'; localHash = 'a' * 64; candidates = @() }) } | Should -Throw
        { New-MmtlCompatibilityCandidateResult -LoaderId Fabric -MinecraftId '1.20.1' -ProviderResult ([pscustomobject]@{ providerStatus = 'Available'; sourceUrl = 'https://example.invalid'; localHash = 'bad'; candidates = @() }) } | Should -Throw
    }

    It 'keeps historical archive candidate identifiers exact' {
        $result = New-MmtlCompatibilityCandidateResult -LoaderId LiteLoader -MinecraftId '1.12.2' -ProviderResult ([pscustomobject]@{
            providerStatus = 'Available'; sourceUrl = 'https://dl.liteloader.com/versions/versions.json'; localHash = 'c' * 64
            candidates = @([pscustomobject]@{ loaderVersion = '1.12.2-SNAPSHOT-###'; version = 'ignored-normalized-value' })
        })

        $result.candidateStatus | Should -Be 'Resolved'
        $result.loaderVersions | Should -Be @('1.12.2-SNAPSHOT-###')
    }

    It 'joins complete exact-target catalogs only when every successful result has matching source evidence' {
        $hashOne = 'a' * 64
        $hashTwo = 'b' * 64
        $universe = [pscustomobject]@{auditStatus='FROZEN';candidateCatalogHash='0'*64;targets=@(
            [pscustomobject]@{targetId='Fabric@1.20.1';loaderId='Fabric';minecraftId='1.20.1';candidateStatus='Pending';loaderVersionCandidates=@();candidateSourceUrl=$null;candidateSourceHash=$null},
            [pscustomobject]@{targetId='Fabric@24w14a';loaderId='Fabric';minecraftId='24w14a';candidateStatus='Pending';loaderVersionCandidates=@();candidateSourceUrl=$null;candidateSourceHash=$null}
        )}
        $catalog = [pscustomobject]@{loaderId='Fabric';targetCount=2;resultCount=2;results=@(
            [pscustomobject]@{targetId='Fabric@1.20.1';minecraftId='1.20.1';candidateStatus='Resolved';loaderVersions=@('0.16.9','0.16.8');sourceUrl='https://meta.fabricmc.net/v2/versions/loader/1.20.1';sourceHash=$hashOne},
            [pscustomobject]@{targetId='Fabric@24w14a';minecraftId='24w14a';candidateStatus='Resolved';loaderVersions=@('0.15.11');sourceUrl='https://meta.fabricmc.net/v2/versions/loader/24w14a';sourceHash=$hashTwo}
        )}
        $evidence = @(
            [pscustomobject]@{providerId='FabricCandidates';sourceUrl=$catalog.results[0].sourceUrl;sha256=$hashOne;relativePath="FabricCandidates/$hashOne.bin";byteLength=10},
            [pscustomobject]@{providerId='FabricCandidates';sourceUrl=$catalog.results[1].sourceUrl;sha256=$hashTwo;relativePath="FabricCandidates/$hashTwo.bin";byteLength=10}
        )

        $joined = Join-MmtlCompatibilityCandidateCatalogs -Universe $universe -CandidateCatalogs @($catalog) -SourceEvidence $evidence -RequiredLoaderIds @('Fabric')

        $joined.targets[0].loaderVersionCandidates | Should -Be @('0.16.9','0.16.8')
        $joined.targets[0].candidateSourceHash | Should -Be $hashOne
        $joined.targets[1].candidateStatus | Should -Be 'Resolved'
        $joined.candidateCatalogHash | Should -Match '^[a-f0-9]{64}$'
        $joined.candidateCatalogHash | Should -Not -Be ('0' * 64)
    }

    It 'rejects incomplete exact-target catalog coverage and mismatched evidence provenance' {
        $hash = 'c' * 64
        $universe = [pscustomobject]@{auditStatus='FROZEN';candidateCatalogHash=$null;targets=@(
            [pscustomobject]@{targetId='Fabric@1.20.1';loaderId='Fabric';minecraftId='1.20.1';candidateStatus='Pending';loaderVersionCandidates=@();candidateSourceUrl=$null;candidateSourceHash=$null},
            [pscustomobject]@{targetId='Fabric@24w14a';loaderId='Fabric';minecraftId='24w14a';candidateStatus='Pending';loaderVersionCandidates=@();candidateSourceUrl=$null;candidateSourceHash=$null}
        )}
        $partial = [pscustomobject]@{loaderId='Fabric';targetCount=1;resultCount=1;results=@([pscustomobject]@{targetId='Fabric@1.20.1';minecraftId='1.20.1';candidateStatus='Resolved';loaderVersions=@('0.16.9');sourceUrl='https://meta.fabricmc.net/v2/versions/loader/1.20.1';sourceHash=$hash})}
        $badEvidence = @([pscustomobject]@{providerId='FabricCandidates';sourceUrl=$partial.results[0].sourceUrl;sha256=('d'*64);relativePath="FabricCandidates/$hash.bin";byteLength=10})

        { Join-MmtlCompatibilityCandidateCatalogs -Universe $universe -CandidateCatalogs @($partial) -SourceEvidence $badEvidence -RequiredLoaderIds @('Fabric') } | Should -Throw '*COVERAGE*'
        $complete = [pscustomobject]@{loaderId='Fabric';targetCount=2;resultCount=2;results=@($partial.results + [pscustomobject]@{targetId='Fabric@24w14a';minecraftId='24w14a';candidateStatus='Resolved';loaderVersions=@('0.15.11');sourceUrl='https://meta.fabricmc.net/v2/versions/loader/24w14a';sourceHash=$hash})}
        { Join-MmtlCompatibilityCandidateCatalogs -Universe $universe -CandidateCatalogs @($complete) -SourceEvidence $badEvidence -RequiredLoaderIds @('Fabric') } | Should -Throw '*SOURCE_EVIDENCE*'
    }

    It 'rejects a resolved non-catalog target when its candidate source hash is absent' {
        $hash = 'e' * 64
        $universe = [pscustomobject]@{auditStatus='FROZEN';candidateCatalogHash=$null;targets=@(
            [pscustomobject]@{targetId='Fabric@1.20.1';loaderId='Fabric';minecraftId='1.20.1';candidateStatus='Pending';loaderVersionCandidates=@();candidateSourceUrl=$null;candidateSourceHash=$null},
            [pscustomobject]@{targetId='Forge@1.20.1';loaderId='Forge';minecraftId='1.20.1';candidateStatus='Resolved';loaderVersionCandidates=@('1.20.1-47.2.0');candidateSourceUrl='https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml';candidateSourceHash=$null}
        )}
        $catalog = [pscustomobject]@{loaderId='Fabric';targetCount=1;resultCount=1;results=@([pscustomobject]@{targetId='Fabric@1.20.1';minecraftId='1.20.1';candidateStatus='Resolved';loaderVersions=@('0.16.9');sourceUrl='https://meta.fabricmc.net/v2/versions/loader/1.20.1';sourceHash=$hash})}
        $evidence = @([pscustomobject]@{providerId='FabricCandidates';sourceUrl=$catalog.results[0].sourceUrl;sha256=$hash;relativePath="FabricCandidates/$hash.bin";byteLength=10})

        { Join-MmtlCompatibilityCandidateCatalogs -Universe $universe -CandidateCatalogs @($catalog) -SourceEvidence $evidence -RequiredLoaderIds @('Fabric') } | Should -Throw '*SOURCE_PROVENANCE_MISSING*'
    }
}
