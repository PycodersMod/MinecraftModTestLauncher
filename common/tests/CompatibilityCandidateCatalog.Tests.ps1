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
}
