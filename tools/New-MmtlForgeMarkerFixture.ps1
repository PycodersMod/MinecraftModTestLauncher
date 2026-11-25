[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceArchivePath,
    [Parameter(Mandatory)][string]$DestinationPath,
    [string]$TargetId='Forge@1.7.10',
    [string]$PinManifestPath
)

$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path -Parent $PSScriptRoot
function Test-MmtlFixturePathInsideRoot {
    param([string]$Root,[string]$Target)
    $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $targetPath=[IO.Path]::GetFullPath($Target)
    return $targetPath.StartsWith($rootPath,[StringComparison]::OrdinalIgnoreCase)
}
$pinManifestPath=if($PinManifestPath){[IO.Path]::GetFullPath($PinManifestPath)}elseif($TargetId -ceq 'Forge@1.8' -and (Test-Path -LiteralPath (Join-Path $repositoryRoot 'compatibility/forge-plugin-build-pins.json'))){Join-Path $repositoryRoot 'compatibility/forge-plugin-build-pins.json'}else{Join-Path $repositoryRoot 'compatibility/forge-build-pins.json'}
$pinManifest=Get-Content -LiteralPath $pinManifestPath -Raw | ConvertFrom-Json
$pin=@($pinManifest.targets | Where-Object targetId -ceq $TargetId)
if($pin.Count -ne 1){throw 'FORGE_MARKER_FIXTURE_PIN_MISSING'}
$pin=$pin[0]
$archive=[IO.Path]::GetFullPath($SourceArchivePath)
if(-not(Test-Path -LiteralPath $archive -PathType Leaf)){throw 'FORGE_MARKER_FIXTURE_ARCHIVE_MISSING'}
if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.sourceArchiveSha256){throw 'FORGE_MARKER_FIXTURE_ARCHIVE_HASH_MISMATCH'}
$destination=[IO.Path]::GetFullPath($DestinationPath)
if(Test-Path -LiteralPath $destination){throw 'FORGE_MARKER_FIXTURE_DESTINATION_EXISTS'}
[void][IO.Directory]::CreateDirectory($destination)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
    foreach($entry in $zip.Entries){
        $relative=$entry.FullName.Replace('\','/')
        if($relative.StartsWith('/') -or $relative -match '^[A-Za-z]:' -or @($relative.Split('/') | Where-Object {$_ -eq '..'}).Count){throw 'FORGE_MARKER_FIXTURE_ARCHIVE_PATH_REJECTED'}
        $targetPath=[IO.Path]::GetFullPath((Join-Path $destination ($relative.Replace('/',[IO.Path]::DirectorySeparatorChar))))
        if(-not(Test-MmtlFixturePathInsideRoot -Root $destination -Target $targetPath)){throw 'FORGE_MARKER_FIXTURE_ARCHIVE_PATH_ESCAPE'}
        $unixType=($entry.ExternalAttributes -shr 16) -band 0xF000
        if($unixType -eq 0xA000){throw 'FORGE_MARKER_FIXTURE_ARCHIVE_SYMLINK_REJECTED'}
        if($entry.FullName.EndsWith('/')){[void][IO.Directory]::CreateDirectory($targetPath);continue}
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
        $inputStream=$entry.Open();$outputStream=[IO.FileStream]::new($targetPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$inputStream.CopyTo($outputStream)}finally{$outputStream.Dispose();$inputStream.Dispose()}
    }
}finally{$zip.Dispose()}

$buildPath=Join-Path $destination 'build.gradle'
if(-not(Test-Path -LiteralPath $buildPath -PathType Leaf) -or (Get-FileHash -LiteralPath $buildPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$pin.buildGradleSha256){throw 'FORGE_MARKER_FIXTURE_BUILD_SCRIPT_MISMATCH'}
$wrapperProperties=Join-Path $destination 'gradle/wrapper/gradle-wrapper.properties'
if(-not(Test-Path -LiteralPath $wrapperProperties -PathType Leaf)){throw 'FORGE_MARKER_FIXTURE_WRAPPER_PROPERTIES_MISSING'}
$distributionLine=Get-Content -LiteralPath $wrapperProperties | Where-Object {$_ -match '^distributionUrl='} | Select-Object -First 1
if(-not $distributionLine -or ([string]$distributionLine.Substring('distributionUrl='.Length)).Replace('\:',':') -cne [string]$pin.gradleDistributionUrl){throw 'FORGE_MARKER_FIXTURE_WRAPPER_MISMATCH'}

$javaRoot=Join-Path $destination 'src/main/java'
if(Test-Path -LiteralPath $javaRoot){Remove-Item -LiteralPath $javaRoot -Recurse -Force}
$ownedJavaPath=Join-Path $javaRoot 'org/pycodersmod/mmtlfixture/MmtlMarkerMod.java'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $ownedJavaPath))
$minecraftVersionMatch=[regex]::Match([string]$pin.minecraftId,'^(?<major>[0-9]+)\.(?<minor>[0-9]+)')
if(-not $minecraftVersionMatch.Success){throw 'FORGE_MARKER_FIXTURE_MINECRAFT_VERSION_INVALID'}
$minecraftMajor=[int]$minecraftVersionMatch.Groups['major'].Value;$minecraftMinor=[int]$minecraftVersionMatch.Groups['minor'].Value
$post17Fml=$minecraftMajor -gt 1 -or ($minecraftMajor -eq 1 -and $minecraftMinor -ge 8)
$modernModAnnotation=$minecraftMajor -eq 1 -and $minecraftMinor -ge 13
$markerTemplate=if($modernModAnnotation){'common/fixtures/forge/1.13-marker/MmtlMarkerMod.java'}elseif($post17Fml){'common/fixtures/forge/1.8-marker/MmtlMarkerMod.java'}else{'common/fixtures/forge/1.7.10-marker/MmtlMarkerMod.java'}
Copy-Item -LiteralPath (Join-Path $repositoryRoot $markerTemplate) -Destination $ownedJavaPath
$resources=Join-Path $destination 'src/main/resources'
[void][IO.Directory]::CreateDirectory($resources)
$mcmodTemplate=[IO.File]::ReadAllText((Join-Path $repositoryRoot 'common/fixtures/forge/1.7.10-marker/mcmod.info'))
$mcmodText=$mcmodTemplate.Replace('"mcversion": "1.7.10"',('"mcversion": "'+[string]$pin.minecraftId+'"'))
if($mcmodText -ceq $mcmodTemplate -and [string]$pin.minecraftId -cne '1.7.10'){throw 'FORGE_MARKER_FIXTURE_MCMOD_TEMPLATE_MISMATCH'}
[IO.File]::WriteAllText((Join-Path $resources 'mcmod.info'),$mcmodText,[Text.UTF8Encoding]::new($false))

$overlayFiles=@(
    [pscustomobject]@{path='src/main/java/org/pycodersmod/mmtlfixture/MmtlMarkerMod.java';sha256=(Get-FileHash $ownedJavaPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    [pscustomobject]@{path='src/main/resources/mcmod.info';sha256=(Get-FileHash (Join-Path $resources 'mcmod.info') -Algorithm SHA256).Hash.ToLowerInvariant()}
)
$overlayRecords=@($overlayFiles | ForEach-Object {$_.path+'|'+$_.sha256} | Sort-Object -CaseSensitive)
$overlayHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($overlayRecords -join "`n")))).ToLowerInvariant()
$fixtureManifest=[ordered]@{schemaVersion=1;fixtureId='MMTLForgeMarkerFixtureV1';targetId=[string]$pin.targetId;sourceArchiveUrl=[string]$pin.sourceArchiveUrl;sourceArchiveSha256=[string]$pin.sourceArchiveSha256;overlaySha256=$overlayHash;overlayFiles=$overlayFiles}
$metadataDirectory=Join-Path $destination '.mmtl-fixture'
[void][IO.Directory]::CreateDirectory($metadataDirectory)
[IO.File]::WriteAllText((Join-Path $metadataDirectory 'manifest.json'),(ConvertTo-Json -InputObject $fixtureManifest -Depth 8),[Text.UTF8Encoding]::new($false))

[pscustomobject]@{fixtureRoot=$destination;targetId=[string]$pin.targetId;sourceArchiveUrl=[string]$pin.sourceArchiveUrl;sourceArchiveSha256=[string]$pin.sourceArchiveSha256;fixtureId='MMTLForgeMarkerFixtureV1';overlaySha256=$overlayHash;overlayFiles=$overlayFiles}
