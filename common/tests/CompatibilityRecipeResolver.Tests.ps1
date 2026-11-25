BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:projectRoot = Split-Path -Parent $script:repoRoot
    Import-Module (Join-Path $script:repoRoot 'src/Compatibility/CompatibilityRecipeResolver.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Compatibility/FullCompatibilityLedger.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Validation/FamilyBatchPolicy.psm1') -Force
    $script:universe = Get-Content (Join-Path $script:repoRoot '../compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
    $script:pinCatalog = Get-Content (Join-Path $script:repoRoot '../compatibility/fabric-build-pins.json') -Raw | ConvertFrom-Json
    $script:quiltPinCatalog = Get-Content (Join-Path $script:repoRoot '../compatibility/quilt-build-pins.json') -Raw | ConvertFrom-Json
    $script:forgePinCatalog = Get-Content (Join-Path $script:repoRoot '../compatibility/forge-build-pins.json') -Raw | ConvertFrom-Json
    $script:runtimeJavaCatalog = Get-Content (Join-Path $script:repoRoot '../compatibility/runtime-java-catalog.json') -Raw | ConvertFrom-Json
    $script:familyManifest = Get-Content (Join-Path $script:repoRoot '../compatibility/families.json') -Raw | ConvertFrom-Json
    $script:target = $script:universe.targets | Where-Object targetId -CEQ 'Fabric@1.21.8' | Select-Object -First 1
    $script:family = $script:familyManifest.families | Where-Object { $_.loaderId -ceq 'Fabric' -and $_.minecraftIds -contains '1.21.8' } | Select-Object -First 1
    $script:ledgerTarget = [pscustomobject]@{
        targetId = 'Fabric@1.21.8'; loaderId = 'Fabric'; minecraftId = '1.21.8'
        familyId = $script:family.familyId; sourceHash = $script:target.sourceHash
        toolchainHash = $script:family.toolchainHash; targetSpecHash = ('a' * 64)
    }
}

Describe 'Family-first exact compatibility recipe resolver' {
    It 'resolves only a pinned exact Fabric target with matching family and fixture provenance' {
        $recipe = Resolve-MmtlCompatibilityRecipe -TargetId 'Fabric@1.21.8' -Universe $script:universe -TargetLedger $script:ledgerTarget -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -RepositoryRoot $script:projectRoot
        $recipe.status | Should -BeExactly 'RecipeReady'
        $recipe.targetSpecHash | Should -BeExactly ('a' * 64)
        $recipe.build.gradleVersion | Should -BeExactly '9.7.1'
        $recipe.build.loaderVersion | Should -BeExactly '0.19.5'
        $recipe.fixture.fixtureId | Should -BeExactly 'MMTLFabricMarkerFixtureV1'
        $recipe.recipeSha256 | Should -Match '^[a-f0-9]{64}$'
        $recipe.adapterSha256 | Should -BeExactly 'f21a4b0098cace1ddaff5bfb41ec9c2352752f739e01782412d8cee2c88e7829'
        $recipe.familyRuleSha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'leaves exact targets without a trusted recipe internally pending' {
        $otherTarget = $script:universe.targets | Where-Object loaderId -CEQ 'Quilt' | Select-Object -First 1
        $otherFamily = $script:familyManifest.families | Where-Object { $_.loaderId -ceq $otherTarget.loaderId -and $_.minecraftIds -contains $otherTarget.minecraftId } | Select-Object -First 1
        $otherLedger = [pscustomobject]@{ targetId=$otherTarget.targetId; loaderId=$otherTarget.loaderId; minecraftId=$otherTarget.minecraftId; familyId=$otherFamily.familyId; sourceHash=$otherTarget.sourceHash; toolchainHash=$otherFamily.toolchainHash; targetSpecHash=('c'*64) }
        $result = Resolve-MmtlCompatibilityRecipe -TargetId $otherTarget.targetId -Universe $script:universe -TargetLedger $otherLedger -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -RepositoryRoot $script:projectRoot
        $result.status | Should -BeExactly 'InternalPending'
        $result.reasonCode | Should -BeExactly 'EXACT_RECIPE_NOT_IMPLEMENTED'
        $result.universeHash | Should -BeExactly $script:universe.catalogHash
    }

    It 'rejects a pin whose source archive hash disagrees with its fixture manifest' {
        $badPins = $script:pinCatalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        ($badPins.targets | Where-Object targetId -CEQ 'Fabric@1.21.8' | Select-Object -First 1).sourceArchiveSha256 = '0' * 64
        { Resolve-MmtlCompatibilityRecipe -TargetId 'Fabric@1.21.8' -Universe $script:universe -TargetLedger $script:ledgerTarget -FamilyManifest $script:familyManifest -PinCatalog $badPins -RepositoryRoot $script:projectRoot } | Should -Throw '*RECIPE_FIXTURE_PIN_MISMATCH*'
    }

    It 'rejects a ledger row for a different exact target' {
        $wrong = $script:ledgerTarget | ConvertTo-Json | ConvertFrom-Json
        $wrong.targetId = 'Fabric@1.21.11'
        { Resolve-MmtlCompatibilityRecipe -TargetId 'Fabric@1.21.8' -Universe $script:universe -TargetLedger $wrong -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -RepositoryRoot $script:projectRoot } | Should -Throw '*RECIPE_LEDGER_TARGET_MISMATCH*'
    }

    It 'resolves trusted exact Quilt pins into a homogeneous immutable family batch' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $recipes = foreach ($id in @('Quilt@1.20.4','Quilt@1.20.6')) {
            $row = $ledger.targets | Where-Object targetId -CEQ $id | Select-Object -First 1
            Resolve-MmtlCompatibilityRecipe -TargetId $id -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -QuiltPinCatalog $script:quiltPinCatalog -RepositoryRoot $script:projectRoot
        }

        @($recipes | Where-Object status -CEQ 'RecipeReady') | Should -HaveCount 2
        $recipes[0].loaderId | Should -BeExactly 'Quilt'
        $recipes[1].build.loomVersion | Should -BeExactly '1.7.4'
        $batch = New-MmtlFamilyBatchSnapshot -Recipes $recipes -BatchOrdinal 0 -CreatedAtUtc ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $batch.loaderId | Should -BeExactly 'Quilt'
        $batch.targetCount | Should -Be 2
        $batch.targets[0].buildToolId | Should -BeExactly 'QuiltLoom'
        (Test-MmtlFamilyBatchSnapshot -Snapshot $batch).isValid | Should -BeTrue
    }

    It 'rejects a Quilt pin whose source archive hash disagrees with the target fixture' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Quilt@1.20.6' | Select-Object -First 1
        $badPins = $script:quiltPinCatalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        ($badPins.targets | Where-Object targetId -CEQ 'Quilt@1.20.6' | Select-Object -First 1).sourceArchiveSha256 = '0' * 64

        { Resolve-MmtlCompatibilityRecipe -TargetId 'Quilt@1.20.6' -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -QuiltPinCatalog $badPins -RepositoryRoot $script:projectRoot } | Should -Throw '*RECIPE_QUILT_FIXTURE_PIN_MISMATCH*'
    }

    It 'rejects a Quilt Adapter whose family evidence hash is stale' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Quilt@1.20.6' | Select-Object -First 1
        $families = $script:familyManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $family = $families.families | Where-Object familyId -CEQ 'quilt-loom-build-launch-plan-v1' | Select-Object -First 1
        $family.evidence = @($family.evidence | ForEach-Object { if ([string]$_ -match '^quilt-adapter-sha256:') { 'quilt-adapter-sha256:' + ('0' * 64) } else { [string]$_ } })

        { Resolve-MmtlCompatibilityRecipe -TargetId 'Quilt@1.20.6' -Universe $script:universe -TargetLedger $row -FamilyManifest $families -PinCatalog $script:pinCatalog -QuiltPinCatalog $script:quiltPinCatalog -RepositoryRoot $script:projectRoot } | Should -Throw '*RECIPE_ADAPTER_HASH_MISMATCH:Quilt@1.20.6*'
    }

    It 'resolves Forge 1.16.5 from its exact MDK, marker overlay, adapter and Mojang Java evidence' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.16.5' | Select-Object -First 1
        $recipe = Resolve-MmtlCompatibilityRecipe -TargetId 'Forge@1.16.5' -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot $script:projectRoot

        $recipe.status | Should -BeExactly 'RecipeReady'
        $recipe.loaderId | Should -BeExactly 'Forge'
        $recipe.build.loaderVersion | Should -BeExactly '1.16.5-36.2.42'
        $recipe.build.buildToolId | Should -BeExactly 'ForgeGradle'
        $recipe.build.runtimeJavaMajor | Should -Be 8
        $batch = New-MmtlFamilyBatchSnapshot -Recipes @($recipe) -BatchOrdinal 0 -CreatedAtUtc ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $batch.targets[0].buildToolId | Should -BeExactly 'ForgeGradle'
        (Test-MmtlFamilyBatchSnapshot -Snapshot $batch).isValid | Should -BeTrue
    }

    It 'accepts the exact source-archive Family evidence format used by Forge 1.7.2' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.7.2' | Select-Object -First 1
        $pin = $script:forgePinCatalog.targets | Where-Object targetId -CEQ 'Forge@1.7.2' | Select-Object -First 1
        $fixtureRoot = Join-Path $TestDrive 'repo/common/fixtures/forge/1.7.2-marker'
        $metadataRoot = Join-Path $fixtureRoot '.mmtl-fixture'
        $adapterRoot = Join-Path $TestDrive 'repo/common/src/Adapters'
        New-Item -ItemType Directory -Path $metadataRoot,$adapterRoot -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:projectRoot 'common/src/Adapters/Forge.psm1') -Destination (Join-Path $adapterRoot 'Forge.psm1')
        $overlayFiles = @(
            [pscustomobject]@{path='src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java';content='forge 1.7.2 marker'},
            [pscustomobject]@{path='src/main/resources/mcmod.info';content='forge 1.7.2 metadata'}
        )
        $records = foreach ($file in $overlayFiles) {
            $path = Join-Path $fixtureRoot $file.path
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [IO.File]::WriteAllText($path,$file.content,[Text.Encoding]::UTF8)
            [pscustomobject]@{path=$file.path;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
        $ordered = @($records | ForEach-Object { "$($_.path)|$($_.sha256)" }); [Array]::Sort($ordered,[StringComparer]::Ordinal)
        $overlayText = $ordered -join "`n"
        $overlaySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($overlayText))).ToLowerInvariant()
        $manifest = [ordered]@{fixtureId='MMTLForgeMarkerFixtureV1';targetId='Forge@1.7.2';sourceArchiveUrl=$pin.sourceArchiveUrl;sourceArchiveSha256=$pin.sourceArchiveSha256;overlaySha256=$overlaySha256;overlayFiles=$records}
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $metadataRoot 'manifest.json') -Encoding utf8

        $recipe = Resolve-MmtlCompatibilityRecipe -TargetId 'Forge@1.7.2' -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot (Join-Path $TestDrive 'repo')

        $recipe.status | Should -BeExactly 'RecipeReady'
        $recipe.familyId | Should -BeExactly 'forge-gradle-source-715210c0156c'
        $recipe.source.archiveSha256 | Should -BeExactly '7c05fc6eaf3520b97248203e2ae2eeeb372eb8fb9d65db7f9ad0f71aacd1ea33'
    }

    It 'keeps Forge targets pending when no exact verified marker fixture exists' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.7.10' | Select-Object -First 1
        $emptyRepository = Join-Path $TestDrive 'empty-repo'
        New-Item -ItemType Directory -Path (Join-Path $emptyRepository 'common/src/Adapters') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:projectRoot 'common/src/Adapters/Forge.psm1') -Destination (Join-Path $emptyRepository 'common/src/Adapters/Forge.psm1')
        $recipe = Resolve-MmtlCompatibilityRecipe -TargetId 'Forge@1.7.10' -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot $emptyRepository
        $recipe.status | Should -BeExactly 'InternalPending'
        $recipe.reasonCode | Should -BeExactly 'EXACT_FIXTURE_NOT_IMPLEMENTED'
    }

    It 'rejects a Forge Adapter whose Family evidence hash is stale' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.16.5' | Select-Object -First 1
        $families = $script:familyManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $family = $families.families | Where-Object familyId -CEQ 'forge-gradle-spec-05ce0c994cd4' | Select-Object -First 1
        $family.evidence = @($family.evidence | ForEach-Object { if ([string]$_ -match '^forge-adapter-sha256:') { 'forge-adapter-sha256:' + ('0' * 64) } else { [string]$_ } })

        { Resolve-MmtlCompatibilityRecipe -TargetId 'Forge@1.16.5' -Universe $script:universe -TargetLedger $row -FamilyManifest $families -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot $script:projectRoot } | Should -Throw '*RECIPE_ADAPTER_HASH_MISMATCH:Forge@1.16.5*'
    }

    It 'resolves every Forge pin that has an exact marker fixture into a build-tool-bound recipe' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $fixturePins = @($script:forgePinCatalog.targets | Where-Object { Test-Path -LiteralPath (Join-Path $script:projectRoot "common/fixtures/forge/$($_.minecraftId)-marker/.mmtl-fixture/manifest.json") -PathType Leaf })
        $recipes = foreach ($pin in $fixturePins) {
            $row = $ledger.targets | Where-Object targetId -CEQ $pin.targetId | Select-Object -First 1
            Resolve-MmtlCompatibilityRecipe -TargetId ([string]$pin.targetId) -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot $script:projectRoot
        }

        $recipes | Should -HaveCount 27
        @($recipes | Where-Object status -CNE 'RecipeReady') | Should -HaveCount 0
        @($recipes | Where-Object { $_.build.buildToolId -cne 'ForgeGradle' }) | Should -HaveCount 0
        @($recipes | Where-Object { $_.build.runtimeJavaMajor -lt 1 -or $_.build.buildJavaMajor -lt 1 }) | Should -HaveCount 0
        $forge189 = @($recipes | Where-Object targetId -CEQ 'Forge@1.8.9')[0]
        $forge189.fixture.overlayFiles | Should -HaveCount 3
        @($forge189.fixture.overlayFiles | Where-Object path -CEQ 'build.gradle') | Should -HaveCount 1
    }

    It 'resolves Forge 1.18.2 when its exact marker fixture is present' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.18.2' | Select-Object -First 1
        $recipe = Resolve-MmtlCompatibilityRecipe -TargetId 'Forge@1.18.2' -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot $script:projectRoot

        $recipe.status | Should -BeExactly 'RecipeReady'
        $recipe.targetId | Should -BeExactly 'Forge@1.18.2'
        $recipe.fixture.fixtureId | Should -BeExactly 'MMTLForgeMarkerFixtureV1'
        $recipe.build.loaderVersion | Should -BeExactly '1.18.2-40.3.11'
        $recipe.build.buildToolId | Should -BeExactly 'ForgeGradle'
        $recipe.recipeSha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'resolves the TaCZ baseline Forge 1.20.1 from its exact frozen MDK and marker fixture' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.20.1' | Select-Object -First 1
        $recipe = Resolve-MmtlCompatibilityRecipe -TargetId 'Forge@1.20.1' -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot $script:projectRoot

        $recipe.status | Should -BeExactly 'RecipeReady'
        $recipe.build.loaderVersion | Should -BeExactly '1.20.1-47.4.5'
        $recipe.build.buildToolId | Should -BeExactly 'ForgeGradle'
        $recipe.build.runtimeJavaMajor | Should -Be 17
        $recipe.fixture.fixtureId | Should -BeExactly 'MMTLForgeMarkerFixtureV1'
        $recipe.recipeSha256 | Should -Match '^[a-f0-9]{64}$'
    }

    It 'resolves Forge 1.9.4 from its exact official MDK, marker fixture, and verified Java metadata' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.9.4' | Select-Object -First 1
        $recipe = Resolve-MmtlCompatibilityRecipe -TargetId 'Forge@1.9.4' -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot $script:projectRoot

        $recipe.status | Should -BeExactly 'RecipeReady'
        $recipe.build.loaderVersion | Should -BeExactly '1.9.4-12.17.0.2317-1.9.4'
        $recipe.build.buildToolId | Should -BeExactly 'ForgeGradle'
        $recipe.build.buildToolVersion | Should -BeExactly '2.2-20210802.021822-44'
        $recipe.build.gradleVersion | Should -BeExactly '2.7'
        $recipe.build.buildJavaMajor | Should -Be 8
        $recipe.build.runtimeJavaMajor | Should -Be 8
        $recipe.source.archiveSha256 | Should -BeExactly 'f67f96e2ccd98f32987c0fb515f53ac51eac3235aff90ef97b2f9a6e0dd9132b'
        $recipe.fixture.fixtureId | Should -BeExactly 'MMTLForgeMarkerFixtureV1'
        $batch = New-MmtlFamilyBatchSnapshot -Recipes @($recipe) -BatchOrdinal 0 -CreatedAtUtc ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $batch.loaderId | Should -BeExactly 'Forge'
        $batch.targetCount | Should -Be 1
        (Test-MmtlFamilyBatchSnapshot -Snapshot $batch).isValid | Should -BeTrue
    }

    It 'resolves Forge 1.15 from its exact official MDK and verified ForgeGradle 3 inputs' {
        $ledger = New-MmtlFullCompatibilityLedger -Universe $script:universe -FamilyManifest $script:familyManifest -GeneratedAt ([DateTimeOffset]'2026-10-15T00:00:00Z')
        $row = $ledger.targets | Where-Object targetId -CEQ 'Forge@1.15' | Select-Object -First 1
        $recipe = Resolve-MmtlCompatibilityRecipe -TargetId 'Forge@1.15' -Universe $script:universe -TargetLedger $row -FamilyManifest $script:familyManifest -PinCatalog $script:pinCatalog -ForgePinCatalog $script:forgePinCatalog -RuntimeJavaCatalog $script:runtimeJavaCatalog -RepositoryRoot $script:projectRoot

        $recipe.status | Should -BeExactly 'RecipeReady'
        $recipe.build.loaderVersion | Should -BeExactly '1.15-29.0.4'
        $recipe.build.buildToolId | Should -BeExactly 'ForgeGradle'
        $recipe.build.buildToolVersion | Should -BeExactly '3.0.197'
        $recipe.build.gradleVersion | Should -BeExactly '4.9'
        $recipe.build.buildJavaMajor | Should -Be 8
        $recipe.build.runtimeJavaMajor | Should -Be 8
        $recipe.source.archiveSha256 | Should -BeExactly 'b90cd94af798bc078a5b2ae8eb3df10aba50476fd716926990ab30c8c23cd556'
        $recipe.fixture.fixtureId | Should -BeExactly 'MMTLForgeMarkerFixtureV1'
    }

}
