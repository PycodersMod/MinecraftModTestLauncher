Set-StrictMode -Version Latest

function Get-MmtlRecipeSha256 {
    param([Parameter(Mandatory)][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Test-MmtlRecipePathNoReparse {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$RelativePath)
    $rootPath=[IO.Path]::GetFullPath($Root)
    $rootItem=Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if(($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)-or $rootItem.LinkType){throw 'RECIPE_FIXTURE_REPARSE_POINT'}
    $cursor=$rootPath
    foreach($segment in @($RelativePath -split '[\\/]')){
        if([string]::IsNullOrWhiteSpace($segment)-or $segment -in @('.','..')){throw 'RECIPE_FIXTURE_PATH_UNSAFE'}
        $cursor=Join-Path $cursor $segment
        if(-not(Test-Path -LiteralPath $cursor)){throw 'RECIPE_FIXTURE_FILE_MISSING'}
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint)-or $item.LinkType){throw 'RECIPE_FIXTURE_REPARSE_POINT'}
    }
}

function Resolve-MmtlQuiltCompatibilityRecipe {
    param([Parameter(Mandatory)][string]$TargetId,[Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$TargetLedger,[Parameter(Mandatory)]$Family,[Parameter(Mandatory)][string]$FamilyRuleSha256,[Parameter(Mandatory)][string]$UniverseHash,[Parameter(Mandatory)]$PinCatalog,[Parameter(Mandatory)][string]$RepositoryRoot)
    if([int]$PinCatalog.schemaVersion -ne 1-or [string]$PinCatalog.status -cne 'PARTIAL'){throw 'RECIPE_QUILT_PIN_CATALOG_INVALID'}
    $pins=@($PinCatalog.targets|Where-Object{[string]$_.targetId -ceq $TargetId})
    if($pins.Count -eq 0){return [pscustomobject][ordered]@{status='InternalPending';targetId=$TargetId;loaderId='Quilt';minecraftId=[string]$Target.minecraftId;familyId=[string]$Family.familyId;universeHash=$UniverseHash;sourceHash=[string]$TargetLedger.sourceHash;toolchainHash=[string]$TargetLedger.toolchainHash;targetSpecHash=[string]$TargetLedger.targetSpecHash;reasonCode='EXACT_RECIPE_NOT_IMPLEMENTED'}}
    if($pins.Count -ne 1){throw "RECIPE_PIN_DUPLICATE:$TargetId"}
    $pin=$pins[0]
    if([string]$pin.sourceVerificationStatus -cne 'PinnedInputsVerified'){throw "RECIPE_PIN_NOT_TRUSTED:$TargetId"}
    if([string]$pin.minecraftVersion -cne [string]$Target.minecraftId-or [string]$pin.loaderVersion -notin @($Target.loaderVersionCandidates|ForEach-Object{[string]$_})){throw "RECIPE_PIN_TARGET_MISMATCH:$TargetId"}
    if([string]$pin.sourceArchiveSha256 -notmatch '^[a-f0-9]{64}$'-or [string]$pin.sourceCommit -notmatch '^[a-f0-9]{40}$'-or [string]$pin.gradleDistributionSha256 -notmatch '^[a-f0-9]{64}$'){throw "RECIPE_PIN_HASH_INVALID:$TargetId"}
    $adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/Quilt.psm1'
    if(-not(Test-Path -LiteralPath $adapterPath -PathType Leaf)){throw "RECIPE_ADAPTER_MISSING:$TargetId"}
    $adapterItem=Get-Item -LiteralPath $adapterPath -Force
    if(($adapterItem.Attributes -band [IO.FileAttributes]::ReparsePoint)-or $adapterItem.LinkType){throw "RECIPE_ADAPTER_REPARSE_POINT:$TargetId"}
    $adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $adapterRefs=@($Family.evidence|Where-Object{[string]$_ -match '^quilt-adapter-sha256:([a-f0-9]{64})$'})
    if($adapterRefs.Count -ne 1){throw "RECIPE_ADAPTER_EVIDENCE_MISSING:$TargetId"}
    $pinnedAdapterHash=([regex]::Match([string]$adapterRefs[0],'^quilt-adapter-sha256:([a-f0-9]{64})$')).Groups[1].Value
    if($pinnedAdapterHash -cne $adapterHash){throw "RECIPE_ADAPTER_HASH_MISMATCH:$TargetId"}

    $fixtureRoot=Join-Path $RepositoryRoot "common/fixtures/quilt/$($Target.minecraftId)-marker"
    $fixtureManifestPath=Join-Path $fixtureRoot '.mmtl-fixture/manifest.json'
    if(-not(Test-Path -LiteralPath $fixtureManifestPath -PathType Leaf)){throw "RECIPE_FIXTURE_MANIFEST_MISSING:$TargetId"}
    Test-MmtlRecipePathNoReparse -Root $RepositoryRoot -RelativePath "common/fixtures/quilt/$($Target.minecraftId)-marker/.mmtl-fixture/manifest.json"
    $fixture=Get-Content -LiteralPath $fixtureManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
    $manifestPairs=@(
        @('fixtureId','MMTLQuiltMarkerFixtureV1'),@('targetId',$TargetId),@('sourceRepository',[string]$pin.sourceRepository),
        @('sourceCommit',[string]$pin.sourceCommit),@('sourceArchiveSha256',[string]$pin.sourceArchiveSha256),
        @('sourceBuildGradleSha256',[string]$pin.sourceBuildGradleSha256),@('sourceSettingsGradleSha256',[string]$pin.sourceSettingsGradleSha256),
        @('sourceGradlePropertiesSha256',[string]$pin.sourceGradlePropertiesSha256),@('sourceVersionsTomlSha256',[string]$pin.sourceVersionsTomlSha256),
        @('sourceWrapperPropertiesSha256',[string]$pin.sourceWrapperPropertiesSha256),@('sourceWrapperJarSha256',[string]$pin.sourceWrapperJarSha256),
        @('quiltLoomVersion',[string]$pin.quiltLoomVersion),@('loaderVersion',[string]$pin.loaderVersion),@('gradleVersion',[string]$pin.gradleVersion),
        @('buildJavaMajor',[string]$pin.buildJavaMajor),@('runtimeJavaMajor',[string]$pin.runtimeJavaMajor)
    )
    foreach($pair in $manifestPairs){if([string]$fixture.($pair[0]) -cne [string]$pair[1]){throw "RECIPE_QUILT_FIXTURE_PIN_MISMATCH:${TargetId}:$($pair[0])"}}
    $files=@($fixture.overlayFiles)
    if($files.Count -ne 7){throw "RECIPE_FIXTURE_OVERLAY_COUNT_INVALID:$TargetId"}
    $records=[Collections.Generic.List[string]]::new()
    foreach($file in $files){
        $relative=[string]$file.path
        if([string]::IsNullOrWhiteSpace($relative)-or $relative.Contains('\')-or [IO.Path]::IsPathRooted($relative)-or @($relative -split '/'|Where-Object{$_ -in @('','.','..')}).Count -gt 0-or [string]$file.sha256 -notmatch '^[a-f0-9]{64}$'){throw "RECIPE_FIXTURE_PATH_UNSAFE:$TargetId"}
        Test-MmtlRecipePathNoReparse -Root $RepositoryRoot -RelativePath "common/fixtures/quilt/$($Target.minecraftId)-marker/$relative"
        $path=Join-Path $fixtureRoot $relative
        $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -cne [string]$file.sha256){throw "RECIPE_FIXTURE_FILE_HASH_MISMATCH:${TargetId}:$relative"}
        $records.Add("$relative|$actual")
    }
    $ordered=$records.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
    $overlayHash=Get-MmtlRecipeSha256 -Text ($ordered -join "`n")
    if($overlayHash -cne [string]$fixture.overlaySha256-or $overlayHash -cne [string]$pin.overlaySha256){throw "RECIPE_QUILT_FIXTURE_PIN_MISMATCH:${TargetId}:overlaySha256"}

    $recipe=[ordered]@{
        schemaVersion=1;status='RecipeReady';targetId=$TargetId;loaderId='Quilt';minecraftId=[string]$Target.minecraftId
        familyId=[string]$Family.familyId;familyRuleSha256=$FamilyRuleSha256;adapterSha256=$adapterHash
        universeHash=$UniverseHash;sourceHash=[string]$TargetLedger.sourceHash;toolchainHash=[string]$TargetLedger.toolchainHash;targetSpecHash=[string]$TargetLedger.targetSpecHash
        build=[ordered]@{loaderVersion=[string]$pin.loaderVersion;buildToolId='QuiltLoom';buildToolVersion=[string]$pin.quiltLoomVersion;quiltedFabricApiVersion=[string]$pin.quiltedFabricApiVersion;loomVersion=[string]$pin.quiltLoomVersion;gradleVersion=[string]$pin.gradleVersion;gradleDistributionUrl=[string]$pin.gradleDistributionUrl;gradleDistributionSha256=[string]$pin.gradleDistributionSha256;buildJavaMajor=[int]$pin.buildJavaMajor;runtimeJavaMajor=[int]$pin.runtimeJavaMajor}
        source=[ordered]@{repository=[string]$pin.sourceRepository;commit=[string]$pin.sourceCommit;archiveUrl=[string]$pin.sourceArchiveUrl;archiveSha256=[string]$pin.sourceArchiveSha256;license=[string]$pin.sourceLicense}
        fixture=[ordered]@{fixtureId=[string]$fixture.fixtureId;manifestPath=[IO.Path]::GetRelativePath($RepositoryRoot,$fixtureManifestPath).Replace('\','/');overlaySha256=$overlayHash;overlayFiles=$files}
    }
    $recipe.recipeSha256=Get-MmtlRecipeSha256 -Text (ConvertTo-Json -InputObject ([pscustomobject]$recipe) -Depth 30 -Compress)
    [pscustomobject]$recipe
}

function Resolve-MmtlForgeCompatibilityRecipe {
    param([Parameter(Mandatory)][string]$TargetId,[Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$TargetLedger,[Parameter(Mandatory)]$Family,[Parameter(Mandatory)][string]$FamilyRuleSha256,[Parameter(Mandatory)][string]$UniverseHash,[Parameter(Mandatory)]$PinCatalog,[Parameter(Mandatory)]$RuntimeJavaCatalog,[Parameter(Mandatory)][string]$RepositoryRoot)
    if([int]$PinCatalog.schemaVersion -ne 1-or [string]$PinCatalog.status -cne 'PARTIAL'){throw 'RECIPE_FORGE_PIN_CATALOG_INVALID'}
    if([string]$RuntimeJavaCatalog.universeHash -cne $UniverseHash){throw 'RECIPE_RUNTIME_JAVA_UNIVERSE_MISMATCH'}
    $pins=@($PinCatalog.targets|Where-Object{[string]$_.targetId -ceq $TargetId})
    if($pins.Count -eq 0){return [pscustomobject][ordered]@{status='InternalPending';targetId=$TargetId;loaderId='Forge';minecraftId=[string]$Target.minecraftId;familyId=[string]$Family.familyId;universeHash=$UniverseHash;sourceHash=[string]$TargetLedger.sourceHash;toolchainHash=[string]$TargetLedger.toolchainHash;targetSpecHash=[string]$TargetLedger.targetSpecHash;reasonCode='EXACT_RECIPE_NOT_IMPLEMENTED'}}
    if($pins.Count -ne 1){throw "RECIPE_PIN_DUPLICATE:$TargetId"}
    $pin=$pins[0]
    if([string]$pin.status -cne 'PinnedInputsVerified'){throw "RECIPE_PIN_NOT_TRUSTED:$TargetId"}
    if([string]$pin.minecraftId -cne [string]$Target.minecraftId-or [string]$pin.forgeVersion -notin @($Target.loaderVersionCandidates|ForEach-Object{[string]$_})){throw "RECIPE_PIN_TARGET_MISMATCH:$TargetId"}
    foreach($name in @('sourceArchiveSha256','buildGradleSha256','gradleDistributionSha256','forgeGradleJarSha256','forgeGradlePomSha256')){if([string]$pin.$name -notmatch '^[a-f0-9]{64}$'){throw "RECIPE_PIN_HASH_INVALID:${TargetId}:$name"}}
    $adapterPath=Join-Path $RepositoryRoot 'common/src/Adapters/Forge.psm1'
    $adapterRefs=@($Family.evidence|Where-Object{[string]$_ -match '^forge-adapter-sha256:([a-f0-9]{64})$'})
    if($adapterRefs.Count -ne 1-or -not(Test-Path -LiteralPath $adapterPath -PathType Leaf)){throw "RECIPE_ADAPTER_EVIDENCE_MISSING:$TargetId"}
    Test-MmtlRecipePathNoReparse -Root $RepositoryRoot -RelativePath 'common/src/Adapters/Forge.psm1'
    $adapterHash=(Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $pinnedAdapterHash=([regex]::Match([string]$adapterRefs[0],'^forge-adapter-sha256:([a-f0-9]{64})$')).Groups[1].Value
    if($adapterHash -cne $pinnedAdapterHash){throw "RECIPE_ADAPTER_HASH_MISMATCH:$TargetId"}
    $runtime=@($RuntimeJavaCatalog.entries|Where-Object{[string]$_.minecraftId -ceq [string]$Target.minecraftId})
    if($runtime.Count -ne 1-or [string]$runtime[0].observationStatus -cne 'VERIFIED'-or [string]$runtime[0].requirement.source -cne 'MojangVersionMetadata'-or [string]$runtime[0].requirement.confidence -cne 'High'-or [int]$runtime[0].requirement.major -lt 1){throw "RECIPE_RUNTIME_JAVA_UNVERIFIED:$TargetId"}

    $fixtureRoot=Join-Path $RepositoryRoot "common/fixtures/forge/$($Target.minecraftId)-marker"
    $fixtureManifestPath=Join-Path $fixtureRoot '.mmtl-fixture/manifest.json'
    if(-not(Test-Path -LiteralPath $fixtureManifestPath -PathType Leaf)){return [pscustomobject][ordered]@{status='InternalPending';targetId=$TargetId;loaderId='Forge';minecraftId=[string]$Target.minecraftId;familyId=[string]$Family.familyId;universeHash=$UniverseHash;sourceHash=[string]$TargetLedger.sourceHash;toolchainHash=[string]$TargetLedger.toolchainHash;targetSpecHash=[string]$TargetLedger.targetSpecHash;reasonCode='EXACT_FIXTURE_NOT_IMPLEMENTED'}}
    $familyTargetRefs=@($Family.evidence|Where-Object{[string]$_ -like "forge-mdk-target:${TargetId}:*" -or [string]$_ -like "forge-source-archive-target:${TargetId}:*"})
    if($familyTargetRefs.Count -ne 1){throw "RECIPE_FAMILY_PIN_EVIDENCE_MISMATCH:$TargetId"}
    $familyTargetRef=[string]$familyTargetRefs[0]
    foreach($evidencePair in @(
        @('coordinate=',[string]$pin.forgeVersion),
        @('archive-sha256=',[string]$pin.sourceArchiveSha256),
        @('build-gradle-sha256=',[string]$pin.buildGradleSha256),
        @('spec=',[string]$pin.forgeGradleSpec),
        @('wrapper=',[string]$pin.gradleDistributionUrl)
    )){
        if($familyTargetRef.IndexOf("$($evidencePair[0])$($evidencePair[1])",[StringComparison]::Ordinal) -lt 0){throw "RECIPE_FAMILY_PIN_EVIDENCE_MISMATCH:$TargetId"}
    }
    if($familyTargetRef.StartsWith("forge-source-archive-target:${TargetId}:",[StringComparison]::Ordinal)-and $familyTargetRef.IndexOf('type=GradleProject',[StringComparison]::Ordinal) -lt 0){throw "RECIPE_FAMILY_PIN_EVIDENCE_MISMATCH:$TargetId"}
    Test-MmtlRecipePathNoReparse -Root $RepositoryRoot -RelativePath "common/fixtures/forge/$($Target.minecraftId)-marker/.mmtl-fixture/manifest.json"
    $fixture=Get-Content -LiteralPath $fixtureManifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
    if([string]$fixture.fixtureId -cne 'MMTLForgeMarkerFixtureV1'-or [string]$fixture.targetId -cne $TargetId-or [string]$fixture.sourceArchiveUrl -cne [string]$pin.sourceArchiveUrl-or [string]$fixture.sourceArchiveSha256 -cne [string]$pin.sourceArchiveSha256){throw "RECIPE_FORGE_FIXTURE_PIN_MISMATCH:$TargetId"}
    $files=@($fixture.overlayFiles)
    $expectedOverlayPaths=if($TargetId -ceq 'Forge@1.8.9'){@('build.gradle','src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java','src/main/resources/mcmod.info')}else{@('src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java','src/main/resources/mcmod.info')}
    if($files.Count -ne $expectedOverlayPaths.Count){throw "RECIPE_FORGE_FIXTURE_OVERLAY_COUNT_INVALID:$TargetId"}
    $actualOverlayPaths=@($files|ForEach-Object{[string]$_.path}|Sort-Object -CaseSensitive)
    $expectedOverlayPaths=@($expectedOverlayPaths|Sort-Object -CaseSensitive)
    if(($actualOverlayPaths -join "`n") -cne ($expectedOverlayPaths -join "`n")){throw "RECIPE_FORGE_FIXTURE_OVERLAY_PATH_SET_INVALID:$TargetId"}
    $records=[Collections.Generic.List[string]]::new()
    foreach($file in $files){
        $relative=[string]$file.path
        if([string]::IsNullOrWhiteSpace($relative)-or $relative.Contains('\')-or [IO.Path]::IsPathRooted($relative)-or @($relative -split '/'|Where-Object{$_ -in @('','.','..')}).Count -gt 0-or [string]$file.sha256 -notmatch '^[a-f0-9]{64}$'){throw "RECIPE_FIXTURE_PATH_UNSAFE:$TargetId"}
        Test-MmtlRecipePathNoReparse -Root $RepositoryRoot -RelativePath "common/fixtures/forge/$($Target.minecraftId)-marker/$relative"
        $path=Join-Path $fixtureRoot $relative
        $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($hash -cne [string]$file.sha256){throw "RECIPE_FIXTURE_FILE_HASH_MISMATCH:${TargetId}:$relative"}
        $records.Add("$relative|$hash")
    }
    $ordered=$records.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
    $overlayHash=Get-MmtlRecipeSha256 -Text ($ordered -join "`n")
    if($overlayHash -cne [string]$fixture.overlaySha256){throw "RECIPE_FORGE_FIXTURE_OVERLAY_HASH_MISMATCH:$TargetId"}
    $distributionName=[IO.Path]::GetFileName([string]$pin.gradleDistributionUrl)
    $gradleMatch=[regex]::Match($distributionName,'^gradle-(?<version>[0-9]+(?:\.[0-9]+){1,2})-(?:bin|all)\.zip$')
    if(-not $gradleMatch.Success){throw "RECIPE_FORGE_GRADLE_DISTRIBUTION_INVALID:$TargetId"}
    $gradleVersion=$gradleMatch.Groups['version'].Value
    $resolvedForgeGradleVersion=if($pin.PSObject.Properties['forgeGradleResolvedVersion']){[string]$pin.forgeGradleResolvedVersion}else{''}
    $forgeGradleTimestamp=if($pin.PSObject.Properties['forgeGradleTimestamp']){[string]$pin.forgeGradleTimestamp}else{''}
    $forgeGradleVersion=if($resolvedForgeGradleVersion){$resolvedForgeGradleVersion}else{$forgeGradleTimestamp}
    if(-not $forgeGradleVersion){throw "RECIPE_FORGE_PLUGIN_VERSION_MISSING:$TargetId"}
    $recipe=[ordered]@{
        schemaVersion=1;status='RecipeReady';targetId=$TargetId;loaderId='Forge';minecraftId=[string]$Target.minecraftId
        familyId=[string]$Family.familyId;familyRuleSha256=$FamilyRuleSha256;adapterSha256=$adapterHash
        universeHash=$UniverseHash;sourceHash=[string]$TargetLedger.sourceHash;toolchainHash=[string]$TargetLedger.toolchainHash;targetSpecHash=[string]$TargetLedger.targetSpecHash
        build=[ordered]@{loaderVersion=[string]$pin.forgeVersion;buildToolId='ForgeGradle';buildToolVersion=$forgeGradleVersion;forgeGradleSpec=[string]$pin.forgeGradleSpec;loomVersion=$null;gradleVersion=$gradleVersion;gradleDistributionUrl=[string]$pin.gradleDistributionUrl;gradleDistributionSha256=[string]$pin.gradleDistributionSha256;buildJavaMajor=[int]$pin.buildJavaMajor;runtimeJavaMajor=[int]$runtime[0].requirement.major}
        source=[ordered]@{repository='https://maven.minecraftforge.net/net/minecraftforge/forge';commit=$null;archiveUrl=[string]$pin.sourceArchiveUrl;archiveSha256=[string]$pin.sourceArchiveSha256;license=$null}
        fixture=[ordered]@{fixtureId=[string]$fixture.fixtureId;manifestPath=[IO.Path]::GetRelativePath($RepositoryRoot,$fixtureManifestPath).Replace('\','/');overlaySha256=$overlayHash;overlayFiles=$files}
    }
    $recipe.recipeSha256=Get-MmtlRecipeSha256 -Text (ConvertTo-Json -InputObject ([pscustomobject]$recipe) -Depth 30 -Compress)
    [pscustomobject]$recipe
}

function Resolve-MmtlCompatibilityRecipe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)]$TargetLedger,
        [Parameter(Mandatory)]$FamilyManifest,
        [Parameter(Mandatory)]$PinCatalog,
        $QuiltPinCatalog,
        $ForgePinCatalog,
        $RuntimeJavaCatalog,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $targets = @($Universe.targets | Where-Object { [string]$_.targetId -ceq $TargetId })
    if ($targets.Count -ne 1 -or [string]$targets[0].availability -cne 'Available') { throw "RECIPE_UNIVERSE_TARGET_INVALID:$TargetId" }
    $target = $targets[0]
    if ([string]$TargetLedger.targetId -cne $TargetId -or [string]$TargetLedger.loaderId -cne [string]$target.loaderId -or [string]$TargetLedger.minecraftId -cne [string]$target.minecraftId) {
        throw 'RECIPE_LEDGER_TARGET_MISMATCH'
    }
    foreach ($name in @('universeHash','sourceHash','toolchainHash','targetSpecHash')) {
        if ($name -eq 'universeHash') { continue }
        if ([string]$TargetLedger.$name -notmatch '^[a-f0-9]{64}$') { throw "RECIPE_LEDGER_IDENTITY_INVALID:$name" }
    }

    $families = @($FamilyManifest.families | Where-Object { [string]$_.familyId -ceq [string]$TargetLedger.familyId -and [string]$_.loaderId -ceq [string]$target.loaderId })
    if ($families.Count -ne 1 -or @($families[0].minecraftIds | Where-Object { [string]$_ -ceq [string]$target.minecraftId }).Count -ne 1) {
        throw "RECIPE_FAMILY_TARGET_MISMATCH:$TargetId"
    }
    $family = $families[0]
    if ([string]$TargetLedger.toolchainHash -cne [string]$family.toolchainHash) { throw "RECIPE_FAMILY_TOOLCHAIN_MISMATCH:$TargetId" }
    $familyRuleSha256 = Get-MmtlRecipeSha256 -Text (ConvertTo-Json -InputObject $family -Depth 30 -Compress)

    if ([string]$target.loaderId -ceq 'Quilt') {
        if (-not $QuiltPinCatalog) { return [pscustomobject][ordered]@{ status='InternalPending'; targetId=$TargetId; loaderId=[string]$target.loaderId; minecraftId=[string]$target.minecraftId; familyId=[string]$family.familyId; universeHash=[string]$Universe.catalogHash; sourceHash=[string]$TargetLedger.sourceHash; toolchainHash=[string]$TargetLedger.toolchainHash; targetSpecHash=[string]$TargetLedger.targetSpecHash; reasonCode='EXACT_RECIPE_NOT_IMPLEMENTED' } }
        return Resolve-MmtlQuiltCompatibilityRecipe -TargetId $TargetId -Target $target -TargetLedger $TargetLedger -Family $family -FamilyRuleSha256 $familyRuleSha256 -UniverseHash ([string]$Universe.catalogHash) -PinCatalog $QuiltPinCatalog -RepositoryRoot $RepositoryRoot
    }
    if ([string]$target.loaderId -ceq 'Forge') {
        if (-not $ForgePinCatalog -or -not $RuntimeJavaCatalog) { return [pscustomobject][ordered]@{ status='InternalPending'; targetId=$TargetId; loaderId=[string]$target.loaderId; minecraftId=[string]$target.minecraftId; familyId=[string]$family.familyId; universeHash=[string]$Universe.catalogHash; sourceHash=[string]$TargetLedger.sourceHash; toolchainHash=[string]$TargetLedger.toolchainHash; targetSpecHash=[string]$TargetLedger.targetSpecHash; reasonCode='EXACT_RECIPE_NOT_IMPLEMENTED' } }
        return Resolve-MmtlForgeCompatibilityRecipe -TargetId $TargetId -Target $target -TargetLedger $TargetLedger -Family $family -FamilyRuleSha256 $familyRuleSha256 -UniverseHash ([string]$Universe.catalogHash) -PinCatalog $ForgePinCatalog -RuntimeJavaCatalog $RuntimeJavaCatalog -RepositoryRoot $RepositoryRoot
    }
    if ([string]$target.loaderId -cne 'Fabric') {
        return [pscustomobject][ordered]@{ status='InternalPending'; targetId=$TargetId; loaderId=[string]$target.loaderId; minecraftId=[string]$target.minecraftId; familyId=[string]$family.familyId; universeHash=[string]$Universe.catalogHash; sourceHash=[string]$TargetLedger.sourceHash; toolchainHash=[string]$TargetLedger.toolchainHash; targetSpecHash=[string]$TargetLedger.targetSpecHash; reasonCode='EXACT_RECIPE_NOT_IMPLEMENTED' }
    }

    $pins = @($PinCatalog.targets | Where-Object { [string]$_.targetId -ceq $TargetId })
    if ($pins.Count -eq 0) {
        return [pscustomobject][ordered]@{ status='InternalPending'; targetId=$TargetId; loaderId=[string]$target.loaderId; minecraftId=[string]$target.minecraftId; familyId=[string]$family.familyId; universeHash=[string]$Universe.catalogHash; sourceHash=[string]$TargetLedger.sourceHash; toolchainHash=[string]$TargetLedger.toolchainHash; targetSpecHash=[string]$TargetLedger.targetSpecHash; reasonCode='EXACT_RECIPE_NOT_IMPLEMENTED' }
    }
    if ($pins.Count -ne 1) { throw "RECIPE_PIN_DUPLICATE:$TargetId" }
    $pin = $pins[0]
    if ([string]$pin.verificationStatus -cne 'PinnedInputsVerified') { throw "RECIPE_PIN_NOT_TRUSTED:$TargetId" }
    if ([string]$pin.minecraftVersion -cne [string]$target.minecraftId -or [string]$pin.loaderVersion -notin @($target.loaderVersionCandidates | ForEach-Object { [string]$_ })) {
        throw "RECIPE_PIN_TARGET_MISMATCH:$TargetId"
    }
    if ([string]$pin.sourceArchiveSha256 -notmatch '^[a-f0-9]{64}$' -or [string]$pin.sourceCommit -notmatch '^[a-f0-9]{40}$' -or [string]$pin.gradleDistributionSha256 -notmatch '^[a-f0-9]{64}$') {
        throw "RECIPE_PIN_HASH_INVALID:$TargetId"
    }
    $adapterRefs = @($family.evidence | Where-Object { [string]$_ -match '^fabric-adapter-sha256:([a-f0-9]{64})$' })
    if ($adapterRefs.Count -ne 1) { throw "RECIPE_ADAPTER_EVIDENCE_MISSING:$TargetId" }
    $adapterHash = ([regex]::Match([string]$adapterRefs[0], '^fabric-adapter-sha256:([a-f0-9]{64})$')).Groups[1].Value
    $adapterPath = Join-Path $RepositoryRoot 'common/src/Adapters/Fabric.psm1'
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf) -or (Get-FileHash -LiteralPath $adapterPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $adapterHash) { throw "RECIPE_ADAPTER_HASH_MISMATCH:$TargetId" }

    $fixtureRoot = Join-Path $RepositoryRoot "common/fixtures/fabric/$($target.minecraftId)-marker"
    $fixtureManifestPath = Join-Path $fixtureRoot '.mmtl-fixture/manifest.json'
    if (-not (Test-Path -LiteralPath $fixtureManifestPath -PathType Leaf)) { throw "RECIPE_FIXTURE_MANIFEST_MISSING:$TargetId" }
    $fixture = Get-Content -LiteralPath $fixtureManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    foreach ($pair in @(
        @('targetId',$TargetId), @('sourceCommit',[string]$pin.sourceCommit),
        @('sourceArchiveSha256',[string]$pin.sourceArchiveSha256), @('loomVersion',[string]$pin.loomVersion),
        @('gradleVersion',[string]$pin.gradleVersion), @('buildJavaMajor',[string]$pin.buildJavaMajor),
        @('runtimeJavaMajor',[string]$pin.runtimeJavaMajor), @('verificationStatus',[string]$pin.verificationStatus)
    )) {
        if ([string]$fixture.($pair[0]) -cne [string]$pair[1]) { throw "RECIPE_FIXTURE_PIN_MISMATCH:${TargetId}:$($pair[0])" }
    }
    if ([string]$fixture.sourceRepository -cne [string]$pin.sourceRepository -or [string]$fixture.sourceArchiveUrl -cne [string]$pin.sourceArchiveUrl) { throw "RECIPE_FIXTURE_SOURCE_MISMATCH:$TargetId" }
    $overlayFiles = @($fixture.overlayFiles)
    if ($overlayFiles.Count -eq 0) { throw "RECIPE_FIXTURE_OVERLAY_EMPTY:$TargetId" }
    foreach ($file in $overlayFiles) {
        $relative = [string]$file.path
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[/\\])\.\.([/\\]|$)') { throw "RECIPE_FIXTURE_PATH_UNSAFE:$TargetId" }
        $path = [IO.Path]::GetFullPath((Join-Path $fixtureRoot $relative))
        $rootPrefix = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "RECIPE_FIXTURE_FILE_MISSING:$TargetId" }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "RECIPE_FIXTURE_REPARSE_POINT:$TargetId" }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$file.sha256) { throw "RECIPE_FIXTURE_FILE_HASH_MISMATCH:${TargetId}:$relative" }
    }

    $recipe = [ordered]@{
        schemaVersion=1; status='RecipeReady'; targetId=$TargetId; loaderId=[string]$target.loaderId; minecraftId=[string]$target.minecraftId
        familyId=[string]$family.familyId; familyRuleSha256=$familyRuleSha256; adapterSha256=$adapterHash
        universeHash=[string]$Universe.catalogHash; sourceHash=[string]$TargetLedger.sourceHash
        toolchainHash=[string]$TargetLedger.toolchainHash; targetSpecHash=[string]$TargetLedger.targetSpecHash
        build=[ordered]@{ loaderVersion=[string]$pin.loaderVersion; buildToolId=[string]$pin.loomPluginId; buildToolVersion=[string]$pin.loomVersion; fabricApiVersion=[string]$pin.fabricApiVersion; loomPluginId=[string]$pin.loomPluginId; loomVersion=[string]$pin.loomVersion; gradleVersion=[string]$pin.gradleVersion; gradleDistributionUrl=[string]$pin.gradleDistributionUrl; gradleDistributionSha256=[string]$pin.gradleDistributionSha256; buildJavaMajor=[int]$pin.buildJavaMajor; runtimeJavaMajor=[int]$pin.runtimeJavaMajor }
        source=[ordered]@{ repository=[string]$pin.sourceRepository; commit=[string]$pin.sourceCommit; archiveUrl=[string]$pin.sourceArchiveUrl; archiveSha256=[string]$pin.sourceArchiveSha256; license=[string]$pin.sourceLicense }
        fixture=[ordered]@{ fixtureId=[string]$fixture.fixtureId; manifestPath=[IO.Path]::GetRelativePath($RepositoryRoot,$fixtureManifestPath).Replace('\','/'); overlaySha256=[string]$fixture.overlaySha256; overlayFiles=$overlayFiles }
    }
    $recipeJson = ConvertTo-Json -InputObject ([pscustomobject]$recipe) -Depth 30 -Compress
    $recipe.recipeSha256 = Get-MmtlRecipeSha256 -Text $recipeJson
    [pscustomobject]$recipe
}

Export-ModuleMember -Function Resolve-MmtlCompatibilityRecipe
