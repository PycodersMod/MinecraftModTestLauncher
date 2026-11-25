[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceArchivePath,
    [Parameter(Mandatory)][string]$DestinationPath,
    [string]$TargetId = 'Quilt@1.20.6',
    [string]$PinManifestPath
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pinPath = if ($PinManifestPath) { [IO.Path]::GetFullPath($PinManifestPath) } else { Join-Path $repo 'compatibility/quilt-build-pins.json' }
$manifest = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
$pins = @($manifest.targets | Where-Object { [string]$_.targetId -ceq $TargetId })
if ([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -cne 'PARTIAL' -or $pins.Count -ne 1) { throw 'QUILT_FIXTURE_PIN_MISSING_OR_INVALID' }
$pin = $pins[0]
if ([string]$pin.sourceVerificationStatus -cne 'PinnedInputsVerified') { throw 'QUILT_FIXTURE_PIN_NOT_VERIFIED' }
$archive = [IO.Path]::GetFullPath($SourceArchivePath)
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'QUILT_FIXTURE_ARCHIVE_MISSING' }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.sourceArchiveSha256) { throw 'QUILT_FIXTURE_ARCHIVE_HASH_MISMATCH' }
$destination = [IO.Path]::GetFullPath($DestinationPath)
if (Test-Path -LiteralPath $destination) { throw 'QUILT_FIXTURE_DESTINATION_EXISTS' }
[void][IO.Directory]::CreateDirectory($destination)
function Test-MmtlQuiltPathInsideRoot {
    param([string]$Root, [string]$Target)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    [IO.Path]::GetFullPath($Target).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
$rootName = 'quilt-template-mod-' + [string]$pin.sourceCommit
try {
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $zip.Entries) {
        $relative = $entry.FullName.Replace('\', '/')
        $parts = @($relative.Split('/'))
        $allowedTrailingEmpty = if ($relative.EndsWith('/')) { 1 } else { 0 }
        if ($relative.StartsWith('/') -or $relative -match '^[A-Za-z]:' -or @($parts | Where-Object { $_ -in @('', '.', '..') }).Count -gt $allowedTrailingEmpty -or $parts[0] -cne $rootName) { throw 'QUILT_FIXTURE_ARCHIVE_PATH_REJECTED' }
        if (-not $seen.Add($relative)) { throw 'QUILT_FIXTURE_ARCHIVE_DUPLICATE_PATH' }
        $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($unixType -eq 0xA000 -or ($unixType -ne 0 -and $unixType -ne 0x8000 -and -not $entry.FullName.EndsWith('/'))) { throw 'QUILT_FIXTURE_ARCHIVE_SPECIAL_FILE_REJECTED' }
        $tail = ($parts | Select-Object -Skip 1) -join '/'
        if (-not $tail) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $destination ($tail.Replace('/', [IO.Path]::DirectorySeparatorChar))))
        if (-not (Test-MmtlQuiltPathInsideRoot -Root $destination -Target $target)) { throw 'QUILT_FIXTURE_ARCHIVE_PATH_ESCAPE' }
        if ($entry.FullName.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($target); continue }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        $input = $entry.Open(); $output = [IO.FileStream]::new($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
} finally { $zip.Dispose() }

$sourceChecks = @(
    @('build.gradle', 'sourceBuildGradleSha256'), @('settings.gradle', 'sourceSettingsGradleSha256'),
    @('gradle.properties', 'sourceGradlePropertiesSha256'), @('gradle/libs.versions.toml', 'sourceVersionsTomlSha256'),
    @('gradle/wrapper/gradle-wrapper.properties', 'sourceWrapperPropertiesSha256'), @('gradle/wrapper/gradle-wrapper.jar', 'sourceWrapperJarSha256')
)
foreach ($check in $sourceChecks) {
    $path = Join-Path $destination $check[0]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.($check[1])) { throw ('QUILT_FIXTURE_SOURCE_HASH_MISMATCH:' + $check[0]) }
}
$versionsPath = Join-Path $destination 'gradle/libs.versions.toml'
$versions = [IO.File]::ReadAllText($versionsPath)
$versionPins = @{
    minecraft = [string]$pin.minecraftVersion
    quilt_mappings = [string]$pin.quiltMappingsVersion
    quilt_loom = [string]$pin.quiltLoomVersion
    quilt_loader = [string]$pin.loaderVersion
}
foreach ($key in $versionPins.Keys) {
    $pattern = '(?m)^' + [regex]::Escape($key) + '\s*=\s*"[^"]*"$'
    if ([regex]::Matches($versions, $pattern).Count -ne 1) { throw ('QUILT_FIXTURE_VERSION_CATALOG_KEY_INVALID:' + $key) }
    $versions = [regex]::Replace($versions, $pattern, ($key + ' = "' + $versionPins[$key] + '"'))
}
if ([string]::IsNullOrWhiteSpace([string]$pin.quiltedFabricApiVersion)) {
    $versions = [regex]::Replace($versions, '(?m)^\s*(?:quilted_fabric_api|quilt_standard_libraries)(?:_deprecated)?\s*=.*\r?\n', '')
} else {
    $qfapiPattern = '(?m)^quilted_fabric_api\s*=\s*"[^"]*"$'
    if ([regex]::Matches($versions, $qfapiPattern).Count -ne 1) { throw 'QUILT_FIXTURE_QFAPI_VERSION_CATALOG_KEY_INVALID' }
    $versions = [regex]::Replace($versions, $qfapiPattern, ('quilted_fabric_api = "' + [string]$pin.quiltedFabricApiVersion + '"'))
}
[IO.File]::WriteAllText($versionsPath, $versions, [Text.UTF8Encoding]::new($false))
$expectedVersions = @(
    "minecraft = `"$($pin.minecraftVersion)`""
    "quilt_mappings = `"$($pin.quiltMappingsVersion)`""
    "quilt_loom = `"$($pin.quiltLoomVersion)`""
    "quilt_loader = `"$($pin.loaderVersion)`""
)
foreach ($expected in $expectedVersions) { if (-not $versions.Contains($expected)) { throw 'QUILT_FIXTURE_DEPENDENCY_VERSION_MISMATCH' } }
if (-not [string]::IsNullOrWhiteSpace([string]$pin.quiltedFabricApiVersion)) {
    if (-not $versions.Contains("quilted_fabric_api = `"$($pin.quiltedFabricApiVersion)`"")) { throw 'QUILT_FIXTURE_DEPENDENCY_VERSION_MISMATCH' }
} elseif ($versions -match '(?m)^\s*(?:quilted_fabric_api|quilt_standard_libraries)\s*=') {
    throw 'QUILT_FIXTURE_UNPUBLISHED_QFAPI_REFERENCED'
}
$wrapperPath = Join-Path $destination 'gradle/wrapper/gradle-wrapper.properties'
$wrapper = [IO.File]::ReadAllText($wrapperPath)
if (-not [regex]::IsMatch($wrapper, ('(?m)^distributionUrl=https\\://services\.gradle\.org/distributions/gradle-' + [regex]::Escape([string]$pin.gradleVersion) + '-bin\.zip$'))) { throw 'QUILT_FIXTURE_WRAPPER_URL_MISMATCH' }
$wrapper += "`ndistributionSha256Sum=" + [string]$pin.gradleDistributionSha256 + "`n"
[IO.File]::WriteAllText($wrapperPath, $wrapper, [Text.UTF8Encoding]::new($false))
$propsPath = Join-Path $destination 'gradle.properties'
$props = [IO.File]::ReadAllText($propsPath)
$props = [regex]::Replace($props, '(?m)^archives_base_name\s*=.*$', 'archives_base_name = mmtl_quilt_marker')
$props = [regex]::Replace($props, '(?m)^maven_group\s*=.*$', 'maven_group = org.pycodersmod.mmtlfixture')
[IO.File]::WriteAllText($propsPath, $props, [Text.UTF8Encoding]::new($false))
$settingsPath = Join-Path $destination 'settings.gradle'
$settings = [IO.File]::ReadAllText($settingsPath)
if ($settings -match '(?m)^\s*rootProject\.name\s*=') { throw 'QUILT_FIXTURE_SETTINGS_DECLARATION_UNEXPECTED' }
$settings = $settings.TrimEnd() + "`n`nrootProject.name = 'mmtl-quilt-marker'`n"
[IO.File]::WriteAllText($settingsPath, $settings, [Text.UTF8Encoding]::new($false))
$buildPath = Join-Path $destination 'build.gradle'
$build = [IO.File]::ReadAllText($buildPath)
if (-not $build.Contains('"example_mod"')) { throw 'QUILT_FIXTURE_LOOM_MOD_DECLARATION_MISSING' }
$build = $build.Replace('"example_mod"', '"mmtl_marker"')
if ([string]::IsNullOrWhiteSpace([string]$pin.quiltedFabricApiVersion)) {
    $build = [regex]::Replace($build, '(?m)^\s*modImplementation\s+libs\.(?:bundles\.)?quilted\.fabric\.api\S*\s*\r?\n', '')
}
[IO.File]::WriteAllText($buildPath, $build, [Text.UTF8Encoding]::new($false))

$javaRoot = Join-Path $destination 'src/main/java'
if (Test-Path -LiteralPath $javaRoot) { Remove-Item -LiteralPath $javaRoot -Recurse -Force }
$javaPath = Join-Path $javaRoot 'org/pycodersmod/mmtlfixture/MmtlMarkerMod.java'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $javaPath))
$java = if ([string]::IsNullOrWhiteSpace([string]$pin.quiltedFabricApiVersion)) { @'
package org.pycodersmod.mmtlfixture;

import net.fabricmc.api.ModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class MmtlMarkerMod implements ModInitializer {
    private static final Logger LOGGER = LoggerFactory.getLogger("mmtl_marker");

    @Override
    public void onInitialize() {
        LOGGER.info("MMTL_QUILT_MARKER_INITIALIZED target=__MMTL_TARGET_ID__ mod=mmtl_marker");
    }
}
'@ } else { @'
package org.pycodersmod.mmtlfixture;

import org.quiltmc.loader.api.ModContainer;
import org.quiltmc.qsl.base.api.entrypoint.ModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class MmtlMarkerMod implements ModInitializer {
    private static final Logger LOGGER = LoggerFactory.getLogger("mmtl_marker");

    @Override
    public void onInitialize(ModContainer mod) {
        LOGGER.info("MMTL_QUILT_MARKER_INITIALIZED target=__MMTL_TARGET_ID__ mod={}", mod.metadata().id());
    }
}
'@ }
$java = $java.Replace('__MMTL_TARGET_ID__', [string]$pin.targetId)
[IO.File]::WriteAllText($javaPath, $java.TrimStart(), [Text.UTF8Encoding]::new($false))
$resourceDirectory = Join-Path $destination 'src/main/resources'
$resourcePath = Join-Path $resourceDirectory 'quilt.mod.json'
if ([string]::IsNullOrWhiteSpace([string]$pin.quiltedFabricApiVersion)) {
    if (Test-Path -LiteralPath $resourcePath) { Remove-Item -LiteralPath $resourcePath -Force }
    $resourcePath = Join-Path $resourceDirectory 'fabric.mod.json'
    $metadata = [ordered]@{
        schemaVersion=1;id='mmtl_marker';version='1.0.0';name='MMTL Quilt Marker'
        description='Controlled Quilt Loader-only compatibility build fixture.';environment='*'
        entrypoints=@{main=@('org.pycodersmod.mmtlfixture.MmtlMarkerMod')}
        depends=@{fabricloader=('=' + [string]$pin.loaderVersion);minecraft=('=' + [string]$pin.minecraftVersion);java=('>=' + [string]$pin.buildJavaMajor)}
    }
} else {
    $metadata = Get-Content -LiteralPath $resourcePath -Raw | ConvertFrom-Json -AsHashtable
    $metadata.quilt_loader.group = 'org.pycodersmod.mmtlfixture'
    $metadata.quilt_loader.id = 'mmtl_marker'
    $metadata.quilt_loader.version = '1.0.0'
    $metadata.quilt_loader.metadata.name = 'MMTL Quilt Marker'
    $metadata.quilt_loader.metadata.description = 'Controlled Quilt compatibility build fixture.'
    $metadata.quilt_loader.entrypoints = @{ init = @('org.pycodersmod.mmtlfixture.MmtlMarkerMod') }
    $metadata.quilt_loader.Remove('mixin')
    $metadata.quilt_loader.depends = @(
        @{ id='quilt_loader'; versions='=' + [string]$pin.loaderVersion },
        @{ id='minecraft'; versions='=' + [string]$pin.minecraftVersion },
        @{ id='quilted_fabric_api'; versions='=' + [string]$pin.quiltedFabricApiVersion }
    )
}
[IO.File]::WriteAllText($resourcePath, (ConvertTo-Json -InputObject $metadata -Depth 12), [Text.UTF8Encoding]::new($false))

$overlayFiles = @(
    [pscustomobject]@{path='build.gradle';sha256=(Get-FileHash $buildPath -Algorithm SHA256).Hash.ToLowerInvariant()},
    [pscustomobject]@{path='settings.gradle';sha256=(Get-FileHash $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()},
    [pscustomobject]@{path='gradle.properties';sha256=(Get-FileHash $propsPath -Algorithm SHA256).Hash.ToLowerInvariant()},
    [pscustomobject]@{path='gradle/wrapper/gradle-wrapper.properties';sha256=(Get-FileHash $wrapperPath -Algorithm SHA256).Hash.ToLowerInvariant()},
    [pscustomobject]@{path='gradle/libs.versions.toml';sha256=(Get-FileHash $versionsPath -Algorithm SHA256).Hash.ToLowerInvariant()},
    [pscustomobject]@{path='src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java';sha256=(Get-FileHash $javaPath -Algorithm SHA256).Hash.ToLowerInvariant()},
    [pscustomobject]@{path=('src/main/resources/' + [IO.Path]::GetFileName($resourcePath));sha256=(Get-FileHash $resourcePath -Algorithm SHA256).Hash.ToLowerInvariant()}
)
$records = @($overlayFiles | ForEach-Object { $_.path + '|' + $_.sha256 } | Sort-Object -CaseSensitive)
$overlayHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($records -join "`n")))).ToLowerInvariant()
$fixture = [ordered]@{
    schemaVersion=1; fixtureId='MMTLQuiltMarkerFixtureV1'; targetId=[string]$pin.targetId
    sourceRepository=[string]$pin.sourceRepository; sourceCommit=[string]$pin.sourceCommit; sourceArchiveSha256=[string]$pin.sourceArchiveSha256
    sourceBuildGradleSha256=[string]$pin.sourceBuildGradleSha256; sourceSettingsGradleSha256=[string]$pin.sourceSettingsGradleSha256
    sourceGradlePropertiesSha256=[string]$pin.sourceGradlePropertiesSha256; sourceVersionsTomlSha256=[string]$pin.sourceVersionsTomlSha256
    sourceWrapperPropertiesSha256=[string]$pin.sourceWrapperPropertiesSha256; sourceWrapperJarSha256=[string]$pin.sourceWrapperJarSha256
    quiltLoomVersion=[string]$pin.quiltLoomVersion; loaderVersion=[string]$pin.loaderVersion; gradleVersion=[string]$pin.gradleVersion
    buildJavaMajor=[int]$pin.buildJavaMajor; runtimeJavaMajor=[int]$pin.runtimeJavaMajor
    overlaySha256=$overlayHash; overlayFiles=$overlayFiles
}
$metaDir = Join-Path $destination '.mmtl-fixture'; [void][IO.Directory]::CreateDirectory($metaDir)
[IO.File]::WriteAllText((Join-Path $metaDir 'manifest.json'), (ConvertTo-Json -InputObject $fixture -Depth 10), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{fixtureRoot=$destination;targetId=[string]$pin.targetId;fixtureId=$fixture.fixtureId;sourceArchiveSha256=$fixture.sourceArchiveSha256;overlaySha256=$overlayHash;overlayFiles=$overlayFiles}
