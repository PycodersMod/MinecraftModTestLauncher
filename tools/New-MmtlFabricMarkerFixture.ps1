[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceArchivePath,
    [Parameter(Mandatory)][string]$DestinationPath,
    [string]$TargetId = 'Fabric@1.21.8',
    [string]$PinManifestPath
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pinPath = if ($PinManifestPath) { [IO.Path]::GetFullPath($PinManifestPath) } else { Join-Path $repositoryRoot 'compatibility/fabric-build-pins.json' }
$manifest = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json -ErrorAction Stop
if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -cne 'PARTIAL') { throw 'FABRIC_BUILD_PIN_MANIFEST_INVALID' }
$matches = @($manifest.targets | Where-Object targetId -CEQ $TargetId)
if ($matches.Count -ne 1) { throw 'FABRIC_BUILD_PIN_TARGET_MISSING' }
$pin = $matches[0]
if ([string]$pin.verificationStatus -cne 'PinnedInputsVerified') { throw 'FABRIC_BUILD_PIN_STATUS_INVALID' }
$archive = [IO.Path]::GetFullPath($SourceArchivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'FABRIC_FIXTURE_ARCHIVE_MISSING' }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.sourceArchiveSha256) { throw 'FABRIC_FIXTURE_ARCHIVE_HASH_MISMATCH' }
$destination = [IO.Path]::GetFullPath($DestinationPath)
if (Test-Path -LiteralPath $destination) { throw 'FABRIC_FIXTURE_DESTINATION_EXISTS' }
[void][IO.Directory]::CreateDirectory($destination)

function Test-MmtlFabricPathInsideRoot {
    param([string]$Root, [string]$Target)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return [IO.Path]::GetFullPath($Target).StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    foreach ($entry in $zip.Entries) {
        $relative = $entry.FullName.Replace('\', '/')
        $segments = @($relative.Split('/'))
        $emptySegments = @($segments | Where-Object { $_ -ceq '' }).Count
        $allowedTrailingEmpty = if ($relative.EndsWith('/')) { 1 } else { 0 }
        if ($relative.StartsWith('/') -or $relative -match '^[A-Za-z]:' -or @($segments | Where-Object { $_ -in @('.', '..') }).Count -gt 0 -or $emptySegments -gt $allowedTrailingEmpty) { throw 'FABRIC_FIXTURE_ARCHIVE_PATH_REJECTED' }
        $parts = $relative.Split('/')
        if ($parts.Count -lt 2 -or $parts[0] -cne ('fabric-example-mod-' + [string]$pin.sourceCommit)) { throw 'FABRIC_FIXTURE_ARCHIVE_ROOT_INVALID' }
        $relativePath = ($parts | Select-Object -Skip 1) -join '/'
        if (-not $relativePath) { continue }
        $targetPath = [IO.Path]::GetFullPath((Join-Path $destination ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        if (-not (Test-MmtlFabricPathInsideRoot -Root $destination -Target $targetPath)) { throw 'FABRIC_FIXTURE_ARCHIVE_PATH_ESCAPE' }
        $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($unixType -eq 0xA000) { throw 'FABRIC_FIXTURE_ARCHIVE_SYMLINK_REJECTED' }
        if ($entry.FullName.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($targetPath); continue }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
        $inputStream = $entry.Open()
        $outputStream = [IO.FileStream]::new($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
    }
} finally { $zip.Dispose() }

$buildPath = Join-Path $destination 'build.gradle'
if (-not (Test-Path -LiteralPath $buildPath -PathType Leaf) -or (Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.sourceBuildGradleSha256) { throw 'FABRIC_FIXTURE_SOURCE_BUILD_SCRIPT_MISMATCH' }
$settingsPath = Join-Path $destination 'settings.gradle'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf) -or (Get-FileHash $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.sourceSettingsGradleSha256) { throw 'FABRIC_FIXTURE_SOURCE_SETTINGS_SCRIPT_MISMATCH' }
$wrapperProperties = Join-Path $destination 'gradle/wrapper/gradle-wrapper.properties'
$distribution = Get-Content -LiteralPath $wrapperProperties | Where-Object { $_ -match '^distributionUrl=' } | Select-Object -First 1
if (-not $distribution -or ([string]$distribution.Substring('distributionUrl='.Length)).Replace('\:', ':') -cne [string]$pin.gradleDistributionUrl) { throw 'FABRIC_FIXTURE_WRAPPER_MISMATCH' }

$versionSegment = [string]$pin.minecraftVersion
if ([IO.Path]::IsPathRooted($versionSegment) -or $versionSegment -match '[\\/:*?"<>|]' -or $versionSegment -in @('', '.', '..')) { throw 'FABRIC_FIXTURE_TARGET_PATH_INVALID' }
$verificationSource = Join-Path $repositoryRoot ('compatibility/fabric-verification-metadata/' + $versionSegment + '.xml')
if (-not (Test-Path -LiteralPath $verificationSource -PathType Leaf) -or (Get-FileHash $verificationSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.verificationMetadataSha256) { throw 'FABRIC_FIXTURE_VERIFICATION_METADATA_HASH_MISMATCH' }
$verificationDestination = Join-Path $destination 'gradle/verification-metadata.xml'
Copy-Item -LiteralPath $verificationSource -Destination $verificationDestination
$wrapperJarPath = Join-Path $destination 'gradle/wrapper/gradle-wrapper.jar'
if ((Get-FileHash $wrapperProperties -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.sourceWrapperPropertiesSha256 -or (Get-FileHash $wrapperJarPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.sourceWrapperJarSha256) { throw 'FABRIC_FIXTURE_WRAPPER_SOURCE_HASH_MISMATCH' }
$wrapperText = [IO.File]::ReadAllText($wrapperProperties)
$wrapperChecksum = 'distributionSha256Sum=' + [string]$pin.gradleDistributionSha256
if ([regex]::IsMatch($wrapperText, '(?m)^distributionSha256Sum=')) {
    if (-not [regex]::IsMatch($wrapperText, ('(?m)^' + [regex]::Escape($wrapperChecksum) + '$'))) { throw 'FABRIC_FIXTURE_WRAPPER_CHECKSUM_CONFLICT' }
} else {
    $wrapperText = $wrapperText.TrimEnd() + "`n" + $wrapperChecksum + "`n"
    [IO.File]::WriteAllText($wrapperProperties, $wrapperText, [Text.UTF8Encoding]::new($false))
}
$buildText = [IO.File]::ReadAllText($buildPath)
if (-not $buildText.Contains('"modid"')) { throw 'FABRIC_FIXTURE_MOD_DECLARATION_MISSING' }
$buildText = $buildText.Replace('"modid"', '"mmtl_marker"')
[IO.File]::WriteAllText($buildPath, $buildText, [Text.UTF8Encoding]::new($false))
$settingsText = [IO.File]::ReadAllText($settingsPath)
if (-not [regex]::IsMatch($settingsText, "(?m)^\s*rootProject\.name\s*=\s*'modid'\s*$")) { throw 'FABRIC_FIXTURE_PROJECT_NAME_DECLARATION_MISSING' }
$settingsText = [regex]::Replace($settingsText, "(?m)^\s*rootProject\.name\s*=\s*'modid'\s*$", "rootProject.name = 'mmtl-marker'")
[IO.File]::WriteAllText($settingsPath, $settingsText, [Text.UTF8Encoding]::new($false))
$propertiesPath = Join-Path $destination 'gradle.properties'
$properties = [IO.File]::ReadAllText($propertiesPath)
foreach ($pair in @(
    @('(?m)^loom_version=.*$', ('loom_version=' + [string]$pin.loomVersion)),
    @('(?m)^version=.*$', 'version=1.0.0'),
    @('(?m)^group=.*$', 'group=org.pycodersmod.mmtlfixture')
)) {
    if (-not [regex]::IsMatch($properties, $pair[0])) { throw 'FABRIC_FIXTURE_GRADLE_PROPERTY_MISSING' }
    $properties = [regex]::Replace($properties, $pair[0], $pair[1])
}
[IO.File]::WriteAllText($propertiesPath, $properties, [Text.UTF8Encoding]::new($false))

$sourceRoot = Join-Path $destination 'src'
if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
$javaPath = Join-Path $destination 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java'
$resourcePath = Join-Path $destination 'src/main/resources/fabric.mod.json'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $javaPath))
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $resourcePath))
$java = @'
package org.pycodersmod.mmtlfixture;

import net.fabricmc.api.ModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class MmtlMarkerMod implements ModInitializer {
    public static final String MOD_ID = "mmtl_marker";
    private static final Logger LOGGER = LoggerFactory.getLogger(MOD_ID);

    @Override
    public void onInitialize() {
        LOGGER.info("MMTL Fabric marker initialized");
    }
}
'@
$metadata = [ordered]@{
    schemaVersion = 1
    id = 'mmtl_marker'
    version = '${version}'
    name = 'MMTL Fabric Marker Fixture'
    description = 'Minimal MMTL-owned marker mod for exact-target validation.'
    environment = '*'
    entrypoints = [ordered]@{ main = @('org.pycodersmod.mmtlfixture.MmtlMarkerMod') }
    depends = [ordered]@{
        minecraft = ('=' + [string]$pin.minecraftVersion)
        fabricloader = ('=' + [string]$pin.loaderVersion)
        'fabric-api' = ('=' + [string]$pin.fabricApiVersion)
        java = ('>=' + [string]$pin.runtimeJavaMajor)
    }
}
[IO.File]::WriteAllText($javaPath, $java.TrimStart(), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($resourcePath, (ConvertTo-Json -InputObject $metadata -Depth 8), [Text.UTF8Encoding]::new($false))

$overlayFiles = @(
    [pscustomobject]@{ path = 'build.gradle'; sha256 = (Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ path = 'settings.gradle'; sha256 = (Get-FileHash $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ path = 'gradle.properties'; sha256 = (Get-FileHash $propertiesPath -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ path = 'gradle/wrapper/gradle-wrapper.properties'; sha256 = (Get-FileHash $wrapperProperties -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ path = 'gradle/verification-metadata.xml'; sha256 = (Get-FileHash $verificationDestination -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ path = 'src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java'; sha256 = (Get-FileHash $javaPath -Algorithm SHA256).Hash.ToLowerInvariant() },
    [pscustomobject]@{ path = 'src/main/resources/fabric.mod.json'; sha256 = (Get-FileHash $resourcePath -Algorithm SHA256).Hash.ToLowerInvariant() }
)
$records = @($overlayFiles | ForEach-Object { $_.path + '|' + $_.sha256 } | Sort-Object -CaseSensitive)
$overlayHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records -join "`n")))).ToLowerInvariant()
$fixtureManifest = [ordered]@{
    schemaVersion = 1
    fixtureId = 'MMTLFabricMarkerFixtureV1'
    targetId = [string]$pin.targetId
    sourceRepository = [string]$pin.sourceRepository
    sourceCommit = [string]$pin.sourceCommit
    sourceArchiveUrl = [string]$pin.sourceArchiveUrl
    sourceArchiveSha256 = [string]$pin.sourceArchiveSha256
    sourceWrapperJarSha256 = [string]$pin.sourceWrapperJarSha256
    verificationMetadataSha256 = [string]$pin.verificationMetadataSha256
    verificationComponentCount = [int]$pin.verificationComponentCount
    verificationArtifactCount = [int]$pin.verificationArtifactCount
    trustedArtifactCount = [int]$pin.trustedArtifactCount
    loomVersion = [string]$pin.loomVersion
    gradleVersion = [string]$pin.gradleVersion
    buildJavaMajor = [int]$pin.buildJavaMajor
    runtimeJavaMajor = [int]$pin.runtimeJavaMajor
    verificationStatus = [string]$pin.verificationStatus
    overlaySha256 = $overlayHash
    overlayFiles = $overlayFiles
}
$metadataDirectory = Join-Path $destination '.mmtl-fixture'
[void][IO.Directory]::CreateDirectory($metadataDirectory)
[IO.File]::WriteAllText((Join-Path $metadataDirectory 'manifest.json'), (ConvertTo-Json -InputObject $fixtureManifest -Depth 10), [Text.UTF8Encoding]::new($false))
$fixtureManifest
