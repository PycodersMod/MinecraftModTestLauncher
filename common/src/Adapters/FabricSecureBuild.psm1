Set-StrictMode -Version Latest

function Get-MmtlFabricFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'FABRIC_PIN_FILE_MISSING' }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) { throw 'FABRIC_PIN_REPARSE_PATH_REJECTED' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Test-MmtlFabricPathInsideRoot {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Target)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $targetPath = [IO.Path]::GetFullPath($Target)
    return $targetPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)
}

function Get-MmtlFabricLoomPluginId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftVersion)
    if ($MinecraftVersion -match '^\d{2}w' -or $MinecraftVersion -ceq '3D Shareware v1.34') { return 'net.fabricmc.fabric-loom-remap' }
    $match = [regex]::Match($MinecraftVersion, '^(?<major>[0-9]+)\.(?<minor>[0-9]+)')
    if (-not $match.Success) { throw "FABRIC_MINECRAFT_VERSION_UNPARSEABLE:$MinecraftVersion" }
    $major = [int]$match.Groups['major'].Value
    $minor = [int]$match.Groups['minor'].Value
    if ($major -gt 26 -or ($major -eq 26 -and $minor -ge 1)) { return 'net.fabricmc.fabric-loom' }
    return 'net.fabricmc.fabric-loom-remap'
}

function Get-MmtlFabricOverlayHash {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$FixtureManifest)
    if ([string]$FixtureManifest.fixtureId -cne 'MMTLFabricMarkerFixtureV1' -or [string]$FixtureManifest.targetId -notmatch '^Fabric@.+$') { throw 'FABRIC_PIN_FIXTURE_MANIFEST_IDENTITY_MISMATCH' }
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $records = [Collections.Generic.List[string]]::new()
    $files = @($FixtureManifest.overlayFiles)
    if ($files.Count -ne 7) { throw 'FABRIC_PIN_OVERLAY_FILE_COUNT_INVALID' }
    foreach ($file in $files) {
        $relative = ([string]$file.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $segments = @($relative.Split([IO.Path]::DirectorySeparatorChar))
        if ([IO.Path]::IsPathRooted($relative) -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or [string]$file.sha256 -notmatch '^(?i:[a-f0-9]{64})$') { throw 'FABRIC_PIN_OVERLAY_PATH_INVALID' }
        $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
        if (-not (Test-MmtlFabricPathInsideRoot -Root $root -Target $path)) { throw 'FABRIC_PIN_OVERLAY_PATH_ESCAPE' }
        $cursor = $root
        foreach ($segment in $segments) {
            $cursor = Join-Path $cursor $segment
            if (-not (Test-Path -LiteralPath $cursor)) { throw 'FABRIC_PIN_OVERLAY_FILE_MISSING' }
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) { throw 'FABRIC_PIN_REPARSE_PATH_REJECTED' }
        }
        $actual = Get-MmtlFabricFileSha256 -Path $path
        if ($actual -cne ([string]$file.sha256).ToLowerInvariant()) { throw 'FABRIC_PIN_OVERLAY_FILE_HASH_MISMATCH' }
        $records.Add(([string]$file.path).Replace('\', '/') + '|' + $actual)
    }
    $ordered = $records.ToArray()
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $overlayHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($ordered -join "`n")))).ToLowerInvariant()
    if ($overlayHash -cne ([string]$FixtureManifest.overlaySha256).ToLowerInvariant()) { throw 'FABRIC_PIN_OVERLAY_HASH_MISMATCH' }
    return $overlayHash
}

function Get-MmtlFabricBuildPin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)]$Fixture
    )
    if ([string]$Project.Loader -cne 'Fabric') { return $null }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $schemaPath = Join-Path $repositoryRoot 'compatibility/fabric-build-pins.schema.json'
    if (-not (Test-Json -Json ($manifest | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath -ErrorAction Stop)) { throw 'FABRIC_PIN_MANIFEST_SCHEMA_INVALID' }
    if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -cne 'PARTIAL') { throw 'FABRIC_PIN_MANIFEST_INVALID' }
    $matches = @($manifest.targets | Where-Object { [string]$_.targetId -ceq [string]$Target.targetId })
    if ($matches.Count -ne 1) { throw 'FABRIC_PIN_TARGET_MISSING_OR_DUPLICATE' }
    $pin = $matches[0]
    if ([string]$pin.verificationStatus -cne 'PinnedInputsVerified') { throw 'FABRIC_PIN_INPUTS_NOT_VERIFIED' }
    if ([string]$pin.targetId -cne [string]$Target.targetId -or [string]$pin.minecraftVersion -cne [string]$Target.minecraftId -or [string]$Target.loaderVersion -cne [string]$pin.loaderVersion -or [string]$Project.MinecraftVersion -cne [string]$pin.minecraftVersion -or [string]$Project.LoaderVersion -cne [string]$pin.loaderVersion) { throw 'FABRIC_PIN_TARGET_IDENTITY_MISMATCH' }
    if ([string]$pin.loomPluginId -cne (Get-MmtlFabricLoomPluginId -MinecraftVersion ([string]$pin.minecraftVersion)) -or [string]$pin.gradleVersion -notmatch '^[0-9]+(?:\.[0-9]+){1,2}$' -or [int]$pin.buildJavaMajor -lt 8 -or [int]$pin.buildJavaMajor -gt 25 -or [int]$pin.runtimeJavaMajor -lt 8 -or [int]$pin.runtimeJavaMajor -gt 25) { throw 'FABRIC_PIN_TOOLCHAIN_IDENTITY_INVALID' }
    if ([string]::IsNullOrWhiteSpace([string]$pin.fabricApiVersion) -or [string]::IsNullOrWhiteSpace([string]$pin.loomVersion)) { throw 'FABRIC_PIN_TOOLCHAIN_IDENTITY_INVALID' }
    foreach ($field in @('sourceArchiveSha256', 'sourceBuildGradleSha256', 'sourceSettingsGradleSha256', 'sourceWrapperPropertiesSha256', 'sourceWrapperJarSha256', 'gradleDistributionSha256', 'verificationMetadataSha256')) {
        if ([string]$pin.$field -notmatch '^(?i:[a-f0-9]{64})$') { throw "FABRIC_PIN_HASH_INVALID:$field" }
    }
    $sourceUri = $null
    $expectedArchiveUrl = 'https://codeload.github.com/FabricMC/fabric-example-mod/zip/' + [string]$pin.sourceCommit
    if ([string]$pin.sourceRepository -cne 'https://github.com/FabricMC/fabric-example-mod' -or [string]$pin.sourceArchiveUrl -cne $expectedArchiveUrl -or -not [Uri]::TryCreate([string]$pin.sourceArchiveUrl, [UriKind]::Absolute, [ref]$sourceUri) -or $sourceUri.Scheme -cne 'https' -or $sourceUri.Host -cne 'codeload.github.com' -or $sourceUri.UserInfo) { throw 'FABRIC_PIN_SOURCE_URL_INVALID' }
    $gradleUri = $null
    if ([string]$pin.gradleDistributionUrl -cne ('https://services.gradle.org/distributions/gradle-' + [string]$pin.gradleVersion + '-bin.zip') -or -not [Uri]::TryCreate([string]$pin.gradleDistributionUrl, [UriKind]::Absolute, [ref]$gradleUri) -or $gradleUri.Scheme -cne 'https' -or $gradleUri.Host -cne 'services.gradle.org' -or $gradleUri.UserInfo) { throw 'FABRIC_PIN_GRADLE_URL_INVALID' }
    if ([string]$Fixture.type -notin @('GeneratedOfficialFixture','GeneratedPinnedLoaderFixture') -or [string]$Fixture.source -cne [string]$pin.sourceRepository -or [string]$Fixture.commit -cne [string]$pin.sourceCommit -or [string]$Fixture.license -cne [string]$pin.sourceLicense -or [string]$Fixture.trust -cne 'TrustedOfficial') { throw 'FABRIC_PIN_SOURCE_IDENTITY_MISMATCH' }
    $fixtureArchiveHash = if ($Fixture.PSObject.Properties['archiveSha256']) { [string]$Fixture.archiveSha256 } elseif ($Fixture.PSObject.Properties['sourceArchiveSha256']) { [string]$Fixture.sourceArchiveSha256 } else { '' }
    if ($fixtureArchiveHash -cne [string]$pin.sourceArchiveSha256) { throw 'FABRIC_PIN_SOURCE_IDENTITY_MISMATCH' }
    $projectRoot = [IO.Path]::GetFullPath([string]$Project.Root)
    if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) { throw 'FABRIC_PIN_PROJECT_ROOT_INVALID' }
    $manifestPath = Join-Path $projectRoot '.mmtl-fixture/manifest.json'
    $fixtureManifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('fixtureId', 'targetId', 'sourceRepository', 'sourceCommit', 'sourceArchiveSha256', 'verificationMetadataSha256', 'loomVersion', 'gradleVersion', 'verificationStatus')) {
        $expected = switch ($field) {
            'fixtureId' { 'MMTLFabricMarkerFixtureV1' }
            'targetId' { [string]$pin.targetId }
            'sourceRepository' { [string]$pin.sourceRepository }
            'sourceCommit' { [string]$pin.sourceCommit }
            'sourceArchiveSha256' { [string]$pin.sourceArchiveSha256 }
            'verificationMetadataSha256' { [string]$pin.verificationMetadataSha256 }
            'loomVersion' { [string]$pin.loomVersion }
            'gradleVersion' { [string]$pin.gradleVersion }
            'verificationStatus' { [string]$pin.verificationStatus }
        }
        if ([string]$fixtureManifest.$field -cne $expected) { throw "FABRIC_PIN_FIXTURE_MANIFEST_MISMATCH:$field" }
    }
    if ([int]$fixtureManifest.buildJavaMajor -ne [int]$pin.buildJavaMajor -or [int]$fixtureManifest.runtimeJavaMajor -ne [int]$pin.runtimeJavaMajor) { throw 'FABRIC_PIN_FIXTURE_JAVA_TRACK_MISMATCH' }
    $actualMetadata = Get-MmtlFabricFileSha256 -Path (Join-Path $projectRoot 'gradle/verification-metadata.xml')
    if ($actualMetadata -cne ([string]$pin.verificationMetadataSha256).ToLowerInvariant() -or [string]$fixtureManifest.verificationMetadataSha256 -cne [string]$pin.verificationMetadataSha256) { throw 'FABRIC_PIN_VERIFICATION_METADATA_HASH_MISMATCH' }
    $overlayHash = Get-MmtlFabricOverlayHash -ProjectRoot $projectRoot -FixtureManifest $fixtureManifest
    if ([string]$Fixture.fixtureId -cne [string]$fixtureManifest.fixtureId -or ($Fixture.PSObject.Properties['overlaySha256'] -and [string]$Fixture.overlaySha256 -cne [string]$fixtureManifest.overlaySha256)) { throw 'FABRIC_PIN_OVERLAY_HASH_MISMATCH' }
    if ($Fixture.PSObject.Properties['overlayFiles'] -and @($Fixture.overlayFiles).Count -ne @($fixtureManifest.overlayFiles).Count) { throw 'FABRIC_PIN_OVERLAY_MANIFEST_MISMATCH' }
    $verificationXml = [xml](Get-Content -LiteralPath (Join-Path $projectRoot 'gradle/verification-metadata.xml') -Raw)
    $components = @($verificationXml.SelectNodes("//*[local-name()='component']"))
    $artifacts = @($verificationXml.SelectNodes("//*[local-name()='artifact']"))
    $checksums = @($verificationXml.SelectNodes("//*[local-name()='sha256']"))
    $trusted = @($verificationXml.SelectNodes("//*[local-name()='trusted-artifacts']/*[local-name()='trust']"))
    if ($components.Count -ne [int]$pin.verificationComponentCount -or $artifacts.Count -ne [int]$pin.verificationArtifactCount -or $checksums.Count -ne [int]$pin.verificationArtifactCount -or $trusted.Count -ne [int]$pin.trustedArtifactCount -or @($pin.trustedArtifactFiles).Count -ne $trusted.Count) { throw 'FABRIC_PIN_DEPENDENCY_CATALOG_COUNTS_INVALID' }
    $actualTrustedFiles = [Collections.Generic.List[string]]::new()
    foreach ($rule in $trusted) {
        $trustedFile=$rule.GetAttribute('file')
        if ($rule.Attributes.Count -ne 2 -or -not $rule.HasAttribute('file') -or $rule.HasAttribute('group') -or $rule.HasAttribute('regex') -or [string]::IsNullOrWhiteSpace($trustedFile)) { throw 'FABRIC_PIN_TRUSTED_ARTIFACT_SCOPE_INVALID' }
        $actualTrustedFiles.Add($trustedFile)
    }
    $expectedTrustedFiles = @($pin.trustedArtifactFiles | ForEach-Object { [string]$_ })
    $actualTrustedFileArray = $actualTrustedFiles.ToArray()
    [Array]::Sort($expectedTrustedFiles, [StringComparer]::Ordinal)
    [Array]::Sort($actualTrustedFileArray, [StringComparer]::Ordinal)
    if (($expectedTrustedFiles -join "`n") -cne ($actualTrustedFileArray -join "`n")) { throw 'FABRIC_PIN_TRUSTED_ARTIFACT_ALLOWLIST_MISMATCH' }
    $wrapperProperties = [IO.File]::ReadAllText((Join-Path $projectRoot 'gradle/wrapper/gradle-wrapper.properties'))
    $distributionLine = @($wrapperProperties -split "`r?`n" | Where-Object { $_ -match '^distributionUrl=' } | Select-Object -First 1)
    $normalizedDistributionUrl = if ($distributionLine.Count -eq 1) { [regex]::Replace(([string]$distributionLine[0]).Substring('distributionUrl='.Length), '\\:', ':') } else { '' }
    if ($normalizedDistributionUrl -cne [string]$pin.gradleDistributionUrl -or -not [regex]::IsMatch($wrapperProperties, ('(?m)^distributionSha256Sum=' + [regex]::Escape([string]$pin.gradleDistributionSha256) + '$'))) { throw 'FABRIC_PIN_WRAPPER_DISTRIBUTION_MISMATCH' }
    if ((Get-MmtlFabricFileSha256 -Path (Join-Path $projectRoot 'gradle/wrapper/gradle-wrapper.jar')) -cne [string]$pin.sourceWrapperJarSha256) { throw 'FABRIC_PIN_WRAPPER_JAR_HASH_MISMATCH' }
    $properties = [IO.File]::ReadAllText((Join-Path $projectRoot 'gradle.properties'))
    $expectedPropertyLines = @(
        ('minecraft_version=' + [string]$pin.minecraftVersion)
        ('loader_version=' + [string]$pin.loaderVersion)
        ('loom_version=' + [string]$pin.loomVersion)
        ('fabric_api_version=' + [string]$pin.fabricApiVersion)
    )
    foreach ($expectedLine in $expectedPropertyLines) {
        if (-not [regex]::IsMatch($properties, ('(?m)^' + [regex]::Escape($expectedLine) + '$'))) { throw 'FABRIC_PIN_GRADLE_PROPERTIES_MISMATCH' }
    }
    $buildScript = [IO.File]::ReadAllText((Join-Path $projectRoot 'build.gradle'))
    $loomPluginPattern = 'id\s+["'']' + [regex]::Escape([string]$pin.loomPluginId) + '["'']\s+version\s+["'']\$\{loom_version\}["'']'
    if ($buildScript -notmatch $loomPluginPattern) { throw 'FABRIC_PIN_LOOM_PLUGIN_DECLARATION_MISMATCH' }
    $canonical = ConvertTo-Json -InputObject $pin -Depth 30 -Compress
    $pinHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
    [pscustomobject]@{policy=$pin;pinHash=$pinHash;buildMode='FabricLoomPinned';verificationMetadataSha256=$actualMetadata;overlaySha256=$overlayHash;additionalArguments=@('--dependency-verification=strict')}
}

Export-ModuleMember -Function Get-MmtlFabricBuildPin,Get-MmtlFabricLoomPluginId
