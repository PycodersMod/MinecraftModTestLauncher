Set-StrictMode -Version Latest

function Get-MmtlQuiltFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'QUILT_PINNED_FILE_MISSING' }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) { throw 'QUILT_PINNED_REPARSE_PATH_REJECTED' }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Test-MmtlQuiltPathInsideRoot {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Target)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    [IO.Path]::GetFullPath($Target).StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)
}

function Test-MmtlQuiltNoReparsePath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    $rootPath = [IO.Path]::GetFullPath($Root)
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $rootItem.LinkType) { throw 'QUILT_PIN_REPARSE_PATH_REJECTED' }
    $cursor = $rootPath
    foreach ($segment in @($RelativePath -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -in @('.', '..')) { throw 'QUILT_PIN_OVERLAY_PATH_INVALID' }
        $cursor = Join-Path $cursor $segment
        if (-not (Test-Path -LiteralPath $cursor)) { throw 'QUILT_PINNED_FILE_MISSING' }
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) { throw 'QUILT_PIN_REPARSE_PATH_REJECTED' }
    }
}

function Get-MmtlQuiltBuildPin {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath, [Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Project, [Parameter(Mandatory)]$Fixture)
    if ([string]$Project.Loader -cne 'Quilt') { return $null }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $schemaPath = Join-Path $repo 'compatibility/quilt-build-pins.schema.json'
    try { $valid = Test-Json -Json ($manifest | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath -ErrorAction Stop } catch { $valid = $false }
    if (-not $valid) { throw 'QUILT_PIN_MANIFEST_SCHEMA_INVALID' }
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -cne 'PARTIAL') { throw 'QUILT_PIN_MANIFEST_INVALID' }
    $rows = @($manifest.targets | Where-Object { [string]$_.targetId -ceq [string]$Target.targetId })
    if ($rows.Count -ne 1) { return $null }
    $pin = $rows[0]
    if ([string]$pin.sourceVerificationStatus -cne 'PinnedInputsVerified') { throw 'QUILT_PIN_INPUTS_NOT_VERIFIED' }
    foreach ($field in @('targetId', 'minecraftVersion', 'loaderVersion')) {
        $targetField = switch ($field) { 'targetId' { [string]$Target.targetId } 'minecraftVersion' { [string]$Target.minecraftId } 'loaderVersion' { [string]$Target.loaderVersion } }
        $projectField = switch ($field) { 'targetId' { [string]$Target.targetId } 'minecraftVersion' { [string]$Project.MinecraftVersion } 'loaderVersion' { [string]$Project.LoaderVersion } }
        if ([string]$pin.$field -cne $targetField -or [string]$pin.$field -cne $projectField) { throw "QUILT_PIN_TARGET_IDENTITY_MISMATCH:$field" }
    }
    $projectToolchain=$Project.PSObject.Properties['Toolchain'].Value
    if($projectToolchain -is [string]){
        # Matrix jobs project the compiler as a Java string; the pinned fixture
        # itself is the authority for Quilt Loom in that execution path.
        if($projectToolchain -cne 'Java' -or -not $Project.PSObject.Properties['javaMajor']){throw 'QUILT_PIN_TOOLCHAIN_IDENTITY_MISMATCH'}
    }elseif(-not $projectToolchain -or -not $projectToolchain.PSObject.Properties['id'] -or -not $projectToolchain.PSObject.Properties['version'] -or [string]$projectToolchain.id -cne 'QuiltLoom' -or [string]$projectToolchain.version -cne [string]$pin.quiltLoomVersion){
        throw 'QUILT_PIN_TOOLCHAIN_IDENTITY_MISMATCH'
    }
    if ([string]$Fixture.type -notin @('GeneratedOfficialFixture','GeneratedPinnedLoaderFixture') -or [string]$Fixture.source -cne [string]$pin.sourceRepository -or [string]$Fixture.commit -cne [string]$pin.sourceCommit -or [string]$Fixture.license -cne [string]$pin.sourceLicense -or [string]$Fixture.trust -cne 'TrustedOfficial' -or [string]$Fixture.archiveSha256 -cne [string]$pin.sourceArchiveSha256) { throw 'QUILT_PIN_SOURCE_IDENTITY_MISMATCH' }
    if([string]$Fixture.type -ceq 'GeneratedPinnedLoaderFixture' -and ([string]$Fixture.archiveUrl -cne [string]$pin.sourceArchiveUrl -or [string]$Fixture.fixtureId -cne 'MMTLQuiltMarkerFixtureV1' -or [string]$Fixture.overlaySha256 -cne [string]$pin.overlaySha256)){throw 'QUILT_PIN_SOURCE_IDENTITY_MISMATCH'}
    $root = [IO.Path]::GetFullPath([string]$Project.Root)
    $fixturePath = Join-Path $root '.mmtl-fixture/manifest.json'
    $fixtureManifest = Get-Content -LiteralPath $fixturePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('fixtureId', 'targetId', 'sourceCommit', 'sourceArchiveSha256', 'sourceBuildGradleSha256', 'sourceSettingsGradleSha256', 'sourceGradlePropertiesSha256', 'sourceWrapperPropertiesSha256', 'sourceWrapperJarSha256', 'sourceVersionsTomlSha256')) {
        $expected = if ($field -ceq 'fixtureId') { 'MMTLQuiltMarkerFixtureV1' } else { [string]$pin.$field }
        if ([string]$fixtureManifest.$field -cne $expected) { throw "QUILT_PIN_FIXTURE_MANIFEST_MISMATCH:$field" }
    }
    $records = [Collections.Generic.List[string]]::new()
    $files = @($fixtureManifest.overlayFiles)
    if ($files.Count -ne 7) { throw 'QUILT_PIN_OVERLAY_FILE_COUNT_INVALID' }
    foreach ($file in $files) {
        $relative = ([string]$file.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $segments = @($relative.Split([IO.Path]::DirectorySeparatorChar))
        if ([IO.Path]::IsPathRooted($relative) -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or [string]$file.sha256 -notmatch '^(?i:[a-f0-9]{64})$') { throw 'QUILT_PIN_OVERLAY_PATH_INVALID' }
        $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not (Test-MmtlQuiltPathInsideRoot -Root $root -Target $path)) { throw 'QUILT_PIN_OVERLAY_PATH_ESCAPE' }
        Test-MmtlQuiltNoReparsePath -Root $root -RelativePath $relative
        $actual = Get-MmtlQuiltFileSha256 -Path $path
        if ($actual -cne ([string]$file.sha256).ToLowerInvariant()) { throw 'QUILT_PIN_OVERLAY_FILE_HASH_MISMATCH' }
        $records.Add(([string]$file.path).Replace('\', '/') + '|' + $actual)
    }
    $ordered = $records.ToArray(); [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $overlayHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($ordered -join "`n")))).ToLowerInvariant()
    if ($overlayHash -cne [string]$fixtureManifest.overlaySha256 -or $overlayHash -cne [string]$pin.overlaySha256 -or ($Fixture.PSObject.Properties['overlaySha256'] -and [string]$Fixture.overlaySha256 -cne $overlayHash)) { throw 'QUILT_PIN_OVERLAY_HASH_MISMATCH' }
    # sourceVersionsTomlSha256 identifies the pinned upstream template file;
    # the target-specific overlay catalog is independently bound by overlayFiles/overlaySha256.
    Test-MmtlQuiltNoReparsePath -Root $root -RelativePath 'gradle/libs.versions.toml'
    Test-MmtlQuiltNoReparsePath -Root $root -RelativePath 'gradle/wrapper/gradle-wrapper.jar'
    if ((Get-MmtlQuiltFileSha256 (Join-Path $root 'gradle/wrapper/gradle-wrapper.jar')) -cne [string]$pin.sourceWrapperJarSha256) { throw 'QUILT_PIN_WRAPPER_JAR_HASH_MISMATCH' }
    $wrapper = [IO.File]::ReadAllText((Join-Path $root 'gradle/wrapper/gradle-wrapper.properties'))
    if (-not [regex]::IsMatch($wrapper, ('(?m)^distributionUrl=https\\://services\.gradle\.org/distributions/gradle-' + [regex]::Escape([string]$pin.gradleVersion) + '-bin\.zip$')) -or -not [regex]::IsMatch($wrapper, ('(?m)^distributionSha256Sum=' + [regex]::Escape([string]$pin.gradleDistributionSha256) + '$'))) { throw 'QUILT_PIN_WRAPPER_DISTRIBUTION_MISMATCH' }
    $versions = [IO.File]::ReadAllText((Join-Path $root 'gradle/libs.versions.toml'))
    $expectedVersions = @(
        "minecraft = `"$($pin.minecraftVersion)`""
        "quilt_mappings = `"$($pin.quiltMappingsVersion)`""
        "quilt_loom = `"$($pin.quiltLoomVersion)`""
        "quilt_loader = `"$($pin.loaderVersion)`""
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$pin.quiltedFabricApiVersion)) {
        $expectedVersions += "quilted_fabric_api = `"$($pin.quiltedFabricApiVersion)`""
    } else {
        if ($versions -match '(?m)^\s*(?:quilted_fabric_api|quilt_standard_libraries)\s*=') { throw 'QUILT_PIN_UNPUBLISHED_QFAPI_REFERENCED' }
        $buildGradle = [IO.File]::ReadAllText((Join-Path $root 'build.gradle'))
        if ($buildGradle -match '(?m)^\s*modImplementation\s+libs\.bundles\.quilted\.fabric\.api') { throw 'QUILT_PIN_UNPUBLISHED_QFAPI_REFERENCED' }
        $quiltMetadataPath = Join-Path $root 'src/main/resources/quilt.mod.json'
        $fabricMetadataPath = Join-Path $root 'src/main/resources/fabric.mod.json'
        if (Test-Path -LiteralPath $quiltMetadataPath -PathType Leaf) { throw 'QUILT_PIN_LOADER_ONLY_METADATA_MUST_USE_FABRIC_COMPAT' }
        $modMetadata = Get-Content -LiteralPath $fabricMetadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$modMetadata.id -cne 'mmtl_marker' -or @($modMetadata.entrypoints.main | Where-Object { [string]$_ -ceq 'org.pycodersmod.mmtlfixture.MmtlMarkerMod' }).Count -ne 1 -or [string]$modMetadata.depends.minecraft -cne ('=' + [string]$pin.minecraftVersion) -or [string]$modMetadata.depends.fabricloader -cne ('=' + [string]$pin.loaderVersion)) { throw 'QUILT_PIN_LOADER_ONLY_METADATA_INVALID' }
    }
    foreach ($expected in $expectedVersions) { if (-not $versions.Contains($expected)) { throw 'QUILT_PIN_DEPENDENCY_VERSION_MISMATCH' } }
    [pscustomobject]@{ policy=$pin; pinHash=(Get-MmtlQuiltFileSha256 -Path $ManifestPath); overlaySha256=$overlayHash }
}

Export-ModuleMember -Function Get-MmtlQuiltBuildPin
