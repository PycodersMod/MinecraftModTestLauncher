BeforeAll {
    $script:modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Compatibility/CompatibilityUniverse.psm1'
    if (Test-Path -LiteralPath $script:modulePath) { Import-Module $script:modulePath -Force }
}

Describe 'Compatibility Universe exact target generation' {
    It 'combines only release catalog entries with explicitly available loader versions and sorts deterministically' {
        $catalog = [pscustomobject]@{
            manifestHash = 'a' * 64
            entries = @(
                [pscustomobject]@{ id = '1.20.1'; type = 'release'; releaseTime = '2023-06-12T00:00:00Z' }
                [pscustomobject]@{ id = '24w14a'; type = 'snapshot'; releaseTime = '2024-04-03T00:00:00Z' }
            )
        }
        $snapshots = @([pscustomobject]@{
            loaderId = 'ExampleLoader'; providerStatus = 'Available'; sourceUrl = 'https://example.invalid/game'
            sourceClass = 'ActiveOfficial'; trustClass = 'TrustedOfficial'; transportSecurity = 'HTTPS'; maintenanceState = 'Active'
            sourceHash = 'f' * 64; supportedVersions = @([pscustomobject]@{ version = '1.20.1'; stable = $true })
            loaderCandidatesByMinecraft = [pscustomobject]@{ '1.20.1' = @('fabric-loader-0.1') }
        })

        $universe = New-MmtlCompatibilityUniverse -Catalog $catalog -LoaderSnapshots $snapshots -GeneratedAt ([DateTimeOffset]'2026-10-07T00:00:00Z')

        $universe.targets.Count | Should -Be 1
        $universe.targets[0].targetId | Should -Be 'ExampleLoader@1.20.1'
        $universe.targets[0].minecraftType | Should -Be 'release'
        $universe.targets[0].status | Should -Be 'Unknown'
        $universe.targets[0].sourceHash | Should -Be ('f' * 64)
        $universe.targets[0].loaderVersionCandidates | Should -Contain 'fabric-loader-0.1'
        $universe.auditStatus | Should -Be 'IN_PROGRESS'
        $universe.catalogHash | Should -Match '^[a-f0-9]{64}$'
    }

    It 'retains unknown provider snapshots as audit issues instead of inferring no support' {
        $catalog = [pscustomobject]@{ manifestHash = 'b' * 64; entries = @() }
        $snapshots = @([pscustomobject]@{
            loaderId = 'UnresolvedLoader'; providerStatus = 'Unavailable'; sourceUrl = 'https://example.invalid/game'
            sourceClass = 'Unknown'; trustClass = 'Unknown'; transportSecurity = 'HTTPS'; maintenanceState = 'Unknown'
            supportedVersions = @(); error = 'metadata timeout'
        })

        $universe = New-MmtlCompatibilityUniverse -Catalog $catalog -LoaderSnapshots $snapshots -GeneratedAt ([DateTimeOffset]'2026-10-07T00:00:00Z')

        $universe.targets.Count | Should -Be 0
        $universe.issues.Count | Should -Be 1
        $universe.issues[0].loaderId | Should -Be 'UnresolvedLoader'
        $universe.issues[0].status | Should -Be 'Unknown'
    }

    It 'serializes deterministic exact targets that conform to the public schema' {
        $catalog = [pscustomobject]@{ manifestHash = 'c' * 64; entries = @([pscustomobject]@{ id = 'b1.2_02'; type = 'old_beta'; releaseTime = $null }) }
        $snapshot = [pscustomobject]@{
            loaderId = 'LegacyFixture'; providerStatus = 'Available'; sourceUrl = 'https://example.invalid/versions'
            sourceClass = 'HistoricalOfficial'; trustClass = 'TrustedOfficial'; transportSecurity = 'HTTPS'; maintenanceState = 'Archived'
            supportedVersions = @('b1.2_02')
        }
        $time = [DateTimeOffset]'2026-10-07T00:00:00Z'
        $first = New-MmtlCompatibilityUniverse -Catalog $catalog -LoaderSnapshots @($snapshot) -GeneratedAt $time
        $second = New-MmtlCompatibilityUniverse -Catalog $catalog -LoaderSnapshots @($snapshot) -GeneratedAt $time
        $schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/compatibility-universe.schema.json'

        $first.targets[0].minecraftId | Should -Be 'b1.2_02'
        $first.targets[0].minecraftType | Should -Be 'old_beta'
        $first.catalogHash | Should -Be $second.catalogHash
        (Test-Json -Json ($first | ConvertTo-Json -Depth 30 -Compress) -SchemaFile $schemaPath) | Should -BeTrue
    }

    It 'keeps partial provider data visible but marks degraded source coverage as unknown' {
        $catalog = [pscustomobject]@{ manifestHash = 'd' * 64; entries = @([pscustomobject]@{ id = '1.20.1'; type = 'release'; releaseTime = '2023-06-12T00:00:00Z' }) }
        $snapshot = [pscustomobject]@{
            loaderId = 'DegradedLoader'; providerStatus = 'Degraded'; sourceUrl = 'https://example.invalid/versions'
            sourceClass = 'ActiveOfficial'; trustClass = 'TrustedOfficial'; transportSecurity = 'HTTPS'; maintenanceState = 'Active'
            supportedVersions = @('1.20.1'); error = 'candidate endpoint timed out'
        }

        $universe = New-MmtlCompatibilityUniverse -Catalog $catalog -LoaderSnapshots @($snapshot) -GeneratedAt ([DateTimeOffset]'2026-10-07T00:00:00Z')

        $universe.targets.Count | Should -Be 1
        $universe.issues.Count | Should -Be 1
        $universe.issues[0].reason | Should -Be 'SOURCE_NOT_FRESH_OR_COMPLETE'
    }

    It 'changes the frozen source hash when the exact availability set changes' {
        $catalog = [pscustomobject]@{ manifestHash = 'e' * 64; entries = @(
            [pscustomobject]@{ id = '1.20.1'; type = 'release'; releaseTime = '2023-06-12T00:00:00Z' }
            [pscustomobject]@{ id = '1.19.4'; type = 'release'; releaseTime = '2022-12-07T00:00:00Z' }
        ) }
        $one = [pscustomobject]@{ loaderId='HashLoader';providerStatus='Available';sourceUrl='https://example.invalid/versions';sourceClass='ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS';maintenanceState='Active';supportedVersions=@('1.20.1') }
        $two = [pscustomobject]@{ loaderId='HashLoader';providerStatus='Available';sourceUrl='https://example.invalid/versions';sourceClass='ActiveOfficial';trustClass='TrustedOfficial';transportSecurity='HTTPS';maintenanceState='Active';supportedVersions=@('1.19.4','1.20.1') }

        $first = New-MmtlCompatibilityUniverse -Catalog $catalog -LoaderSnapshots @($one) -GeneratedAt ([DateTimeOffset]'2026-10-07T00:00:00Z')
        $second = New-MmtlCompatibilityUniverse -Catalog $catalog -LoaderSnapshots @($two) -GeneratedAt ([DateTimeOffset]'2026-10-07T00:00:00Z')

        $first.catalogHash | Should -Not -Be $second.catalogHash
    }

    It 'retains loader-listed historical IDs missing from Mojang manifest as unknown exact targets' {
        $catalog = [pscustomobject]@{ manifestHash = 'a' * 64; entries = @([pscustomobject]@{ id = '1.0'; type = 'release'; releaseTime = '2011-11-18T00:00:00Z' }) }
        $snapshot = [pscustomobject]@{
            loaderId = 'OldLoader'; providerStatus = 'Available'; sourceUrl = 'https://example.invalid/versions'
            sourceClass = 'HistoricalOfficial'; trustClass = 'TrustedOfficial'; transportSecurity = 'HTTPS'; maintenanceState = 'Archived'
            supportedVersions = @('b1.2_02')
        }

        $universe = New-MmtlCompatibilityUniverse -Catalog $catalog -LoaderSnapshots @($snapshot) -GeneratedAt ([DateTimeOffset]'2026-10-07T00:00:00Z')

        $universe.targets.Count | Should -Be 1
        $universe.targets[0].minecraftId | Should -Be 'b1.2_02'
        $universe.targets[0].minecraftType | Should -Be 'Unknown'
        $universe.issues[0].reason | Should -Be 'MINECRAFT_ID_NOT_RESOLVED_IN_MOJANG_CATALOG'
    }
}
