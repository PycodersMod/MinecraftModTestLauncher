Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\\Platform\\Platform.psm1') -Force

function Test-MmtlForgePinValue {
    param([Parameter(Mandatory)]$Pin)
    foreach($field in @('forgeGradleSpec','buildGradleSha256','forgeGradleJarSha256','forgeGradlePomSha256','forgeGradleJarUrl','forgeGradlePomUrl','gradleDistributionUrl','gradleDistributionSha256','buildJavaMajor','client','server')){
        if(-not $Pin.PSObject.Properties[$field] -or $null -eq $Pin.$field){throw "FORGE_BUILD_PIN_FIELD_MISSING:$field"}
    }
    $timestampProperty=$Pin.PSObject.Properties['forgeGradleTimestamp'];$timestampValue=if($timestampProperty){[string]$timestampProperty.Value}else{''}
    $resolvedProperty=$Pin.PSObject.Properties['forgeGradleResolvedVersion'];$resolvedPluginVersion=if($resolvedProperty){[string]$resolvedProperty.Value}else{''}
    $snapshotSpec=[regex]::Match([string]$Pin.forgeGradleSpec,'^(?<base>[0-9]+(?:\.[0-9]+)*)-SNAPSHOT$')
    $dynamicSpec=[regex]::Match([string]$Pin.forgeGradleSpec,'^(?<base>[0-9]+)\.\+$')
    $rangeSpec=[regex]::Match([string]$Pin.forgeGradleSpec,'^\[(?<minimum>[0-9]+(?:\.[0-9]+)*),(?<maximum>[0-9]+(?:\.[0-9]+)*)\)$')
    if($snapshotSpec.Success){
        if(-not $timestampProperty -or $timestampValue -notmatch ('^'+[regex]::Escape($snapshotSpec.Groups['base'].Value)+'-(?<stamp>[0-9]{8}\.[0-9]{6})-(?<build>[0-9]+)$') -or $resolvedProperty){throw 'FORGE_BUILD_PIN_TIMESTAMP_INVALID'}
        $resolvedPluginVersion=[string]$Pin.forgeGradleSpec
    }elseif($dynamicSpec.Success){
        if(-not $resolvedProperty -or $resolvedPluginVersion -notmatch ('^'+[regex]::Escape($dynamicSpec.Groups['base'].Value)+'(?:\.[0-9]+)+$') -or $timestampProperty){throw 'FORGE_BUILD_PIN_DYNAMIC_VERSION_INVALID'}
    }elseif($rangeSpec.Success){
        $minimumVersion=$null;$maximumVersion=$null;$resolvedVersion=$null
        if(-not $resolvedProperty -or $timestampProperty -or $resolvedPluginVersion -notmatch '^[0-9]+(?:\.[0-9]+){1,3}$' -or -not [version]::TryParse($rangeSpec.Groups['minimum'].Value,[ref]$minimumVersion) -or -not [version]::TryParse($rangeSpec.Groups['maximum'].Value,[ref]$maximumVersion) -or -not [version]::TryParse($resolvedPluginVersion,[ref]$resolvedVersion) -or $minimumVersion -ge $maximumVersion -or $resolvedVersion -lt $minimumVersion -or $resolvedVersion -ge $maximumVersion){throw 'FORGE_BUILD_PIN_RANGE_INVALID'}
    }else{throw 'FORGE_BUILD_PIN_SPEC_INVALID'}
    if([int]$Pin.buildJavaMajor -lt 1 -or [int]$Pin.buildJavaMajor -gt 25){throw 'FORGE_BUILD_PIN_JAVA_MAJOR_INVALID'}
    foreach($field in @('buildGradleSha256','forgeGradleJarSha256','forgeGradlePomSha256')){if([string]$Pin.$field -notmatch '^(?i:[a-f0-9]{64})$'){throw "FORGE_BUILD_PIN_HASH_INVALID:$field"}}
    foreach($field in @('forgeGradleJarUrl','forgeGradlePomUrl')){
        $uri=$null;if(-not [Uri]::TryCreate([string]$Pin.$field,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo){throw "FORGE_BUILD_PIN_URL_INVALID:$field"}
    }
    $gradleUri=$null
    if([string]$Pin.gradleDistributionSha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not [Uri]::TryCreate([string]$Pin.gradleDistributionUrl,[UriKind]::Absolute,[ref]$gradleUri) -or $gradleUri.Scheme -cne 'https' -or $gradleUri.Host -cne 'services.gradle.org' -or $gradleUri.UserInfo -or $gradleUri.AbsolutePath -notmatch '^/distributions/gradle-[0-9.]+-(?:bin|all)\.zip$'){throw 'FORGE_BUILD_PIN_GRADLE_DISTRIBUTION_INVALID'}
    foreach($name in @('client','server')){
        $download=$Pin.$name;$uri=$null
        if(-not $download.PSObject.Properties['url'] -or -not $download.PSObject.Properties['sha1'] -or -not $download.PSObject.Properties['sizeBytes'] -or [long]$download.sizeBytes -le 0 -or -not [Uri]::TryCreate([string]$download.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -notin @('launcher.mojang.com','piston-data.mojang.com') -or $uri.UserInfo -or [string]$download.sha1 -notmatch '^(?i:[a-f0-9]{40})$'){throw "FORGE_BUILD_PIN_MOJANG_DOWNLOAD_INVALID:$name"}
        if($uri.AbsolutePath -cne (('/v1/objects/'+[string]$download.sha1+'/'+$name+'.jar'))){throw "FORGE_BUILD_PIN_MOJANG_HASH_URL_MISMATCH:$name"}
    }
}

function Get-MmtlForgePinFileHash {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw 'FORGE_PINNED_ARTIFACT_MISSING'}
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-MmtlForgeBuildScriptDeclarations {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$BuildScriptText)
    $active=[regex]::Replace($BuildScriptText,'(?s)/\*.*?\*/','')
    $active=[regex]::Replace($active,'(?m)^\s*//.*$','')
    $classpath=[Collections.Generic.List[object]]::new()
    foreach($match in [regex]::Matches($active,'(?im)\bclasspath\s+["'']net\.minecraftforge\.gradle:ForgeGradle:(?<version>[^:"'']+)["'']')){
        $classpath.Add([pscustomobject]@{kind='BuildscriptClasspath';coordinate='net.minecraftforge.gradle:ForgeGradle';version=$match.Groups['version'].Value})
    }
    foreach($match in [regex]::Matches($active,'(?im)\bclasspath\s+group\s*:\s*["'']net\.minecraftforge\.gradle["'']\s*,\s*name\s*:\s*["'']ForgeGradle["'']\s*,\s*version\s*:\s*["''](?<version>[^"'']+)["'']')){
        $classpath.Add([pscustomobject]@{kind='BuildscriptClasspath';coordinate='net.minecraftforge.gradle:ForgeGradle';version=$match.Groups['version'].Value})
    }
    $plugins=[Collections.Generic.List[object]]::new()
    foreach($match in [regex]::Matches($active,'(?im)\bid\s+["''](?<id>net\.minecraftforge\.gradle(?:\.forge)?)["'']\s+version\s+["''](?<version>[^"'']+)["'']')){
        $plugins.Add([pscustomobject]@{kind='PluginsDsl';coordinate=$match.Groups['id'].Value;version=$match.Groups['version'].Value})
    }
    [pscustomobject]@{classpath=@($classpath.ToArray());plugins=@($plugins.ToArray())}
}

function Get-MmtlForgeFixtureOverlayHash {
    param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)]$Fixture)
    if(-not $Fixture.PSObject.Properties['fixtureId'] -or [string]$Fixture.fixtureId -cne 'MMTLForgeMarkerFixtureV1' -or -not $Fixture.PSObject.Properties['overlaySha256'] -or -not $Fixture.PSObject.Properties['overlayFiles']){throw 'FORGE_FIXTURE_OVERLAY_IDENTITY_INVALID'}
    $root=[IO.Path]::GetFullPath($ProjectRoot);$records=[Collections.Generic.List[string]]::new()
    $files=@($Fixture.overlayFiles)
    if($files.Count -lt 1){throw 'FORGE_FIXTURE_OVERLAY_FILES_MISSING'}
    foreach($file in $files){
        $relative=([string]$file.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if([IO.Path]::IsPathRooted($relative) -or @($relative.Split([IO.Path]::DirectorySeparatorChar) | Where-Object {$_ -in @('','.','..')}).Count -or [string]$file.sha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_FIXTURE_OVERLAY_PATH_INVALID'}
        $path=[IO.Path]::GetFullPath((Join-Path $root $relative))
        if(-not(Test-MmtlPlatformPathInsideRoot -Root $root -Target $path) -or -not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'FORGE_FIXTURE_OVERLAY_FILE_MISSING'}
        $item=Get-Item -LiteralPath $path -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw 'FORGE_FIXTURE_OVERLAY_REPARSE_PATH'}
        $actual=(Get-MmtlForgePinFileHash -Path $path)
        if($actual -cne ([string]$file.sha256).ToLowerInvariant()){throw 'FORGE_FIXTURE_OVERLAY_FILE_HASH_MISMATCH'}
        $records.Add(([string]$file.path).Replace('\\','/')+'|'+$actual)
    }
    $ordered=$records.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
    $actualOverlay=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($ordered -join "`n")))).ToLowerInvariant()
    if($actualOverlay -cne ([string]$Fixture.overlaySha256).ToLowerInvariant()){throw 'FORGE_FIXTURE_OVERLAY_HASH_MISMATCH'}
    return $actualOverlay
}

function Get-MmtlForgeExpectedBuildGradleSha256 {
    param(
        [Parameter(Mandatory)]$Pin,
        [object]$Fixture,
        [string]$FixtureOverlayRoot
    )
    if(-not $Fixture -or -not $Fixture.PSObject.Properties['overlayFiles']){return ([string]$Pin.buildGradleSha256).ToLowerInvariant()}
    $buildOverlay=@($Fixture.overlayFiles | Where-Object {([string]$_.path).Replace('\','/').TrimStart('/') -ieq 'build.gradle'})
    if($buildOverlay.Count -eq 0){return ([string]$Pin.buildGradleSha256).ToLowerInvariant()}
    if([string]::IsNullOrWhiteSpace($FixtureOverlayRoot) -or -not(Test-Path -LiteralPath $FixtureOverlayRoot -PathType Container)){throw 'FORGE_FIXTURE_OVERLAY_ROOT_REQUIRED'}
    Get-MmtlForgeFixtureOverlayHash -ProjectRoot $FixtureOverlayRoot -Fixture $Fixture | Out-Null
    return ([string]$buildOverlay[0].sha256).ToLowerInvariant()
}

function Get-MmtlForgeGradle6CatalogFileNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][ValidateSet('Windows','Linux','macOS')][string]$OperatingSystem,
        [Parameter(Mandatory)][ValidateSet('x64','arm64')][string]$Architecture
    )
    $match=[regex]::Match($TargetId,'^Forge@(?<minecraftId>[0-9]+(?:\.[0-9]+){1,2})$')
    if(-not $match.Success){throw 'FORGE_GRADLE6_CATALOG_TARGET_INVALID'}
    $minecraftId=$match.Groups['minecraftId'].Value
    $baseName="Forge-$minecraftId"
    [pscustomobject]@{
        minecraftId=$minecraftId
        buildClasspath="$baseName.json"
        targetInputs="$baseName.json"
        runtimeArtifacts="$baseName-$OperatingSystem-$Architecture.json"
    }
}

function ConvertTo-MmtlForgeSecureBuildScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$SourceText)

    $repositoryMatch=[regex]::Matches($SourceText,'https?://files\.minecraftforge\.net/maven')
    $buildscriptMatch=[regex]::Matches($SourceText,'buildscript\s*\{\s*repositories\s*\{')
    if($repositoryMatch.Count -ne 1 -or $buildscriptMatch.Count -ne 1){throw 'FORGE_BUILD_GRADLE_PATCH_SHAPE_UNEXPECTED'}
    $separator=if($SourceText.Contains("`r`n")){"`r`n"}else{"`n"}
    $insertAt=$buildscriptMatch[0].Index+$buildscriptMatch[0].Length
    $localRepository="        maven { url uri('.mmtl-forge-secure/repository') }"+$separator
    $patched=$SourceText.Substring(0,$insertAt)+$localRepository+$SourceText.Substring($insertAt)
    $patched=[regex]::Replace($patched,'https?://files\.minecraftforge\.net/maven','https://maven.minecraftforge.net')
    $patched=$patched.Replace('mavenCentral()',"maven { url 'https://repo.maven.apache.org/maven2' }")
    return $patched
}

function Get-MmtlForgeBuildPin {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Fixture)
    if([string]$Project.Loader -cne 'Forge'){return $null}
    $manifest=Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -notin @('PARTIAL','PASS')){throw 'FORGE_BUILD_PIN_MANIFEST_INVALID'}
    $matches=@($manifest.targets|Where-Object{$_.targetId -ceq [string]$Target.targetId -and $_.minecraftId -ceq [string]$Target.minecraftId})
    if($matches.Count -eq 0){return $null}
    if($matches.Count -ne 1){throw 'FORGE_BUILD_PIN_DUPLICATE_TARGET'}
    $pin=$matches[0]
    if([string]$pin.status -cne 'PinnedInputsVerified'){throw 'FORGE_BUILD_PIN_NOT_VERIFIED'}
    Test-MmtlForgePinValue -Pin $pin
    if([string]$Project.MinecraftVersion -cne [string]$pin.minecraftId -or [string]$Project.LoaderVersion -cne [string]$pin.forgeVersion -or [string]$Target.loaderVersion -cne [string]$pin.forgeVersion){throw 'FORGE_BUILD_PIN_IDENTITY_MISMATCH'}
    if([string]$pin.forgeGradleSpec -ceq '[6.0,6.2)'){
        if([string]$Target.targetId -cne [string]$pin.targetId -or [string]$pin.buildClasspathCatalogHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_GRADLE6_BUILD_CATALOG_PIN_MISSING'}
        $platform=Get-MmtlPlatformProvider
        $catalogFiles=Get-MmtlForgeGradle6CatalogFileNames -TargetId ([string]$pin.targetId) -OperatingSystem ([string]$platform.OS) -Architecture ([string]$platform.Arch)
        if([string]$catalogFiles.minecraftId -cne [string]$pin.minecraftId){throw 'FORGE_GRADLE6_CATALOG_TARGET_MISMATCH'}
        $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
        $classpathPath=Join-Path (Join-Path $repositoryRoot 'compatibility/forge-gradle6-build-classpath-artifacts') $catalogFiles.buildClasspath
        $classpathCatalog=Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $classpathPath
        if([string]$pin.buildClasspathCatalogHash -cne [string]$classpathCatalog.catalogHash){throw 'FORGE_GRADLE6_BUILD_CATALOG_PIN_MISMATCH'}
        if([string]$pin.targetInputCatalogHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_GRADLE6_TARGET_INPUT_CATALOG_PIN_MISSING'}
        $targetInputPath=Join-Path (Join-Path $repositoryRoot 'compatibility/forge-gradle6-target-inputs') $catalogFiles.targetInputs
        $targetInputCatalog=Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $targetInputPath
        if([string]$pin.targetInputCatalogHash -cne [string]$targetInputCatalog.catalogHash){throw 'FORGE_GRADLE6_TARGET_INPUT_CATALOG_PIN_MISMATCH'}
        if([string]$pin.runtimeArtifactCatalogHash -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_GRADLE6_RUNTIME_CATALOG_PIN_MISSING'}
        $runtimeArtifactPath=Join-Path (Join-Path $repositoryRoot 'compatibility/forge-gradle6-runtime-artifacts') $catalogFiles.runtimeArtifacts
        $runtimeArtifactCatalog=Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $runtimeArtifactPath
        if([string]$pin.runtimeArtifactCatalogHash -cne [string]$runtimeArtifactCatalog.catalogHash){throw 'FORGE_GRADLE6_RUNTIME_CATALOG_PIN_MISMATCH'}
    }
    if([string]$Fixture.type -cne 'OfficialArtifactFixture' -or [string]$Fixture.trust -cne 'TrustedOfficial' -or [string]$Fixture.source -cne [string]$pin.sourceArchiveUrl -or [string]$Fixture.commit -cne [string]$pin.sourceArchiveSha256 -or [string]$Fixture.officialChecksumAlgorithm -cne 'SHA256' -or [string]$Fixture.officialChecksum -cne [string]$pin.sourceArchiveSha256){throw 'FORGE_BUILD_PIN_SOURCE_IDENTITY_MISMATCH'}
    if($Fixture.PSObject.Properties['fixtureId'] -or $Fixture.PSObject.Properties['overlaySha256'] -or $Fixture.PSObject.Properties['overlayFiles']){Get-MmtlForgeFixtureOverlayHash -ProjectRoot ([string]$Project.Root) -Fixture $Fixture | Out-Null}
    $canonical=ConvertTo-Json -InputObject $pin -Depth 30 -Compress
    $pinHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
    $buildMode=if([string]$pin.forgeGradleSpec -ceq '[6.0,6.2)'){'ForgeGradle6PluginsDsl'}else{'ForgeGradleClasspath'}
    [pscustomobject]@{policy=$pin;pinHash=$pinHash;buildMode=$buildMode}
}

function Get-MmtlForgePluginBuildPin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,[Parameter(Mandatory)][string]$PluginCatalogPath,
        [Parameter(Mandatory)][string]$BuildArtifactCatalogPath,[Parameter(Mandatory)][string]$MojangSnapshotsPath,
        [Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Fixture
    )
    if([string]$Project.Loader -cne 'Forge' -or [string]$Target.targetId -cne 'Forge@1.8'){return $null}
    $manifest=Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if([int]$manifest.schemaVersion -ne 1 -or [string]$manifest.status -notin @('PARTIAL','PASS')){throw 'FORGE_PLUGIN_BUILD_PIN_MANIFEST_INVALID'}
    $matches=@($manifest.targets|Where-Object{$_.targetId -ceq [string]$Target.targetId -and $_.minecraftId -ceq [string]$Target.minecraftId})
    if($matches.Count -eq 0){return $null};if($matches.Count -ne 1){throw 'FORGE_PLUGIN_BUILD_PIN_DUPLICATE_TARGET'}
    $pin=$matches[0]
    if([string]$pin.status -cne 'PinnedInputsVerified'){throw 'FORGE_PLUGIN_BUILD_PIN_NOT_VERIFIED'}
    if([string]$pin.targetId -cne 'Forge@1.8' -or [string]$pin.minecraftId -cne '1.8' -or [string]$pin.forgeVersion -cne '1.8-11.14.4.1577' -or [string]$pin.pluginId -cne 'net.minecraftforge.gradle.forge' -or [string]$pin.pluginVersion -cne '2.0.2' -or [int]$pin.buildJavaMajor -ne 8){throw 'FORGE_PLUGIN_BUILD_PIN_IDENTITY_INVALID'}
    if([string]$Project.MinecraftVersion -cne [string]$pin.minecraftId -or [string]$Project.LoaderVersion -cne [string]$pin.forgeVersion -or [string]$Target.loaderVersion -cne [string]$pin.forgeVersion){throw 'FORGE_PLUGIN_BUILD_PIN_TARGET_MISMATCH'}
    foreach($field in @('sourceArchiveSha256','buildGradleSha256','gradleDistributionSha256','pluginArtifactCatalogHash','buildArtifactCatalogHash','mojangMetadataSnapshot')){if([string]$pin.$field -notmatch '^(?i:[a-f0-9]{64})$'){throw "FORGE_PLUGIN_BUILD_PIN_HASH_INVALID:$field"}}
    $sourceUri=$null;$gradleUri=$null
    if(-not [Uri]::TryCreate([string]$pin.sourceArchiveUrl,[UriKind]::Absolute,[ref]$sourceUri) -or $sourceUri.Scheme -cne 'https' -or $sourceUri.Host -cne 'maven.minecraftforge.net' -or $sourceUri.AbsolutePath -cne '/net/minecraftforge/forge/1.8-11.14.4.1577/forge-1.8-11.14.4.1577-mdk.zip' -or -not [Uri]::TryCreate([string]$pin.gradleDistributionUrl,[UriKind]::Absolute,[ref]$gradleUri) -or $gradleUri.Scheme -cne 'https' -or $gradleUri.Host -cne 'services.gradle.org' -or $gradleUri.AbsolutePath -cne '/distributions/gradle-2.7-bin.zip'){throw 'FORGE_PLUGIN_BUILD_PIN_SOURCE_URL_INVALID'}
    $pluginCatalog=Get-MmtlForgePluginArtifactCatalog -CatalogPath $PluginCatalogPath
    $buildCatalog=Get-MmtlForgeBuildArtifactCatalog -CatalogPath $BuildArtifactCatalogPath
    if([string]$pluginCatalog.catalogHash -cne [string]$pin.pluginArtifactCatalogHash -or [string]$buildCatalog.catalogHash -cne [string]$pin.buildArtifactCatalogHash -or [string]$pluginCatalog.catalog.pluginId -cne [string]$pin.pluginId -or [string]$pluginCatalog.catalog.pluginVersion -cne [string]$pin.pluginVersion -or [int]$pluginCatalog.catalog.javaMajor -ne [int]$pin.buildJavaMajor){throw 'FORGE_PLUGIN_BUILD_PIN_CATALOG_MISMATCH'}
    if([string]$pin.mcpVersions.url -cne [string]$pluginCatalog.catalog.mcpVersions.url -or [long]$pin.mcpVersions.bytes -ne [long]$pluginCatalog.catalog.mcpVersions.bytes -or [string]$pin.mcpVersions.sha256 -cne [string]$pluginCatalog.catalog.mcpVersions.sha256 -or [string]$pin.mcpVersions.mapping -cne [string]$pluginCatalog.catalog.mcpMapping){throw 'FORGE_PLUGIN_BUILD_PIN_MCP_MISMATCH'}
    $versionUri=$null;if([long]$pin.versionJson.bytes -ne 17224 -or [string]$pin.versionJson.sha256 -cne [string]$pin.mojangMetadataSnapshot -or [string]$pin.versionJson.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or -not [Uri]::TryCreate([string]$pin.versionJson.url,[UriKind]::Absolute,[ref]$versionUri) -or $versionUri.Scheme -cne 'https' -or $versionUri.Host -cne 'piston-meta.mojang.com' -or $versionUri.AbsolutePath -cne ('/v1/packages/'+[string]$pin.versionJson.sha1+'/1.8.json')){throw 'FORGE_PLUGIN_BUILD_PIN_VERSION_JSON_INVALID'}
    if([string]$pin.fernflowerArchive.url -cne 'https://files.minecraftforge.net/fernflower-fix-1.0.zip' -or [long]$pin.fernflowerArchive.bytes -ne 230445 -or [string]$pin.fernflowerArchive.sha256 -cne '7b18843dec340463a7e00c49325d7a6a8621a1de6ae64a4a282d629b0263d0ac' -or [string]$pin.fernflowerJar.entry -cne 'fernflower.jar' -or [long]$pin.fernflowerJar.bytes -ne 248683 -or [string]$pin.fernflowerJar.sha256 -cne 'f857d0a5dc440e9576a099ffe2dcf0f57f62ec6a9a90cdd7e8a27d4573e0504b'){throw 'FORGE_PLUGIN_BUILD_PIN_FERNFLOWER_INVALID'}
    $generationPath=Join-Path $PSScriptRoot '..\..\..\compatibility\forge-mdk-generations.json'
    $generationManifest=Get-Content -LiteralPath $generationPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $generation=@($generationManifest.targets|Where-Object{$_.targetId -ceq 'Forge@1.8' -and $_.status -ceq 'Available'})
    if($generation.Count -ne 1 -or [string]$generation[0].mdkUrl -cne [string]$pin.sourceArchiveUrl -or [string]$generation[0].archiveSha256 -cne [string]$pin.sourceArchiveSha256 -or [string]$generation[0].buildGradleSha256 -cne [string]$pin.buildGradleSha256 -or [string]$generation[0].forgeGradleSpec -cne [string]$pin.pluginVersion){throw 'FORGE_PLUGIN_BUILD_PIN_GENERATION_MISMATCH'}
    $snapshotFiles=@(Get-ChildItem -LiteralPath $MojangSnapshotsPath -File -ErrorAction Stop|Where-Object{try{([IO.File]::ReadAllText($_.FullName)|ConvertFrom-Json -ErrorAction Stop).id -ceq [string]$pin.minecraftId}catch{$false}})
    if($snapshotFiles.Count -ne 1 -or (Get-MmtlForgePinFileHash -Path $snapshotFiles[0].FullName) -cne [string]$pin.mojangMetadataSnapshot){throw 'FORGE_PLUGIN_BUILD_PIN_MOJANG_SNAPSHOT_MISMATCH'}
    $metadata=[IO.File]::ReadAllText($snapshotFiles[0].FullName)|ConvertFrom-Json -ErrorAction Stop
    foreach($name in @('client','server')){if([string]$pin.$name.url -cne [string]$metadata.downloads.$name.url -or [string]$pin.$name.sha1 -cne [string]$metadata.downloads.$name.sha1 -or [long]$pin.$name.sizeBytes -ne [long]$metadata.downloads.$name.size){throw "FORGE_PLUGIN_BUILD_PIN_MOJANG_DOWNLOAD_MISMATCH:$name"}}
    if([string]$Fixture.type -cne 'OfficialArtifactFixture' -or [string]$Fixture.trust -cne 'TrustedOfficial' -or [string]$Fixture.source -cne [string]$pin.sourceArchiveUrl -or [string]$Fixture.commit -cne [string]$pin.sourceArchiveSha256 -or [string]$Fixture.officialChecksumAlgorithm -cne 'SHA256' -or [string]$Fixture.officialChecksum -cne [string]$pin.sourceArchiveSha256){throw 'FORGE_PLUGIN_BUILD_PIN_FIXTURE_MISMATCH'}
    if($Fixture.PSObject.Properties['fixtureId'] -or $Fixture.PSObject.Properties['overlaySha256'] -or $Fixture.PSObject.Properties['overlayFiles']){Get-MmtlForgeFixtureOverlayHash -ProjectRoot ([string]$Project.Root) -Fixture $Fixture | Out-Null}
    $canonical=ConvertTo-Json -InputObject $pin -Depth 30 -Compress
    $pinHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
    [pscustomobject]@{policy=$pin;pinHash=$pinHash;buildMode='PluginsDsl'}
}

function Invoke-MmtlForgeHttpsDownload {
    param([Parameter(Mandatory)][Uri]$Uri,[Parameter(Mandatory)][string]$DestinationPath,[ValidateRange(1,600)][int]$TimeoutSeconds=120,[string[]]$AllowedHosts=@('maven.minecraftforge.net'))
    $current=$Uri
    for($redirect=0;$redirect -le 5;$redirect++){
        if($current.Scheme -cne 'https' -or $current.Host -notin $AllowedHosts -or $current.UserInfo){throw 'FORGE_PIN_DOWNLOAD_REDIRECT_REJECTED'}
        $request=[Net.HttpWebRequest]::Create($current);$request.Method='GET';$request.AllowAutoRedirect=$false;$request.Timeout=$TimeoutSeconds*1000;$request.ReadWriteTimeout=$TimeoutSeconds*1000
        $response=$null
        try{$response=$request.GetResponse()}catch [Net.WebException]{$response=$_.Exception.Response;if(-not $response){throw}}
        if([int]$response.StatusCode -in @(301,302,303,307,308)){
            $location=[string]$response.Headers['Location'];$response.Close()
            if(-not $location -or $redirect -eq 5){throw 'FORGE_PIN_DOWNLOAD_REDIRECT_LIMIT'}
            $current=[Uri]::new($current,$location);continue
        }
        if([int]$response.StatusCode -ne 200){$status=[int]$response.StatusCode;$response.Close();throw "FORGE_PIN_DOWNLOAD_HTTP_STATUS:$status"}
        try{
            $responseStream=$response.GetResponseStream();$output=[IO.FileStream]::new($DestinationPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$responseStream.CopyTo($output)}finally{$output.Dispose();$responseStream.Dispose()}
        }finally{$response.Close()}
        return
    }
    throw 'FORGE_PIN_DOWNLOAD_REDIRECT_LIMIT'
}

function Get-MmtlForgePluginArtifactCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if([int]$catalog.schemaVersion -ne 1 -or [string]$catalog.targetId -cne 'Forge@1.8' -or [string]$catalog.pluginId -cne 'net.minecraftforge.gradle.forge' -or [string]$catalog.pluginVersion -cne '2.0.2' -or [string]$catalog.implementationCoordinate -cne 'gradle.plugin.net.minecraftforge.gradle:ForgeGradle:2.0.2' -or [string]$catalog.sourceRepository -cne 'https://plugins.gradle.org/m2' -or [string]$catalog.artifactStatus -cne 'HashesVerified' -or [string]$catalog.targetBuildStatus -notin @('PendingRunnerValidation','BuildVerified')){throw 'FORGE_PLUGIN_ARTIFACT_CATALOG_IDENTITY_INVALID'}
    $artifacts=@($catalog.artifacts)
    if($artifacts.Count -lt 3){throw 'FORGE_PLUGIN_ARTIFACT_CATALOG_INCOMPLETE'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $artifacts){
        $name=[string]$artifact.file;$extension=[string]$artifact.extension
        if([string]$artifact.group -notmatch '^[A-Za-z0-9_.-]+$' -or [string]$artifact.artifact -notmatch '^[A-Za-z0-9_.-]+$' -or [string]$artifact.version -notmatch '^[A-Za-z0-9_.+-]+$' -or $name -notmatch '^[A-Za-z0-9_.+-]+\.(jar|pom)$' -or $extension -notin @('jar','pom') -or -not $name.EndsWith('.'+$extension,[StringComparison]::Ordinal) -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_PLUGIN_ARTIFACT_ENTRY_INVALID'}
        $relativeUrl=([string]$artifact.group).Replace('.','/')+'/'+[string]$artifact.artifact+'/'+[string]$artifact.version+'/'+$name
        $expectedUrl='https://plugins.gradle.org/m2/'+$relativeUrl
        if([string]$artifact.url -cne $expectedUrl){throw 'FORGE_PLUGIN_ARTIFACT_URL_COORDINATE_MISMATCH'}
        if(-not $seen.Add($relativeUrl)){throw 'FORGE_PLUGIN_ARTIFACT_DUPLICATE'}
    }
    $core=[pscustomobject][ordered]@{
        schemaVersion=[int]$catalog.schemaVersion;targetId=[string]$catalog.targetId;pluginId=[string]$catalog.pluginId;pluginVersion=[string]$catalog.pluginVersion
        implementationCoordinate=[string]$catalog.implementationCoordinate;sourceRepository=[string]$catalog.sourceRepository;resolver=[string]$catalog.resolver;javaMajor=[int]$catalog.javaMajor
        artifactStatus=[string]$catalog.artifactStatus;targetBuildStatus=[string]$catalog.targetBuildStatus
        mcpVersions=[pscustomobject][ordered]@{url=[string]$catalog.mcpVersions.url;bytes=[long]$catalog.mcpVersions.bytes;sha256=[string]$catalog.mcpVersions.sha256}
        mcpMapping=[string]$catalog.mcpMapping;forgeVersionMetadataFallback=[string]$catalog.forgeVersionMetadataFallback;artifacts=$artifacts
    }
    if([string]$catalog.mcpVersions.url -cne 'https://maven.minecraftforge.net/de/oceanlabs/mcp/versions.json' -or [long]$catalog.mcpVersions.bytes -le 0 -or [string]$catalog.mcpVersions.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$catalog.mcpMapping -cne 'snapshot_20141130' -or [string]$catalog.forgeVersionMetadataFallback -cne 'ExactPinnedTargetOnly'){throw 'FORGE_PLUGIN_MCP_METADATA_PIN_INVALID'}
    $actualHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 20 -Compress)))).ToLowerInvariant()
    if($actualHash -cne [string]$catalog.catalogHash){throw 'FORGE_PLUGIN_ARTIFACT_CATALOG_HASH_MISMATCH'}
    $marker=@($artifacts|Where-Object{$_.group -ceq 'net.minecraftforge.gradle.forge' -and $_.artifact -ceq 'net.minecraftforge.gradle.forge.gradle.plugin' -and $_.version -ceq '2.0.2' -and $_.extension -ceq 'pom'})
    $implementationPom=@($artifacts|Where-Object{$_.group -ceq 'gradle.plugin.net.minecraftforge.gradle' -and $_.artifact -ceq 'ForgeGradle' -and $_.version -ceq '2.0.2' -and $_.extension -ceq 'pom'})
    $implementationJar=@($artifacts|Where-Object{$_.group -ceq 'gradle.plugin.net.minecraftforge.gradle' -and $_.artifact -ceq 'ForgeGradle' -and $_.version -ceq '2.0.2' -and $_.extension -ceq 'jar'})
    if($marker.Count -ne 1 -or $implementationPom.Count -ne 1 -or $implementationJar.Count -ne 1){throw 'FORGE_PLUGIN_ARTIFACT_IMPLEMENTATION_MISSING'}
    [pscustomobject]@{catalog=$catalog;catalogHash=$actualHash;artifacts=$artifacts}
}

function Get-MmtlForgePluginArtifactMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $resolvedCatalog=Get-MmtlForgePluginArtifactCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$artifactCache=Join-Path $root 'artifact-cache';$mirrorRoot=Join-Path $root 'maven-mirror'
    [void][IO.Directory]::CreateDirectory($artifactCache);[void][IO.Directory]::CreateDirectory($mirrorRoot)
    foreach($artifact in $resolvedCatalog.artifacts){
        $hash=[string]$artifact.sha256;$cachedPath=Join-Path $artifactCache $hash
        if(Test-Path -LiteralPath $cachedPath -PathType Leaf){
            $cacheItem=Get-Item -LiteralPath $cachedPath -Force
            if(($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-MmtlForgePinFileHash -Path $cachedPath) -cne $hash){throw 'FORGE_PLUGIN_ARTIFACT_CACHE_HASH_MISMATCH'}
        }else{
            $temporary=Join-Path $artifactCache ('.download-'+[guid]::NewGuid().ToString('N')+'.tmp')
            try{
                Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('plugins.gradle.org','plugins-artifacts.gradle.org','repo.maven.apache.org')
                if((Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash){throw 'FORGE_PLUGIN_ARTIFACT_DOWNLOAD_HASH_MISMATCH'}
                [IO.File]::Move($temporary,$cachedPath)
            }finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}
        }
        $groupPath=([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar)
        $moduleRelative=Join-Path (Join-Path $groupPath ([string]$artifact.artifact)) ([string]$artifact.version)
        $destinationDirectory=[IO.Path]::GetFullPath((Join-Path $mirrorRoot $moduleRelative))
        if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $destinationDirectory)){throw 'FORGE_PLUGIN_MIRROR_PATH_ESCAPE'}
        [void][IO.Directory]::CreateDirectory($destinationDirectory)
        $destination=[IO.Path]::GetFullPath((Join-Path $destinationDirectory ([string]$artifact.file)))
        if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $destination)){throw 'FORGE_PLUGIN_MIRROR_PATH_ESCAPE'}
        if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_PLUGIN_MIRROR_HASH_CONFLICT'}}else{[IO.File]::Copy($cachedPath,$destination,$false)}
    }
    [pscustomobject]@{mirrorRoot=$mirrorRoot;catalogHash=$resolvedCatalog.catalogHash;artifactCount=$resolvedCatalog.artifacts.Count}
}

function Get-MmtlForgePluginMcpVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $resolved=Get-MmtlForgePluginArtifactCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);[void][IO.Directory]::CreateDirectory($root)
    $destination=Join-Path $root ([string]$resolved.catalog.mcpVersions.sha256+'.json')
    if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or [long](Get-Item -LiteralPath $destination).Length -ne [long]$resolved.catalog.mcpVersions.bytes -or (Get-MmtlForgePinFileHash -Path $destination) -cne [string]$resolved.catalog.mcpVersions.sha256){throw 'FORGE_PLUGIN_MCP_VERSIONS_CACHE_INVALID'}}
    else{$temporary=Join-Path $root ('.mcp-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$resolved.catalog.mcpVersions.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$resolved.catalog.mcpVersions.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne [string]$resolved.catalog.mcpVersions.sha256){throw 'FORGE_PLUGIN_MCP_VERSIONS_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$destination)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
    [pscustomobject]@{path=$destination;bytes=[long]$resolved.catalog.mcpVersions.bytes;sha256=[string]$resolved.catalog.mcpVersions.sha256}
}

function Get-MmtlForgePinnedFernflower {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pin,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $archivePin=$Pin.fernflowerArchive;$jarPin=$Pin.fernflowerJar;$uri=$null
    if([string]$archivePin.url -cne 'https://files.minecraftforge.net/fernflower-fix-1.0.zip' -or [long]$archivePin.bytes -ne 230445 -or [string]$archivePin.sha256 -cne '7b18843dec340463a7e00c49325d7a6a8621a1de6ae64a4a282d629b0263d0ac' -or [string]$jarPin.entry -cne 'fernflower.jar' -or [long]$jarPin.bytes -ne 248683 -or [string]$jarPin.sha256 -cne 'f857d0a5dc440e9576a099ffe2dcf0f57f62ec6a9a90cdd7e8a27d4573e0504b' -or -not [Uri]::TryCreate([string]$archivePin.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'files.minecraftforge.net' -or $uri.AbsolutePath -cne '/fernflower-fix-1.0.zip'){throw 'FORGE_FERNFLOWER_PIN_INVALID'}
    $root=[IO.Path]::GetFullPath($CacheRoot);[void][IO.Directory]::CreateDirectory($root)
    $archivePath=Join-Path $root ('fernflower-'+[string]$archivePin.sha256+'.zip')
    if(Test-Path -LiteralPath $archivePath -PathType Leaf){if((Get-Item -LiteralPath $archivePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or [long](Get-Item -LiteralPath $archivePath).Length -ne [long]$archivePin.bytes -or (Get-MmtlForgePinFileHash -Path $archivePath) -cne [string]$archivePin.sha256){throw 'FORGE_FERNFLOWER_ARCHIVE_CACHE_INVALID'}}
    else{$temporary=Join-Path $root ('.fernflower-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri $uri -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('files.minecraftforge.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$archivePin.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne [string]$archivePin.sha256){throw 'FORGE_FERNFLOWER_ARCHIVE_HASH_MISMATCH'};[IO.File]::Move($temporary,$archivePath)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
    $jarPath=Join-Path $root 'fernflower-fixed.jar'
    if(Test-Path -LiteralPath $jarPath -PathType Leaf){if((Get-Item -LiteralPath $jarPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or [long](Get-Item -LiteralPath $jarPath).Length -ne [long]$jarPin.bytes -or (Get-MmtlForgePinFileHash -Path $jarPath) -cne [string]$jarPin.sha256){throw 'FORGE_FERNFLOWER_JAR_CACHE_INVALID'}}
    else{$temporaryJar=Join-Path $root ('.fernflower-jar-'+[guid]::NewGuid().ToString('N')+'.tmp');$zip=[IO.Compression.ZipFile]::OpenRead($archivePath);try{$entries=@($zip.Entries|Where-Object{$_.FullName -ceq [string]$jarPin.entry});if($entries.Count -ne 1 -or $entries[0].Length -ne [long]$jarPin.bytes -or (($entries[0].ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'FORGE_FERNFLOWER_ARCHIVE_ENTRY_INVALID'};$input=$entries[0].Open();$output=[IO.FileStream]::new($temporaryJar,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$input.CopyTo($output)}finally{$output.Dispose();$input.Dispose()};if([long](Get-Item -LiteralPath $temporaryJar -Force).Length -ne [long]$jarPin.bytes -or (Get-MmtlForgePinFileHash -Path $temporaryJar) -cne [string]$jarPin.sha256){throw 'FORGE_FERNFLOWER_JAR_HASH_MISMATCH'};[IO.File]::Move($temporaryJar,$jarPath)}finally{$zip.Dispose();if(Test-Path -LiteralPath $temporaryJar -PathType Leaf){[IO.File]::Delete($temporaryJar)}}}
    [pscustomobject]@{archivePath=$archivePath;archiveBytes=[long]$archivePin.bytes;archiveSha256=[string]$archivePin.sha256;jarPath=$jarPath;jarBytes=[long]$jarPin.bytes;jarSha256=[string]$jarPin.sha256}
}

function Initialize-MmtlForgePluginDslProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionRoot,[Parameter(Mandatory)]$Pin,[Parameter(Mandatory)][string]$ArtifactCatalogPath,[Parameter(Mandatory)][string]$MirrorRoot,[Parameter(Mandatory)][string]$BuildArtifactCatalogPath,[Parameter(Mandatory)][string]$BuildMirrorRoot,[Parameter(Mandatory)][string]$GradleHome,[Parameter(Mandatory)][string]$McpVersionsPath,[Parameter(Mandatory)][string]$FernflowerJarPath)
    $resolvedCatalog=Get-MmtlForgePluginArtifactCatalog -CatalogPath $ArtifactCatalogPath
    if([string]$Pin.targetId -cne 'Forge@1.8' -or [string]$Pin.minecraftId -cne '1.8' -or [string]$Pin.forgeVersion -cne '1.8-11.14.4.1577' -or [string]$Pin.pluginVersion -cne [string]$resolvedCatalog.catalog.pluginVersion){throw 'FORGE_PLUGIN_DSL_PIN_IDENTITY_MISMATCH'}
    $resolvedBuildCatalog=Get-MmtlForgeBuildArtifactCatalog -CatalogPath $BuildArtifactCatalogPath
    if(-not $Pin.PSObject.Properties['pluginArtifactCatalogHash'] -or [string]$Pin.pluginArtifactCatalogHash -cne [string]$resolvedCatalog.catalogHash -or -not $Pin.PSObject.Properties['buildArtifactCatalogHash'] -or [string]$Pin.buildArtifactCatalogHash -cne [string]$resolvedBuildCatalog.catalogHash){throw 'FORGE_PLUGIN_DSL_PIN_CATALOG_MISMATCH'}
    if(-not(Test-Path -LiteralPath $McpVersionsPath -PathType Leaf)){throw 'FORGE_PLUGIN_MCP_VERSIONS_FILE_MISSING'}
    $root=[IO.Path]::GetFullPath($SessionRoot)
    if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'FORGE_SESSION_ROOT_MISSING'}
    $secureRoot=Join-Path $root '.mmtl-forge-secure'
    [void][IO.Directory]::CreateDirectory($secureRoot)
    $mcpItem=Get-Item -LiteralPath $McpVersionsPath -Force
    if(($mcpItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$mcpItem.Length -ne [long]$resolvedCatalog.catalog.mcpVersions.bytes -or (Get-MmtlForgePinFileHash -Path $McpVersionsPath) -cne [string]$resolvedCatalog.catalog.mcpVersions.sha256){throw 'FORGE_PLUGIN_MCP_VERSIONS_HASH_MISMATCH'}
    $fernflowerItem=Get-Item -LiteralPath $FernflowerJarPath -Force;if(($fernflowerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$fernflowerItem.Length -ne [long]$Pin.fernflowerJar.bytes -or (Get-MmtlForgePinFileHash -Path $FernflowerJarPath) -cne [string]$Pin.fernflowerJar.sha256){throw 'FORGE_FERNFLOWER_JAR_HASH_MISMATCH'}
    try{$mcpJson=[IO.File]::ReadAllText([IO.Path]::GetFullPath($McpVersionsPath))|ConvertFrom-Json -ErrorAction Stop}catch{throw 'FORGE_PLUGIN_MCP_VERSIONS_JSON_INVALID'}
    $mappingDate=[regex]::Match([string]$resolvedCatalog.catalog.mcpMapping,'^snapshot_(\d{8})$')
    if(-not $mappingDate.Success -or @($mcpJson.'1.8'.snapshot|ForEach-Object{[string]$_}) -cnotcontains $mappingDate.Groups[1].Value){throw 'FORGE_PLUGIN_MCP_MAPPING_NOT_PUBLISHED'}
    $gradleHomePath=[IO.Path]::GetFullPath($GradleHome)
    [void][IO.Directory]::CreateDirectory($gradleHomePath)
    $minecraftCache=Join-Path $gradleHomePath 'caches/minecraft'
    [void][IO.Directory]::CreateDirectory($minecraftCache)
    foreach($cachePath in @($gradleHomePath,(Join-Path $gradleHomePath 'caches'),$minecraftCache)){
        $cacheItem=Get-Item -LiteralPath $cachePath -Force
        if($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FORGE_PLUGIN_GRADLE_HOME_REPARSE_POINT'}
    }
    $mcpCachePath=Join-Path $minecraftCache 'McpMappings.json'
    [IO.File]::Copy([IO.Path]::GetFullPath($McpVersionsPath),$mcpCachePath,$true)
    $forgeVersionCachePath=Join-Path $minecraftCache 'ForgeVersion.json'
    [IO.File]::WriteAllText($forgeVersionCachePath,'{"promos":{},"number":{"1577":{"version":"11.14.4.1577","mcversion":"1.8"}}}',[Text.UTF8Encoding]::new($false))
    [IO.File]::Copy([IO.Path]::GetFullPath($FernflowerJarPath),(Join-Path $minecraftCache 'fernflower-fixed.jar'),$true)
    $initScriptPath=Join-Path $secureRoot 'mojang.init.gradle'
    $fernflowerSourceB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($FernflowerJarPath)))
    $initScript=@"
gradle.projectsEvaluated {
  def p = gradle.rootProject
  p.tasks.getByName('getVersionJson').setUrl('$([System.Security.SecurityElement]::Escape([string]$Pin.versionJson.url))')
  p.tasks.getByName('downloadClient').setUrl('$([System.Security.SecurityElement]::Escape([string]$Pin.client.url))')
  p.tasks.getByName('downloadServer').setUrl('$([System.Security.SecurityElement]::Escape([string]$Pin.server.url))')
  def fernflowerSourcePath = new String(java.util.Base64.decoder.decode('$fernflowerSourceB64'), 'UTF-8')
  def fernflowerExpectedHash = '$([string]$Pin.fernflowerJar.sha256)'
  def fernflowerTask = p.tasks.getByName('getFernFlower')
  fernflowerTask.outputs.upToDateWhen { false }
  fernflowerTask.doFirst {
    def source = new File(fernflowerSourcePath)
    if (!source.isFile()) { throw new GradleException('MMTL_FORGE_FERNFLOWER_SOURCE_MISSING') }
    def hashFile = { java.io.File file -> java.security.MessageDigest.getInstance('SHA-256').digest(file.bytes).collect { String.format('%02x', it & 0xff) }.join() }
    if (hashFile(source) != fernflowerExpectedHash) { throw new GradleException('MMTL_FORGE_FERNFLOWER_SOURCE_HASH_MISMATCH') }
    def target = new File(gradle.gradleUserHomeDir, 'caches/minecraft/fernflower-fixed.jar')
    target.parentFile.mkdirs()
    java.nio.file.Files.copy(source.toPath(), target.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
    if (hashFile(target) != fernflowerExpectedHash) { throw new GradleException('MMTL_FORGE_FERNFLOWER_SEED_HASH_MISMATCH') }
    println('MMTL_FORGE_PINNED_FERNFLOWER_SEEDED')
  }
  println('MMTL_FORGE_PINNED_MOJANG_URLS_SET')
}
"@
    [IO.File]::WriteAllText($initScriptPath,$initScript.Trim()+"`n",[Text.UTF8Encoding]::new($false))
    $buildPath=Join-Path $root 'build.gradle';if(-not(Test-Path -LiteralPath $buildPath -PathType Leaf)){throw 'FORGE_BUILD_GRADLE_MISSING'}
    $sourceText=[IO.File]::ReadAllText($buildPath);$sourceHash=Get-MmtlForgePinFileHash -Path $buildPath
    if($sourceHash -cne [string]$Pin.buildGradleSha256){throw 'FORGE_BUILD_GRADLE_HASH_MISMATCH'}
    $wrapperPath=Join-Path $root 'gradle/wrapper/gradle-wrapper.properties'
    if(-not(Test-Path -LiteralPath $wrapperPath -PathType Leaf)){throw 'FORGE_GRADLE_WRAPPER_PROPERTIES_MISSING'}
    $distributionLine=Get-Content -LiteralPath $wrapperPath|Where-Object{$_ -match '^distributionUrl='}|Select-Object -First 1
    if(-not $distributionLine -or ([string]$distributionLine.Substring('distributionUrl='.Length)).Replace('\:',':') -cne [string]$Pin.gradleDistributionUrl){throw 'FORGE_GRADLE_WRAPPER_DISTRIBUTION_MISMATCH'}
    $declarations=Get-MmtlForgeBuildScriptDeclarations -BuildScriptText $sourceText
    if(@($declarations.plugins).Count -ne 1 -or @($declarations.classpath).Count -ne 0 -or [string]$declarations.plugins[0].coordinate -cne [string]$resolvedCatalog.catalog.pluginId -or [string]$declarations.plugins[0].version -cne [string]$resolvedCatalog.catalog.pluginVersion){throw 'FORGE_BUILD_GRADLE_PLUGIN_SPEC_MISMATCH'}
    $escapedId=[regex]::Escape([string]$resolvedCatalog.catalog.pluginId);$escapedVersion=[regex]::Escape([string]$resolvedCatalog.catalog.pluginVersion)
    $pluginBlock=[regex]::Matches($sourceText,'(?m)^[\t ]*plugins\s*\{\s*id\s+["'']'+$escapedId+'["'']\s+version\s+["'']'+$escapedVersion+'["'']\s*\}[\t ]*(?:\r?\n|$)')
    if($pluginBlock.Count -ne 1){throw 'FORGE_PLUGIN_DSL_PATCH_SHAPE_UNEXPECTED'}
    $mirror=[IO.Path]::GetFullPath($MirrorRoot)
    if(-not(Test-Path -LiteralPath $mirror -PathType Container)){throw 'FORGE_PLUGIN_MIRROR_MISSING'}
    $sessionMirror=Join-Path $secureRoot 'plugin-repository';[void][IO.Directory]::CreateDirectory($sessionMirror)
    foreach($artifact in $resolvedCatalog.artifacts){
        $relative=Join-Path (Join-Path (([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar)) ([string]$artifact.artifact)) ([string]$artifact.version)
        $sourceArtifact=[IO.Path]::GetFullPath((Join-Path (Join-Path $mirror $relative) ([string]$artifact.file)))
        if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirror -Target $sourceArtifact) -or -not(Test-Path -LiteralPath $sourceArtifact -PathType Leaf) -or (Get-MmtlForgePinFileHash -Path $sourceArtifact) -cne [string]$artifact.sha256){throw 'FORGE_PLUGIN_MIRROR_ARTIFACT_INVALID'}
        $targetDirectory=Join-Path $sessionMirror $relative;[void][IO.Directory]::CreateDirectory($targetDirectory)
        $targetArtifact=Join-Path $targetDirectory ([string]$artifact.file)
        if(Test-Path -LiteralPath $targetArtifact -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $targetArtifact) -cne [string]$artifact.sha256){throw 'FORGE_PLUGIN_SESSION_MIRROR_CONFLICT'}}else{[IO.File]::Copy($sourceArtifact,$targetArtifact,$false)}
    }
    $buildMirror=[IO.Path]::GetFullPath($BuildMirrorRoot)
    if(-not(Test-Path -LiteralPath $buildMirror -PathType Container)){throw 'FORGE_BUILD_ARTIFACT_MIRROR_MISSING'}
    $sessionBuildMirror=Join-Path $secureRoot 'build-repository';[void][IO.Directory]::CreateDirectory($sessionBuildMirror)
    foreach($artifact in $resolvedBuildCatalog.artifacts){
        $relative=Join-Path (Join-Path (([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar)) ([string]$artifact.artifact)) ([string]$artifact.version)
        $sourceArtifact=[IO.Path]::GetFullPath((Join-Path (Join-Path $buildMirror $relative) ([string]$artifact.file)))
        if(-not(Test-MmtlPlatformPathInsideRoot -Root $buildMirror -Target $sourceArtifact) -or -not(Test-Path -LiteralPath $sourceArtifact -PathType Leaf) -or [long](Get-Item -LiteralPath $sourceArtifact).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $sourceArtifact) -cne [string]$artifact.sha256){throw 'FORGE_BUILD_ARTIFACT_MIRROR_INVALID'}
        $targetDirectory=[IO.Path]::GetFullPath((Join-Path $sessionBuildMirror $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $sessionBuildMirror -Target $targetDirectory)){throw 'FORGE_BUILD_ARTIFACT_SESSION_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($targetDirectory)
        $targetArtifact=[IO.Path]::GetFullPath((Join-Path $targetDirectory ([string]$artifact.file)));if(-not(Test-MmtlPlatformPathInsideRoot -Root $sessionBuildMirror -Target $targetArtifact)){throw 'FORGE_BUILD_ARTIFACT_SESSION_PATH_ESCAPE'}
        if(Test-Path -LiteralPath $targetArtifact -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $targetArtifact) -cne [string]$artifact.sha256){throw 'FORGE_BUILD_ARTIFACT_SESSION_CONFLICT'}}else{[IO.File]::Copy($sourceArtifact,$targetArtifact,$false)}
    }
    $separator=if($sourceText.Contains("`r`n")){"`r`n"}else{"`n"}
    $replacement=@"
buildscript {
    repositories { maven { url uri('.mmtl-forge-secure/plugin-repository') } }
    dependencies { classpath '$([string]$resolvedCatalog.catalog.implementationCoordinate)' }
}
apply plugin: '$([string]$resolvedCatalog.catalog.pluginId)'
repositories { maven { url uri('.mmtl-forge-secure/build-repository') } }
"@
    $patched=$sourceText.Remove($pluginBlock[0].Index,$pluginBlock[0].Length).Insert($pluginBlock[0].Index,$replacement.Trim()+$separator)
    [IO.File]::WriteAllText($buildPath,$patched,[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{buildScriptPath=$buildPath;buildScriptSha256Before=$sourceHash;buildScriptSha256After=(Get-MmtlForgePinFileHash -Path $buildPath);pluginRepositoryPath=$sessionMirror;buildRepositoryPath=$sessionBuildMirror;initScriptPath=$initScriptPath;requiresOffline=$true;preparationTasks=@('setupDecompWorkspace');additionalArguments=@('-x','getAssets');pluginId=[string]$resolvedCatalog.catalog.pluginId;pluginVersion=[string]$resolvedCatalog.catalog.pluginVersion;catalogHash=[string]$resolvedCatalog.catalogHash;artifactCount=$resolvedCatalog.artifacts.Count;buildCatalogHash=[string]$resolvedBuildCatalog.catalogHash;buildArtifactCount=$resolvedBuildCatalog.artifacts.Count;fernflowerArchiveSha256=[string]$Pin.fernflowerArchive.sha256;fernflowerJarSha256=[string]$Pin.fernflowerJar.sha256;gradleHome=$gradleHomePath;mojangDirectory=(Join-Path $secureRoot 'mojang');minecraftVersion=[string]$Pin.minecraftId;client=$Pin.client;server=$Pin.server;mcpMapping=[string]$resolvedCatalog.catalog.mcpMapping}
}

function Get-MmtlForgeGradle3TargetInputCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if([int]$catalog.schemaVersion -ne 1 -or [string]$catalog.artifactStatus -cne 'HashesVerified'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
    $artifacts=@($catalog.artifacts)
    if([string]$catalog.targetId -ceq 'Forge@1.12.2'){
        if([string]$catalog.forgeVersion -cne '1.12.2-14.23.5.2860'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev3='net.minecraftforge:forge:1.12.2-14.23.5.2860:forge-1.12.2-14.23.5.2860-userdev3.jar:2146657:9040f8f95d7296eb2f4ae9dd638021b6af43cedfa1ca4d30a2beae5491e9f3e2'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.12.2-20200226.224830:mcp_config-1.12.2-20200226.224830.zip:421086:e2ddd3a7bb65618ad0de1d8fc0334527e5c346180300d94bfc7d3727b1976b42'
            mcpSnapshot='de.oceanlabs.mcp:mcp_snapshot:20171003-1.12:mcp_snapshot-20171003-1.12.zip:371642:b346508f8d25e7b2bcf7484b3b1d2e549be1b8e1ba477665153ea64fd138f50c'
            forgeSources='net.minecraftforge:forge:1.12.2-14.23.5.2860:forge-1.12.2-14.23.5.2860-sources.jar:1873505:52c1f22b56a936d62108d6c0d752c8ccd9cea90bdd190f3e344d6b0c698a4f57'
            forgeUniversal='net.minecraftforge:forge:1.12.2-14.23.5.2860:forge-1.12.2-14.23.5.2860-universal.jar:4466148:cd3fbf85d7ca744507fd6a37a41b90122d43e616a4f8962332b1b658655e8a64'
            binarypatcher='net.minecraftforge:binarypatcher:1.1.1:binarypatcher-1.1.1-fatjar.jar:3814811:0b035c849666cdd839b2c44deebf488736bdb19c1d588e8adf0bc9e15a5541cd'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        if([string]$catalog.mcpConfig.coordinate -cne 'de.oceanlabs.mcp:mcp_config:1.12.2-20200226.224830@zip' -or [string]$catalog.userdev3.mcpCoordinate -cne [string]$catalog.mcpConfig.coordinate -or [long]$catalog.mcpConfig.mappingsBytes -ne 1073337 -or [string]$catalog.mcpConfig.mappingsSha256 -cne '57527913c5bea02e110aa0d1fa929da6f995f1a7836b0e46d891014b94779f4e' -or @($catalog.userdev3.libraries).Count -ne 22 -or @($catalog.userdev3.processors).Count -ne 2 -or [string]$catalog.mojangVersion.sha256 -cne '56dac2e1caa872d7e37a7b5523056cd812dca94f912ad2bd652817bee60edca4'){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.13.2'){
        if([string]$catalog.forgeVersion -cne '1.13.2-25.0.223' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expectedKinds=@('userdev','mcpConfig','forgeSources','forgeUniversal','launcher','binarypatcher')
        if($artifacts.Count -ne $expectedKinds.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expectedKinds){if(@($artifacts|Where-Object kind -CEQ $kind).Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'}}
        foreach($artifact in $artifacts){
            $file=[string]$artifact.file;$group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version
            if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or $file -notmatch '^[A-Za-z0-9_.+-]+\.(jar|zip)$'){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_INVALID'}
            $uri=$null;if(-not[Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne ('/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}
        }
        $forgeVersion=[string]$catalog.forgeVersion
        foreach($kind in @('userdev','forgeSources','forgeUniversal','launcher')){if([string](@($artifacts|Where-Object kind -CEQ $kind)[0].version) -cne $forgeVersion){throw 'FORGE_GRADLE3_TARGET_INPUT_FORGE_COORDINATE_MISMATCH'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -notmatch '^de\.oceanlabs\.mcp:mcp_config:1\.13\.2-[A-Za-z0-9.]+@zip$' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.configBytes -le 0 -or [long]$catalog.mcpConfig.mappingsBytes -le 0 -or [string]$catalog.mcpConfig.configSha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$catalog.mcpConfig.mappingsSha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -le 0 -or [string]$userdev.configSha256 -notmatch '^(?i:[a-f0-9]{64})$' -or @($userdev.libraries).Count -lt 1 -or @($userdev.processors).Count -lt 1 -or @($userdev.processors) -notcontains 'net.minecraftforge:binarypatcher:1.1.1:fatjar'){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        $mcpArtifact=@($artifacts|Where-Object kind -CEQ 'mcpConfig')[0]
        if([string]$mcpArtifact.group -cne 'de.oceanlabs.mcp' -or [string]$mcpArtifact.artifact -cne 'mcp_config' -or [string]$mcpArtifact.version -cne ($mcp -replace '^de\.oceanlabs\.mcp:mcp_config:','' -replace '@zip$','')){throw 'FORGE_GRADLE3_TARGET_INPUT_MCP_COORDINATE_MISMATCH'}
        foreach($library in @($userdev.libraries)){if([string]$library -notmatch '^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.+-]+(:[A-Za-z0-9_.+-]+)?$'){throw 'FORGE_GRADLE3_TARGET_INPUT_LIBRARY_COORDINATE_INVALID'}}
        $mojang=$catalog.mojangVersion
        if([string]$mojang.url -notmatch '^https://piston-meta\.mojang\.com/v1/packages/[a-f0-9]{40}/1\.13\.2\.json$' -or [string]$mojang.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [long]$mojang.bytes -le 0 -or [string]$mojang.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not([string]$mojang.url).Contains('/'+[string]$mojang.sha1+'/')){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.14.2'){
        if([string]$catalog.forgeVersion -cne '1.14.2-26.0.63' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.14.2-26.0.63:forge-1.14.2-26.0.63-userdev.jar:2796274:b9f1327e4255ed9d897ed391e8d29d20768d5d94d77c3333e247cd01df371379'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.14.2-20190603.175704:mcp_config-1.14.2-20190603.175704.zip:610488:2e38fa087fa6675a26d2e1967404e5578ae0f7fc328f5d0dc2f4d81be5fe5895'
            forgeSources='net.minecraftforge:forge:1.14.2-26.0.63:forge-1.14.2-26.0.63-sources.jar:1429843:a084d0124c84953de73e522b46e861b049791cc44cc1322917b51085717b0d20'
            forgeUniversal='net.minecraftforge:forge:1.14.2-26.0.63:forge-1.14.2-26.0.63-universal.jar:2385105:4818af596fc4864560a844d712196608978d33c02e00251067ab5e998e331ef9'
            launcher='net.minecraftforge:forge:1.14.2-26.0.63:forge-1.14.2-26.0.63-launcher.jar:163126:9920eef0a9a335638369a9d1a4d77b561fbc8a76ec78a3f95d29aff7b44cc463'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.5:binarypatcher-1.0.5-fatjar.jar:3809174:2cf1aad100fbdefe1eacdcbb08da38b6a565aeb1c4b32b14247a8eb95228099a'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.14.2-20190603.175704@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6436 -or [string]$catalog.mcpConfig.configSha256 -cne '9ad5f783c143a103e7d2e35d11b8cad9777466e48ec3792451b6ba5ca19daa11' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 1692937 -or [string]$catalog.mcpConfig.mappingsSha256 -cne '977078c91578d6531a36d334b1263cb3302190a6ec572940989467eb92e5e97d' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 2891 -or [string]$userdev.configSha256 -cne '5285bedba3ffa72394813f5605d7c5efb9a5813e7796f592112e3e7b13b624a2' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.5:fatjar' -or @($userdev.libraries).Count -ne 21){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/83299b3bf3139ebd9ae5547b3144dcf68d4cb1fd/1.14.2.json' -or [string]$catalog.mojangVersion.sha1 -cne '83299b3bf3139ebd9ae5547b3144dcf68d4cb1fd' -or [long]$catalog.mojangVersion.bytes -ne 21597 -or [string]$catalog.mojangVersion.sha256 -cne '237aa8d499b71bb17122cbee40b8748efcd5ac9d8362c68c89e99ab0703e66b8'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.14.3'){
        if([string]$catalog.forgeVersion -cne '1.14.3-27.0.60' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.14.3-27.0.60:forge-1.14.3-27.0.60-userdev.jar:2861279:aa8edf1305c247fe9c25fc2c8c0867f382b21d663a65c530318385b664d5530c'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.14.3-20190624.152911:mcp_config-1.14.3-20190624.152911.zip:616560:5abf7118a91562ab51b185ee2d5c2f04b3c2589087bf5e002fec7d86d13284d5'
            forgeSources='net.minecraftforge:forge:1.14.3-27.0.60:forge-1.14.3-27.0.60-sources.jar:1436202:bfa21ef8243ebdbdc17d5d150306f4101f0e16e0707b937d2da4cea78c550e62'
            forgeUniversal='net.minecraftforge:forge:1.14.3-27.0.60:forge-1.14.3-27.0.60-universal.jar:2023969:7583738aa27efeef115fc3d3fc334987f814a83ee8ea1353c2d41ee2d57fa3e4'
            launcher='net.minecraftforge:forge:1.14.3-27.0.60:forge-1.14.3-27.0.60-launcher.jar:163780:40b7d9bb269d109ec4ddcba12003a7192e2dad694cc669774f0886413412ebb0'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.5:binarypatcher-1.0.5-fatjar.jar:3809174:2cf1aad100fbdefe1eacdcbb08da38b6a565aeb1c4b32b14247a8eb95228099a'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.14.3-20190624.152911@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6436 -or [string]$catalog.mcpConfig.configSha256 -cne '426e6d9ac41e374022a1146d92d1c646d4ae8d8db684a03637c6dfbecbdd1bce' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 1699455 -or [string]$catalog.mcpConfig.mappingsSha256 -cne 'c2ee1999455f08c6e98c2a41187457761f942c0efd088acaeba553918caef2be' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 2939 -or [string]$userdev.configSha256 -cne '46fb9bc70dfbc30c853548e85e29831abecb3c10bdd0c7cb6fbabf0186cc970e' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.5:fatjar' -or @($userdev.libraries).Count -ne 21){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/e21618620e02be5a14543d1d17ffdba941d09aa8/1.14.3.json' -or [string]$catalog.mojangVersion.sha1 -cne 'e21618620e02be5a14543d1d17ffdba941d09aa8' -or [long]$catalog.mojangVersion.bytes -ne 21598 -or [string]$catalog.mojangVersion.sha256 -cne 'ebf2df95d9bd83c6687f287d5a6f5f41f74bc1b39159fcbb74ff6d1d19d8464c'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.14.4'){
        if([string]$catalog.forgeVersion -cne '1.14.4-28.2.26' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.14.4-28.2.26:forge-1.14.4-28.2.26-userdev.jar:2417875:572c52438fd9160f315e60122a45e25574c0bc48d9855eddd26c3da96fe0d3fb'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.14.4-20190829.143755:mcp_config-1.14.4-20190829.143755.zip:644820:49d0b7818ccf385a57feda19fbd88b1fb4bd97c95d98e7044d9cb4c735e37820'
            forgeSources='net.minecraftforge:forge:1.14.4-28.2.26:forge-1.14.4-28.2.26-sources.jar:1580409:0d3b2a366e55a08f2088c6742646b485f767d87e085d98eacde1c00da061251f'
            forgeUniversal='net.minecraftforge:forge:1.14.4-28.2.26:forge-1.14.4-28.2.26-universal.jar:2386355:3552443b6a3f36dee6a18c885355f9b4e1b2fc5bbd840a87f4e494809bf88a8e'
            launcher='net.minecraftforge:forge:1.14.4-28.2.26:forge-1.14.4-28.2.26-launcher.jar:183428:3917c2f46e0ae4d93c007156a850b0ca2b6586649c6b4d3d8ac8d58d74801e01'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.12:binarypatcher-1.0.12-fatjar.jar:3809410:16454ff27db627d408d58d267e64fc9c48bcf9f691a71c2e65bbd65a61f0a627'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.14.4-20190829.143755@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6436 -or [string]$catalog.mcpConfig.configSha256 -cne 'eb6315a903ae8130a733e908151f161d4a03504038ddef3088622c5e3f5b61a9' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 1786864 -or [string]$catalog.mcpConfig.mappingsSha256 -cne 'd0a1d4e4766ff7dc1428195f33ade060db04fc779d3e371b5732c2ce5e80b489' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 3003 -or [string]$userdev.configSha256 -cne '4bd908fb48f14d8b71cb946db8fc4eca89ceb0f15aa19febcffc477e866ef35d' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.12:fatjar' -or @($userdev.libraries).Count -ne 22){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/be146d5f66a3627ed0a87c234c4d8dde8ab35098/1.14.4.json' -or [string]$catalog.mojangVersion.sha1 -cne 'be146d5f66a3627ed0a87c234c4d8dde8ab35098' -or [long]$catalog.mojangVersion.bytes -ne 26942 -or [string]$catalog.mojangVersion.sha256 -cne '615f466a39d2c19ae9b6e2401aa7bd07dbda337f976bcce383326b8d6ba4e532'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.15'){
        if([string]$catalog.forgeVersion -cne '1.15-29.0.4' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 official Forge 1.15 MDK: hash-pinned userdev, MCP config and snapshot mapping'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.15-29.0.4:forge-1.15-29.0.4-userdev.jar:3161912:9d80248800d3d050aba29ef1668636716b6d381af44deba5fca26fe50bf1652e'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.15-20191212.203412:mcp_config-1.15-20191212.203412.zip:672728:14def49a2c27d279050c43d8f8c851c0dec1c813880098ef3a444f5d65b6dca3'
            mcpSnapshot='de.oceanlabs.mcp:mcp_snapshot:20190719-1.14.3:mcp_snapshot-20190719-1.14.3.zip:366977:eafd59009aa0c7f72a2f4a92a0d5d56b04a79460ad885948e4ddb4f509381142'
            forgeSources='net.minecraftforge:forge:1.15-29.0.4:forge-1.15-29.0.4-sources.jar:1500884:a9b7aa826cdd08cda5ce047e7e3a245f14a92e15484bc8c0043a1e83e625d60f'
            forgeUniversal='net.minecraftforge:forge:1.15-29.0.4:forge-1.15-29.0.4-universal.jar:2150848:7656f2a76f19ca3afdd0faf4022ce732929a944d0e16983a06e0ac40fd6260ea'
            launcher='net.minecraftforge:forge:1.15-29.0.4:forge-1.15-29.0.4-launcher.jar:183392:5a37a600b30d3c58b319b1d616c20fbb1ea97d66a274a0c2a395e5528024bb59'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.7:binarypatcher-1.0.7-fatjar.jar:3809328:41792c359cb225b41823b84c88f42f76e240b10206361c3579ea596cde1bbc72'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev;$snapshot=$catalog.mcpSnapshot
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.15-20191212.203412@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6432 -or [string]$catalog.mcpConfig.configSha256 -cne '0937517c89ca06801e8cc49fb8a232e571dae1d42ac1cfc6a588a522ab06930c' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 1873182 -or [string]$catalog.mcpConfig.mappingsSha256 -cne '26919352a2dfe781c5f10d155824df88a5e5d9a66eae3993fb85d0ca8af0689d' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 2942 -or [string]$userdev.configSha256 -cne '5738e13723c22f18c4e6425706fdca15183f1071faf3d6b1f479c25d5faf95e9' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.7:fatjar' -or @($userdev.libraries).Count -ne 20 -or [string]$snapshot.channel -cne 'snapshot' -or [string]$snapshot.version -cne '20190719-1.14.3' -or [string]$snapshot.coordinate -cne 'de.oceanlabs.mcp:mcp_snapshot:20190719-1.14.3'){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/833322370ab320e77717097082effe1d124d48bd/1.15.json' -or [string]$catalog.mojangVersion.sha1 -cne '833322370ab320e77717097082effe1d124d48bd' -or [long]$catalog.mojangVersion.bytes -ne 29344 -or [string]$catalog.mojangVersion.sha256 -cne 'd154eaf07885a7fd6dfc6014bb9caf08fecc19ccd9a0862b31b1c7d1639e7785'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.15.1'){
        if([string]$catalog.forgeVersion -cne '1.15.1-30.0.51' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.15.1-30.0.51:forge-1.15.1-30.0.51-userdev.jar:3199649:c4f7390002680f5d78b8e908b29b8c23d384f1b4786b51147b676f713d1535a7'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.15.1-20191217.105819:mcp_config-1.15.1-20191217.105819.zip:675485:9c2749ab1896be958f09e4f7a4892abe6a5bf27b38712b82b9be22bf6a3effd4'
            forgeSources='net.minecraftforge:forge:1.15.1-30.0.51:forge-1.15.1-30.0.51-sources.jar:1477799:907b3dd6bf46101543b38e6baaf26c683532630282b6b4b6120fe9e62c3f6b33'
            forgeUniversal='net.minecraftforge:forge:1.15.1-30.0.51:forge-1.15.1-30.0.51-universal.jar:2147639:6922d2899ef600f93c4819013f61222246f4e8bc84e96631cd76745842f5ac3e'
            launcher='net.minecraftforge:forge:1.15.1-30.0.51:forge-1.15.1-30.0.51-launcher.jar:183622:c20f9e3ac41dafb2812072872e10255c0a25680078582291165329c1214fed01'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.7:binarypatcher-1.0.7-fatjar.jar:3809328:41792c359cb225b41823b84c88f42f76e240b10206361c3579ea596cde1bbc72'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.15.1-20191217.105819@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6436 -or [string]$catalog.mcpConfig.configSha256 -cne '155843a264334208b1f6e86d4993557dfc7f09258d79227088b462355d3aa391' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 1931201 -or [string]$catalog.mcpConfig.mappingsSha256 -cne '8e19205823785f3662c868057655834ac859204560fda3c6930acebbd208a0b1' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 2962 -or [string]$userdev.configSha256 -cne 'a5bd706a10e73ef5450f46fefed77e43a85fbd2983ef8e426258b7c9440f722d' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.7:fatjar' -or @($userdev.libraries).Count -ne 20){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/18c3063de87ae126b4e017121219ba802be0755b/1.15.1.json' -or [string]$catalog.mojangVersion.sha1 -cne '18c3063de87ae126b4e017121219ba802be0755b' -or [long]$catalog.mojangVersion.bytes -ne 29346 -or [string]$catalog.mojangVersion.sha256 -cne 'dda0859bca7447ff5f071643006b35a51f54e2fbef851a6665b424cf5743c598'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.15.2'){
        if([string]$catalog.forgeVersion -cne '1.15.2-31.2.57' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.15.2-31.2.57:forge-1.15.2-31.2.57-userdev.jar:2533784:bfef6d74e733a0c9ec694857b962374ad3773eadf28d66a0247d2c5e0f9bb7a9'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.15.2-20200515.085601:mcp_config-1.15.2-20200515.085601.zip:675404:17a1898f6a91ae61cc9a044fbec19e33f49b8a02e37e624fa762de156422a665'
            forgeSources='net.minecraftforge:forge:1.15.2-31.2.57:forge-1.15.2-31.2.57-sources.jar:1532234:b7b83f46f3dc0aaa5b61764a863a94fe917e5b016dc83b5607fee70512b1b107'
            forgeUniversal='net.minecraftforge:forge:1.15.2-31.2.57:forge-1.15.2-31.2.57-universal.jar:2262896:415329285fca582800582f5e40d807ea6d3ba14f5d7fa7d8595f35b79b2e8c79'
            launcher='net.minecraftforge:forge:1.15.2-31.2.57:forge-1.15.2-31.2.57-launcher.jar:194694:52f070b74817ad31b6d08a267ffe0cb9ab99c08363c8880ea813807c7bdd1517'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.12:binarypatcher-1.0.12-fatjar.jar:3809410:16454ff27db627d408d58d267e64fc9c48bcf9f691a71c2e65bbd65a61f0a627'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.15.2-20200515.085601@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6466 -or [string]$catalog.mcpConfig.configSha256 -cne '5a05690df881be58cb4f727a2dac15099d3d967087b7e8d94cc89ced8ebf2923' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 1876772 -or [string]$catalog.mcpConfig.mappingsSha256 -cne '22be93172671e7877f56e050a1090ea0cd657c11a6f34c1f347563c5bb6412cd' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 3080 -or [string]$userdev.configSha256 -cne '1fad4c901f87f02db4570e636e86c39cbcb99afccdbfc4ea42f672f5ce3a637f' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.12:fatjar' -or @($userdev.libraries).Count -ne 24){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/e9d0adb8f642abe422909ede50f651b2b58a3573/1.15.2.json' -or [string]$catalog.mojangVersion.sha1 -cne 'e9d0adb8f642abe422909ede50f651b2b58a3573' -or [long]$catalog.mojangVersion.bytes -ne 29346 -or [string]$catalog.mojangVersion.sha256 -cne 'e974511243e845b2427ab635eba5612481cb420a70c0630aa041eab3eeb590c5'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.16.1'){
        if([string]$catalog.forgeVersion -cne '1.16.1-32.0.108' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.16.1-32.0.108:forge-1.16.1-32.0.108-userdev.jar:2593733:d83eaef8776e66a968d8980c6c2dbe043c60f856ddd6f8e617a363f714eea069'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.16.1-20200625.160719:mcp_config-1.16.1-20200625.160719.zip:754061:2e158cbdc9c65afc50b89b649de84bace072f93f9062dc24561d68da592bd072'
            forgeSources='net.minecraftforge:forge:1.16.1-32.0.108:forge-1.16.1-32.0.108-sources.jar:1485266:decdb046466c1cf88000744207129a530a871791bd294d8040ec0434eae6fa7b'
            forgeUniversal='net.minecraftforge:forge:1.16.1-32.0.108:forge-1.16.1-32.0.108-universal.jar:2212022:ff25663828fd5ba3f9d69343b0b5f4e0bc38f1de200b83119348c56768a5b893'
            launcher='net.minecraftforge:forge:1.16.1-32.0.108:forge-1.16.1-32.0.108-launcher.jar:195270:7f8b07c41c732964f259f882c72a68201fd8c86061769160adf831f27731b34c'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.12:binarypatcher-1.0.12-fatjar.jar:3809410:16454ff27db627d408d58d267e64fc9c48bcf9f691a71c2e65bbd65a61f0a627'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.16.1-20200625.160719@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6492 -or [string]$catalog.mcpConfig.configSha256 -cne 'd18f2f613d6949c64b1b865f7f2c0fa7a3b1263b491018b8c564232591fcd660' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 2079581 -or [string]$catalog.mcpConfig.mappingsSha256 -cne '603b76d87af7080ffc631f8d8ff9aa53e238fc4278962c8f1a66e4d23d65e135' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 2994 -or [string]$userdev.configSha256 -cne '4b64ea537be7bee775f6520186d60474026ae72b0bad1af4dd8c2720e738c657' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.12:fatjar' -or @($userdev.libraries).Count -ne 23){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/54fa3af57d041d2771e66d390197b2c0288e697c/1.16.1.json' -or [string]$catalog.mojangVersion.sha1 -cne '54fa3af57d041d2771e66d390197b2c0288e697c' -or [long]$catalog.mojangVersion.bytes -ne 29287 -or [string]$catalog.mojangVersion.sha256 -cne '9688ec094a807c45513733388f7c8426d80a58cee96ed86be5380cb6a45f4a73'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.16.2'){
        if([string]$catalog.forgeVersion -cne '1.16.2-33.0.61' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.16.2-33.0.61:forge-1.16.2-33.0.61-userdev.jar:2632572:b7ae11579ec40b27ced060568136558b938c822c4022cbe34a8eb470cca395d7'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.16.2-20200812.004259:mcp_config-1.16.2-20200812.004259.zip:773087:ca1afc393660a82dbb8dd19f508b0049b5dadcf912f71be7eabc3002492e9542'
            forgeSources='net.minecraftforge:forge:1.16.2-33.0.61:forge-1.16.2-33.0.61-sources.jar:1498023:bfdbfff02ca4cd125745464452cb0d85e8f264e49c9ef666903e55d38755ef40'
            forgeUniversal='net.minecraftforge:forge:1.16.2-33.0.61:forge-1.16.2-33.0.61-universal.jar:2223643:3349cdba3a0d8dbb81af033624580a0970ee000165f67a21e5c62099f3525342'
            launcher='net.minecraftforge:forge:1.16.2-33.0.61:forge-1.16.2-33.0.61-launcher.jar:197261:beb6eb4812ca0b3ee619d51f94b1115ecfe10b80adf9b0bea13847e4967d909c'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.12:binarypatcher-1.0.12-fatjar.jar:3809410:16454ff27db627d408d58d267e64fc9c48bcf9f691a71c2e65bbd65a61f0a627'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.16.2-20200812.004259@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6492 -or [string]$catalog.mcpConfig.configSha256 -cne '35a254de89eadef23cb76d16e4414ab072f8c37eac6a0e7855dcc61b55f3decb' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 2171590 -or [string]$catalog.mcpConfig.mappingsSha256 -cne 'a7ee8661e854ce086fa82c531715eda1416de9218cdc3c34bda6a32f466cbcca' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 2988 -or [string]$userdev.configSha256 -cne 'b14290e2a877c7d07790b973eae487346815565d8c09f8eb8c09590ea1fce3a7' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.12:fatjar' -or @($userdev.libraries).Count -ne 23){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/998d9ef5770d05c20d760dc16cf85151f35009f2/1.16.2.json' -or [string]$catalog.mojangVersion.sha1 -cne '998d9ef5770d05c20d760dc16cf85151f35009f2' -or [long]$catalog.mojangVersion.bytes -ne 29287 -or [string]$catalog.mojangVersion.sha256 -cne 'f696986f4c07cd12dede183c86266d5cd34def6846eb0f014e1a84c2a76688d4'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.16.3'){
        if([string]$catalog.forgeVersion -cne '1.16.3-34.1.42' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.16.3-34.1.42:forge-1.16.3-34.1.42-userdev.jar:2654968:65bb83fe1cec3b031f8e3386069ab2c0bb268d77fd563073657c3c64c07dd95e'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.16.3-20201025.185957:mcp_config-1.16.3-20201025.185957.zip:769976:31df936e7d74c03cfd9b1f0fa2b55040c1cea5753cdbd54b2497d193e7c2da9e'
            forgeSources='net.minecraftforge:forge:1.16.3-34.1.42:forge-1.16.3-34.1.42-sources.jar:1537793:4f48f5b613a32b7e61b40ba963e3914cb0cf2111a433b9e93b055562434f8fff'
            forgeUniversal='net.minecraftforge:forge:1.16.3-34.1.42:forge-1.16.3-34.1.42-universal.jar:2285730:c7a2488596fc227dc0b5880f935b01ae19a2a72dfe5b3c5dfb8879181264279c'
            launcher='net.minecraftforge:forge:1.16.3-34.1.42:forge-1.16.3-34.1.42-launcher.jar:206253:0dded423373582940e51d20e3f196c96143e3a5ee62abba4901797e83ad7e9f3'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.12:binarypatcher-1.0.12-fatjar.jar:3809410:16454ff27db627d408d58d267e64fc9c48bcf9f691a71c2e65bbd65a61f0a627'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.16.3-20201025.185957@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6492 -or [string]$catalog.mcpConfig.configSha256 -cne 'de5ff99dc5424ca3599f9a14a9772202136e48dea3e97ff04d7941390cc9790c' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 2106645 -or [string]$catalog.mcpConfig.mappingsSha256 -cne '04fa2ee7d73da3166a9582b18e8af0fb0e897854dede8d54d732c0fa98d5df8e' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 2990 -or [string]$userdev.configSha256 -cne '07f519c277ef9638fd188e2f2554783a1a4463fed02369549073e39bf31a4ccd' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.12:fatjar' -or @($userdev.libraries).Count -ne 23){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/6485dd131ef68c968041a9f6fd73094b027e42e1/1.16.3.json' -or [string]$catalog.mojangVersion.sha1 -cne '6485dd131ef68c968041a9f6fd73094b027e42e1' -or [long]$catalog.mojangVersion.bytes -ne 29287 -or [string]$catalog.mojangVersion.sha256 -cne '193c5226095ce9e8a317f1e35ddbe4d976f176f6df7ac649ecfa669e17160ead'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }elseif([string]$catalog.targetId -ceq 'Forge@1.16.4'){
        if([string]$catalog.forgeVersion -cne '1.16.4-35.1.37' -or [string]$catalog.resolver -cne 'ForgeGradle 3.0.197 target inputs captured from the official MDK build'){throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
        $expected=[ordered]@{
            userdev='net.minecraftforge:forge:1.16.4-35.1.37:forge-1.16.4-35.1.37-userdev.jar:2744718:01ae2bcc1a2173209f68d669506efc9dbef1110a1a175c4c2d97ec64df5a4f80'
            mcpConfig='de.oceanlabs.mcp:mcp_config:1.16.4-20201102.104115:mcp_config-1.16.4-20201102.104115.zip:779191:34beacd09443f419441e5815af48be6847dbc3a1b792ee89035e56c5948a81ec'
            forgeSources='net.minecraftforge:forge:1.16.4-35.1.37:forge-1.16.4-35.1.37-sources.jar:1575336:82174c94453b17bba3ae326e6b474a88e064e8d875d5f346b7ce482ddb630d56'
            forgeUniversal='net.minecraftforge:forge:1.16.4-35.1.37:forge-1.16.4-35.1.37-universal.jar:2326479:503ee00b7ee746267791972385e16569aa18cb91db13ea56aa136e2fe7c8b868'
            launcher='net.minecraftforge:forge:1.16.4-35.1.37:forge-1.16.4-35.1.37-launcher.jar:210116:3965ea90ff064da622b6494c118a8f39e5498aa18bf9b0710d87ed44f6259248'
            binarypatcher='net.minecraftforge:binarypatcher:1.0.12:binarypatcher-1.0.12-fatjar.jar:3809410:16454ff27db627d408d58d267e64fc9c48bcf9f691a71c2e65bbd65a61f0a627'
        }
        if($artifacts.Count -ne $expected.Count){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_SET_INVALID'}
        foreach($kind in $expected.Keys){$matches=@($artifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw 'FORGE_GRADLE3_TARGET_INPUT_ARTIFACT_MISSING'};$a=$matches[0];$identity=([string]$a.group+':'+[string]$a.artifact+':'+[string]$a.version+':'+[string]$a.file+':'+[string]$a.bytes+':'+[string]$a.sha256);if($identity -cne $expected[$kind]){throw 'FORGE_GRADLE3_TARGET_INPUT_PIN_MISMATCH'};$uri=$null;if(-not[Uri]::TryCreate([string]$a.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/'+[string]$a.group.Replace('.','/')+'/'+[string]$a.artifact+'/'+[string]$a.version+'/'+[string]$a.file)){throw 'FORGE_GRADLE3_TARGET_INPUT_URL_INVALID'}}
        $mcp=[string]$catalog.mcpConfig.coordinate;$userdev=$catalog.userdev
        if($mcp -cne 'de.oceanlabs.mcp:mcp_config:1.16.4-20201102.104115@zip' -or [string]$userdev.mcpCoordinate -cne $mcp -or [string]$catalog.mcpConfig.configEntry -cne 'config.json' -or [long]$catalog.mcpConfig.configBytes -ne 6492 -or [string]$catalog.mcpConfig.configSha256 -cne '96fc561c762bc0cf08f27dcfab74c27480ce0b873a21c0c302102ea05fe4fe12' -or [string]$catalog.mcpConfig.mappingsEntry -cne 'config/joined.tsrg' -or [long]$catalog.mcpConfig.mappingsBytes -ne 2181741 -or [string]$catalog.mcpConfig.mappingsSha256 -cne 'e997e16c023c5d7caccb5c9496974ac38643412e12ab470d6b607e7637e33f91' -or [string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -ne 3064 -or [string]$userdev.configSha256 -cne '29a40379415d71e3e4fbe67a8f317d68281dbd6c71e3ad429e94ca0e74de13f0' -or [string]$userdev.processors -notcontains 'net.minecraftforge:binarypatcher:1.0.12:fatjar' -or @($userdev.libraries).Count -ne 25){throw 'FORGE_GRADLE3_TARGET_INPUT_CONFIG_INVALID'}
        if([string]$catalog.mojangVersion.url -cne 'https://piston-meta.mojang.com/v1/packages/596ad61fda7612d9edf8881cf81869276bdb7f82/1.16.4.json' -or [string]$catalog.mojangVersion.sha1 -cne '596ad61fda7612d9edf8881cf81869276bdb7f82' -or [long]$catalog.mojangVersion.bytes -ne 29287 -or [string]$catalog.mojangVersion.sha256 -cne '667fff4ca7fd0f56ab78b757224515e8e64375868e8d1ce6040091d7b63a0cb5'){throw 'FORGE_GRADLE3_TARGET_INPUT_MOJANG_PIN_INVALID'}
    }else{throw 'FORGE_GRADLE3_TARGET_INPUT_IDENTITY_INVALID'}
    $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
    if($hash -cne [string]$catalog.catalogHash){throw 'FORGE_GRADLE3_TARGET_INPUT_CATALOG_HASH_MISMATCH'}
    [pscustomobject]@{catalog=$catalog;catalogHash=$hash;artifacts=$artifacts}
}

function Get-MmtlForgeGradle3TargetInputMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=180,[string]$RuntimeArtifactCatalogPath)
    $resolved=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$artifactCache=Join-Path $root 'artifact-cache';$repository=Join-Path $root 'maven-mirror';[void][IO.Directory]::CreateDirectory($artifactCache);[void][IO.Directory]::CreateDirectory($repository)
    $files=@{}
    foreach($artifact in $resolved.artifacts){
        $hash=[string]$artifact.sha256;$cached=Join-Path $artifactCache $hash
        if(Test-Path -LiteralPath $cached -PathType Leaf){$item=Get-Item -LiteralPath $cached -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cached) -cne $hash){throw 'FORGE_GRADLE3_TARGET_CACHE_INVALID'}}
        else{$temporary=Join-Path $artifactCache ('.target-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash){throw 'FORGE_GRADLE3_TARGET_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cached)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version);$directory=[IO.Path]::GetFullPath((Join-Path $repository $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $repository -Target $directory)){throw 'FORGE_GRADLE3_TARGET_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($directory);$destination=Join-Path $directory ([string]$artifact.file);if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_GRADLE3_TARGET_MIRROR_CONFLICT'}}else{[IO.File]::Copy($cached,$destination,$false)};$files[[string]$artifact.kind]=$destination
    }
    $mojangPin=$resolved.catalog.mojangVersion;$mojangCache=Join-Path $artifactCache ([string]$mojangPin.sha256)
    if(Test-Path -LiteralPath $mojangCache -PathType Leaf){$item=Get-Item -LiteralPath $mojangCache -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$mojangPin.bytes -or (Get-MmtlForgePinFileHash -Path $mojangCache) -cne [string]$mojangPin.sha256){throw 'FORGE_GRADLE3_MOJANG_CACHE_INVALID'}}else{$temporary=Join-Path $artifactCache ('.mojang-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$mojangPin.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('piston-meta.mojang.com');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$mojangPin.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne [string]$mojangPin.sha256 -or [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([IO.File]::ReadAllBytes($temporary))).ToLowerInvariant() -cne [string]$mojangPin.sha1){throw 'FORGE_GRADLE3_MOJANG_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$mojangCache)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
    $minecraftVersion=[string]$resolved.catalog.targetId -replace '^Forge@','';$mojangVersionPath=Join-Path $root ('mojang-version-'+$minecraftVersion+'.json');if(Test-Path -LiteralPath $mojangVersionPath -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $mojangVersionPath) -cne [string]$mojangPin.sha256){throw 'FORGE_GRADLE3_MOJANG_COPY_CONFLICT'}}else{[IO.File]::Copy($mojangCache,$mojangVersionPath,$false)}
    $userdevProperty=if($resolved.catalog.PSObject.Properties['userdev']){'userdev'}else{'userdev3'};$userdevCatalog=$resolved.catalog.$userdevProperty;$userdevKind=$userdevProperty
    $userdev=Get-MmtlForgeUserdevConfiguration -ArchivePath $files[$userdevKind] -EntryName ([string]$userdevCatalog.configEntry) -ExpectedBytes ([long]$userdevCatalog.configBytes) -ExpectedSha256 ([string]$userdevCatalog.configSha256) -ExpectedMcpCoordinate ([string]$userdevCatalog.mcpCoordinate) -ExpectedLibraries @($userdevCatalog.libraries)
    $mcp=Get-MmtlForgeUserdevConfiguration -ArchivePath $files.mcpConfig -EntryName ([string]$resolved.catalog.mcpConfig.configEntry) -ExpectedBytes ([long]$resolved.catalog.mcpConfig.configBytes) -ExpectedSha256 ([string]$resolved.catalog.mcpConfig.configSha256) -ExpectedLibraries @() -SkipLibraryValidation
    if([string]$mcp.config.version -cne $minecraftVersion -or [string]$mcp.config.data.mappings -cne [string]$resolved.catalog.mcpConfig.mappingsEntry){throw 'FORGE_GRADLE3_MCP_CONFIG_IDENTITY_INVALID'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $mappingDirectory=Join-Path $root 'mcp-config';[void][IO.Directory]::CreateDirectory($mappingDirectory);$mappingPath=Join-Path $mappingDirectory 'joined.tsrg'
    $zip=[IO.Compression.ZipFile]::OpenRead($files.mcpConfig)
    try{$entries=@($zip.Entries|Where-Object FullName -CEQ ([string]$resolved.catalog.mcpConfig.mappingsEntry));if($entries.Count -ne 1 -or [long]$entries[0].Length -ne [long]$resolved.catalog.mcpConfig.mappingsBytes){throw 'FORGE_GRADLE3_MCP_MAPPING_ENTRY_INVALID'};$stream=$entries[0].Open();try{$target=[IO.File]::Open($mappingPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.CopyTo($target)}finally{$target.Dispose()}}finally{$stream.Dispose()}}finally{$zip.Dispose()}
    if((Get-MmtlForgePinFileHash -Path $mappingPath) -cne [string]$resolved.catalog.mcpConfig.mappingsSha256){throw 'FORGE_GRADLE3_MCP_MAPPING_HASH_MISMATCH'}
    $runtimePomCoordinates=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);if($RuntimeArtifactCatalogPath){$runtimeCatalog=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $RuntimeArtifactCatalogPath;foreach($runtimePom in @($runtimeCatalog.artifacts|Where-Object extension -CEQ 'pom')){[void]$runtimePomCoordinates.Add([string]$runtimePom.group+':'+[string]$runtimePom.artifact+':'+[string]$runtimePom.version)}}
    foreach($artifact in $resolved.artifacts){$parts=([string]$artifact.group+':'+[string]$artifact.artifact+':'+[string]$artifact.version).Split(':');if($runtimePomCoordinates.Contains($parts[0]+':'+$parts[1]+':'+$parts[2])){continue};$moduleRoot=Join-Path (Join-Path (Join-Path $repository $parts[0].Replace('.', [IO.Path]::DirectorySeparatorChar)) $parts[1]) $parts[2];$pom=Join-Path $moduleRoot ($parts[1]+'-'+$parts[2]+'.pom');$packaging=if([string]$artifact.file.EndsWith('.zip')){'zip'}else{'jar'};$pomText='<?xml version="1.0" encoding="UTF-8"?><project><modelVersion>4.0.0</modelVersion><groupId>'+$parts[0]+'</groupId><artifactId>'+$parts[1]+'</artifactId><version>'+$parts[2]+'</version><packaging>'+$packaging+'</packaging></project>';if(Test-Path -LiteralPath $pom -PathType Leaf){if([IO.File]::ReadAllText($pom) -cne $pomText){throw 'FORGE_GRADLE3_TARGET_POM_COLLISION'}}else{[IO.File]::WriteAllText($pom,$pomText,[Text.UTF8Encoding]::new($false))}}
    [pscustomobject]@{cacheRoot=$root;repositoryRoot=$repository;artifactFiles=$files;mojangVersionPath=$mojangVersionPath;mojangVersionUrl=[string]$mojangPin.url;mcpMappingPath=$mappingPath;mcpMappingSha256=[string]$resolved.catalog.mcpConfig.mappingsSha256;mcpSnapshot=$resolved.catalog.mcpSnapshot;mcpSnapshotArtifactPath=$files.mcpSnapshot;userdevConfig=$userdev.config;userdev3Config=$userdev.config;mcpConfig=$mcp.config;mcpMappingEntry=[string]$resolved.catalog.mcpConfig.mappingsEntry;catalogHash=$resolved.catalogHash;artifactCount=$resolved.artifacts.Count+1}
}

function Get-MmtlForgeGradle3RuntimeArtifactCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $targetId=[string]$catalog.targetId
    $targetExpectations=switch($targetId){
        'Forge@1.13.2' {@{resolver='Forge 1.13.2 official MDK userdev configuration resolved with Gradle 4.9 and pinned repositories';libraries=23;components=35;artifacts=71;jars=36;poms=35;support=16;mojang=58;inputs='Forge-1.13.2.json';launcher='Forge@1.13.2';launcherVersion='2.1.5';modlauncher=@{'0.10.+'='0.10.0';'1.0.+'='1.0.0';'2.1.+'='2.1.5'};log4j='2.15.0'}}
        'Forge@1.14.2' {@{resolver='Forge 1.14.2 official MDK userdev configuration resolved with Gradle 4.9 and pinned repositories';libraries=21;components=37;artifacts=77;jars=40;poms=37;support=18;mojang=55;inputs='Forge-1.14.2.json';launcher='Forge@1.14.2';launcherVersion='2.1.4';modlauncher=@{'0.10.+'='2.1.4';'1.0.+'='2.1.4';'2.1.+'='2.1.4'};log4j='2.11.2'}}
        'Forge@1.14.3' {@{resolver='Forge 1.14.3 official MDK userdev configuration resolved with Gradle 4.9 and pinned repositories';libraries=21;components=37;artifacts=77;jars=40;poms=37;support=18;mojang=55;inputs='Forge-1.14.3.json';launcher='Forge@1.14.3';launcherVersion='3.0.2';modlauncher=@{'0.10.+'='2.1.4';'1.0.+'='2.1.4';'2.1.+'='2.1.4'};log4j='2.11.2'}}
        'Forge@1.14.4' {@{resolver='Forge 1.14.4 official MDK userdev configuration resolved with Gradle 4.9 and pinned repositories';libraries=22;components=33;artifacts=69;jars=36;poms=33;support=16;mojang=60;inputs='Forge-1.14.4.json';launcher='Forge@1.14.4';launcherVersion='4.1.0';modlauncher=@{'3.2.+'='4.1.0'};log4j='2.15.0';forgespi='1.5.0'}}
        'Forge@1.15' {@{resolver='Forge 1.15 official MDK exact userdev closure matched to the Forge 1.15.1 Gradle 4.9 capture; Forge 1.15 launcher POM and Mojang snapshot independently verified';libraries=20;components=30;artifacts=63;jars=33;poms=30;support=12;mojang=65;inputs='Forge-1.15.json';launcher='Forge@1.15';launcherVersion='5.0.0-milestone.4';modlauncher=@{'5.0.+'='5.0.0-milestone.4'};log4j='2.12.1';forgespi='2.0.0-milestone.1';grossjava9hacks='1.1.0';selections=3;metadata=5}}
        'Forge@1.15.1' {@{resolver='Forge 1.15.1 official MDK userdev configuration resolved with Gradle 4.9 and pinned repositories';libraries=20;components=30;artifacts=63;jars=33;poms=30;support=12;mojang=65;inputs='Forge-1.15.1.json';launcher='Forge@1.15.1';launcherVersion='5.0.0-milestone.4';modlauncher=@{'5.0.+'='5.0.0-milestone.4'};log4j='2.12.1';forgespi='2.0.0-milestone.1';grossjava9hacks='1.1.0';selections=3;metadata=5}}
        'Forge@1.15.2' {@{resolver='Forge 1.15.2 official MDK userdev configuration resolved with Gradle 4.10.3 and pinned repositories';libraries=24;components=33;artifacts=69;jars=36;poms=33;support=15;mojang=65;inputs='Forge-1.15.2.json';launcher='Forge@1.15.2';launcherVersion='5.1.2';modlauncher=@{'5.1.+'='5.1.2'};log4j='2.15.0';forgespi='3.0.0';grossjava9hacks='1.3.3';typetools='0.8.3';selections=1;metadata=6}}
        'Forge@1.16.1' {@{resolver='Forge 1.16.1 official MDK userdev configuration resolved with Gradle 4.10.3 and pinned repositories';libraries=23;components=30;artifacts=63;jars=33;poms=30;support=12;mojang=65;inputs='Forge-1.16.1.json';launcher='Forge@1.16.1';launcherVersion='6.1.3';modlauncher=@{'5.1.+'='6.1.3';'6.1.+'='6.1.3'};log4j='2.11.2';forgespi='3.1.1';grossjava9hacks='1.3.3';typetools='0.8.3';selections=4;metadata=6}}
        'Forge@1.16.2' {@{resolver='Forge 1.16.2 official MDK userdev configuration resolved with Gradle 4.10.3 and pinned repositories';libraries=23;components=30;artifacts=63;jars=33;poms=30;support=12;mojang=65;inputs='Forge-1.16.2.json';launcher='Forge@1.16.2';launcherVersion='7.0.1';modlauncher=@{'5.1.+'='7.0.1';'6.1.+'='7.0.1'};log4j='2.11.2';forgespi='3.1.1';grossjava9hacks='1.3.3';typetools='0.8.3';selections=4;metadata=6}}
        'Forge@1.16.3' {@{resolver='Forge 1.16.3 official MDK userdev configuration resolved with Gradle 4.10.3 and pinned repositories';libraries=23;components=30;artifacts=63;jars=33;poms=30;support=12;mojang=65;inputs='Forge-1.16.3.json';launcher='Forge@1.16.3';launcherVersion='8.0.6';modlauncher=@{'5.1.+'='8.0.6';'6.1.+'='8.0.6'};log4j='2.11.2';forgespi='3.2.0';grossjava9hacks='1.3.3';typetools='0.8.3';selections=5;metadata=6}}
        'Forge@1.16.4' {@{resolver='Forge 1.16.4 official MDK userdev configuration resolved with Gradle 4.10.3 and pinned repositories';libraries=25;components=31;artifacts=65;jars=34;poms=31;support=12;mojang=65;inputs='Forge-1.16.4.json';launcher='Forge@1.16.4';launcherVersion='8.0.9';modlauncher=@{'5.1.+'='8.0.9';'6.1.+'='8.0.9'};log4j='2.11.2';forgespi='3.2.0';grossjava9hacks='1.3.3';typetools='0.8.3';selections=5;metadata=6}}
        default {$null}
    }
    if([int]$catalog.schemaVersion -ne 1 -or -not $targetExpectations -or [string]$catalog.resolver -cne $targetExpectations.resolver -or [string]$catalog.artifactStatus -cne 'HashesVerified'){throw 'FORGE_GRADLE3_RUNTIME_CATALOG_IDENTITY_INVALID'}
    $libraries=@($catalog.userdevLibraries);$components=@($catalog.components);$artifacts=@($catalog.artifacts);$supportArtifacts=@($catalog.supportArtifacts);$dynamicMetadata=@($catalog.dynamicMetadata);$mojangArtifacts=@($catalog.mojangArtifacts)
    $expectedMetadataCount=if($targetExpectations.ContainsKey('metadata')){$targetExpectations.metadata}else{5};$expectedSelectionCount=if($targetExpectations.ContainsKey('selections')){$targetExpectations.selections}else{0};$selections=@();if($catalog.PSObject.Properties['componentSelections']){$selections=@($catalog.componentSelections)}
    if($libraries.Count -ne $targetExpectations.libraries -or @($libraries|Sort-Object -Unique).Count -ne $targetExpectations.libraries -or $components.Count -ne $targetExpectations.components -or @($components|Sort-Object -Unique).Count -ne $targetExpectations.components -or $artifacts.Count -ne $targetExpectations.artifacts -or $supportArtifacts.Count -ne $targetExpectations.support -or $dynamicMetadata.Count -ne $expectedMetadataCount -or $mojangArtifacts.Count -ne $targetExpectations.mojang -or $selections.Count -ne $expectedSelectionCount){throw 'FORGE_GRADLE3_RUNTIME_CATALOG_SET_INVALID'}
    $componentSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($coordinate in $components){if([string]$coordinate -notmatch '^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.+-]+$' -or -not $componentSet.Add([string]$coordinate)){throw 'FORGE_GRADLE3_RUNTIME_COMPONENT_INVALID'}}
    $expectedSelections=[ordered]@{}
    if($targetId -in @('Forge@1.15','Forge@1.15.1')){$expectedSelections['org.apache.maven:maven-artifact:3.6.0']=@('org.apache.maven:maven-artifact:3.6.3','between versions 3.6.0 and 3.6.3');$expectedSelections['org.apache.logging.log4j:log4j-api:2.11.2']=@('org.apache.logging.log4j:log4j-api:2.12.1','by conflict resolution: between versions 2.11.2, 2.8.1 and 2.12.1');$expectedSelections['org.apache.logging.log4j:log4j-core:2.11.2']=@('org.apache.logging.log4j:log4j-core:2.12.1','by conflict resolution: between versions 2.11.2, 2.8.1 and 2.12.1')}
    elseif($targetId -ceq 'Forge@1.15.2'){$expectedSelections['org.apache.maven:maven-artifact:3.6.0']=@('org.apache.maven:maven-artifact:3.6.3','between versions 3.6.0 and 3.6.3')}
    elseif($targetId -ceq 'Forge@1.16.1'){$expectedSelections['org.apache.maven:maven-artifact:3.6.0']=@('org.apache.maven:maven-artifact:3.6.3','between versions 3.6.0 and 3.6.3');$expectedSelections['cpw.mods:modlauncher:6.1.1']=@('cpw.mods:modlauncher:6.1.3','between versions 6.1.1, 6.1.3 and 5.1.2');$expectedSelections['cpw.mods:grossjava9hacks:1.3.0']=@('cpw.mods:grossjava9hacks:1.3.3','between versions 1.3.0 and 1.3.3');$expectedSelections['net.jodah:typetools:0.8.1']=@('net.jodah:typetools:0.8.3','between versions 0.8.1 and 0.8.3')}
    elseif($targetId -ceq 'Forge@1.16.2'){$expectedSelections['org.apache.maven:maven-artifact:3.6.0']=@('org.apache.maven:maven-artifact:3.6.3','between versions 3.6.0 and 3.6.3');$expectedSelections['cpw.mods:modlauncher:6.1.3']=@('cpw.mods:modlauncher:7.0.1','between versions 7.0.1, 6.1.3 and 5.1.2');$expectedSelections['cpw.mods:grossjava9hacks:1.3.0']=@('cpw.mods:grossjava9hacks:1.3.3','between versions 1.3.0 and 1.3.3');$expectedSelections['net.jodah:typetools:0.8.1']=@('net.jodah:typetools:0.8.3','between versions 0.8.1 and 0.8.3')}
    elseif($targetId -ceq 'Forge@1.16.3'){$expectedSelections['org.apache.maven:maven-artifact:3.6.0']=@('org.apache.maven:maven-artifact:3.6.3','between versions 3.6.0 and 3.6.3');$expectedSelections['cpw.mods:modlauncher:6.1.3']=@('cpw.mods:modlauncher:8.0.6','between versions 8.0.6, 6.1.3 and 5.1.2');$expectedSelections['cpw.mods:grossjava9hacks:1.3.0']=@('cpw.mods:grossjava9hacks:1.3.3','between versions 1.3.0 and 1.3.3');$expectedSelections['net.jodah:typetools:0.8.1']=@('net.jodah:typetools:0.8.3','between versions 0.8.1 and 0.8.3');$expectedSelections['net.minecraftforge:forgespi:3.1.1']=@('net.minecraftforge:forgespi:3.2.0','between versions 3.2.0 and 3.1.1')}
    elseif($targetId -ceq 'Forge@1.16.4'){$expectedSelections['org.apache.maven:maven-artifact:3.6.0']=@('org.apache.maven:maven-artifact:3.6.3','between versions 3.6.0 and 3.6.3');$expectedSelections['cpw.mods:modlauncher:6.1.3']=@('cpw.mods:modlauncher:8.0.9','between versions 8.0.9, 6.1.3 and 5.1.2');$expectedSelections['cpw.mods:grossjava9hacks:1.3.0']=@('cpw.mods:grossjava9hacks:1.3.3','between versions 1.3.0 and 1.3.3');$expectedSelections['net.jodah:typetools:0.8.1']=@('net.jodah:typetools:0.8.3','didn''t match versions 0.6.3, 0.6.2, 0.6.1, 0.6.0, 0.5.0, 0.4.9, 0.4.8, 0.4.7, 0.4.6, 0.4.5, 0.4.4, 0.4.3, 0.4.2, 0.4.1, 0.4.0, 0.3.1');$expectedSelections['net.minecraftforge:forgespi:3.1.1']=@('net.minecraftforge:forgespi:3.2.0','between versions 3.2.0 and 3.1.1')}
    $selectionMap=@{};foreach($selection in $selections){$requested=[string]$selection.requested;$selected=[string]$selection.selected;$reason=[string]$selection.reason;$expectedSelection=$expectedSelections[$requested];if(-not $expectedSelection -or $selected -cne $expectedSelection[0] -or $reason -cne $expectedSelection[1] -or $selectionMap.ContainsKey($requested) -or -not $componentSet.Contains($selected)){throw 'FORGE_GRADLE3_RUNTIME_COMPONENT_SELECTION_INVALID'};$selectionMap[$requested]=$selected}
    if($selectionMap.Count -ne $expectedSelections.Count){throw 'FORGE_GRADLE3_RUNTIME_COMPONENT_SELECTION_INVALID'}
    foreach($coordinate in $libraries){if([string]$coordinate -notmatch '^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.+-]+(:[A-Za-z0-9_.+-]+)?$'){throw 'FORGE_GRADLE3_RUNTIME_LIBRARY_INVALID'};$parts=([string]$coordinate).Split(':');$moduleCoordinate=$parts[0]+':'+$parts[1]+':'+$parts[2];$selectedCoordinate=if($selectionMap.ContainsKey($moduleCoordinate)){$selectionMap[$moduleCoordinate]}else{$moduleCoordinate};if(-not $componentSet.Contains($selectedCoordinate)){if(($targetId -ceq 'Forge@1.16.1' -and $moduleCoordinate -ceq 'net.minecraftforge:forge:1.16.1-32.0.108') -or ($targetId -ceq 'Forge@1.16.2' -and $moduleCoordinate -ceq 'net.minecraftforge:forge:1.16.2-33.0.61') -or ($targetId -ceq 'Forge@1.16.3' -and $moduleCoordinate -ceq 'net.minecraftforge:forge:1.16.3-34.1.42') -or ($targetId -ceq 'Forge@1.16.4' -and $moduleCoordinate -ceq 'net.minecraftforge:forge:1.16.4-35.1.37')){continue};throw 'FORGE_GRADLE3_RUNTIME_LIBRARY_COMPONENT_MISSING'}}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$pomSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$jarCount=0;$pomCount=0
    foreach($artifact in $artifacts){
        $group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$extension=[string]$artifact.extension
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $extension -notin @('jar','pom') -or $file -notmatch '^[A-Za-z0-9_.+-]+\.(jar|pom)$' -or -not $file.EndsWith('.'+$extension,[StringComparison]::Ordinal) -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_GRADLE3_RUNTIME_ARTIFACT_INVALID'}
        $coordinate=$group+':'+$module+':'+$version;if(-not $componentSet.Contains($coordinate)){throw 'FORGE_GRADLE3_RUNTIME_ARTIFACT_COMPONENT_MISSING'}
        $expectedArtifactPath='/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file;$uri=$null
        if(-not [Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -notin @('maven.minecraftforge.net','libraries.minecraft.net','repo.maven.apache.org') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw 'FORGE_GRADLE3_RUNTIME_ARTIFACT_URL_INVALID'}
        if($uri.Host -ceq 'repo.maven.apache.org'){$expectedArtifactPath='/maven2'+$expectedArtifactPath};if($uri.AbsolutePath -cne $expectedArtifactPath){throw 'FORGE_GRADLE3_RUNTIME_ARTIFACT_URL_INVALID'}
        if(-not $seen.Add($coordinate+':'+$file)){throw 'FORGE_GRADLE3_RUNTIME_ARTIFACT_DUPLICATE'}
        if($extension -ceq 'pom'){$pomCount++;if($file -cne ($module+'-'+$version+'.pom') -or -not $pomSet.Add($coordinate)){throw 'FORGE_GRADLE3_RUNTIME_POM_INVALID'}}else{$jarCount++}
    }
    if($jarCount -ne $targetExpectations.jars -or $pomCount -ne $targetExpectations.poms -or $pomSet.Count -ne $componentSet.Count){throw 'FORGE_GRADLE3_RUNTIME_CLOSURE_INCOMPLETE'}
    $supportSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $supportArtifacts){
        $group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file
        $uri=$null
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or [string]$artifact.extension -cne 'pom' -or $file -cne ($module+'-'+$version+'.pom') -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not[Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'repo.maven.apache.org' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne ('/maven2/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file)){throw 'FORGE_GRADLE3_RUNTIME_SUPPORT_ARTIFACT_INVALID'}
        $coordinate=$group+':'+$module+':'+$version
        if($componentSet.Contains($coordinate) -or $pomSet.Contains($coordinate) -or -not $supportSeen.Add($coordinate)){throw 'FORGE_GRADLE3_RUNTIME_SUPPORT_ARTIFACT_DUPLICATE'}
    }
    $expectedMetadata=[ordered]@{
        'cpw.mods:grossjava9hacks'=@('1.1.+')
        'cpw.mods:modlauncher'=@('0.10.+','1.0.+','2.1.+')
        'net.minecraftforge:forgespi'=@('0.13.+')
        'org.apache.logging.log4j:log4j-api'=@('2.11.+')
        'org.apache.logging.log4j:log4j-core'=@('2.11.+')
    }
    if([string]$catalog.targetId -ceq 'Forge@1.14.4'){$expectedMetadata=[ordered]@{'cpw.mods:grossjava9hacks'=@('1.1.+');'cpw.mods:modlauncher'=@('3.2.+');'net.minecraftforge:forgespi'=@('1.1.+');'org.apache.logging.log4j:log4j-api'=@('2.11.+');'org.apache.logging.log4j:log4j-core'=@('2.11.+')}}
    if([string]$catalog.targetId -in @('Forge@1.15','Forge@1.15.1')){$expectedMetadata=[ordered]@{'cpw.mods:grossjava9hacks'=@('1.1.+');'cpw.mods:modlauncher'=@('5.0.+');'net.minecraftforge:forgespi'=@('2.0.+');'org.apache.logging.log4j:log4j-api'=@('2.11.+','2.12.+');'org.apache.logging.log4j:log4j-core'=@('2.11.+','2.12.+')}}
    if([string]$catalog.targetId -ceq 'Forge@1.15.2'){$expectedMetadata=[ordered]@{'cpw.mods:grossjava9hacks'=@('1.3.+');'cpw.mods:modlauncher'=@('5.1.+');'net.minecraftforge:forgespi'=@('2.1.+');'net.jodah:typetools'=@('0.8.+');'org.apache.logging.log4j:log4j-api'=@('2.11.+');'org.apache.logging.log4j:log4j-core'=@('2.11.+')}}
    if([string]$catalog.targetId -ceq 'Forge@1.16.1'){$expectedMetadata=[ordered]@{'cpw.mods:grossjava9hacks'=@('1.3.+');'cpw.mods:modlauncher'=@('5.1.+','6.1.+');'net.minecraftforge:forgespi'=@('3.1.+');'net.jodah:typetools'=@('0.8.+');'org.apache.logging.log4j:log4j-api'=@('2.11.+');'org.apache.logging.log4j:log4j-core'=@('2.11.+')}}
    if([string]$catalog.targetId -ceq 'Forge@1.16.2'){$expectedMetadata=[ordered]@{'cpw.mods:grossjava9hacks'=@('1.3.+');'cpw.mods:modlauncher'=@('5.1.+','6.1.+');'net.minecraftforge:forgespi'=@('3.1.+');'net.jodah:typetools'=@('0.8.+');'org.apache.logging.log4j:log4j-api'=@('2.11.+');'org.apache.logging.log4j:log4j-core'=@('2.11.+')}}
    if([string]$catalog.targetId -ceq 'Forge@1.16.3'){$expectedMetadata=[ordered]@{'cpw.mods:grossjava9hacks'=@('1.3.+');'cpw.mods:modlauncher'=@('5.1.+','6.1.+');'net.minecraftforge:forgespi'=@('3.1.+');'net.jodah:typetools'=@('0.8.+');'org.apache.logging.log4j:log4j-api'=@('2.11.+');'org.apache.logging.log4j:log4j-core'=@('2.11.+')}}
    if([string]$catalog.targetId -ceq 'Forge@1.16.4'){$expectedMetadata=[ordered]@{'cpw.mods:grossjava9hacks'=@('1.3.+');'cpw.mods:modlauncher'=@('5.1.+','6.1.+');'net.minecraftforge:forgespi'=@('3.1.+');'net.jodah:typetools'=@('0.8.+');'org.apache.logging.log4j:log4j-api'=@('2.11.+');'org.apache.logging.log4j:log4j-core'=@('2.11.+')}}
    $expectedForgeSpiVersion=if($targetExpectations.ContainsKey('forgespi')){$targetExpectations.forgespi}else{'0.13.0'}
    $metadataSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($metadata in $dynamicMetadata){
        $group=[string]$metadata.group;$module=[string]$metadata.artifact;$key=$group+':'+$module;$expectedSelectors=$expectedMetadata[$key];$uri=$null
        if(-not $expectedSelectors -or -not $metadataSeen.Add($key) -or [string]$metadata.file -cne 'maven-metadata.xml' -or [long]$metadata.bytes -le 0 -or [string]$metadata.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not[Uri]::TryCreate([string]$metadata.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne ('/'+$group.Replace('.','/')+'/'+$module+'/maven-metadata.xml') -or (@($metadata.requiredSelectors|Sort-Object -Unique) -join "`n") -cne (@($expectedSelectors|Sort-Object -Unique) -join "`n")){throw 'FORGE_GRADLE3_RUNTIME_DYNAMIC_METADATA_INVALID'}
        $resolutionSelectors=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($resolution in @($metadata.resolutions)){$selector=[string]$resolution.selector;$version=[string]$resolution.version;$expectedResolution=if($key -ceq 'cpw.mods:modlauncher'){$targetExpectations.modlauncher[$selector]}elseif($key -ceq 'org.apache.logging.log4j:log4j-api' -or $key -ceq 'org.apache.logging.log4j:log4j-core'){$targetExpectations.log4j}elseif($key -ceq 'cpw.mods:grossjava9hacks'){if($targetExpectations.ContainsKey('grossjava9hacks')){$targetExpectations.grossjava9hacks}else{'1.1.0'}}elseif($key -ceq 'net.minecraftforge:forgespi'){$expectedForgeSpiVersion}elseif($key -ceq 'net.jodah:typetools'){$targetExpectations.typetools};if($selector -notin $expectedSelectors -or -not $resolutionSelectors.Add($selector) -or $version -notmatch '^[0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9_.+-]+)?$' -or -not $expectedResolution -or $version -cne $expectedResolution){throw 'FORGE_GRADLE3_RUNTIME_DYNAMIC_RESOLUTION_INVALID'}};if($resolutionSelectors.Count -ne $expectedSelectors.Count){throw 'FORGE_GRADLE3_RUNTIME_DYNAMIC_RESOLUTION_INCOMPLETE'}
    }
    $grossjava9hacksVersion=if($targetExpectations.ContainsKey('grossjava9hacks')){$targetExpectations.grossjava9hacks}else{'1.1.0'}
    if($metadataSeen.Count -ne $expectedMetadata.Count -or -not $componentSet.Contains('cpw.mods:grossjava9hacks:'+$grossjava9hacksVersion) -or -not $componentSet.Contains('net.minecraftforge:forgespi:'+$expectedForgeSpiVersion) -or -not $componentSet.Contains('org.apache.logging.log4j:log4j-api:'+$targetExpectations.log4j) -or -not $componentSet.Contains('org.apache.logging.log4j:log4j-core:'+$targetExpectations.log4j) -or ($targetExpectations.ContainsKey('typetools') -and -not $componentSet.Contains('net.jodah:typetools:'+$targetExpectations.typetools))){throw 'FORGE_GRADLE3_RUNTIME_DYNAMIC_CLOSURE_INCOMPLETE'}
    if(-not $componentSet.Contains('cpw.mods:modlauncher:'+$targetExpectations.launcherVersion)){throw 'FORGE_GRADLE3_RUNTIME_DYNAMIC_CLOSURE_INCOMPLETE'}
    $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $targetInputs=Get-MmtlForgeGradle3TargetInputCatalog -CatalogPath (Join-Path $repositoryRoot ('compatibility/forge-gradle3-target-inputs/'+$targetExpectations.inputs))
    $mojangPin=$targetInputs.catalog.mojangVersion
    if([string]$catalog.mojangVersionSha256 -cne [string]$mojangPin.sha256){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_PIN_MISMATCH'}
    $mojangSnapshotPath=Join-Path $repositoryRoot ('compatibility/snapshots/MojangVersions/'+[string]$mojangPin.sha256+'.bin')
    if(-not(Test-Path -LiteralPath $mojangSnapshotPath -PathType Leaf) -or [long](Get-Item -LiteralPath $mojangSnapshotPath).Length -ne [long]$mojangPin.bytes -or (Get-MmtlForgePinFileHash -Path $mojangSnapshotPath) -cne [string]$mojangPin.sha256){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_SNAPSHOT_INVALID'}
    $mojangJson=Get-Content -LiteralPath $mojangSnapshotPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $officialMojangArtifacts=[Collections.Generic.List[object]]::new();foreach($library in $mojangJson.libraries){if($library.downloads.PSObject.Properties['artifact'] -and $library.downloads.artifact){$officialMojangArtifacts.Add($library.downloads.artifact)};if($library.downloads.PSObject.Properties['classifiers'] -and $library.downloads.classifiers){foreach($classifier in $library.downloads.classifiers.PSObject.Properties){$officialMojangArtifacts.Add($classifier.Value)}}};$officialMojangArtifacts=@($officialMojangArtifacts|Sort-Object path -Unique)
    if($officialMojangArtifacts.Count -ne $targetExpectations.mojang){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_LIBRARY_SET_INVALID'}
    $mojangSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $mojangArtifacts){
        $group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$coordinate=$group+':'+$module+':'+$version;$expected=@($officialMojangArtifacts|Where-Object{[string]$_.path -ceq ($group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file)})
        $uri=$null
        if($expected.Count -ne 1 -or -not $mojangSeen.Add($coordinate+':'+$file) -or [string]$artifact.extension -cne 'jar' -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not[Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'libraries.minecraft.net' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne ('/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file) -or [string]$expected[0].url -cne [string]$artifact.url -or [long]$expected[0].size -ne [long]$artifact.bytes -or [string]$expected[0].sha1 -cne [string]$artifact.sha1){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_ARTIFACT_INVALID'}
    }
    if($mojangSeen.Count -ne $officialMojangArtifacts.Count){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_CLOSURE_INCOMPLETE'}
    $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
    if($hash -cne [string]$catalog.catalogHash){throw 'FORGE_GRADLE3_RUNTIME_CATALOG_HASH_MISMATCH'}
    $dynamicVersionResolutions=@(foreach($metadata in $dynamicMetadata){foreach($resolution in @($metadata.resolutions)){[pscustomobject]@{group=[string]$metadata.group;artifact=[string]$metadata.artifact;selector=[string]$resolution.selector;version=[string]$resolution.version}}})
    [pscustomobject]@{catalog=$catalog;catalogHash=$hash;components=$components;artifacts=$artifacts;dynamicVersionResolutions=$dynamicVersionResolutions}
}

function Get-MmtlForgeGradle3RuntimeArtifactMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=180)
    $resolved=Get-MmtlForgeGradle3RuntimeArtifactCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$cache=Join-Path $root 'artifact-cache';$repository=Join-Path $root 'maven-mirror';[void][IO.Directory]::CreateDirectory($cache);[void][IO.Directory]::CreateDirectory($repository)
    foreach($artifact in @($resolved.artifacts)+@($resolved.catalog.supportArtifacts)){
        $hash=[string]$artifact.sha256;$cached=Join-Path $cache $hash
        if(Test-Path -LiteralPath $cached -PathType Leaf){$item=Get-Item -LiteralPath $cached -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cached) -cne $hash){throw 'FORGE_GRADLE3_RUNTIME_CACHE_INVALID'}}
        else{$temporary=Join-Path $cache ('.runtime-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net','libraries.minecraft.net','repo.maven.apache.org');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash){throw 'FORGE_GRADLE3_RUNTIME_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cached)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version);$directory=[IO.Path]::GetFullPath((Join-Path $repository $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $repository -Target $directory)){throw 'FORGE_GRADLE3_RUNTIME_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($directory);$destination=Join-Path $directory ([string]$artifact.file);if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_GRADLE3_RUNTIME_MIRROR_CONFLICT'}}else{[IO.File]::Copy($cached,$destination,$false)}
    }
    foreach($metadata in $resolved.catalog.dynamicMetadata){
        $hash=[string]$metadata.sha256;$cached=Join-Path $cache $hash
        if(Test-Path -LiteralPath $cached -PathType Leaf){$item=Get-Item -LiteralPath $cached -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$metadata.bytes -or (Get-MmtlForgePinFileHash -Path $cached) -cne $hash){throw 'FORGE_GRADLE3_RUNTIME_METADATA_CACHE_INVALID'}}
        else{$temporary=Join-Path $cache ('.metadata-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$metadata.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$metadata.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash){throw 'FORGE_GRADLE3_RUNTIME_METADATA_HASH_MISMATCH'};[IO.File]::Move($temporary,$cached)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $metadataBytes=[IO.File]::ReadAllBytes($cached);try{$metadataXml=[xml][Text.Encoding]::UTF8.GetString($metadataBytes)}catch{throw 'FORGE_GRADLE3_RUNTIME_METADATA_XML_INVALID'}
        if([string]$metadataXml.metadata.groupId -cne [string]$metadata.group -or [string]$metadataXml.metadata.artifactId -cne [string]$metadata.artifact){throw 'FORGE_GRADLE3_RUNTIME_METADATA_IDENTITY_INVALID'}
        $available=@($metadataXml.metadata.versioning.versions.version|ForEach-Object{[string]$_})
        foreach($selector in $metadata.requiredSelectors){$prefix=([string]$selector).TrimEnd('+');if(-not @($available|Where-Object{$_ -like ($prefix+'*')}).Count){throw 'FORGE_GRADLE3_RUNTIME_METADATA_SELECTOR_UNAVAILABLE'}}
        foreach($resolution in @($metadata.resolutions)){if([string]$resolution.version -notin $available){throw 'FORGE_GRADLE3_RUNTIME_METADATA_RESOLUTION_UNAVAILABLE'}}
        $moduleRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path $repository ([string]$metadata.group).Replace('.', [IO.Path]::DirectorySeparatorChar)) ([string]$metadata.artifact)));if(-not(Test-MmtlPlatformPathInsideRoot -Root $repository -Target $moduleRoot)){throw 'FORGE_GRADLE3_RUNTIME_METADATA_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($moduleRoot);$destination=Join-Path $moduleRoot 'maven-metadata.xml';if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_GRADLE3_RUNTIME_METADATA_MIRROR_CONFLICT'}}else{[IO.File]::Copy($cached,$destination,$false)}
    }
    foreach($artifact in $resolved.catalog.mojangArtifacts){
        $hash=[string]$artifact.sha256;$cached=Join-Path $cache $hash
        if(Test-Path -LiteralPath $cached -PathType Leaf){$item=Get-Item -LiteralPath $cached -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cached) -cne $hash -or (Get-FileHash -LiteralPath $cached -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$artifact.sha1){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_CACHE_INVALID'}}
        else{$temporary=Join-Path $cache ('.mojang-library-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('libraries.minecraft.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$artifact.sha1){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cached)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version);$directory=[IO.Path]::GetFullPath((Join-Path $repository $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $repository -Target $directory)){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($directory);$destination=Join-Path $directory ([string]$artifact.file);if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_GRADLE3_RUNTIME_MOJANG_MIRROR_CONFLICT'}}else{[IO.File]::Copy($cached,$destination,$false)}
    }
    [pscustomobject]@{cacheRoot=$root;mirrorRoot=$repository;catalogHash=$resolved.catalogHash;artifactCount=$resolved.artifacts.Count+$resolved.catalog.supportArtifacts.Count+$resolved.catalog.dynamicMetadata.Count+$resolved.catalog.mojangArtifacts.Count;componentCount=$resolved.components.Count;supportArtifactCount=$resolved.catalog.supportArtifacts.Count;dynamicMetadataCount=$resolved.catalog.dynamicMetadata.Count;mojangArtifactCount=$resolved.catalog.mojangArtifacts.Count;dynamicVersionResolutions=$resolved.dynamicVersionResolutions}
}

function Get-MmtlForgeGradle3PinnedMojangArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pin,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=180)
    $minecraftVersion=if($Pin.PSObject.Properties['minecraftId']){[string]$Pin.minecraftId}else{([string]$Pin.targetId -replace '^Forge@','')}
    if([string]$Pin.targetId -notin @('Forge@1.12.2','Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4') -or $minecraftVersion -notin @('1.12.2','1.13.2','1.14.2','1.14.3','1.14.4','1.15','1.15.1','1.15.2','1.16.1','1.16.2','1.16.3','1.16.4') -or [string]$Pin.targetId -cne ('Forge@'+$minecraftVersion)){throw 'FORGE_GRADLE3_MOJANG_PIN_TARGET_INVALID'}
    $root=[IO.Path]::GetFullPath($CacheRoot);$cache=Join-Path $root 'mojang-artifacts';[void][IO.Directory]::CreateDirectory($cache);$records=[Collections.Generic.List[object]]::new()
    foreach($kind in @('client','server')){
        $pinValue=$Pin.$kind;$hash=[string]$pinValue.sha1;$uri=$null
        if($hash -notmatch '^(?i:[a-f0-9]{40})$' -or [long]$pinValue.sizeBytes -le 0 -or -not[Uri]::TryCreate([string]$pinValue.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'piston-data.mojang.com' -or $uri.UserInfo -or $uri.AbsolutePath -cne ('/v1/objects/'+$hash+'/'+$kind+'.jar')){throw "FORGE_GRADLE3_MOJANG_PIN_INVALID:$kind"}
        $destination=Join-Path $cache ($kind+'-'+$hash+'.jar')
        if(Test-Path -LiteralPath $destination -PathType Leaf){$item=Get-Item -LiteralPath $destination -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$pinValue.sizeBytes -or (Get-FileHash -LiteralPath $destination -Algorithm SHA1).Hash.ToLowerInvariant() -cne $hash){throw "FORGE_GRADLE3_MOJANG_CACHE_INVALID:$kind"}}
        else{$temporary=Join-Path $cache ('.'+$kind+'-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri $uri -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('piston-data.mojang.com');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$pinValue.sizeBytes -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash.ToLowerInvariant() -cne $hash){throw "FORGE_GRADLE3_MOJANG_DOWNLOAD_HASH_MISMATCH:$kind"};[IO.File]::Move($temporary,$destination)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $records.Add([pscustomobject]@{kind=$kind;path=$destination;sha1=$hash;sizeBytes=[long]$pinValue.sizeBytes})
    }
    return @($records.ToArray())
}

function Get-MmtlForgeGradle6PinnedMojangArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pin,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=180)
    $targetMatch=[regex]::Match([string]$Pin.targetId,'^Forge@(?<minecraftId>[0-9]+(?:\.[0-9]+){1,2})$')
    if(-not $targetMatch.Success -or [string]$Pin.minecraftId -cne $targetMatch.Groups['minecraftId'].Value){throw 'FORGE_GRADLE6_MOJANG_PIN_TARGET_INVALID'}
    $root=[IO.Path]::GetFullPath($CacheRoot);$cache=Join-Path $root 'mojang-artifacts';[void][IO.Directory]::CreateDirectory($cache);$records=[Collections.Generic.List[object]]::new()
    foreach($kind in @('client','server')){
        $pinValue=$Pin.$kind;$sha1=[string]$pinValue.sha1;$uri=$null
        if($sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [long]$pinValue.sizeBytes -le 0 -or -not[Uri]::TryCreate([string]$pinValue.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'piston-data.mojang.com' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne ('/v1/objects/'+$sha1+'/'+$kind+'.jar')){throw "FORGE_GRADLE6_MOJANG_PIN_INVALID:$kind"}
        $destination=Join-Path $cache ($kind+'-'+$sha1+'.jar')
        if(Test-Path -LiteralPath $destination -PathType Leaf){$item=Get-Item -LiteralPath $destination -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$pinValue.sizeBytes -or (Get-FileHash -LiteralPath $destination -Algorithm SHA1).Hash.ToLowerInvariant() -cne $sha1){throw "FORGE_GRADLE6_MOJANG_CACHE_INVALID:$kind"}}
        else{$temporary=Join-Path $cache ('.'+$kind+'-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri $uri -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('piston-data.mojang.com');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$pinValue.sizeBytes -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash.ToLowerInvariant() -cne $sha1){throw "FORGE_GRADLE6_MOJANG_DOWNLOAD_INVALID:$kind"};[IO.File]::Move($temporary,$destination)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $records.Add([pscustomobject]@{kind=$kind;path=$destination;sha1=$sha1;sizeBytes=[long]$pinValue.sizeBytes;url=[string]$pinValue.url})
    }
    return $records.ToArray()
}

function Get-MmtlForgeGradle6OfflineInitScript {
    [CmdletBinding()]
    param(
        [ValidatePattern('^[0-9]+(?:\.[0-9]+){2}$')][string]$ForgeGradleResolvedVersion='6.0.54',
        [ValidatePattern('^[0-9]+(?:\.[0-9]+){1,2}$')][string]$FoojayResolverVersion='0.7.0'
    )
    $script=@'
gradle.beforeSettings { settings ->
    settings.pluginManagement.repositories.clear()
    settings.pluginManagement.repositories.maven {
        url = new File(settings.settingsDir, '.mmtl-forge-secure/maven-mirror').toURI()
        metadataSources { gradleMetadata(); mavenPom(); artifact() }
    }
    settings.pluginManagement.resolutionStrategy.eachPlugin { details ->
        if (details.requested.id.id == 'net.minecraftforge.gradle') details.useModule('net.minecraftforge.gradle:ForgeGradle:6.0.54')
        if (details.requested.id.id == 'org.gradle.toolchains.foojay-resolver-convention') details.useModule('org.gradle.toolchains:foojay-resolver:0.7.0')
    }
}
gradle.beforeProject { project ->
    def localMirror = new File(project.rootDir, '.mmtl-forge-secure/maven-mirror').toURI()
    project.buildscript.repositories.clear()
    project.buildscript.repositories.maven {
        url = localMirror
        metadataSources { gradleMetadata(); mavenPom(); artifact() }
    }
    project.repositories.clear()
    project.repositories.maven {
        url = localMirror
        metadataSources { gradleMetadata(); mavenPom(); artifact() }
    }
}
'@
    return $script.Replace('net.minecraftforge.gradle:ForgeGradle:6.0.54','net.minecraftforge.gradle:ForgeGradle:'+ $ForgeGradleResolvedVersion).Replace('org.gradle.toolchains:foojay-resolver:0.7.0','org.gradle.toolchains:foojay-resolver:'+$FoojayResolverVersion)
}

function Initialize-MmtlForgeGradle6PinnedProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionRoot,[Parameter(Mandatory)]$Pin,
        [Parameter(Mandatory)][string]$BuildClasspathCatalogPath,[Parameter(Mandatory)][string]$BuildClasspathMirrorRoot,
        [Parameter(Mandatory)][string]$TargetInputCatalogPath,[Parameter(Mandatory)][string]$TargetInputMirrorRoot,
        [Parameter(Mandatory)][string]$MojangVersionJsonPath,[Parameter(Mandatory)][string]$RuntimeCatalogPath,[Parameter(Mandatory)][string]$RuntimeMirrorRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$PinnedMojangArtifacts,[Parameter(Mandatory)][string]$GradleHome
    )
    $targetMatch=[regex]::Match([string]$Pin.targetId,'^Forge@(?<minecraftId>[0-9]+(?:\.[0-9]+){1,2})$')
    $minecraftVersion=if($targetMatch.Success){$targetMatch.Groups['minecraftId'].Value}else{''}
    $resolvedPluginVersion=$null;$minimumPluginVersion=[version]'6.0';$maximumPluginVersion=[version]'6.2'
    if(-not $targetMatch.Success -or [string]$Pin.minecraftId -cne $minecraftVersion -or [string]$Pin.forgeVersion -notmatch ('^'+[regex]::Escape($minecraftVersion)+'-[0-9][A-Za-z0-9.-]*$') -or [string]$Pin.forgeGradleSpec -cne '[6.0,6.2)' -or -not [version]::TryParse([string]$Pin.forgeGradleResolvedVersion,[ref]$resolvedPluginVersion) -or $resolvedPluginVersion -lt $minimumPluginVersion -or $resolvedPluginVersion -ge $maximumPluginVersion){throw 'FORGE_GRADLE6_PIN_IDENTITY_INVALID'}
    $classpath=Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $BuildClasspathCatalogPath
    if([string]$Pin.buildClasspathCatalogHash -cne [string]$classpath.catalogHash){throw 'FORGE_GRADLE6_BUILD_CATALOG_PIN_MISMATCH'}
    $targetInputs=Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $TargetInputCatalogPath
    if([string]$Pin.targetInputCatalogHash -cne [string]$targetInputs.catalogHash){throw 'FORGE_GRADLE6_TARGET_INPUT_CATALOG_PIN_MISMATCH'}
    $runtime=Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $RuntimeCatalogPath
    if([string]$Pin.runtimeArtifactCatalogHash -cne [string]$runtime.catalogHash){throw 'FORGE_GRADLE6_RUNTIME_CATALOG_PIN_MISMATCH'}
    $mojangPin=$targetInputs.catalog.mojangVersion
    if(-not(Test-Path -LiteralPath $MojangVersionJsonPath -PathType Leaf) -or [long](Get-Item -LiteralPath $MojangVersionJsonPath).Length -ne [long]$mojangPin.bytes -or (Get-MmtlForgePinFileHash -Path $MojangVersionJsonPath) -cne [string]$mojangPin.sha256 -or (Get-FileHash -LiteralPath $MojangVersionJsonPath -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$mojangPin.sha1){throw 'FORGE_GRADLE6_MOJANG_VERSION_HASH_MISMATCH'}
    $root=[IO.Path]::GetFullPath($SessionRoot);if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'FORGE_SESSION_ROOT_MISSING'}
    $buildPath=Join-Path $root 'build.gradle';if(-not(Test-Path -LiteralPath $buildPath -PathType Leaf)){throw 'FORGE_BUILD_GRADLE_MISSING'}
    $buildGradleHash=Get-MmtlForgePinFileHash -Path $buildPath
    if($buildGradleHash -cne [string]$Pin.buildGradleSha256){throw 'FORGE_BUILD_GRADLE_HASH_MISMATCH'}
    $wrapperProperties=Join-Path $root 'gradle/wrapper/gradle-wrapper.properties';if(-not(Test-Path -LiteralPath $wrapperProperties -PathType Leaf)){throw 'FORGE_GRADLE_WRAPPER_PROPERTIES_MISSING'}
    $distribution=Get-Content -LiteralPath $wrapperProperties|Where-Object{$_ -match '^distributionUrl='}|Select-Object -First 1
    if(-not$distribution -or ([string]$distribution.Substring('distributionUrl='.Length)).Replace('\:',':') -cne [string]$Pin.gradleDistributionUrl){throw 'FORGE_GRADLE_WRAPPER_DISTRIBUTION_MISMATCH'}
    if(@($PinnedMojangArtifacts).Count -ne 2){throw 'FORGE_GRADLE6_MOJANG_ARTIFACTS_INCOMPLETE'}
    foreach($mirror in @($BuildClasspathMirrorRoot,$TargetInputMirrorRoot,$RuntimeMirrorRoot)){$path=[IO.Path]::GetFullPath($mirror);if(-not(Test-Path -LiteralPath $path -PathType Container)){throw 'FORGE_GRADLE6_MIRROR_MISSING'}}
    $verifyMirrorFile={param([string]$Mirror,[string]$Relative,[long]$Bytes,[string]$Hash)$mirrorRoot=[IO.Path]::GetFullPath($Mirror);$filePath=[IO.Path]::GetFullPath((Join-Path $mirrorRoot $Relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $filePath) -or -not(Test-Path -LiteralPath $filePath -PathType Leaf)){throw 'FORGE_GRADLE6_MIRROR_ARTIFACT_MISSING'};$item=Get-Item -LiteralPath $filePath -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne $Bytes -or (Get-MmtlForgePinFileHash -Path $filePath) -cne $Hash){throw 'FORGE_GRADLE6_MIRROR_ARTIFACT_HASH_MISMATCH'}}
    foreach($artifact in $classpath.artifacts){$relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version);&$verifyMirrorFile $BuildClasspathMirrorRoot (Join-Path $relative ([string]$artifact.file)) ([long]$artifact.bytes) ([string]$artifact.sha256)}
    foreach($artifact in $targetInputs.artifacts){$relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version);&$verifyMirrorFile $TargetInputMirrorRoot (Join-Path $relative ([string]$artifact.file)) ([long]$artifact.bytes) ([string]$artifact.sha256)}
    foreach($artifact in $runtime.mavenArtifacts){$relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version);&$verifyMirrorFile $RuntimeMirrorRoot (Join-Path $relative ([string]$artifact.file)) ([long]$artifact.bytes) ([string]$artifact.sha256);&$verifyMirrorFile $RuntimeMirrorRoot (Join-Path $relative ([string]$artifact.pom.file)) ([long]$artifact.pom.bytes) ([string]$artifact.pom.sha256)}
    foreach($artifact in @($runtime.supportPoms)+@($runtime.moduleMetadata)){$relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version);&$verifyMirrorFile $RuntimeMirrorRoot (Join-Path $relative ([string]$artifact.file)) ([long]$artifact.bytes) ([string]$artifact.sha256)}
    foreach($artifact in $runtime.dynamicCandidates){$relative=Join-Path (Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version)) ([string]$artifact.file);&$verifyMirrorFile $RuntimeMirrorRoot $relative ([long]$artifact.bytes) ([string]$artifact.sha256)}
    foreach($artifact in $runtime.dynamicMetadata){$relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) 'maven-metadata.xml';&$verifyMirrorFile $RuntimeMirrorRoot $relative ([long]$artifact.bytes) ([string]$artifact.sha256)}
    foreach($artifact in $runtime.catalog.mojangArtifacts){$uri=[Uri][string]$artifact.url;$relative=$uri.AbsolutePath.TrimStart('/').Replace('/',[IO.Path]::DirectorySeparatorChar);&$verifyMirrorFile $RuntimeMirrorRoot $relative ([long]$artifact.bytes) ([string]$artifact.sha256);$mojangPath=Join-Path $RuntimeMirrorRoot $relative;if((Get-FileHash -LiteralPath $mojangPath -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$artifact.sha1){throw 'FORGE_GRADLE6_MIRROR_MOJANG_SHA1_MISMATCH'}}

    $secureRoot=Join-Path $root '.mmtl-forge-secure';$repository=Join-Path $secureRoot 'maven-mirror';[void][IO.Directory]::CreateDirectory($repository)
    foreach($mirrorRoot in @($BuildClasspathMirrorRoot,$TargetInputMirrorRoot,$RuntimeMirrorRoot)){
        $sourceRoot=[IO.Path]::GetFullPath($mirrorRoot)
        foreach($source in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop){
            if(($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $source.LinkType){throw 'FORGE_GRADLE6_MIRROR_REPARSE_PATH'}
            $relative=[IO.Path]::GetRelativePath($sourceRoot,$source.FullName);$destination=[IO.Path]::GetFullPath((Join-Path $repository $relative))
            if(-not(Test-MmtlPlatformPathInsideRoot -Root $repository -Target $destination)){throw 'FORGE_GRADLE6_MIRROR_PATH_ESCAPE'}
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination));$sourceHash=(Get-MmtlForgePinFileHash -Path $source.FullName)
            if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $sourceHash){throw 'FORGE_GRADLE6_MIRROR_COLLISION'}}else{[IO.File]::Copy($source.FullName,$destination,$false)}
        }
    }
    $buildSource=[IO.File]::ReadAllText($buildPath);$pluginLine=[regex]::Matches($buildSource,'(?m)^[\t ]*id\s+["'']net\.minecraftforge\.gradle["'']\s+version\s+["'']\[6\.0,6\.2\)["''][\t ]*(?:\r?\n|$)')
    if($pluginLine.Count -ne 1){throw 'FORGE_GRADLE6_PLUGIN_DECLARATION_SHAPE_INVALID'}
    $settingsPath=Join-Path $root 'settings.gradle';if(-not(Test-Path -LiteralPath $settingsPath -PathType Leaf)){throw 'FORGE_GRADLE6_SETTINGS_GRADLE_MISSING'}
    $settingsText=[IO.File]::ReadAllText($settingsPath)
    if($settingsText -notmatch '(?m)^\s*pluginManagement\s*\{' -or $settingsText -notmatch '(?m)^\s*plugins\s*\{\s*$'){throw 'FORGE_GRADLE6_SETTINGS_SHAPE_INVALID'}
    $settingsBlock=[regex]::Matches($settingsText,'(?sm)pluginManagement\s*\{.*?^\}\s*\r?\n\s*plugins\s*\{.*?^\}\s*\r?\n?')
    if($settingsBlock.Count -ne 1){throw 'FORGE_GRADLE6_SETTINGS_SHAPE_INVALID'}
    $settingsReplacement=@"
pluginManagement {
    repositories { maven { url = uri(new File(settingsDir, '.mmtl-forge-secure/maven-mirror')) } }
    resolutionStrategy {
        eachPlugin {
            if (requested.id.id == 'net.minecraftforge.gradle') useModule('net.minecraftforge.gradle:ForgeGradle:__MMTL_FORGE_GRADLE_VERSION__')
            if (requested.id.id == 'org.gradle.toolchains.foojay-resolver-convention') useModule('org.gradle.toolchains:foojay-resolver:__MMTL_FOOJAY_VERSION__')
        }
    }
}
"@
    $settingsReplacement=$settingsReplacement.Replace('__MMTL_FORGE_GRADLE_VERSION__',[string]$Pin.forgeGradleResolvedVersion)
    $settingsReplacement=$settingsReplacement.Replace('__MMTL_FOOJAY_VERSION__',[string]$classpath.foojayResolverVersion)
    $settingsPatched=$settingsText.Remove($settingsBlock[0].Index,$settingsBlock[0].Length).Insert($settingsBlock[0].Index,$settingsReplacement.Trim()+"`n")
    [IO.File]::WriteAllText($settingsPath,$settingsPatched,[Text.UTF8Encoding]::new($false))
    $line=$pluginLine[0];$newline=if($buildSource.Contains("`r`n")){"`r`n"}else{"`n"};$buildPatched=$buildSource.Remove($line.Index,$line.Length).Insert($line.Index,"id 'net.minecraftforge.gradle'"+$newline)
    [IO.File]::WriteAllText($buildPath,$buildPatched,[Text.UTF8Encoding]::new($false))
    $gradleHomePath=[IO.Path]::GetFullPath($GradleHome);[void][IO.Directory]::CreateDirectory($gradleHomePath)
    foreach($mojang in $PinnedMojangArtifacts){$kind=[string]$mojang.kind;if($kind -notin @('client','server')){throw 'FORGE_GRADLE6_MOJANG_ARTIFACT_KIND_INVALID'};$expected=$Pin.$kind;if([string]$mojang.sha1 -cne [string]$expected.sha1 -or [long]$mojang.sizeBytes -ne [long]$expected.sizeBytes -or (Get-FileHash -LiteralPath $mojang.path -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$expected.sha1){throw "FORGE_GRADLE6_MOJANG_ARTIFACT_INVALID:$kind"};$artifactName=if($kind -eq 'client'){'minecraft'}else{'minecraft_server'};$cachePath=Join-Path $gradleHomePath ("caches/minecraft/net/minecraft/$artifactName/$minecraftVersion/$artifactName-$minecraftVersion.jar");[void][IO.Directory]::CreateDirectory((Split-Path -Parent $cachePath));if(Test-Path -LiteralPath $cachePath -PathType Leaf){if((Get-FileHash -LiteralPath $cachePath -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$expected.sha1){throw "FORGE_GRADLE6_MOJANG_GRADLE_CACHE_CONFLICT:$kind"}}else{[IO.File]::Copy([string]$mojang.path,$cachePath,$false)}}
    $mojangDirectory=Join-Path $secureRoot 'mojang';[void][IO.Directory]::CreateDirectory($mojangDirectory)
    foreach($kind in @('client','server')){$artifactName=if($kind -eq 'client'){'minecraft'}else{'minecraft_server'};$source=Join-Path (Join-Path (Join-Path $gradleHomePath 'caches/minecraft/net/minecraft') (Join-Path $artifactName $minecraftVersion)) ($artifactName+'-'+$minecraftVersion+'.jar');[IO.File]::Copy($source,(Join-Path $mojangDirectory ($kind+'.jar')),$true)}
    [IO.File]::Copy([IO.Path]::GetFullPath($MojangVersionJsonPath),(Join-Path $mojangDirectory ($minecraftVersion+'.json')),$true)
    $initPath=Join-Path $secureRoot 'forge-gradle6-offline.init.gradle'
    $initScript=Get-MmtlForgeGradle6OfflineInitScript -ForgeGradleResolvedVersion ([string]$Pin.forgeGradleResolvedVersion) -FoojayResolverVersion ([string]$classpath.foojayResolverVersion)
    [IO.File]::WriteAllText($initPath,$initScript.Trim()+"`n",[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{buildScriptPath=$buildPath;buildScriptSha256Before=[string]$Pin.buildGradleSha256;buildScriptSha256After=(Get-MmtlForgePinFileHash -Path $buildPath);settingsPath=$settingsPath;settingsSha256After=(Get-MmtlForgePinFileHash -Path $settingsPath);initScriptPath=$initPath;requiresOffline=$false;preparationTasks=@();additionalArguments=@();gradleHome=$gradleHomePath;repositoryPath=$repository;mojangDirectory=$mojangDirectory;minecraftVersion=$minecraftVersion;client=$Pin.client;server=$Pin.server;buildClasspathCatalogHash=$classpath.catalogHash;buildClasspathArtifactCount=$classpath.artifacts.Count;targetInputCatalogHash=$targetInputs.catalogHash;targetInputArtifactCount=$targetInputs.artifacts.Count;runtimeArtifactCatalogHash=$runtime.catalogHash;runtimeArtifactCount=($runtime.mavenArtifacts.Count+$runtime.components.Count+$runtime.supportPoms.Count+$runtime.moduleMetadata.Count+$runtime.dynamicMetadata.Count+$runtime.dynamicCandidates.Count+$runtime.catalog.mojangArtifacts.Count);mojangVersionHash=[string]$targetInputs.catalog.mojangVersion.sha256}
}

function Get-MmtlForgeGradle3BuildClasspathArtifactCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $expectedDependencies=@(
        'dev.gradleplugins:gradle-api:4.9','com.cloudbees:diff4j:1.2','commons-io:commons-io:2.4',
        'com.github.jponge:lzma-java:1.3','com.nothome:javaxdelta:2.0.1','com.google.code.gson:gson:2.8.5',
        'com.google.guava:guava:26.0-jre','de.siegmar:fastcsv:1.0.2','net.minecraftforge:artifactural:1.0.13',
        'org.apache.maven:maven-artifact:3.6.0','org.apache.httpcomponents:httpclient:4.3.3',
        'net.minecraftforge:srgutils:0.2.12','net.minecraftforge:legacydev:0.2.3.1'
    )
    $expectedDynamics=@('net.minecraftforge:artifactural:1.0.+:1.0.13','net.minecraftforge:legacydev:0.2.3.+:0.2.3.1')
    if([string]$catalog.targetId -in @('Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4')){
        $expectedDependencies=@($expectedDependencies|Where-Object{$_ -notmatch ':legacydev:'})
        $expectedDynamics=@('net.minecraftforge:artifactural:1.0.+:1.0.13')
        $expectedResolver='ForgeGradle 3.0.197 buildscript closure'
    }else{$expectedResolver='ForgeGradle 3.0.197 buildscript closure plus userdev3 dynamic legacydev resolution'}
    if([int]$catalog.schemaVersion -ne 1 -or [string]$catalog.targetId -notin @('Forge@1.12.2','Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4') -or [string]$catalog.rootCoordinate -cne 'net.minecraftforge.gradle:ForgeGradle:3.0.197' -or [string]$catalog.resolver -cne $expectedResolver -or [string]$catalog.artifactStatus -cne 'HashesVerified'){throw 'FORGE_GRADLE3_CLASSPATH_CATALOG_IDENTITY_INVALID'}
    $dependencies=@($catalog.dependencies);$artifacts=@($catalog.artifacts);$dynamic=@($catalog.dynamicVersionResolutions)
    $actualDependencies=@($dependencies|ForEach-Object{[string]$_.group+':'+[string]$_.artifact+':'+[string]$_.version}|Sort-Object -Unique)
    $expectedArtifactCount=if([string]$catalog.targetId -in @('Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4')){193}else{195};$expectedDynamicCount=$expectedDynamics.Count
    if($dependencies.Count -ne $expectedDependencies.Count -or ($actualDependencies -join "`n") -cne (($expectedDependencies|Sort-Object -Unique) -join "`n") -or $artifacts.Count -ne $expectedArtifactCount -or $dynamic.Count -ne $expectedDynamicCount){throw 'FORGE_GRADLE3_CLASSPATH_CATALOG_INCOMPLETE'}
    $actualDynamics=@($dynamic|ForEach-Object{[string]$_.group+':'+[string]$_.artifact+':'+[string]$_.selector+':'+[string]$_.resolvedVersion}|Sort-Object -Unique)
    if(($actualDynamics -join "`n") -cne (($expectedDynamics|Sort-Object -Unique) -join "`n")){throw 'FORGE_GRADLE3_DYNAMIC_VERSION_RESOLUTION_INVALID'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $artifacts){
        $group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$extension=[string]$artifact.extension
        $expectedFile=$module+'-'+$version+$(if($module -ceq 'legacydev' -and $extension -ceq 'jar'){'-fatjar'}else{''})+'.'+$extension
        $isMojangNativeJar=$extension -ceq 'jar' -and $file -match ('^'+[regex]::Escape($module+'-'+$version)+'-natives-(windows|linux|osx)(-\d+)?\.jar$')
        $isForgeMergetoolJar=$group -ceq 'net.minecraftforge' -and $module -ceq 'mergetool' -and $version -ceq '1.0.13' -and $extension -ceq 'jar' -and $file -ceq 'mergetool-1.0.13-forge.jar'
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or ($file -cne $expectedFile -and -not $isMojangNativeJar -and -not $isForgeMergetoolJar) -or $extension -notin @('jar','pom') -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_GRADLE3_CLASSPATH_ARTIFACT_INVALID'}
        $uri=$null;if(-not [Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -notin @('maven.minecraftforge.net','libraries.minecraft.net','repo.maven.apache.org') -or $uri.UserInfo){throw 'FORGE_GRADLE3_CLASSPATH_ARTIFACT_URL_INVALID'}
        $expectedPath='/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file
        if($uri.Host -ceq 'repo.maven.apache.org'){$expectedPath='/maven2'+$expectedPath}
        if($uri.AbsolutePath -cne $expectedPath){throw 'FORGE_GRADLE3_CLASSPATH_ARTIFACT_COORDINATE_MISMATCH'}
        if(-not $seen.Add($group+':'+$module+':'+$version+':'+$file)){throw 'FORGE_GRADLE3_CLASSPATH_ARTIFACT_DUPLICATE'}
    }
    foreach($dependency in $dependencies){$coordinate=[string]$dependency.group+':'+[string]$dependency.artifact+':'+[string]$dependency.version;$match=@($artifacts|Where-Object{[string]$_.group+':'+[string]$_.artifact+':'+[string]$_.version -ceq $coordinate -and [string]$_.extension -ceq 'jar'});if($match.Count -ne 1){throw 'FORGE_GRADLE3_CLASSPATH_DEPENDENCY_ARTIFACT_MISSING'}}
    $core=[ordered]@{schemaVersion=[int]$catalog.schemaVersion;targetId=[string]$catalog.targetId;rootCoordinate=[string]$catalog.rootCoordinate;resolver=[string]$catalog.resolver;artifactStatus=[string]$catalog.artifactStatus;dependencies=$dependencies;artifacts=$artifacts;dynamicVersionResolutions=$dynamic}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
    if($hash -cne [string]$catalog.catalogHash){throw 'FORGE_GRADLE3_CLASSPATH_CATALOG_HASH_MISMATCH'}
    [pscustomobject]@{catalog=$catalog;catalogHash=$hash;dependencies=$dependencies;artifacts=$artifacts;dynamicVersionResolutions=$dynamic}
}

function Get-MmtlForgeGradle6BuildClasspathArtifactCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $targetMatch=[regex]::Match([string]$catalog.targetId,'^Forge@(?<minecraftId>[0-9]+(?:\.[0-9]+){1,2})$');$resolvedForgeGradleVersion=$null
    $schemaVersion=[int]$catalog.schemaVersion
    if($schemaVersion -eq 2){
        $modernTargets=@{
            'Forge@1.18.2'=@{forge='1.18.2-40.3.11';gradle='8.8';java=17;foojay='0.7.0';mdk='06dc30e30b148d33e36e1c24f47c985e46ae669556f2060d750a141264bcdc26';distribution='https://services.gradle.org/distributions/gradle-8.8-bin.zip';distributionSha256='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612'}
            'Forge@1.19.2'=@{forge='1.19.2-43.5.1';gradle='8.8';java=17;foojay='0.7.0';mdk='145514b3e54c78c05fb7e6d8bbc22c5ab63b1155a31415478b454e53baffd90e';distribution='https://services.gradle.org/distributions/gradle-8.8-bin.zip';distributionSha256='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612'}
            'Forge@1.19.4'=@{forge='1.19.4-45.4.1';gradle='8.8';java=17;foojay='0.7.0';mdk='9af67ea5ac56c0113dce53d879cbe4f38a0b1b45542e7488c8757b3509b963ae';distribution='https://services.gradle.org/distributions/gradle-8.8-bin.zip';distributionSha256='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612'}
            'Forge@1.20'=@{forge='1.20-46.0.14';gradle='8.1.1';java=17;foojay='0.5.0';mdk='a7a0cc82e28092fc069dfecb689212a6e36203a6ce9e1548c871b3f445e36d7f';distribution='https://services.gradle.org/distributions/gradle-8.1.1-bin.zip';distributionSha256='e111cb9948407e26351227dabce49822fb88c37ee72f1d1582a69c68af2e702f'}
            'Forge@1.20.1'=@{forge='1.20.1-47.4.5';gradle='8.8';java=17;foojay='0.7.0';mdk='3a55c4c6cb66420d69f5d99858da222272fea19592077cd60652143c188360fc';distribution='https://services.gradle.org/distributions/gradle-8.8-bin.zip';distributionSha256='a4b4158601f8636cdeeab09bd76afb640030bb5b144aafe261a5e8af027dc612'}
        }
        $pin=$modernTargets[[string]$catalog.targetId]
        if(-not $pin -or [string]$catalog.forgeVersion -cne $pin.forge -or [string]$catalog.gradleVersion -cne $pin.gradle -or [int]$catalog.buildJavaMajor -ne $pin.java -or [string]$catalog.foojayResolverVersion -cne $pin.foojay -or [string]$catalog.mdkSha256 -cne $pin.mdk -or [string]$catalog.gradleDistributionUrl -cne $pin.distribution -or [string]$catalog.gradleDistributionSha256 -cne $pin.distributionSha256){throw 'FORGE_GRADLE6_CLASSPATH_CATALOG_TARGET_PIN_MISMATCH'}
    }
    if($schemaVersion -notin @(1,2) -or -not $targetMatch.Success -or [string]$catalog.forgeVersion -notmatch ('^'+[regex]::Escape($targetMatch.Groups['minecraftId'].Value)+'-[0-9][A-Za-z0-9.-]*$') -or [string]$catalog.forgeGradleSpec -cne '[6.0,6.2)' -or -not [version]::TryParse([string]$catalog.forgeGradleResolvedVersion,[ref]$resolvedForgeGradleVersion) -or $resolvedForgeGradleVersion -lt [version]'6.0' -or $resolvedForgeGradleVersion -ge [version]'6.2' -or [string]$catalog.gradleVersion -notmatch '^[0-9]+(?:\.[0-9]+){1,2}$' -or [int]$catalog.buildJavaMajor -lt 8 -or [int]$catalog.buildJavaMajor -gt 25 -or [string]$catalog.artifactStatus -cne 'HashesVerified'){throw 'FORGE_GRADLE6_CLASSPATH_CATALOG_IDENTITY_INVALID'}
    $dependencies=@($catalog.dependencies);$artifacts=@($catalog.artifacts)
    if($dependencies.Count -lt 2 -or $artifacts.Count -lt $dependencies.Count){throw 'FORGE_GRADLE6_CLASSPATH_CATALOG_INCOMPLETE'}
    $dependencySeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($dependency in $dependencies){$scope=[string]$dependency.scope;$group=[string]$dependency.group;$module=[string]$dependency.artifact;$version=[string]$dependency.version;$coordinate="$group`:$module`:$version";if($scope -notin @('project-plugin','settings-plugin') -or $group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or -not $dependencySeen.Add($scope+'|'+$coordinate)){throw 'FORGE_GRADLE6_CLASSPATH_DEPENDENCY_INVALID'}}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $artifacts){
        $group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$extension=[string]$artifact.extension
        $uri=$null
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $file -notmatch '^[A-Za-z0-9_.+-]+\.(?:jar|pom)$' -or $extension -notin @('jar','pom') -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not [Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -notin @('maven.minecraftforge.net','plugins.gradle.org','repo.maven.apache.org') -or $uri.UserInfo){throw 'FORGE_GRADLE6_CLASSPATH_ARTIFACT_INVALID'}
        if($extension -eq 'jar' -and -not $file.EndsWith('.jar',[StringComparison]::Ordinal) -or $extension -eq 'pom' -and -not $file.EndsWith('.pom',[StringComparison]::Ordinal)){throw 'FORGE_GRADLE6_CLASSPATH_ARTIFACT_INVALID'}
        $relativePath='/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file
        if($uri.Host -ceq 'plugins.gradle.org'){$relativePath='/m2'+$relativePath}elseif($uri.Host -ceq 'repo.maven.apache.org'){$relativePath='/maven2'+$relativePath}
        if($uri.AbsolutePath -cne $relativePath -or ($group.StartsWith('net.minecraftforge') -and $uri.Host -cne 'maven.minecraftforge.net') -or ($group.StartsWith('org.gradle.toolchains') -and $uri.Host -cne 'plugins.gradle.org') -or (-not $group.StartsWith('net.minecraftforge') -and -not $group.StartsWith('org.gradle.toolchains') -and $uri.Host -notin @('repo.maven.apache.org','plugins.gradle.org'))){throw 'FORGE_GRADLE6_CLASSPATH_ARTIFACT_URL_INVALID'}
        if(-not $seen.Add($group+':'+$module+':'+$version+':'+$file)){throw 'FORGE_GRADLE6_CLASSPATH_ARTIFACT_DUPLICATE'}
    }
    foreach($dependency in $dependencies){$coordinate=[string]$dependency.group+':'+[string]$dependency.artifact+':'+[string]$dependency.version;if(@($artifacts|Where-Object{[string]$_.group+':'+[string]$_.artifact+':'+[string]$_.version -ceq $coordinate -and [string]$_.extension -ceq 'jar'}).Count -ne 1){throw 'FORGE_GRADLE6_CLASSPATH_DEPENDENCY_ARTIFACT_MISSING'}}
    $forgePluginMarker=@($artifacts|Where-Object{[string]$_.group -ceq 'net.minecraftforge.gradle' -and [string]$_.artifact -ceq 'net.minecraftforge.gradle.gradle.plugin' -and [string]$_.extension -ceq 'pom'})
    $foojayPluginMarker=@($artifacts|Where-Object{[string]$_.group -ceq 'org.gradle.toolchains.foojay-resolver-convention' -and [string]$_.artifact -ceq 'org.gradle.toolchains.foojay-resolver-convention.gradle.plugin' -and [string]$_.extension -ceq 'pom'})
    if($forgePluginMarker.Count -ne 1 -or [string]$forgePluginMarker[0].version -cne [string]$catalog.forgeGradleResolvedVersion -or $foojayPluginMarker.Count -ne 1 -or [string]$foojayPluginMarker[0].version -notmatch '^[0-9]+(?:\.[0-9]+){1,2}$'){throw 'FORGE_GRADLE6_PLUGIN_MARKER_MISSING'}
    $requiredPluginDependencies=@()
    $requiredPluginDependencies+=@{scope='project-plugin';coordinate='net.minecraftforge.gradle:ForgeGradle:'+ [string]$catalog.forgeGradleResolvedVersion}
    $requiredPluginDependencies+=@{scope='settings-plugin';coordinate='org.gradle.toolchains:foojay-resolver:'+ [string]$foojayPluginMarker[0].version}
    foreach($required in $requiredPluginDependencies){$matches=@($dependencies|Where-Object{[string]$_.scope -ceq $required.scope -and ([string]$_.group+':'+[string]$_.artifact+':'+[string]$_.version) -ceq $required.coordinate});if($matches.Count -ne 1){throw 'FORGE_GRADLE6_REQUIRED_PLUGIN_DEPENDENCY_MISSING'}}
    $requiredPluginPoms=@()
    $requiredPluginPoms+='net.minecraftforge.gradle:ForgeGradle:'+ [string]$catalog.forgeGradleResolvedVersion
    $requiredPluginPoms+='org.gradle.toolchains:foojay-resolver:'+ [string]$foojayPluginMarker[0].version
    foreach($coordinate in $requiredPluginPoms){if(@($artifacts|Where-Object{([string]$_.group+':'+[string]$_.artifact+':'+[string]$_.version) -ceq $coordinate -and [string]$_.extension -ceq 'pom'}).Count -ne 1){throw 'FORGE_GRADLE6_PLUGIN_POM_MISSING'}}
    if($schemaVersion -eq 1){$core=[ordered]@{schemaVersion=[int]$catalog.schemaVersion;targetId=[string]$catalog.targetId;forgeVersion=[string]$catalog.forgeVersion;forgeGradleSpec=[string]$catalog.forgeGradleSpec;forgeGradleResolvedVersion=[string]$catalog.forgeGradleResolvedVersion;gradleVersion=[string]$catalog.gradleVersion;buildJavaMajor=[int]$catalog.buildJavaMajor;artifactStatus=[string]$catalog.artifactStatus;dependencies=$dependencies;artifacts=$artifacts}}
    else{$core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
    if($hash -cne [string]$catalog.catalogHash){throw 'FORGE_GRADLE6_CLASSPATH_CATALOG_HASH_MISMATCH'}
    if($schemaVersion -eq 2 -and [string]$foojayPluginMarker[0].version -cne [string]$catalog.foojayResolverVersion){throw 'FORGE_GRADLE6_CLASSPATH_CATALOG_TARGET_PIN_MISMATCH'}
    [pscustomobject]@{catalog=$catalog;catalogHash=$hash;dependencies=$dependencies;artifacts=$artifacts;foojayResolverVersion=[string]$foojayPluginMarker[0].version}
}

function Get-MmtlForgeBuildClasspathArtifactCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if([string]$catalog.targetId -ceq 'Forge@1.16.5'){return Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $CatalogPath}
    if([string]$catalog.targetId -in @('Forge@1.12.2','Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4')){return Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $CatalogPath}
    $targetSpecs=@{
        'Forge@1.8.8'=[pscustomobject]@{minecraft='1.8.8';resolver='ForgeGradle 2.1 POM compile dependency union plus pinned Mojang 1.8.8 and Forge UserDev development libraries';mojangUrl='https://piston-meta.mojang.com/v1/packages/690172f1227e1c1d2fa8fceadd0f578f7851a69e/1.8.8.json';mojangBytes=18243L;mojangSha256='7f002c1dca74cc51ce995e7fdb465ab4984c940e77a1b1c4f2b09bed8702e558';mojangSha1='690172f1227e1c1d2fa8fceadd0f578f7851a69e';forgeVersion='1.8.8-11.15.0.1655';devJsonBytes=7483L;devJsonSha256='6260944d8e1619da5553ae8bb04e1353eb878d2fd1415e7478ae334dfe60cb44';devLibraryCount=54;mojangLibraryCount=29;devOnlyLibraryCount=17;requiredLibraryCount=46;mcpMapping='stable_20';mcpStableMappingVersion='20';mcpVersion='1.8.8';mcpFile='mcp-1.8.8-srg.zip';mcpBytes=473788L;mcpSha256='c52c6479413a3779fc745553fa1ca5de17ac0982a6cb1accfff841f93ccc93eb';mcpStableVersion='20-1.8.8';mcpStableFile='mcp_stable-20-1.8.8.zip';mcpStableBytes=270192L;mcpStableSha256='dce44b85a3c1d731cfc4ad7325d55497515137641c4a9148c6fca9f1664cfb71';mcpSnapshotVersion='20151122-1.8';mcpSnapshotMinecraft='1.8';mcpSnapshotFile='mcp_snapshot-20151122-1.8.zip';mcpSnapshotBytes=278552L;mcpSnapshotSha256='41e4a56901b39df2db48c4f22332b9a2c365737ce7e75466117b3609098386a3'}
        'Forge@1.8.9'=[pscustomobject]@{minecraft='1.8.9';resolver='ForgeGradle 2.1 POM compile dependency union plus pinned Mojang 1.8.9 and Forge UserDev development libraries';mojangUrl='https://piston-meta.mojang.com/v1/packages/d546f1707a3f2b7d034eece5ea2e311eda875787/1.8.9.json';mojangBytes=18244L;mojangSha256='341af5f47a6b5bc137bfe681f4f3533e081041290aabbf9d7ebeae9881de768f';mojangSha1='d546f1707a3f2b7d034eece5ea2e311eda875787';forgeVersion='1.8.9-11.15.1.2318-1.8.9';devJsonBytes=2798L;devJsonSha256='47adbb996168cd35aa54931d1ca50b8dc172e8c78321fcc1e9cec0dd04f14629';devLibraryCount=18;mojangLibraryCount=29;devOnlyLibraryCount=17;requiredLibraryCount=46;mcpMapping='stable_22';mcpStableMappingVersion='22';mcpVersion='1.8.9';mcpFile='mcp-1.8.9-srg.zip';mcpBytes=471509L;mcpSha256='ea6fdd37e68569a378fd149b0ab7cfede1de7fa3e794f4ed81f9018366fbdc51';mcpStableVersion='22-1.8.9';mcpStableFile='mcp_stable-22-1.8.9.zip';mcpStableBytes=282686L;mcpStableSha256='aeed0aaba9d159b7ce60a21e2dcc36adb249fade65ce2f76c730dd0ec7270763'}
        'Forge@1.9'=[pscustomobject]@{minecraft='1.9';resolver='ForgeGradle 2.1 POM compile dependency union plus pinned Mojang 1.9 and Forge UserDev development libraries';mojangUrl='https://piston-meta.mojang.com/v1/packages/9178828493e41a24452841039710f05728c466d6/1.9.json';mojangBytes=15752L;mojangSha256='8d6f1e7f3a99f1236914b61e64eeade955ba21e8150563457142d3981aeee688';mojangSha1='9178828493e41a24452841039710f05728c466d6';forgeVersion='1.9-12.16.1.1938-1.9.0';devJsonBytes=2796L;devJsonSha256='4fc7474ffb66100fd8604f705ed099254fe12274b72e084787945bb03673417d';devLibraryCount=18;mojangLibraryCount=28;devOnlyLibraryCount=17;requiredLibraryCount=45;mcpMapping='stable_24';mcpStableMappingVersion='24';mcpVersion='1.9';mcpFile='mcp-1.9-srg.zip';mcpBytes=665494L;mcpSha256='706f479571c79dd662319c449901fdf3ff17b1e65b78ba322302b9223f21c890';mcpStableVersion='24-1.9';mcpStableFile='mcp_stable-24-1.9.zip';mcpStableBytes=334162L;mcpStableSha256='0de05247bcce00378654420acc41a18bf8a634a6596c5113c4d41a38880859c6';mcpSnapshotVersion='20160312-1.9';mcpSnapshotMinecraft='1.9';mcpSnapshotFile='mcp_snapshot-20160312-1.9.zip';mcpSnapshotBytes=307451L;mcpSnapshotSha256='d81da4f9c200930eef565e8ef1d7a1ac869dba157ca22de9988365aa60bfa592'}
        'Forge@1.10'=[pscustomobject]@{minecraft='1.10';rootCoordinate='net.minecraftforge.gradle:ForgeGradle:2.2-SNAPSHOT';resolver='ForgeGradle 2.2 POM compile dependency union plus pinned Mojang 1.10, Forge UserDev development libraries and exact ForgeGradle Minecraft compile classpath';mojangUrl='https://piston-meta.mojang.com/v1/packages/a827abf9c022a08ed9c4c7807a8c1b7f2f05deca/1.10.json';mojangBytes=16081L;mojangSha256='462441ee38c35c6ad52ffe2ab668b217eb2b29b51de25f1774a454560bc3a261';mojangSha1='a827abf9c022a08ed9c4c7807a8c1b7f2f05deca';forgeVersion='1.10-12.18.0.2000-1.10.0';devJsonBytes=2693L;devJsonSha256='dabefe42326448e5380461c8178285c49a3787142f7191125e3689d8a692b855';devLibraryCount=18;mojangLibraryCount=29;devOnlyLibraryCount=18;forgeMcLibraryCoordinate='com.google.code.findbugs:jsr305:3.0.1';forgeMcLibraryBytes=19943L;forgeMcLibrarySha1='f7be08ec23c21485b9b5a1cf1654c2ec8c58168d';forgeMcLibrarySha256='c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd';requiredLibraryCount=48;mcpMapping='snapshot_20160518';mcpStableMappingVersion='26';mcpVersion='1.10';mcpFile='mcp-1.10-srg.zip';mcpBytes=683341L;mcpSha256='1068b0fbaae07d10c4848606c835ad4deca90a4f2629d09bfa6ca266dbd05712';mcpStableVersion='26-1.9.4';mcpStableFile='mcp_stable-26-1.9.4.zip';mcpStableBytes=330968L;mcpStableSha256='79c17c99e5a6a9ce92b4e2677abdec8ef5a13a6c38d89300aa29fd124504a005';mcpSnapshotVersion='20160518-1.9.4';mcpSnapshotMinecraft='1.9.4';mcpSnapshotFile='mcp_snapshot-20160518-1.9.4.zip';mcpSnapshotBytes=329977L;mcpSnapshotSha256='16f933fe337c265ed20fd616a2acadbd119a0b1d1fb186ca26fc8964aeebe0c2'}
        'Forge@1.11'=[pscustomobject]@{minecraft='1.11';rootCoordinate='net.minecraftforge.gradle:ForgeGradle:2.2-SNAPSHOT';resolver='ForgeGradle 2.2 POM compile dependency union plus pinned Mojang 1.11, Forge UserDev development libraries and exact ForgeGradle Minecraft compile classpath';mojangUrl='https://piston-meta.mojang.com/v1/packages/935062464617c9904d20045065515cfd3f1b76d2/1.11.json';mojangBytes=16086L;mojangSha256='a77e2568ef2f6733064c394eb40a7f1d8ca8ed48c56ee17cb6c720aeaf0118f4';mojangSha1='935062464617c9904d20045065515cfd3f1b76d2';forgeVersion='1.11-13.19.1.2199';devJsonBytes=2693L;devJsonSha256='2d8296b4a90776cbad99d12ec6b28b3712a828954959612abb2ef15eec7a0a4c';devLibraryCount=18;mojangLibraryCount=29;devOnlyLibraryCount=18;forgeMcLibraryCoordinate='com.google.code.findbugs:jsr305:3.0.1';forgeMcLibraryBytes=19943L;forgeMcLibrarySha1='f7be08ec23c21485b9b5a1cf1654c2ec8c58168d';forgeMcLibrarySha256='c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd';requiredLibraryCount=48;mcpMapping='snapshot_20161220';mcpStableMappingVersion='32';mcpVersion='1.11';mcpFile='mcp-1.11-srg.zip';mcpBytes=708468L;mcpSha256='9346e52ec542a990ea18722a7ff61a208b14796ba4a117bf0a1a043dee3cfc7c';mcpStableVersion='32-1.11';mcpStableFile='mcp_stable-32-1.11.zip';mcpStableBytes=350621L;mcpStableSha256='a4878373319ec0b86c53305001c251637570b3673c9c1f4e643405533cac9014';mcpSnapshotVersion='20161220-1.11';mcpSnapshotMinecraft='1.11';mcpSnapshotFile='mcp_snapshot-20161220-1.11.zip';mcpSnapshotBytes=342912L;mcpSnapshotSha256='755416d68281e0c6998fc743929f36e14563510467d1c749d4bf66ba5bf82b19'}
        'Forge@1.11.2'=[pscustomobject]@{minecraft='1.11.2';rootCoordinate='net.minecraftforge.gradle:ForgeGradle:2.2-SNAPSHOT';resolver='ForgeGradle 2.2 POM compile dependency union plus pinned Mojang 1.11.2, Forge UserDev development libraries and exact ForgeGradle Minecraft compile classpath';mojangUrl='https://piston-meta.mojang.com/v1/packages/fa3f6d94a9fad648ff97d18fd710997261a421e8/1.11.2.json';mojangBytes=16093L;mojangSha256='c98508dfc20ed365e6666c8f44879582df033bbde0e3499782381130f3dbaa1c';mojangSha1='fa3f6d94a9fad648ff97d18fd710997261a421e8';forgeVersion='1.11.2-13.20.1.2588';devJsonBytes=2695L;devJsonSha256='8ad51c650f805b367dd38dd17a571bce357eaaf1246dcc2b1bfc7ad625118ab9';devLibraryCount=18;mojangLibraryCount=29;devOnlyLibraryCount=18;forgeMcLibraryCoordinate='com.google.code.findbugs:jsr305:3.0.1';forgeMcLibraryBytes=19943L;forgeMcLibrarySha1='f7be08ec23c21485b9b5a1cf1654c2ec8c58168d';forgeMcLibrarySha256='c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd';requiredLibraryCount=48;mcpMapping='snapshot_20161220';mcpStableMappingVersion='32';mcpVersion='1.11.2';mcpFile='mcp-1.11.2-srg.zip';mcpBytes=708724L;mcpSha256='be95745a7052c11e232fe1b307e5e75444d8408b4d4127c32660e07fea338511';mcpStableVersion='32-1.11';mcpStableFile='mcp_stable-32-1.11.zip';mcpStableBytes=350621L;mcpStableSha256='a4878373319ec0b86c53305001c251637570b3673c9c1f4e643405533cac9014';mcpSnapshotVersion='20161220-1.11';mcpSnapshotMinecraft='1.11';mcpSnapshotFile='mcp_snapshot-20161220-1.11.zip';mcpSnapshotBytes=342912L;mcpSnapshotSha256='755416d68281e0c6998fc743929f36e14563510467d1c749d4bf66ba5bf82b19'}
        'Forge@1.12'=[pscustomobject]@{minecraft='1.12';rootCoordinate='net.minecraftforge.gradle:ForgeGradle:2.3-SNAPSHOT';resolver='ForgeGradle 2.3 POM compile dependency union plus pinned Mojang 1.12, Forge UserDev development libraries and exact ForgeGradle Minecraft compile classpath';mojangUrl='https://piston-meta.mojang.com/v1/packages/da76e0a25ffccf2765f9e86ce61c063e44b2183b/1.12.json';mojangBytes=18414L;mojangSha256='33cc40a05466b4e34e04e65def732094388e9149eb6bd37e5daa227c06cbde4b';mojangSha1='da76e0a25ffccf2765f9e86ce61c063e44b2183b';forgeVersion='1.12-14.21.1.2443';devJsonBytes=2691L;devJsonSha256='0bbdf47f68e0a89da46a9131d045e3d19766ca925e9749f5fdfe3e85462f4804';devLibraryCount=18;mojangLibraryCount=32;devOnlyLibraryCount=18;forgeMcLibraryCoordinate='com.google.code.findbugs:jsr305:3.0.1';forgeMcLibraryBytes=19943L;forgeMcLibrarySha1='f7be08ec23c21485b9b5a1cf1654c2ec8c58168d';forgeMcLibrarySha256='c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd';requiredLibraryCount=51;dependencyCount=12;mcpMapping='snapshot_20170624';mcpStableMappingVersion='39';mcpVersion='1.12';mcpFile='mcp-1.12-srg.zip';mcpBytes=650427L;mcpSha256='82cdc6283bc0842bdfa243c1eb807338d1f106db8aef73d26bc908649c586d36';mcpStableVersion='39-1.12';mcpStableFile='mcp_stable-39-1.12.zip';mcpStableBytes=378607L;mcpStableSha256='13a31f28c11f8f395ffe7e8563ade459f5a0ee46493abbbde3ce6e9493ac4152';mcpSnapshotVersion='20170624-1.12';mcpSnapshotMinecraft='1.12';mcpSnapshotFile='mcp_snapshot-20170624-1.12.zip';mcpSnapshotBytes=365094L;mcpSnapshotSha256='6c571b05af4326d29e528d7451e5aa67406b537af417e06be6e6f72fd316d81e'}
        'Forge@1.12.1'=[pscustomobject]@{minecraft='1.12.1';rootCoordinate='net.minecraftforge.gradle:ForgeGradle:2.3-SNAPSHOT';resolver='ForgeGradle 2.3 POM compile dependency union plus pinned Mojang 1.12.1, Forge UserDev development libraries and exact ForgeGradle Minecraft compile classpath';mojangUrl='https://piston-meta.mojang.com/v1/packages/5b3e7d137ea360e1d418f0cf68de160acf93fbff/1.12.1.json';mojangBytes=18416L;mojangSha256='a83e8ab7e3e78fd8dfa8fdbd0216b090ef7298fb44637b79093fe663bf2d6814';mojangSha1='5b3e7d137ea360e1d418f0cf68de160acf93fbff';forgeVersion='1.12.1-14.22.1.2485';devJsonBytes=2693L;devJsonSha256='18131e22a74c56965b7a7aa7d36daaab6eeee6ed8e1e6774388ef2fe25e3af25';devLibraryCount=18;mojangLibraryCount=32;devOnlyLibraryCount=18;forgeMcLibraryCoordinate='com.google.code.findbugs:jsr305:3.0.1';forgeMcLibraryBytes=19943L;forgeMcLibrarySha1='f7be08ec23c21485b9b5a1cf1654c2ec8c58168d';forgeMcLibrarySha256='c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd';requiredLibraryCount=51;dependencyCount=12;mcpMapping='snapshot_20170624';mcpStableMappingVersion='39';mcpVersion='1.12.1';mcpFile='mcp-1.12.1-srg.zip';mcpBytes=652347L;mcpSha256='a95c958f0c052e0a94d20de1d30a9151f68e66b19bdbea60a58cd41539558874';mcpStableVersion='39-1.12';mcpStableFile='mcp_stable-39-1.12.zip';mcpStableBytes=378607L;mcpStableSha256='13a31f28c11f8f395ffe7e8563ade459f5a0ee46493abbbde3ce6e9493ac4152';mcpSnapshotVersion='20170624-1.12';mcpSnapshotMinecraft='1.12';mcpSnapshotFile='mcp_snapshot-20170624-1.12.zip';mcpSnapshotBytes=365094L;mcpSnapshotSha256='6c571b05af4326d29e528d7451e5aa67406b537af417e06be6e6f72fd316d81e'}
        'Forge@1.10.2'=[pscustomobject]@{minecraft='1.10.2';rootCoordinate='net.minecraftforge.gradle:ForgeGradle:2.2-SNAPSHOT';resolver='ForgeGradle 2.2 POM compile dependency union plus pinned Mojang 1.10.2, Forge UserDev development libraries and exact ForgeGradle Minecraft compile classpath';mojangUrl='https://piston-meta.mojang.com/v1/packages/819460dcabf1a2e41b0cf65d342b18ad8dc12281/1.10.2.json';mojangBytes=16083L;mojangSha256='d0624badea6367233d47c830341952126cdb0f99b1e11fb60428dd530a0d4db5';mojangSha1='819460dcabf1a2e41b0cf65d342b18ad8dc12281';forgeVersion='1.10.2-12.18.3.2511';devJsonBytes=2695L;devJsonSha256='1510d7e40581825920e9bd112dfa168e48ddf77e2eb21895208bcfeada4887dd';devLibraryCount=18;mojangLibraryCount=29;devOnlyLibraryCount=18;forgeMcLibraryCoordinate='com.google.code.findbugs:jsr305:3.0.1';forgeMcLibraryBytes=19943L;forgeMcLibrarySha1='f7be08ec23c21485b9b5a1cf1654c2ec8c58168d';forgeMcLibrarySha256='c885ce34249682bc0236b4a7d56efcc12048e6135a5baf7a9cde8ad8cda13fcd';requiredLibraryCount=48;mcpMapping='stable_29';mcpStableMappingVersion='29';mcpVersion='1.10.2';mcpFile='mcp-1.10.2-srg.zip';mcpBytes=682739L;mcpSha256='f2ce9e7cdc3e3598390a495a07cc18aa930a8b9e1480d97bfae31f29e1e75a19';mcpStableVersion='29-1.10.2';mcpStableFile='mcp_stable-29-1.10.2.zip';mcpStableBytes=336350L;mcpStableSha256='0df1f289ed8417db736ee36406204309ab65e516998fa8f4139235b9127c2b7b';mcpSnapshotVersion='20161111-1.10.2';mcpSnapshotMinecraft='1.10.2';mcpSnapshotFile='mcp_snapshot-20161111-1.10.2.zip';mcpSnapshotBytes=336513L;mcpSnapshotSha256='912bc85953e769198afbc52ac1b7f324a86990529706b36d4771415cab5f3a3d'}
    }
    $targetSpec=$targetSpecs[[string]$catalog.targetId]
    $expectedRootCoordinate=if($targetSpec.PSObject.Properties['rootCoordinate']){[string]$targetSpec.rootCoordinate}else{'net.minecraftforge.gradle:ForgeGradle:2.1-SNAPSHOT'}
    if(-not $targetSpec -or [int]$catalog.schemaVersion -ne 1 -or [string]$catalog.rootCoordinate -cne $expectedRootCoordinate -or [string]$catalog.resolver -cne [string]$targetSpec.resolver -or [string]$catalog.artifactStatus -cne 'HashesVerified'){throw 'FORGE_BUILD_CLASSPATH_CATALOG_IDENTITY_INVALID'}
    $dependencies=@($catalog.dependencies);$artifacts=@($catalog.artifacts);$requiredLibraries=@($catalog.requiredLibraries)
    $expectedDependencyCount=if($targetSpec.PSObject.Properties['dependencyCount']){[int]$targetSpec.dependencyCount}else{13};if($dependencies.Count -ne $expectedDependencyCount -or $artifacts.Count -lt 4 -or $requiredLibraries.Count -ne [int]$targetSpec.requiredLibraryCount){throw 'FORGE_BUILD_CLASSPATH_CATALOG_INCOMPLETE'}
    if([string]$catalog.mcpVersions.url -cne 'https://maven.minecraftforge.net/de/oceanlabs/mcp/versions.json' -or [long]$catalog.mcpVersions.bytes -ne 26705 -or [string]$catalog.mcpVersions.sha256 -cne 'df5875099a4191293a4d36df5cc95086eb95eed4d4549a7a976e847ee3ae5156' -or [string]$catalog.mcpMapping -cne [string]$targetSpec.mcpMapping){throw 'FORGE_BUILD_CLASSPATH_MCP_PIN_INVALID'}
    if([string]$catalog.mojangVersion.url -cne [string]$targetSpec.mojangUrl -or [long]$catalog.mojangVersion.bytes -ne [long]$targetSpec.mojangBytes -or [string]$catalog.mojangVersion.sha256 -cne [string]$targetSpec.mojangSha256 -or [string]$catalog.mojangVersion.sha1 -cne [string]$targetSpec.mojangSha1 -or [string]$catalog.mojangVersion.snapshotSha256 -cne [string]$targetSpec.mojangSha256){throw 'FORGE_BUILD_CLASSPATH_MOJANG_VERSION_PIN_INVALID'}
    if([string]$catalog.forgeUserdev.coordinate -cne 'net.minecraftforge:forge' -or [string]$catalog.forgeUserdev.version -cne [string]$targetSpec.forgeVersion -or [string]$catalog.forgeUserdev.devJson.entry -cne 'dev.json' -or [long]$catalog.forgeUserdev.devJson.bytes -ne [long]$targetSpec.devJsonBytes -or [string]$catalog.forgeUserdev.devJson.sha256 -cne [string]$targetSpec.devJsonSha256 -or @($catalog.forgeUserdev.devLibraries).Count -ne [int]$targetSpec.devLibraryCount){throw 'FORGE_BUILD_USERDEV_COORDINATE_INVALID'}
    $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $devSnapshotPath=Join-Path $repositoryRoot ('compatibility/snapshots/ForgeUserdev/Forge-'+[string]$targetSpec.minecraft+'-dev.json')
    if(-not(Test-Path -LiteralPath $devSnapshotPath -PathType Leaf)){throw 'FORGE_BUILD_USERDEV_DEV_JSON_SNAPSHOT_MISSING'}
    $devSnapshotItem=Get-Item -LiteralPath $devSnapshotPath -Force
    if(($devSnapshotItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$devSnapshotItem.Length -ne [long]$catalog.forgeUserdev.devJson.bytes -or (Get-MmtlForgePinFileHash -Path $devSnapshotPath) -cne [string]$catalog.forgeUserdev.devJson.sha256){throw 'FORGE_BUILD_USERDEV_DEV_JSON_SNAPSHOT_HASH_MISMATCH'}
    $devSnapshot=Get-Content -LiteralPath $devSnapshotPath -Raw|ConvertFrom-Json -ErrorAction Stop
    $actualDevCoordinates=@($devSnapshot.libraries|ForEach-Object{[string]$_.name}|Sort-Object -Unique)
    $pinnedDevCoordinates=@($catalog.forgeUserdev.devLibraries|ForEach-Object{[string]$_}|Sort-Object -Unique)
    if(($actualDevCoordinates -join "`n") -cne ($pinnedDevCoordinates -join "`n")){throw 'FORGE_BUILD_USERDEV_DEV_JSON_COORDINATES_MISMATCH'}
    $mojangSnapshotPath=Join-Path $repositoryRoot ('compatibility/snapshots/MojangVersions/'+[string]$targetSpec.mojangSha256+'.bin')
    if(-not(Test-Path -LiteralPath $mojangSnapshotPath -PathType Leaf)){throw 'FORGE_BUILD_MOJANG_VERSION_SNAPSHOT_MISSING'}
    $mojangSnapshotItem=Get-Item -LiteralPath $mojangSnapshotPath -Force
    if(($mojangSnapshotItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$mojangSnapshotItem.Length -ne [long]$targetSpec.mojangBytes -or (Get-MmtlForgePinFileHash -Path $mojangSnapshotPath) -cne [string]$targetSpec.mojangSha256){throw 'FORGE_BUILD_MOJANG_VERSION_SNAPSHOT_HASH_MISMATCH'}
    $mojangSnapshot=Get-Content -LiteralPath $mojangSnapshotPath -Raw|ConvertFrom-Json -ErrorAction Stop
    if([string]$mojangSnapshot.id -cne [string]$targetSpec.minecraft -or [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([IO.File]::ReadAllBytes($mojangSnapshotPath))).ToLowerInvariant() -cne [string]$targetSpec.mojangSha1){throw 'FORGE_BUILD_MOJANG_VERSION_SNAPSHOT_ID_MISMATCH'}
    $buildJarCoordinates=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $artifacts){if([string]$artifact.extension -ceq 'jar'){[void]$buildJarCoordinates.Add([string]$artifact.group+':'+[string]$artifact.artifact+':'+[string]$artifact.version)}}
    $mojangCoordinates=@($mojangSnapshot.libraries|Where-Object{$_.downloads -and $_.downloads.PSObject.Properties['artifact']}|ForEach-Object{[string]$_.name}|Where-Object{-not $buildJarCoordinates.Contains($_)}|Sort-Object -Unique)
    $allMojangCoordinates=@($mojangSnapshot.libraries|ForEach-Object{[string]$_.name}|Sort-Object -Unique)
    $expectedDevCoordinates=@($actualDevCoordinates|Where-Object{$_ -notin $allMojangCoordinates -and -not $buildJarCoordinates.Contains($_)}|Sort-Object -Unique)
    $pinnedMojangLibraries=@($requiredLibraries|Where-Object source -eq 'MojangVersionJson'|ForEach-Object{[string]$_.coordinate}|Sort-Object -Unique)
    $pinnedDevLibraries=@($requiredLibraries|Where-Object source -eq 'ForgeUserdevDevJson'|ForEach-Object{[string]$_.coordinate}|Sort-Object -Unique)
    if(($pinnedMojangLibraries -join "`n") -cne ($mojangCoordinates -join "`n") -or ($pinnedDevLibraries -join "`n") -cne ($expectedDevCoordinates -join "`n")){throw 'FORGE_BUILD_CLASSPATH_REQUIRED_LIBRARY_CLOSURE_MISMATCH'}
    $expectedMcpArtifactCount=if($targetSpec.PSObject.Properties['mcpSnapshotVersion']){3}else{2}
    if(@($catalog.mcpArtifacts).Count -ne $expectedMcpArtifactCount -or [string]$catalog.mcpArtifacts[0].coordinate -cne 'de.oceanlabs.mcp:mcp' -or [string]$catalog.mcpArtifacts[0].version -cne [string]$targetSpec.mcpVersion -or [string]$catalog.mcpArtifacts[0].file -cne [string]$targetSpec.mcpFile -or [long]$catalog.mcpArtifacts[0].bytes -ne [long]$targetSpec.mcpBytes -or [string]$catalog.mcpArtifacts[0].sha256 -cne [string]$targetSpec.mcpSha256 -or [string]$catalog.mcpArtifacts[1].coordinate -cne 'de.oceanlabs.mcp:mcp_stable' -or [string]$catalog.mcpArtifacts[1].version -cne [string]$targetSpec.mcpStableVersion -or [string]$catalog.mcpArtifacts[1].file -cne [string]$targetSpec.mcpStableFile -or [long]$catalog.mcpArtifacts[1].bytes -ne [long]$targetSpec.mcpStableBytes -or [string]$catalog.mcpArtifacts[1].sha256 -cne [string]$targetSpec.mcpStableSha256 -or [string]$catalog.mcpMapping -cne [string]$targetSpec.mcpMapping){throw 'FORGE_BUILD_MCP_ARTIFACTS_INVALID'}
    if($expectedMcpArtifactCount -eq 3 -and ([string]$catalog.mcpArtifacts[2].coordinate -cne 'de.oceanlabs.mcp:mcp_snapshot' -or [string]$catalog.mcpArtifacts[2].version -cne [string]$targetSpec.mcpSnapshotVersion -or [string]$catalog.mcpArtifacts[2].file -cne [string]$targetSpec.mcpSnapshotFile -or [long]$catalog.mcpArtifacts[2].bytes -ne [long]$targetSpec.mcpSnapshotBytes -or [string]$catalog.mcpArtifacts[2].sha256 -cne [string]$targetSpec.mcpSnapshotSha256)){throw 'FORGE_BUILD_MCP_SNAPSHOT_ARTIFACT_INVALID'}
    $dependencyKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($dependency in $dependencies){
        $group=[string]$dependency.group;$module=[string]$dependency.artifact;$version=[string]$dependency.version
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or -not $dependencyKeys.Add($group+':'+$module+':'+$version)){throw 'FORGE_BUILD_CLASSPATH_DEPENDENCY_INVALID'}
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $artifacts){
        $group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$extension=[string]$artifact.extension
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $file -notmatch '^[A-Za-z0-9_.+-]+\.(jar|pom)$' -or $extension -notin @('jar','pom') -or -not $file.EndsWith('.'+$extension,[StringComparison]::Ordinal) -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_BUILD_CLASSPATH_ARTIFACT_INVALID'}
        $uri=$null;if(-not [Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -notin @('plugins.gradle.org','plugins-artifacts.gradle.org','maven.minecraftforge.net','libraries.minecraft.net','repo.maven.apache.org') -or $uri.UserInfo){throw 'FORGE_BUILD_CLASSPATH_ARTIFACT_URL_INVALID'}
        $pathPrefix='/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'
        if(-not $uri.AbsolutePath.EndsWith($pathPrefix+$file,[StringComparison]::Ordinal) -and -not $uri.AbsolutePath.EndsWith('/m2'+$pathPrefix+$file,[StringComparison]::Ordinal) -and -not ($group -ceq 'net.minecraftforge' -and $module -ceq 'fernflower' -and $version -ceq '2.0-SNAPSHOT' -and $uri.AbsolutePath -match '/net/minecraftforge/fernflower/2\.0-SNAPSHOT/fernflower-2\.0-[0-9]{8}\.[0-9]{6}-[0-9]+\.(jar|pom)$')){throw 'FORGE_BUILD_CLASSPATH_ARTIFACT_URL_COORDINATE_MISMATCH'}
        $isPinnedFernflowerSnapshot=$group -ceq 'net.minecraftforge' -and $module -ceq 'fernflower' -and $version -ceq '2.0-SNAPSHOT' -and $uri.AbsolutePath -match '/fernflower-2\.0-[0-9]{8}\.[0-9]{6}-[0-9]+\.(jar|pom)$'
        if(-not $isPinnedFernflowerSnapshot -and -not $uri.AbsolutePath.EndsWith('/'+$file,[StringComparison]::Ordinal)){throw 'FORGE_BUILD_CLASSPATH_ARTIFACT_URL_FILENAME_MISMATCH'}
        $key=$group+':'+$module+':'+$version+':'+$extension
        if(-not $seen.Add($key)){throw 'FORGE_BUILD_CLASSPATH_ARTIFACT_DUPLICATE'}
    }
    $requiredKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$requiredCoordinates=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $requiredLibraryArtifacts=[Collections.Generic.List[object]]::new()
    foreach($library in $requiredLibraries){
        $coordinate=[string]$library.coordinate;$parts=$coordinate.Split(':');$source=[string]$library.source;$file=[string]$library.file
        if($parts.Count -ne 3 -or $parts[0] -notmatch '^[A-Za-z0-9_.-]+$' -or $parts[1] -notmatch '^[A-Za-z0-9_.-]+$' -or $parts[2] -notmatch '^[A-Za-z0-9_.+-]+$' -or $source -notin @('MojangVersionJson','ForgeUserdevDevJson','ForgeGradleMinecraftClasspath') -or $file -cne ($parts[1]+'-'+$parts[2]+'.jar') -or [long]$library.bytes -le 0 -or [string]$library.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [string]$library.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$library.sha1Source -notin @('MojangVersionJson','MavenCentralSha1','ComputedPinnedSource')){throw 'FORGE_BUILD_CLASSPATH_REQUIRED_LIBRARY_INVALID'}
        $uri=$null;if(-not [Uri]::TryCreate([string]$library.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -notin @('libraries.minecraft.net','repo.maven.apache.org') -or $uri.UserInfo){throw 'FORGE_BUILD_CLASSPATH_REQUIRED_LIBRARY_URL_INVALID'}
        if(($source -ceq 'MojangVersionJson' -and ($uri.Host -cne 'libraries.minecraft.net' -or [string]$library.sha1Source -cne 'MojangVersionJson')) -or ($source -ceq 'ForgeUserdevDevJson' -and $uri.Host -cne 'libraries.minecraft.net' -and $uri.Host -cne 'repo.maven.apache.org') -or ($source -ceq 'ForgeGradleMinecraftClasspath' -and ($uri.Host -cne 'repo.maven.apache.org' -or [string]$library.sha1Source -cne 'MavenCentralSha1'))){throw 'FORGE_BUILD_CLASSPATH_REQUIRED_LIBRARY_SOURCE_MISMATCH'}
        $expectedSuffix='/'+$parts[0].Replace('.','/')+'/'+$parts[1]+'/'+$parts[2]+'/'+$file
        if(-not $uri.AbsolutePath.EndsWith($expectedSuffix,[StringComparison]::Ordinal)){throw 'FORGE_BUILD_CLASSPATH_REQUIRED_LIBRARY_COORDINATE_MISMATCH'}
        if(-not $requiredCoordinates.Add($coordinate)){throw 'FORGE_BUILD_CLASSPATH_REQUIRED_LIBRARY_DUPLICATE'}
        $requiredKey=$coordinate+':jar';if(-not $requiredKeys.Add($requiredKey) -or $seen.Contains($requiredKey)){throw 'FORGE_BUILD_CLASSPATH_REQUIRED_LIBRARY_COLLISION'}
        $requiredLibraryArtifacts.Add([pscustomobject][ordered]@{group=$parts[0];artifact=$parts[1];version=$parts[2];file=$file;extension='jar';bytes=[long]$library.bytes;sha256=[string]$library.sha256;sha1=[string]$library.sha1;sha1Source=[string]$library.sha1Source;url=[string]$library.url})
    }
    $forgeMcLibraries=@($requiredLibraries|Where-Object source -eq 'ForgeGradleMinecraftClasspath')
    $expectedForgeMcCount=if($targetSpec.PSObject.Properties['forgeMcLibraryCoordinate']){1}else{0}
    if(@($requiredLibraries|Where-Object source -eq 'MojangVersionJson').Count -ne [int]$targetSpec.mojangLibraryCount -or @($requiredLibraries|Where-Object source -eq 'ForgeUserdevDevJson').Count -ne [int]$targetSpec.devOnlyLibraryCount -or $forgeMcLibraries.Count -ne $expectedForgeMcCount){throw 'FORGE_BUILD_CLASSPATH_REQUIRED_LIBRARY_SOURCE_COUNTS_INVALID'}
    if($expectedForgeMcCount -and ([string]$forgeMcLibraries[0].coordinate -cne [string]$targetSpec.forgeMcLibraryCoordinate -or [long]$forgeMcLibraries[0].bytes -ne [long]$targetSpec.forgeMcLibraryBytes -or [string]$forgeMcLibraries[0].sha1 -cne [string]$targetSpec.forgeMcLibrarySha1 -or [string]$forgeMcLibraries[0].sha256 -cne [string]$targetSpec.forgeMcLibrarySha256)){throw 'FORGE_BUILD_CLASSPATH_FORGE_MINECRAFT_LIBRARY_PIN_INVALID'}
    foreach($dependency in $dependencies){foreach($extension in @('jar','pom')){$key=[string]$dependency.group+':'+[string]$dependency.artifact+':'+[string]$dependency.version+':'+$extension;if(-not $seen.Contains($key)){throw 'FORGE_BUILD_CLASSPATH_DEPENDENCY_ARTIFACT_MISSING'}}}
    $mcpVersions=[pscustomobject][ordered]@{url=[string]$catalog.mcpVersions.url;bytes=[long]$catalog.mcpVersions.bytes;sha256=[string]$catalog.mcpVersions.sha256}
    $mojangVersion=[pscustomobject][ordered]@{url=[string]$catalog.mojangVersion.url;bytes=[long]$catalog.mojangVersion.bytes;sha256=[string]$catalog.mojangVersion.sha256;sha1=[string]$catalog.mojangVersion.sha1;snapshotSha256=[string]$catalog.mojangVersion.snapshotSha256}
    $forgeUserdev=$catalog.forgeUserdev
    $mcpArtifacts=@($catalog.mcpArtifacts)
    $core=[pscustomobject][ordered]@{schemaVersion=[int]$catalog.schemaVersion;targetId=[string]$catalog.targetId;rootCoordinate=[string]$catalog.rootCoordinate;resolver=[string]$catalog.resolver;artifactStatus=[string]$catalog.artifactStatus;mcpVersions=$mcpVersions;mcpMapping=[string]$catalog.mcpMapping;mojangVersion=$mojangVersion;forgeUserdev=$forgeUserdev;mcpArtifacts=$mcpArtifacts;dependencies=$dependencies;artifacts=$artifacts;requiredLibraries=$requiredLibraries}
    $actualHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
    if($actualHash -cne [string]$catalog.catalogHash){throw 'FORGE_BUILD_CLASSPATH_CATALOG_HASH_MISMATCH'}
    [pscustomobject]@{catalog=$catalog;catalogHash=$actualHash;dependencies=$dependencies;artifacts=@($artifacts)+@($requiredLibraryArtifacts);requiredLibraries=$requiredLibraries;mcpVersions=$mcpVersions;mojangVersion=$mojangVersion;forgeUserdev=$forgeUserdev;mcpArtifacts=$mcpArtifacts}
}

function Get-MmtlForgeBuildClasspathArtifactMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$artifactCache=Join-Path $root 'artifact-cache';$mirrorRoot=Join-Path $root 'maven-mirror'
    [void][IO.Directory]::CreateDirectory($artifactCache);[void][IO.Directory]::CreateDirectory($mirrorRoot)
    foreach($artifact in $resolved.artifacts){
        $hash=[string]$artifact.sha256;$cachedPath=Join-Path $artifactCache $hash
        if(Test-Path -LiteralPath $cachedPath -PathType Leaf){$item=Get-Item -LiteralPath $cachedPath -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cachedPath) -cne $hash -or ($artifact.PSObject.Properties['sha1'] -and (Get-FileHash -LiteralPath $cachedPath -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$artifact.sha1)){throw 'FORGE_BUILD_CLASSPATH_ARTIFACT_CACHE_INVALID'}}
        else{$temporary=Join-Path $artifactCache ('.download-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('plugins.gradle.org','plugins-artifacts.gradle.org','repo.maven.apache.org','maven.minecraftforge.net','libraries.minecraft.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash -or ($artifact.PSObject.Properties['sha1'] -and (Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$artifact.sha1)){throw 'FORGE_BUILD_CLASSPATH_ARTIFACT_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cachedPath)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version)
        $directory=[IO.Path]::GetFullPath((Join-Path $mirrorRoot $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $directory)){throw 'FORGE_BUILD_CLASSPATH_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($directory)
        $destination=[IO.Path]::GetFullPath((Join-Path $directory ([string]$artifact.file)));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $destination)){throw 'FORGE_BUILD_CLASSPATH_MIRROR_PATH_ESCAPE'}
        if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_BUILD_CLASSPATH_MIRROR_COLLISION'}}else{[IO.File]::Copy($cachedPath,$destination,$false)}
    }
    $mcpHash=[string]$resolved.mcpVersions.sha256;$mcpCachePath=Join-Path $artifactCache $mcpHash
    if(Test-Path -LiteralPath $mcpCachePath -PathType Leaf){$mcpCacheItem=Get-Item -LiteralPath $mcpCachePath -Force;if(($mcpCacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$mcpCacheItem.Length -ne [long]$resolved.mcpVersions.bytes -or (Get-MmtlForgePinFileHash -Path $mcpCachePath) -cne $mcpHash){throw 'FORGE_BUILD_CLASSPATH_MCP_CACHE_INVALID'}}
    else{$mcpTemporary=Join-Path $artifactCache ('.mcp-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$resolved.mcpVersions.url) -DestinationPath $mcpTemporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net');if([long](Get-Item -LiteralPath $mcpTemporary).Length -ne [long]$resolved.mcpVersions.bytes -or (Get-MmtlForgePinFileHash -Path $mcpTemporary) -cne $mcpHash){throw 'FORGE_BUILD_CLASSPATH_MCP_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($mcpTemporary,$mcpCachePath)}finally{if(Test-Path -LiteralPath $mcpTemporary -PathType Leaf){[IO.File]::Delete($mcpTemporary)}}}
    $mcpVersionsPath=Join-Path $root 'mcp-versions.json'
    if(Test-Path -LiteralPath $mcpVersionsPath -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $mcpVersionsPath) -cne $mcpHash){throw 'FORGE_BUILD_CLASSPATH_MCP_COPY_HASH_MISMATCH'}}else{[IO.File]::Copy($mcpCachePath,$mcpVersionsPath,$false)}
    $mojangPin=$resolved.mojangVersion;$mojangCachePath=Join-Path $artifactCache ([string]$mojangPin.sha256)
    if(Test-Path -LiteralPath $mojangCachePath -PathType Leaf){$item=Get-Item -LiteralPath $mojangCachePath -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$mojangPin.bytes -or (Get-MmtlForgePinFileHash -Path $mojangCachePath) -cne [string]$mojangPin.sha256){throw 'FORGE_BUILD_CLASSPATH_MOJANG_CACHE_INVALID'}}
    else{$temporary=Join-Path $artifactCache ('.mojang-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$mojangPin.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('piston-meta.mojang.com');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$mojangPin.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne [string]$mojangPin.sha256){throw 'FORGE_BUILD_CLASSPATH_MOJANG_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$mojangCachePath)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
    $minecraftVersion=([string]$resolved.catalog.targetId -replace '^Forge@','')
    $mojangVersionPath=Join-Path $root ('mojang-version-'+$minecraftVersion+'.json');if(Test-Path -LiteralPath $mojangVersionPath -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $mojangVersionPath) -cne [string]$mojangPin.sha256){throw 'FORGE_BUILD_CLASSPATH_MOJANG_COPY_HASH_MISMATCH'}}else{[IO.File]::Copy($mojangCachePath,$mojangVersionPath,$false)}
    [pscustomobject]@{mirrorRoot=$mirrorRoot;catalogHash=$resolved.catalogHash;artifactCount=$resolved.artifacts.Count;dependencyCount=$resolved.dependencies.Count;mcpVersionsPath=$mcpVersionsPath;mcpVersionsSha256=$mcpHash;mcpMapping=[string]$resolved.catalog.mcpMapping;mojangVersionPath=$mojangVersionPath;mojangVersionSha256=[string]$mojangPin.sha256}
}

function Get-MmtlForgeGradle3BuildClasspathArtifactMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $resolved=Get-MmtlForgeGradle3BuildClasspathArtifactCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$artifactCache=Join-Path $root 'artifact-cache';$mirrorRoot=Join-Path $root 'maven-mirror'
    [void][IO.Directory]::CreateDirectory($artifactCache);[void][IO.Directory]::CreateDirectory($mirrorRoot)
    foreach($artifact in $resolved.artifacts){
        $hash=[string]$artifact.sha256;$cachedPath=Join-Path $artifactCache $hash
        if(Test-Path -LiteralPath $cachedPath -PathType Leaf){$item=Get-Item -LiteralPath $cachedPath -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cachedPath) -cne $hash){throw 'FORGE_GRADLE3_CLASSPATH_CACHE_INVALID'}}
        else{$temporary=Join-Path $artifactCache ('.download-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net','libraries.minecraft.net','repo.maven.apache.org');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash){throw 'FORGE_GRADLE3_CLASSPATH_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cachedPath)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version)
        $directory=[IO.Path]::GetFullPath((Join-Path $mirrorRoot $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $directory)){throw 'FORGE_GRADLE3_CLASSPATH_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($directory)
        $destination=[IO.Path]::GetFullPath((Join-Path $directory ([string]$artifact.file)));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $destination)){throw 'FORGE_GRADLE3_CLASSPATH_MIRROR_PATH_ESCAPE'}
        if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_GRADLE3_CLASSPATH_MIRROR_COLLISION'}}else{[IO.File]::Copy($cachedPath,$destination,$false)}
    }
    $dynamicPaths=@(New-MmtlForgeClasspathDynamicVersionMetadata -ClasspathCatalog $resolved -RepositoryRoot $mirrorRoot)
    [pscustomobject]@{mirrorRoot=$mirrorRoot;catalogHash=$resolved.catalogHash;artifactCount=$resolved.artifacts.Count;dependencyCount=$resolved.dependencies.Count;dynamicMetadataPaths=$dynamicPaths;dynamicVersionResolutions=$resolved.dynamicVersionResolutions}
}

function Get-MmtlForgeGradle6BuildClasspathArtifactMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $resolved=Get-MmtlForgeGradle6BuildClasspathArtifactCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$artifactCache=Join-Path $root 'artifact-cache';$mirrorRoot=Join-Path $root 'maven-mirror'
    [void][IO.Directory]::CreateDirectory($artifactCache);[void][IO.Directory]::CreateDirectory($mirrorRoot)
    foreach($artifact in $resolved.artifacts){
        $hash=[string]$artifact.sha256;$cachedPath=Join-Path $artifactCache $hash
        if(Test-Path -LiteralPath $cachedPath -PathType Leaf){$item=Get-Item -LiteralPath $cachedPath -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cachedPath) -cne $hash){throw 'FORGE_GRADLE6_CLASSPATH_CACHE_INVALID'}}
        else{$temporary=Join-Path $artifactCache ('.download-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net','plugins.gradle.org','plugins-artifacts.gradle.org','repo.maven.apache.org');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash){throw 'FORGE_GRADLE6_CLASSPATH_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cachedPath)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version)
        $directory=[IO.Path]::GetFullPath((Join-Path $mirrorRoot $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $directory)){throw 'FORGE_GRADLE6_CLASSPATH_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($directory)
        $destination=[IO.Path]::GetFullPath((Join-Path $directory ([string]$artifact.file)));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $destination)){throw 'FORGE_GRADLE6_CLASSPATH_MIRROR_PATH_ESCAPE'}
        if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_GRADLE6_CLASSPATH_MIRROR_COLLISION'}}else{[IO.File]::Copy($cachedPath,$destination,$false)}
    }
    [pscustomobject]@{mirrorRoot=$mirrorRoot;catalogHash=$resolved.catalogHash;artifactCount=$resolved.artifacts.Count;dependencyCount=$resolved.dependencies.Count}
}

function Get-MmtlForgeGradle6RuntimeArtifactCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $targetMatch=[regex]::Match([string]$catalog.targetId,'^Forge@(?<minecraftId>[0-9]+(?:\.[0-9]+){1,2})$');$resolverMatch=[regex]::Match([string]$catalog.resolver,'^Gradle (?<version>[0-9]+(?:\.[0-9]+){1,2}) official MDK offline resolved configuration capture$')
    if([int]$catalog.schemaVersion -ne 1 -or -not $targetMatch.Success -or [string]$catalog.forgeVersion -notmatch ('^'+[regex]::Escape($targetMatch.Groups['minecraftId'].Value)+'-[0-9][A-Za-z0-9.-]*$') -or -not $resolverMatch.Success -or [string]$catalog.artifactStatus -cne 'HashesVerified' -or [string]$catalog.platform.os -cne 'Windows' -or [string]$catalog.platform.architecture -cne 'x64'){throw 'FORGE_GRADLE6_RUNTIME_CATALOG_IDENTITY_INVALID'}
    $maven=@($catalog.mavenArtifacts);$mojang=@($catalog.mojangArtifacts);$generated=@($catalog.generatedArtifacts);$configurations=@($catalog.configurations);$supportPoms=@($catalog.supportPoms);$moduleMetadata=@($catalog.moduleMetadata);$dynamicMetadata=@($catalog.dynamicMetadata);$dynamicCandidates=@($catalog.dynamicCandidates)
    $configurationKeys=@($configurations|ForEach-Object{[string]$_.project+':'+[string]$_.name});$observedArtifactCount=($configurations|Measure-Object -Property artifactCount -Sum).Sum
    if($maven.Count -lt 1 -or $mojang.Count -lt 1 -or $generated.Count -lt 1 -or $configurations.Count -lt 1 -or [int]$catalog.resolvedConfigurationCount -ne $configurations.Count -or [long]$catalog.resolvedArtifactObservations -ne [long]$observedArtifactCount -or @($configurationKeys|Sort-Object -Unique).Count -ne $configurationKeys.Count){throw 'FORGE_GRADLE6_RUNTIME_CATALOG_SET_INVALID'}
    $configurationNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($configuration in $configurations){if([string]$configuration.project -cne ':' -or [string]$configuration.name -notmatch '^[A-Za-z0-9_.-]+$' -or [int]$configuration.artifactCount -lt 0 -or -not $configurationNames.Add([string]$configuration.name)){throw 'FORGE_GRADLE6_RUNTIME_CONFIGURATION_INVALID'}}
    foreach($artifact in @($maven)+@($mojang)+@($generated)){foreach($configuration in @($artifact.configurations)){if(-not $configurationNames.Contains([string]$configuration)){throw 'FORGE_GRADLE6_RUNTIME_CONFIGURATION_REFERENCE_INVALID'}}}
    $artifactSeen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $maven){
        $group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$uri=$null;$repo=[string]$artifact.repository
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $file -notmatch '^[A-Za-z0-9_.+-]+\.jar$' -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$artifact.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or $repo -notin @('mavenCentral','forgeMaven')){throw 'FORGE_GRADLE6_RUNTIME_ARTIFACT_INVALID'}
        if(-not[Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw 'FORGE_GRADLE6_RUNTIME_ARTIFACT_URL_INVALID'}
        $host=if($repo -ceq 'mavenCentral'){'repo.maven.apache.org'}else{'maven.minecraftforge.net'};$prefix=if($repo -ceq 'mavenCentral'){'/maven2'}else{''};$expectedPath=$prefix+'/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file
        if($uri.Host -cne $host -or $uri.AbsolutePath -cne $expectedPath){throw 'FORGE_GRADLE6_RUNTIME_ARTIFACT_URL_INVALID'}
        if(-not$artifactSeen.Add($group+':'+$module+':'+$version+':'+$file)){throw 'FORGE_GRADLE6_RUNTIME_ARTIFACT_DUPLICATE'}
        $pom=$artifact.pom;$pomUri=$null;$pomFile=$module+'-'+$version+'.pom';$expectedPomUrl=if($repo -ceq 'mavenCentral'){'https://repo.maven.apache.org/maven2'}else{'https://maven.minecraftforge.net'};$expectedPomUrl+='/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$pomFile
        if([string]$pom.file -cne $pomFile -or [long]$pom.bytes -le 0 -or [string]$pom.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not[Uri]::TryCreate([string]$pom.url,[UriKind]::Absolute,[ref]$pomUri) -or [string]$pom.url -cne $expectedPomUrl){throw 'FORGE_GRADLE6_RUNTIME_POM_INVALID'}
    }
    foreach($artifact in $supportPoms+$moduleMetadata){$group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$extension=if($file.EndsWith('.module',[StringComparison]::Ordinal)){'module'}else{'pom'};$uri=$null;$metadataHost=if($group -ceq 'net.minecraftforge' -or $group.StartsWith('net.minecraftforge.') -or $group.StartsWith('cpw.mods') -or $group -in @('net.jodah','org.spongepowered')){'maven.minecraftforge.net'}else{'repo.maven.apache.org'};$prefix=if($metadataHost -ceq 'repo.maven.apache.org'){'/maven2'}else{''};$expectedFile="$module-$version.$extension";$expectedUrl="https://$metadataHost$prefix/$($group.Replace('.','/'))/$module/$version/$expectedFile";if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $file -cne $expectedFile -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not[Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or [string]$artifact.url -cne $expectedUrl){throw 'FORGE_GRADLE6_RUNTIME_METADATA_INVALID'}}
    foreach($artifact in $dynamicCandidates){$group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$extension=if($file.EndsWith('.module',[StringComparison]::Ordinal)){'module'}elseif($file.EndsWith('.pom',[StringComparison]::Ordinal)){'pom'}else{''};$candidateHost=if($group -ceq 'net.minecraftforge' -or $group.StartsWith('net.minecraftforge.') -or $group.StartsWith('cpw.mods') -or $group -in @('net.jodah','org.spongepowered')){'maven.minecraftforge.net'}else{'repo.maven.apache.org'};$prefix=if($candidateHost -ceq 'repo.maven.apache.org'){'/maven2'}else{''};$expectedUrl="https://$candidateHost$prefix/$($group.Replace('.','/'))/$module/$version/$file";$uri=$null;if($extension -notin @('pom','module') -or $group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $file -cne "$module-$version.$extension" -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not[Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or [string]$artifact.url -cne $expectedUrl){throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_CANDIDATE_INVALID'}}
    $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    foreach($metadata in $dynamicMetadata){$group=[string]$metadata.group;$module=[string]$metadata.artifact;$mavenHost=if($group -ceq 'org.apache.logging.log4j'){'repo.maven.apache.org'}else{'maven.minecraftforge.net'};$prefix=if($mavenHost -ceq 'repo.maven.apache.org'){'/maven2'}else{''};$expectedUrl="https://$mavenHost$prefix/$($group.Replace('.','/'))/$module/maven-metadata.xml";$metadataUri=$null;if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or [string]$metadata.file -cne 'maven-metadata.xml' -or [long]$metadata.bytes -le 0 -or [string]$metadata.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$metadata.url -cne $expectedUrl -or -not[Uri]::TryCreate([string]$metadata.url,[UriKind]::Absolute,[ref]$metadataUri)){throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_METADATA_INVALID'};$snapshotPath=Join-Path $repositoryRoot ('compatibility/snapshots/MavenMetadata/'+[string]$metadata.sha256+'.bin');if(-not(Test-Path -LiteralPath $snapshotPath -PathType Leaf) -or [long](Get-Item -LiteralPath $snapshotPath).Length -ne [long]$metadata.bytes -or (Get-MmtlForgePinFileHash -Path $snapshotPath) -cne [string]$metadata.sha256){throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_METADATA_SNAPSHOT_INVALID'};try{$metadataXml=[xml][Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($snapshotPath))}catch{throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_METADATA_XML_INVALID'};if([string]$metadataXml.metadata.groupId -cne $group -or [string]$metadataXml.metadata.artifactId -cne $module){throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_METADATA_IDENTITY_INVALID'};$available=@($metadataXml.metadata.versioning.versions.version|ForEach-Object{[string]$_});$selectors=@($metadata.requiredSelectors);$resolutions=@($metadata.resolutions);if($selectors.Count -lt 1 -or $resolutions.Count -ne $selectors.Count){throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_METADATA_SELECTOR_INVALID'};foreach($selector in $selectors){if([string]$selector -notmatch '^[0-9]+(?:\.[0-9]+)*\.\+$'){throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_METADATA_SELECTOR_INVALID'};$prefixVersion=([string]$selector).TrimEnd('+');if(-not @($available|Where-Object{$_ -like ($prefixVersion+'*')}).Count){throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_METADATA_SELECTOR_UNAVAILABLE'}};foreach($resolution in $resolutions){if([string]$resolution.selector -notin $selectors -or [string]$resolution.version -notin $available -or -not @($dynamicCandidates|Where-Object{[string]$_.group -ceq $group -and [string]$_.artifact -ceq $module -and [string]$_.version -ceq [string]$resolution.version}).Count){throw 'FORGE_GRADLE6_RUNTIME_DYNAMIC_METADATA_RESOLUTION_INVALID'}}}
    foreach($artifact in $mojang){$uri=$null;if([long]$artifact.bytes -le 0 -or [string]$artifact.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not[Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'libraries.minecraft.net' -or $uri.AbsolutePath -notmatch ('/'+[regex]::Escape([string]$artifact.file)+'$')){throw 'FORGE_GRADLE6_RUNTIME_MOJANG_ARTIFACT_INVALID'}}
    foreach($artifact in $generated){if([string]$artifact.component -notmatch '^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.+-]+$' -or [string]$artifact.file -notmatch '^[A-Za-z0-9_.+-]+\.(?:jar|zip)$' -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or @($artifact.configurations).Count -lt 1){throw 'FORGE_GRADLE6_RUNTIME_GENERATED_ARTIFACT_INVALID'}}
    $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
    if($hash -cne [string]$catalog.catalogHash){throw 'FORGE_GRADLE6_RUNTIME_CATALOG_HASH_MISMATCH'}
    [pscustomobject]@{catalog=$catalog;catalogHash=$hash;mavenArtifacts=$maven;supportPoms=$supportPoms;moduleMetadata=$moduleMetadata;dynamicMetadata=$dynamicMetadata;dynamicCandidates=$dynamicCandidates;components=@($maven|ForEach-Object{"$($_.group):$($_.artifact):$($_.version)"}|Sort-Object -Unique)}
}

function Get-MmtlForgeGradle6RuntimeArtifactMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=180)
    $resolved=Get-MmtlForgeGradle6RuntimeArtifactCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$cache=Join-Path $root 'artifact-cache';$mirror=[IO.Path]::GetFullPath((Join-Path $root 'maven-mirror'))
    [void][IO.Directory]::CreateDirectory($cache);[void][IO.Directory]::CreateDirectory($mirror)
    $records=[Collections.Generic.List[object]]::new();$recordKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $resolved.mavenArtifacts){$records.Add([pscustomobject]@{group=[string]$artifact.group;artifact=[string]$artifact.artifact;version=[string]$artifact.version;file=[string]$artifact.file;bytes=[long]$artifact.bytes;sha256=[string]$artifact.sha256;url=[string]$artifact.url;repository='maven'})}
    foreach($artifact in $resolved.mavenArtifacts){$coordinate=[string]$artifact.group+':'+[string]$artifact.artifact+':'+[string]$artifact.version;if($recordKeys.Add($coordinate+':'+[string]$artifact.pom.file)){$records.Add([pscustomobject]@{group=[string]$artifact.group;artifact=[string]$artifact.artifact;version=[string]$artifact.version;file=[string]$artifact.pom.file;bytes=[long]$artifact.pom.bytes;sha256=[string]$artifact.pom.sha256;url=[string]$artifact.pom.url;repository='maven'})}}
    foreach($artifact in $resolved.supportPoms+$resolved.moduleMetadata){$records.Add([pscustomobject]@{group=[string]$artifact.group;artifact=[string]$artifact.artifact;version=[string]$artifact.version;file=[string]$artifact.file;bytes=[long]$artifact.bytes;sha256=[string]$artifact.sha256;url=[string]$artifact.url;repository='maven'})}
    foreach($metadata in $resolved.dynamicMetadata){$records.Add([pscustomobject]@{group=[string]$metadata.group;artifact=[string]$metadata.artifact;file=[string]$metadata.file;bytes=[long]$metadata.bytes;sha256=[string]$metadata.sha256;url=[string]$metadata.url;repository='metadata'})}
    foreach($candidate in $resolved.dynamicCandidates){$records.Add([pscustomobject]@{group=[string]$candidate.group;artifact=[string]$candidate.artifact;version=[string]$candidate.version;file=[string]$candidate.file;bytes=[long]$candidate.bytes;sha256=[string]$candidate.sha256;url=[string]$candidate.url;repository='candidateMetadata'})}
    foreach($artifact in $resolved.catalog.mojangArtifacts){$uri=[Uri][string]$artifact.url;$relative=$uri.AbsolutePath.TrimStart('/').Replace('/',[IO.Path]::DirectorySeparatorChar);$records.Add([pscustomobject]@{relative=$relative;file=[string]$artifact.file;bytes=[long]$artifact.bytes;sha256=[string]$artifact.sha256;sha1=[string]$artifact.sha1;url=[string]$artifact.url;repository='mojang'})}
    $written=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$mavenCount=0;$mojangCount=0;$dynamicMetadataCount=0;$dynamicCandidateCount=0
    foreach($artifact in $records){
        $hash=[string]$artifact.sha256;$cached=Join-Path $cache $hash
        if(Test-Path -LiteralPath $cached -PathType Leaf){$cacheItem=Get-Item -LiteralPath $cached -Force;if(($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$cacheItem.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cached) -cne $hash -or ($artifact.repository -ceq 'mojang' -and (Get-FileHash -LiteralPath $cached -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$artifact.sha1)){throw 'FORGE_GRADLE6_RUNTIME_CACHE_INVALID'}}
        else{$temporary=Join-Path $cache ('.fg6-runtime-'+[guid]::NewGuid().ToString('N')+'.tmp');try{$allowed=if($artifact.repository -ceq 'mojang'){@('libraries.minecraft.net')}else{@('maven.minecraftforge.net','repo.maven.apache.org')};Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts $allowed;if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash -or ($artifact.repository -ceq 'mojang' -and (Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$artifact.sha1)){throw 'FORGE_GRADLE6_RUNTIME_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cached)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        if($artifact.repository -ceq 'mojang'){$destination=[IO.Path]::GetFullPath((Join-Path $mirror ([string]$artifact.relative)))}elseif($artifact.repository -ceq 'metadata'){$relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.file);$destination=[IO.Path]::GetFullPath((Join-Path $mirror $relative))}else{$relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version);$destination=[IO.Path]::GetFullPath((Join-Path (Join-Path $mirror $relative) ([string]$artifact.file)))}
        if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirror -Target $destination)){throw 'FORGE_GRADLE6_RUNTIME_MIRROR_PATH_ESCAPE'}
        $destinationDirectory=[IO.Path]::GetDirectoryName($destination);if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirror -Target $destinationDirectory)){throw 'FORGE_GRADLE6_RUNTIME_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($destinationDirectory)
        if($written.Add($destination)){if(Test-Path -LiteralPath $destination -PathType Leaf){$existing=Get-Item -LiteralPath $destination -Force;if(($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$existing.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_GRADLE6_RUNTIME_MIRROR_CONFLICT'}}else{try{[IO.File]::Copy($cached,$destination,$false)}catch{throw 'FORGE_GRADLE6_RUNTIME_MIRROR_WRITE_FAILED'}}}
        if($artifact.repository -ceq 'mojang'){$mojangCount++}elseif($artifact.repository -ceq 'metadata'){$dynamicMetadataCount++}elseif($artifact.repository -ceq 'candidateMetadata'){$dynamicCandidateCount++}else{$mavenCount++}
    }
    [pscustomobject]@{cacheRoot=$root;mirrorRoot=$mirror;catalogHash=$resolved.catalogHash;artifactCount=$records.Count;mavenArtifactCount=$mavenCount;mojangArtifactCount=$mojangCount;dynamicMetadataCount=$dynamicMetadataCount;dynamicCandidateCount=$dynamicCandidateCount;componentCount=$resolved.components.Count;supportPomCount=$resolved.supportPoms.Count;moduleMetadataCount=$resolved.moduleMetadata.Count}
}

function Get-MmtlForgeGradle6TargetInputCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    $targetMatch=[regex]::Match([string]$catalog.targetId,'^Forge@(?<minecraftId>[0-9]+(?:\.[0-9]+){1,2})$');$forgeGradleVersion=$null;$schemaVersion=[int]$catalog.schemaVersion
    if($schemaVersion -notin @(1,2) -or -not $targetMatch.Success -or [string]$catalog.forgeVersion -notmatch ('^'+[regex]::Escape($targetMatch.Groups['minecraftId'].Value)+'-[0-9][A-Za-z0-9.-]*$') -or [string]$catalog.forgeGradleSpec -cne '[6.0,6.2)' -or -not [version]::TryParse([string]$catalog.forgeGradleResolvedVersion,[ref]$forgeGradleVersion) -or $forgeGradleVersion -lt [version]'6.0' -or $forgeGradleVersion -ge [version]'6.2' -or [string]$catalog.resolver -notmatch ('^ForgeGradle '+[regex]::Escape([string]$catalog.forgeGradleResolvedVersion)+' official MDK Gradle [0-9]+(?:\.[0-9]+){1,2} cache capture$') -or [string]$catalog.artifactStatus -cne 'HashesVerified'){throw 'FORGE_GRADLE6_TARGET_INPUT_IDENTITY_INVALID'}
    $legacyKinds=@('mdk','userdev','forgeSources','forgeUniversal','launcher','mcpConfig','mcinjector','accesstransformers','binarypatcher','specialSource','forgeflower','mergetool','renamer')
    $requiredKinds=if($schemaVersion -eq 1){$legacyKinds}else{@('mdk','userdev','forgeSources','forgeUniversal','mcpConfig','binarypatcher')}
    $artifacts=@($catalog.artifacts)
    if(($schemaVersion -eq 1 -and $artifacts.Count -ne $legacyKinds.Count) -or ($schemaVersion -eq 2 -and ($artifacts.Count -lt ($requiredKinds.Count+1) -or @($catalog.mcpTools).Count -lt 1))){throw 'FORGE_GRADLE6_TARGET_INPUT_ARTIFACT_SET_INVALID'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($kind in $requiredKinds){if(@($artifacts|Where-Object kind -CEQ $kind).Count -ne 1){throw 'FORGE_GRADLE6_TARGET_INPUT_ARTIFACT_MISSING'}}
    if($schemaVersion -eq 1){foreach($kind in $legacyKinds){if(@($artifacts|Where-Object kind -CEQ $kind).Count -ne 1){throw 'FORGE_GRADLE6_TARGET_INPUT_ARTIFACT_MISSING'}}}
    foreach($artifact in $artifacts){
        $kind=[string]$artifact.kind;$group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file
        $v2Kinds=@('mdk','userdev','forgeSources','forgeUniversal','launcher','mcpConfig','accesstransformers','binarypatcher','mcpTool')
        $allowedKinds=if($schemaVersion -eq 1){$legacyKinds}else{$v2Kinds}
        if($kind -notin $allowedKinds){throw 'FORGE_GRADLE6_TARGET_INPUT_ARTIFACT_KIND_INVALID'}
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $file -notmatch '^[A-Za-z0-9_.+-]+\.(?:jar|zip)$' -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_GRADLE6_TARGET_INPUT_ARTIFACT_INVALID'}
        $uri=$null;if(-not[Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw 'FORGE_GRADLE6_TARGET_INPUT_ARTIFACT_URL_INVALID'}
        $expectedPath='/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file
        if($uri.AbsolutePath -cne $expectedPath){throw 'FORGE_GRADLE6_TARGET_INPUT_ARTIFACT_URL_INVALID'}
        $identity=$group+':'+$module+':'+$version+':'+$file;if(-not $seen.Add($identity)){throw 'FORGE_GRADLE6_TARGET_INPUT_ARTIFACT_DUPLICATE'}
    }
    $forgeKindSuffix=@{mdk='mdk.zip';userdev='userdev.jar';forgeSources='sources.jar';forgeUniversal='universal.jar';launcher='launcher.jar'}
    $forgeArtifacts=@($artifacts|Where-Object kind -in @('mdk','userdev','forgeSources','forgeUniversal','launcher'))
    foreach($artifact in $forgeArtifacts){if([string]$artifact.group -cne 'net.minecraftforge' -or [string]$artifact.artifact -cne 'forge' -or [string]$artifact.version -cne [string]$catalog.forgeVersion -or [string]$artifact.file -cne ('forge-'+[string]$catalog.forgeVersion+'-'+$forgeKindSuffix[[string]$artifact.kind])){throw 'FORGE_GRADLE6_TARGET_INPUT_FORGE_ARTIFACT_MISMATCH'}}
    $mcp=$catalog.mcpConfig;$userdev=$catalog.userdev;$mojang=$catalog.mojangVersion;$mcpArtifact=@($artifacts|Where-Object kind -CEQ 'mcpConfig');$userdevArtifact=@($artifacts|Where-Object kind -CEQ 'userdev');$binarypatcherArtifact=@($artifacts|Where-Object kind -CEQ 'binarypatcher')
    if($mcpArtifact.Count -ne 1 -or $userdevArtifact.Count -ne 1 -or $binarypatcherArtifact.Count -ne 1 -or [string]$mcp.coordinate -notmatch '^de\.oceanlabs\.mcp:mcp_config:[A-Za-z0-9_.+-]+@zip$' -or [string]$mcpArtifact[0].group+':'+[string]$mcpArtifact[0].artifact+':'+[string]$mcpArtifact[0].version+'@zip' -cne [string]$mcp.coordinate -or [string]$mcp.configEntry -cne 'config.json' -or [long]$mcp.configBytes -le 0 -or [string]$mcp.configSha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$mcp.mappingsEntry -notmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or [long]$mcp.mappingsBytes -le 0 -or [string]$mcp.mappingsSha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_GRADLE6_TARGET_INPUT_MCP_INVALID'}
    $libraries=@($userdev.libraries);$libraryPattern='^[A-Za-z0-9_.-]+:[A-Za-z0-9_.-]+:[A-Za-z0-9_.+-]+(?::[A-Za-z0-9_.-]+)?$';$binarypatcherCoordinate='net.minecraftforge:binarypatcher:'+ [string]$binarypatcherArtifact[0].version+':fatjar'
    $duplicateLibrariesInvalid=($schemaVersion -eq 1 -and @($libraries|Sort-Object -Unique).Count -ne $libraries.Count)
    if([string]$userdev.configEntry -cne 'config.json' -or [long]$userdev.configBytes -le 0 -or [string]$userdev.configSha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$userdev.mcpCoordinate -cne [string]$mcp.coordinate -or $libraries.Count -lt 1 -or $duplicateLibrariesInvalid -or @($libraries|Where-Object{[string]$_ -notmatch $libraryPattern}).Count -gt 0 -or [string]$userdev.binarypatcher -cne $binarypatcherCoordinate -or [string]$userdevArtifact[0].version -cne [string]$catalog.forgeVersion){throw 'FORGE_GRADLE6_TARGET_INPUT_USERDEV_INVALID'}
    $mcpTools=@()
    if($schemaVersion -eq 2){
        $mcpTools=@($catalog.mcpTools);if($mcpTools.Count -lt 1 -or $mcpTools.Count -gt 64){throw 'FORGE_GRADLE6_MCP_TOOL_PIN_INVALID'};$functionNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$toolCoordinates=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($pin in $mcpTools){
            $functionName=[string]$pin.functionName;$coordinate=[string]$pin.coordinate
            if($functionName -notmatch '^[A-Za-z][A-Za-z0-9_-]*$' -or -not $functionNames.Add($functionName) -or $coordinate -notmatch '^(?<group>[A-Za-z0-9_.-]+):(?<artifact>[A-Za-z0-9_.-]+):(?<version>[A-Za-z0-9_.+-]+)(?::(?<classifier>[A-Za-z0-9_.-]+))?$'){throw 'FORGE_GRADLE6_MCP_TOOL_PIN_INVALID'}
            $null=$toolCoordinates.Add($coordinate)
        }
        $toolArtifacts=@($artifacts|Where-Object kind -CEQ 'mcpTool')
        if($toolArtifacts.Count -ne $toolCoordinates.Count){throw 'FORGE_GRADLE6_MCP_TOOL_ARTIFACT_SET_INVALID'}
        foreach($coordinate in $toolCoordinates){
            $match=[regex]::Match($coordinate,'^(?<group>[A-Za-z0-9_.-]+):(?<artifact>[A-Za-z0-9_.-]+):(?<version>[A-Za-z0-9_.+-]+)(?::(?<classifier>[A-Za-z0-9_.-]+))?$')
            $expectedFile=$match.Groups['artifact'].Value+'-'+$match.Groups['version'].Value+$(if($match.Groups['classifier'].Success){'-'+$match.Groups['classifier'].Value})+'.jar'
            $matches=@($toolArtifacts|Where-Object {[string]$_.group -ceq $match.Groups['group'].Value -and [string]$_.artifact -ceq $match.Groups['artifact'].Value -and [string]$_.version -ceq $match.Groups['version'].Value -and [string]$_.file -ceq $expectedFile})
            if($matches.Count -ne 1){throw 'FORGE_GRADLE6_MCP_TOOL_ARTIFACT_MISMATCH'}
        }
    }
    $mojangMatch=[regex]::Match([string]$mojang.url,'^https://piston-meta\.mojang\.com/v1/packages/(?<sha1>[a-f0-9]{40})/'+[regex]::Escape($targetMatch.Groups['minecraftId'].Value)+'\.json$')
    if(-not $mojangMatch.Success -or [string]$mojang.sha1 -cne $mojangMatch.Groups['sha1'].Value -or [long]$mojang.bytes -le 0 -or [string]$mojang.sha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_GRADLE6_TARGET_INPUT_MOJANG_INVALID'}
    $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
    if($hash -cne [string]$catalog.catalogHash){throw 'FORGE_GRADLE6_TARGET_INPUT_CATALOG_HASH_MISMATCH'}
    [pscustomobject]@{catalog=$catalog;catalogHash=$hash;artifacts=$artifacts;mcpTools=$mcpTools;minecraftId=$targetMatch.Groups['minecraftId'].Value}
}

function Get-MmtlForgeGradle6TargetInputMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=180)
    $resolved=Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$cache=Join-Path $root 'artifact-cache';$mirror=Join-Path $root 'maven-mirror'
    [void][IO.Directory]::CreateDirectory($cache);[void][IO.Directory]::CreateDirectory($mirror)
    foreach($artifact in $resolved.artifacts){
        $hash=[string]$artifact.sha256;$cached=Join-Path $cache $hash
        if(Test-Path -LiteralPath $cached -PathType Leaf){$item=Get-Item -LiteralPath $cached -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cached) -cne $hash){throw 'FORGE_GRADLE6_TARGET_INPUT_CACHE_INVALID'}}
        else{$temporary=Join-Path $cache ('.target-input-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash){throw 'FORGE_GRADLE6_TARGET_INPUT_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cached)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version)
        $destinationDirectory=[IO.Path]::GetFullPath((Join-Path $mirror $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirror -Target $destinationDirectory)){throw 'FORGE_GRADLE6_TARGET_INPUT_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($destinationDirectory)
        $destination=[IO.Path]::GetFullPath((Join-Path $destinationDirectory ([string]$artifact.file)));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirror -Target $destination)){throw 'FORGE_GRADLE6_TARGET_INPUT_MIRROR_PATH_ESCAPE'}
        if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_GRADLE6_TARGET_INPUT_MIRROR_COLLISION'}}else{[IO.File]::Copy($cached,$destination,$false)}
    }
    $version=$resolved.catalog.mojangVersion;$versionCache=Join-Path $cache ([string]$version.sha256)
    if(Test-Path -LiteralPath $versionCache -PathType Leaf){$item=Get-Item -LiteralPath $versionCache -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$version.bytes -or (Get-MmtlForgePinFileHash -Path $versionCache) -cne [string]$version.sha256 -or (Get-FileHash -LiteralPath $versionCache -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$version.sha1){throw 'FORGE_GRADLE6_MOJANG_VERSION_CACHE_INVALID'}}
    else{$temporary=Join-Path $cache ('.mojang-version-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$version.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('piston-meta.mojang.com');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$version.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne [string]$version.sha256 -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$version.sha1){throw 'FORGE_GRADLE6_MOJANG_VERSION_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$versionCache)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
    $versionPath=Join-Path $root ($resolved.minecraftId+'-version.json');if(Test-Path -LiteralPath $versionPath -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $versionPath) -cne [string]$version.sha256){throw 'FORGE_GRADLE6_MOJANG_VERSION_COPY_MISMATCH'}}else{[IO.File]::Copy($versionCache,$versionPath,$false)}
    $byKind=@{};foreach($artifact in $resolved.artifacts){$byKind[[string]$artifact.kind]=$artifact}
    $verifyArchiveEntry={param([string]$ArchivePath,[string]$EntryName,[long]$ExpectedBytes,[string]$ExpectedHash)$archive=[IO.Compression.ZipFile]::OpenRead($ArchivePath);try{$entries=@($archive.Entries|Where-Object FullName -CEQ $EntryName);if($entries.Count -ne 1 -or [long]$entries[0].Length -ne $ExpectedBytes -or (($entries[0].ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'FORGE_GRADLE6_TARGET_INPUT_ARCHIVE_ENTRY_INVALID'};$input=$entries[0].Open();$memory=[IO.MemoryStream]::new();try{$input.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose();$input.Dispose()};$actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();if($actual -cne $ExpectedHash){throw 'FORGE_GRADLE6_TARGET_INPUT_ARCHIVE_ENTRY_HASH_MISMATCH'};,$bytes}finally{$archive.Dispose()}}
    $userdevDirectory=Join-Path (Join-Path (Join-Path $mirror ([string]$byKind.userdev.group.Replace('.',[IO.Path]::DirectorySeparatorChar))) ([string]$byKind.userdev.artifact)) ([string]$byKind.userdev.version)
    $userdevPath=Join-Path $userdevDirectory ([string]$byKind.userdev.file)
    $mcpDirectory=Join-Path (Join-Path (Join-Path $mirror ([string]$byKind.mcpConfig.group.Replace('.',[IO.Path]::DirectorySeparatorChar))) ([string]$byKind.mcpConfig.artifact)) ([string]$byKind.mcpConfig.version)
    $mcpPath=Join-Path $mcpDirectory ([string]$byKind.mcpConfig.file)
    $userdevBytes=&$verifyArchiveEntry $userdevPath ([string]$resolved.catalog.userdev.configEntry) ([long]$resolved.catalog.userdev.configBytes) ([string]$resolved.catalog.userdev.configSha256)
    $userdevConfig=[Text.Encoding]::UTF8.GetString($userdevBytes)|ConvertFrom-Json -ErrorAction Stop
    if([string]$userdevConfig.mcp -cne [string]$resolved.catalog.userdev.mcpCoordinate -or [string]$userdevConfig.binpatcher.version -cne [string]$resolved.catalog.userdev.binarypatcher){throw 'FORGE_GRADLE6_USERDEV_CONFIG_MISMATCH'}
    [void](Test-MmtlForgeGradle6UserdevLibraries -Actual @($userdevConfig.libraries) -Expected @($resolved.catalog.userdev.libraries))
    $mcpConfigBytes=&$verifyArchiveEntry $mcpPath ([string]$resolved.catalog.mcpConfig.configEntry) ([long]$resolved.catalog.mcpConfig.configBytes) ([string]$resolved.catalog.mcpConfig.configSha256)
    [void](&$verifyArchiveEntry $mcpPath ([string]$resolved.catalog.mcpConfig.mappingsEntry) ([long]$resolved.catalog.mcpConfig.mappingsBytes) ([string]$resolved.catalog.mcpConfig.mappingsSha256))
    if([int]$resolved.catalog.schemaVersion -eq 2){
        try{$mcpConfig=[Text.Encoding]::UTF8.GetString($mcpConfigBytes)|ConvertFrom-Json -ErrorAction Stop}catch{throw 'FORGE_GRADLE6_MCP_CONFIG_JSON_INVALID'}
        [void](Test-MmtlForgeGradle6McpToolPins -Config $mcpConfig -ExpectedTools $resolved.mcpTools)
    }
    [pscustomobject]@{mirrorRoot=$mirror;catalogHash=$resolved.catalogHash;artifactCount=$resolved.artifacts.Count;userdevPath=$userdevPath;mcpConfigPath=$mcpPath;mojangVersionPath=$versionPath;mojangVersionHash=[string]$version.sha256}
}

function Test-MmtlForgeGradle6McpToolPins {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Config,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ExpectedTools)
    if(-not $Config.functions -or -not $Config.functions.PSObject.Properties){throw 'FORGE_GRADLE6_MCP_TOOLS_MISMATCH'}
    $actual=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$expected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($property in $Config.functions.PSObject.Properties){
        $coordinate=[string]$property.Value.version
        if(-not $coordinate){throw 'FORGE_GRADLE6_MCP_TOOLS_MISMATCH'}
        $null=$actual.Add([string]$property.Name+'|'+$coordinate)
    }
    foreach($pin in $ExpectedTools){
        $functionName=[string]$pin.functionName;$coordinate=[string]$pin.coordinate
        if(-not $expected.Add($functionName+'|'+$coordinate)){throw 'FORGE_GRADLE6_MCP_TOOLS_MISMATCH'}
    }
    if($actual.Count -ne $expected.Count){throw 'FORGE_GRADLE6_MCP_TOOLS_MISMATCH'}
    foreach($entry in $actual){if(-not $expected.Contains($entry)){throw 'FORGE_GRADLE6_MCP_TOOLS_MISMATCH'}}
    $true
}

function Test-MmtlForgeGradle6UserdevLibraries {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual,[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected)
    if($Actual.Count -ne $Expected.Count -or (($Actual|Sort-Object)-join "`n") -cne (($Expected|Sort-Object)-join "`n")){throw 'FORGE_GRADLE6_USERDEV_CONFIG_MISMATCH'}
    $true
}

function Get-MmtlForgeBuildUserdevArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $CatalogPath;$root=[IO.Path]::GetFullPath($CacheRoot);$cache=Join-Path $root 'artifact-cache';[void][IO.Directory]::CreateDirectory($cache);$files=@{}
    foreach($kind in @('pom','userdev','universal')){$entry=$resolved.forgeUserdev.$kind;$cachePath=Join-Path $cache ([string]$entry.sha256);if(Test-Path -LiteralPath $cachePath -PathType Leaf){$item=Get-Item -LiteralPath $cachePath -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$entry.bytes -or (Get-MmtlForgePinFileHash -Path $cachePath) -cne [string]$entry.sha256){throw 'FORGE_BUILD_USERDEV_CACHE_INVALID'}}else{$temporary=Join-Path $cache ('.forge-userdev-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$entry.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$entry.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne [string]$entry.sha256){throw 'FORGE_BUILD_USERDEV_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cachePath)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}};$copyPath=Join-Path $root ([string]$entry.file);if(Test-Path -LiteralPath $copyPath -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $copyPath) -cne [string]$entry.sha256){throw 'FORGE_BUILD_USERDEV_COPY_HASH_MISMATCH'}}else{[IO.File]::Copy($cachePath,$copyPath,$false)};$files[$kind]=$copyPath}
    $files
}

function Get-MmtlForgeUserdevConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+\.json$')][string]$EntryName,
        [Parameter(Mandatory)][ValidateRange(1,1048576)][long]$ExpectedBytes,
        [Parameter(Mandatory)][ValidatePattern('^(?i:[a-f0-9]{64})$')][string]$ExpectedSha256,
        [ValidateNotNullOrEmpty()][string]$ExpectedMcpCoordinate,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedLibraries,
        [switch]$SkipLibraryValidation
    )
    $path=[IO.Path]::GetFullPath($ArchivePath)
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'FORGE_USERDEV_ARCHIVE_MISSING'}
    $item=Get-Item -LiteralPath $path -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -le 0){throw 'FORGE_USERDEV_ARCHIVE_INVALID'}
    $archive=[IO.Compression.ZipFile]::OpenRead($path)
    try{
        $entries=@($archive.Entries|Where-Object FullName -CEQ $EntryName)
        if($entries.Count -ne 1 -or [long]$entries[0].Length -ne $ExpectedBytes){throw 'FORGE_USERDEV_CONFIG_ENTRY_INVALID'}
        $stream=$entries[0].Open();$memory=[IO.MemoryStream]::new()
        try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose();$stream.Dispose()}
    }finally{$archive.Dispose()}
    $sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if([long]$bytes.Length -ne $ExpectedBytes -or $sha256 -cne $ExpectedSha256.ToLowerInvariant()){throw 'FORGE_USERDEV_CONFIG_HASH_MISMATCH'}
    try{$config=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -ErrorAction Stop}catch{throw 'FORGE_USERDEV_CONFIG_JSON_INVALID'}
    $mcpCoordinate=if($config.PSObject.Properties['mcp']){[string]$config.mcp}else{''}
    if($ExpectedMcpCoordinate -and $mcpCoordinate -cne $ExpectedMcpCoordinate){throw 'FORGE_USERDEV_CONFIG_MCP_COORDINATE_MISMATCH'}
    $actualLibraries=if($config.libraries -is [Array]){@($config.libraries|ForEach-Object{if($_ -is [string]){[string]$_}elseif($_ -and $_.PSObject.Properties['name']){[string]$_.name}else{throw 'FORGE_USERDEV_CONFIG_LIBRARY_ENTRY_INVALID'}})}elseif($config.libraries -and $config.libraries.PSObject.Properties){@($config.libraries.PSObject.Properties|ForEach-Object{@($_.Value)}|ForEach-Object{[string]$_}|Where-Object{$_})}else{@()}
    if(@($actualLibraries|Where-Object{[string]::IsNullOrWhiteSpace([string]$_)}).Count){throw 'FORGE_USERDEV_CONFIG_LIBRARY_ENTRY_INVALID'}
    if(-not $SkipLibraryValidation -and ($actualLibraries.Count -ne @($ExpectedLibraries).Count -or @($actualLibraries|Sort-Object -Unique).Count -ne $actualLibraries.Count -or (($actualLibraries|Sort-Object -Unique) -join "`n") -cne ((@($ExpectedLibraries)|Sort-Object -Unique) -join "`n"))){throw 'FORGE_USERDEV_CONFIG_LIBRARY_SET_MISMATCH'}
    [pscustomobject]@{entry=$EntryName;bytes=[long]$bytes.Length;sha256=$sha256;mcp=$mcpCoordinate;libraries=$actualLibraries;config=$config}
}

function Get-MmtlForgeBuildMcpArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $resolved=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $CatalogPath;$root=[IO.Path]::GetFullPath($CacheRoot);$cache=Join-Path $root 'artifact-cache';[void][IO.Directory]::CreateDirectory($cache);$files=@{}
    foreach($entry in $resolved.mcpArtifacts){$cachePath=Join-Path $cache ([string]$entry.sha256);if(Test-Path -LiteralPath $cachePath -PathType Leaf){$item=Get-Item -LiteralPath $cachePath -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$item.Length -ne [long]$entry.bytes -or (Get-MmtlForgePinFileHash -Path $cachePath) -cne [string]$entry.sha256){throw 'FORGE_BUILD_MCP_ARTIFACT_CACHE_INVALID'}}else{$temporary=Join-Path $cache ('.mcp-artifact-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$entry.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$entry.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne [string]$entry.sha256){throw 'FORGE_BUILD_MCP_ARTIFACT_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cachePath)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}};$files[[string]$entry.coordinate]=$cachePath}
    $files
}

function Get-MmtlForgeBuildArtifactCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)
    $catalog=Get-Content -LiteralPath $CatalogPath -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
    if([int]$catalog.schemaVersion -ne 1 -or [string]$catalog.targetId -cne 'Forge@1.8' -or [string]$catalog.resolver -cne 'Gradle 2.7 official MDK build cache capture' -or [string]$catalog.artifactStatus -cne 'HashesVerified' -or [string]$catalog.targetBuildStatus -notin @('PendingRunnerValidation','BuildVerified')){throw 'FORGE_BUILD_ARTIFACT_CATALOG_IDENTITY_INVALID'}
    $artifacts=@($catalog.artifacts)
    if($artifacts.Count -lt 1){throw 'FORGE_BUILD_ARTIFACT_CATALOG_EMPTY'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($artifact in $artifacts){
        $group=[string]$artifact.group;$module=[string]$artifact.artifact;$version=[string]$artifact.version;$file=[string]$artifact.file;$extension=[string]$artifact.extension
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $file -notmatch '^[A-Za-z0-9_.+-]+\.(jar|pom|zip)$' -or $extension -notin @('jar','pom','zip') -or -not $file.EndsWith('.'+$extension,[StringComparison]::Ordinal) -or [long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$'){throw 'FORGE_BUILD_ARTIFACT_ENTRY_INVALID'}
        $uri=$null;if(-not [Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -notin @('maven.minecraftforge.net','libraries.minecraft.net') -or $uri.UserInfo){throw 'FORGE_BUILD_ARTIFACT_URL_INVALID'}
        $expectedPath='/'+$group.Replace('.','/')+'/'+$module+'/'+$version+'/'+$file
        if($uri.AbsolutePath -cne $expectedPath){throw 'FORGE_BUILD_ARTIFACT_URL_COORDINATE_MISMATCH'}
        $key=$group+':'+$module+':'+$version+':'+$file
        if(-not $seen.Add($key)){throw 'FORGE_BUILD_ARTIFACT_DUPLICATE'}
    }
    $core=[pscustomobject][ordered]@{schemaVersion=[int]$catalog.schemaVersion;targetId=[string]$catalog.targetId;resolver=[string]$catalog.resolver;artifactStatus=[string]$catalog.artifactStatus;targetBuildStatus=[string]$catalog.targetBuildStatus;artifacts=$artifacts}
    $actualHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 20 -Compress)))).ToLowerInvariant()
    if($actualHash -cne [string]$catalog.catalogHash){throw 'FORGE_BUILD_ARTIFACT_CATALOG_HASH_MISMATCH'}
    [pscustomobject]@{catalog=$catalog;catalogHash=$actualHash;artifacts=$artifacts}
}

function Get-MmtlForgeBuildArtifactMirror {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    $resolvedCatalog=Get-MmtlForgeBuildArtifactCatalog -CatalogPath $CatalogPath
    $root=[IO.Path]::GetFullPath($CacheRoot);$artifactCache=Join-Path $root 'artifact-cache';$mirrorRoot=Join-Path $root 'maven-mirror'
    [void][IO.Directory]::CreateDirectory($artifactCache);[void][IO.Directory]::CreateDirectory($mirrorRoot)
    foreach($artifact in $resolvedCatalog.artifacts){
        $hash=[string]$artifact.sha256;$cachedPath=Join-Path $artifactCache $hash
        if(Test-Path -LiteralPath $cachedPath -PathType Leaf){$cacheItem=Get-Item -LiteralPath $cachedPath -Force;if(($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$cacheItem.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $cachedPath) -cne $hash){throw 'FORGE_BUILD_ARTIFACT_CACHE_INVALID'}}
        else{$temporary=Join-Path $artifactCache ('.download-'+[guid]::NewGuid().ToString('N')+'.tmp');try{Invoke-MmtlForgeHttpsDownload -Uri ([Uri][string]$artifact.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net','libraries.minecraft.net');if([long](Get-Item -LiteralPath $temporary -Force).Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $temporary) -cne $hash){throw 'FORGE_BUILD_ARTIFACT_DOWNLOAD_HASH_MISMATCH'};[IO.File]::Move($temporary,$cachedPath)}finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}}
        $relative=Join-Path (Join-Path (([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar)) ([string]$artifact.artifact)) ([string]$artifact.version)
        $destinationDirectory=[IO.Path]::GetFullPath((Join-Path $mirrorRoot $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $destinationDirectory)){throw 'FORGE_BUILD_ARTIFACT_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory($destinationDirectory)
        $destination=[IO.Path]::GetFullPath((Join-Path $destinationDirectory ([string]$artifact.file)));if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $destination)){throw 'FORGE_BUILD_ARTIFACT_MIRROR_PATH_ESCAPE'}
        if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $hash){throw 'FORGE_BUILD_ARTIFACT_MIRROR_CONFLICT'}}else{[IO.File]::Copy($cachedPath,$destination,$false)}
    }
    [pscustomobject]@{mirrorRoot=$mirrorRoot;catalogHash=$resolvedCatalog.catalogHash;artifactCount=$resolvedCatalog.artifacts.Count}
}

function Get-MmtlForgePinnedArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pin,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=120)
    Test-MmtlForgePinValue -Pin $Pin
    $root=[IO.Path]::GetFullPath($CacheRoot)
    $artifactVersion=if($Pin.PSObject.Properties['forgeGradleResolvedVersion']){[string]$Pin.forgeGradleResolvedVersion}else{[string]$Pin.forgeGradleTimestamp}
    $pluginDirectory=Join-Path $root $artifactVersion
    [void][IO.Directory]::CreateDirectory($pluginDirectory)
    $resolved=@()
    foreach($item in @(
        [pscustomobject]@{kind='jar';url=[string]$Pin.forgeGradleJarUrl;hash=[string]$Pin.forgeGradleJarSha256},
        [pscustomobject]@{kind='pom';url=[string]$Pin.forgeGradlePomUrl;hash=[string]$Pin.forgeGradlePomSha256}
    )){
        $name='ForgeGradle-'+$artifactVersion+'.'+$item.kind
        $destination=Join-Path $pluginDirectory $name
        if(Test-Path -LiteralPath $destination -PathType Leaf){
            if((Get-MmtlForgePinFileHash -Path $destination) -cne $item.hash){throw "FORGE_PIN_CACHE_HASH_MISMATCH:$($item.kind)"}
        } else {
            $temporary=Join-Path $pluginDirectory ('.download-'+[guid]::NewGuid().ToString('N')+'.tmp')
            try{
                Invoke-MmtlForgeHttpsDownload -Uri ([Uri]$item.url) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('maven.minecraftforge.net')
                if((Get-MmtlForgePinFileHash -Path $temporary) -cne $item.hash){throw "FORGE_PIN_DOWNLOAD_HASH_MISMATCH:$($item.kind)"}
                try{[IO.File]::Move($temporary,$destination)}catch{if(-not(Test-Path -LiteralPath $destination -PathType Leaf) -or (Get-MmtlForgePinFileHash -Path $destination) -cne $item.hash){throw}}
            }finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}
        }
        $resolved+=,[pscustomobject]@{kind=$item.kind;path=$destination;sha256=(Get-MmtlForgePinFileHash -Path $destination)}
    }
    [pscustomobject]@{jarPath=[string]($resolved|Where-Object kind -eq 'jar').path;pomPath=[string]($resolved|Where-Object kind -eq 'pom').path;jarSha256=[string]($resolved|Where-Object kind -eq 'jar').sha256;pomSha256=[string]($resolved|Where-Object kind -eq 'pom').sha256}
}

function Get-MmtlForgePinnedGradle {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pin,[Parameter(Mandatory)][string]$CacheRoot,[ValidateRange(1,600)][int]$TimeoutSeconds=180)
    if($Pin.PSObject.Properties['pluginVersion']){
        $uri=$null;if([string]$Pin.gradleDistributionSha256 -notmatch '^(?i:[a-f0-9]{64})$' -or -not [Uri]::TryCreate([string]$Pin.gradleDistributionUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'services.gradle.org' -or $uri.AbsolutePath -cne '/distributions/gradle-2.7-bin.zip'){throw 'FORGE_PLUGIN_BUILD_PIN_GRADLE_DISTRIBUTION_INVALID'}
    }else{Test-MmtlForgePinValue -Pin $Pin}
    $root=[IO.Path]::GetFullPath($CacheRoot);[void][IO.Directory]::CreateDirectory($root)
    $archive=Join-Path $root ('gradle-'+[string]$Pin.gradleDistributionSha256+'.zip')
    if(Test-Path -LiteralPath $archive -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $archive) -cne [string]$Pin.gradleDistributionSha256){throw 'FORGE_GRADLE_DISTRIBUTION_CACHE_HASH_MISMATCH'}}
    else{
        $temporary=Join-Path $root ('.gradle-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try{
            Invoke-MmtlForgeHttpsDownload -Uri ([Uri]$Pin.gradleDistributionUrl) -DestinationPath $temporary -TimeoutSeconds $TimeoutSeconds -AllowedHosts @('services.gradle.org','github.com','objects.githubusercontent.com','release-assets.githubusercontent.com')
            if((Get-MmtlForgePinFileHash -Path $temporary) -cne [string]$Pin.gradleDistributionSha256){throw 'FORGE_GRADLE_DISTRIBUTION_DOWNLOAD_HASH_MISMATCH'}
            try{[IO.File]::Move($temporary,$archive)}catch{if(-not(Test-Path -LiteralPath $archive -PathType Leaf) -or (Get-MmtlForgePinFileHash -Path $archive) -cne [string]$Pin.gradleDistributionSha256){throw}}
        }finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}
    }
    $versionMatch=[regex]::Match([Uri]$Pin.gradleDistributionUrl,'gradle-(?<version>[0-9.]+)-(?:bin|all)\.zip$')
    if(-not $versionMatch.Success){throw 'FORGE_GRADLE_DISTRIBUTION_VERSION_INVALID'}
    $distributionRoot=Join-Path $root ('gradle-'+$versionMatch.Groups['version'].Value)
    $provider=Get-MmtlPlatformProvider
    $executable=Join-Path $distributionRoot $(if($provider.OS -eq 'Windows'){'bin/gradle.bat'}else{'bin/gradle'})
    if(-not(Test-Path -LiteralPath $executable -PathType Leaf)){
        if(Test-Path -LiteralPath $distributionRoot){throw 'FORGE_GRADLE_DISTRIBUTION_CACHE_INCOMPLETE'}
        [void][IO.Directory]::CreateDirectory($distributionRoot)
        $zip=[IO.Compression.ZipFile]::OpenRead($archive)
        try{
            foreach($entry in $zip.Entries){
                $relative=$entry.FullName.Replace('/',[IO.Path]::DirectorySeparatorChar)
                $destination=[IO.Path]::GetFullPath((Join-Path $root $relative))
                if(-not(Test-MmtlPlatformPathInsideRoot -Root $root -Target $destination)){throw 'FORGE_GRADLE_DISTRIBUTION_PATH_ESCAPE'}
                $unixType=($entry.ExternalAttributes -shr 16) -band 0xF000
                if($unixType -eq 0xA000){throw 'FORGE_GRADLE_DISTRIBUTION_SYMLINK_REJECTED'}
                if($entry.FullName.EndsWith('/')){[void][IO.Directory]::CreateDirectory($destination);continue}
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                $source=$entry.Open();$stream=[IO.FileStream]::new($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$source.CopyTo($stream)}finally{$stream.Dispose();$source.Dispose()}
            }
        }finally{$zip.Dispose()}
        if(-not(Test-Path -LiteralPath $executable -PathType Leaf)){throw 'FORGE_GRADLE_DISTRIBUTION_EXECUTABLE_MISSING'}
    }
    if($provider.OS -ne 'Windows'){
        $mode=[IO.File]::GetUnixFileMode($executable)
        if(($mode -band [IO.UnixFileMode]::UserExecute) -eq 0){[IO.File]::SetUnixFileMode($executable,$mode -bor [IO.UnixFileMode]::UserExecute)}
    }
    [pscustomobject]@{distributionRoot=$distributionRoot;executablePath=$executable;archivePath=$archive;archiveSha256=[string]$Pin.gradleDistributionSha256;version=$versionMatch.Groups['version'].Value}
}

function Get-MmtlForgePinnedVersionJsonUrl {
    [CmdletBinding()]
    param($Pin,$ClasspathCatalog)
    if($Pin -and $Pin.PSObject.Properties['versionJson'] -and $Pin.versionJson -and $Pin.versionJson.url){return [string]$Pin.versionJson.url}
    if($ClasspathCatalog -and $ClasspathCatalog.PSObject.Properties['mojangVersion'] -and $ClasspathCatalog.mojangVersion -and $ClasspathCatalog.mojangVersion.url){return [string]$ClasspathCatalog.mojangVersion.url}
    return $null
}

function New-MmtlForgeClasspathSnapshotMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ClasspathCatalog,[Parameter(Mandatory)][string]$RepositoryRoot)
    $dependencies=@($ClasspathCatalog.dependencies|Where-Object { $_.group -ceq 'net.minecraftforge' -and (($_.artifact -ceq 'fernflower' -and $_.version -ceq '2.0-SNAPSHOT') -or ($_.artifact -ceq 'forgeflower' -and $_.version -ceq '1.0.342-SNAPSHOT')) })
    if($dependencies.Count -ne 1){throw 'FORGE_BUILD_CLASSPATH_DECOMPILER_PIN_MISSING'}
    $decompiler=$dependencies[0];$baseVersion=[string]$decompiler.version -replace '-SNAPSHOT$',''
    $artifacts=@($ClasspathCatalog.artifacts|Where-Object { $_.group -ceq 'net.minecraftforge' -and $_.artifact -ceq [string]$decompiler.artifact -and $_.version -ceq [string]$decompiler.version })
    $jars=@($artifacts|Where-Object extension -ceq 'jar');$poms=@($artifacts|Where-Object extension -ceq 'pom')
    $prefix=[regex]::Escape([string]$decompiler.artifact+'-'+$baseVersion)
    $jarMatch=if($jars.Count -eq 1){[regex]::Match([string]$jars[0].file,('^'+$prefix+'-(?<stamp>[0-9]{8}\.[0-9]{6})-(?<build>[0-9]+)\.jar$'))}else{$null}
    $pomMatch=if($poms.Count -eq 1){[regex]::Match([string]$poms[0].file,('^'+$prefix+'-(?<stamp>[0-9]{8}\.[0-9]{6})-(?<build>[0-9]+)\.pom$'))}else{$null}
    if(-not $jarMatch -or -not $jarMatch.Success -or -not $pomMatch -or -not $pomMatch.Success -or $jarMatch.Groups['stamp'].Value -cne $pomMatch.Groups['stamp'].Value -or $jarMatch.Groups['build'].Value -cne $pomMatch.Groups['build'].Value){throw 'FORGE_BUILD_CLASSPATH_DECOMPILER_SNAPSHOT_INVALID'}
    $stamp=$jarMatch.Groups['stamp'].Value;$build=$jarMatch.Groups['build'].Value;$updated=$stamp.Replace('.','')
    $groupPath=[string]$decompiler.group -replace '\.',[string][IO.Path]::DirectorySeparatorChar
    $repository=[IO.Path]::GetFullPath($RepositoryRoot);$modulePath=Join-Path (Join-Path (Join-Path $repository $groupPath) ([string]$decompiler.artifact)) ([string]$decompiler.version)
    [void][IO.Directory]::CreateDirectory($modulePath)
    $value=$baseVersion+'-'+$stamp+'-'+$build
    $metadata='<?xml version="1.0" encoding="UTF-8"?><metadata><groupId>'+[string]$decompiler.group+'</groupId><artifactId>'+[string]$decompiler.artifact+'</artifactId><version>'+[string]$decompiler.version+'</version><versioning><snapshot><timestamp>'+$stamp+'</timestamp><buildNumber>'+$build+'</buildNumber></snapshot><lastUpdated>'+$updated+'</lastUpdated><snapshotVersions><snapshotVersion><extension>pom</extension><value>'+$value+'</value><updated>'+$updated+'</updated></snapshotVersion><snapshotVersion><extension>jar</extension><value>'+$value+'</value><updated>'+$updated+'</updated></snapshotVersion></snapshotVersions></versioning></metadata>'
    $path=Join-Path $modulePath 'maven-metadata.xml';[IO.File]::WriteAllText($path,$metadata,[Text.UTF8Encoding]::new($false));return $path
}

function New-MmtlForgeClasspathDynamicVersionMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ClasspathCatalog,[Parameter(Mandatory)][string]$RepositoryRoot)
    $resolutions=@($ClasspathCatalog.catalog.dynamicVersionResolutions)
    $repository=[IO.Path]::GetFullPath($RepositoryRoot)
    $targetId=if($ClasspathCatalog.catalog.PSObject.Properties['targetId']){[string]$ClasspathCatalog.catalog.targetId}else{''}
    $allowed=switch($targetId){
        'Forge@1.12.2' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13';'net.minecraftforge|legacydev|0.2.3.+'='0.2.3.1'}}
        'Forge@1.13.2' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.14.2' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.14.3' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.14.4' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.15' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.15.2' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.15.1' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.16.1' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.16.2' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.16.3' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        'Forge@1.16.4' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13'}}
        '' {@{'net.minecraftforge|artifactural|1.0.+'='1.0.13';'net.minecraftforge|legacydev|0.2.3.+'='0.2.3.1'}}
        default {throw 'FORGE_BUILD_CLASSPATH_DYNAMIC_VERSION_TARGET_UNSUPPORTED'}
    }
    if($resolutions.Count -ne $allowed.Count){throw 'FORGE_BUILD_CLASSPATH_DYNAMIC_VERSION_PIN_INVALID'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$paths=[Collections.Generic.List[string]]::new()
    foreach($resolution in $resolutions){
        $key=[string]$resolution.group+'|'+[string]$resolution.artifact+'|'+[string]$resolution.selector
        if(-not $allowed.ContainsKey($key) -or [string]$resolution.resolvedVersion -cne [string]$allowed[$key] -or -not $seen.Add($key)){throw 'FORGE_BUILD_CLASSPATH_DYNAMIC_VERSION_PIN_UNSUPPORTED'}
        $dependency=@($ClasspathCatalog.dependencies|Where-Object{[string]$_.group -ceq [string]$resolution.group -and [string]$_.artifact -ceq [string]$resolution.artifact -and [string]$_.version -ceq [string]$resolution.resolvedVersion})
        if($dependency.Count -ne 1){throw 'FORGE_BUILD_CLASSPATH_DYNAMIC_VERSION_DEPENDENCY_MISMATCH'}
        $groupPath=[string]$resolution.group -replace '\.',[string][IO.Path]::DirectorySeparatorChar
        $modulePath=[IO.Path]::GetFullPath((Join-Path (Join-Path $repository $groupPath) ([string]$resolution.artifact)))
        if(-not(Test-MmtlPlatformPathInsideRoot -Root $repository -Target $modulePath)){throw 'FORGE_BUILD_CLASSPATH_DYNAMIC_VERSION_PATH_ESCAPE'}
        [void][IO.Directory]::CreateDirectory($modulePath)
        $groupXml=[Security.SecurityElement]::Escape([string]$resolution.group);$artifactXml=[Security.SecurityElement]::Escape([string]$resolution.artifact);$versionXml=[Security.SecurityElement]::Escape([string]$resolution.resolvedVersion)
        $metadata='<?xml version="1.0" encoding="UTF-8"?><metadata><groupId>'+$groupXml+'</groupId><artifactId>'+$artifactXml+'</artifactId><versioning><latest>'+$versionXml+'</latest><release>'+$versionXml+'</release><versions><version>'+$versionXml+'</version></versions></versioning></metadata>'
        $path=Join-Path $modulePath 'maven-metadata.xml';[IO.File]::WriteAllText($path,$metadata,[Text.UTF8Encoding]::new($false));$paths.Add($path)
    }
    if($seen.Count -ne $allowed.Count){throw 'FORGE_BUILD_CLASSPATH_DYNAMIC_VERSION_PIN_INCOMPLETE'}
    return $paths.ToArray()
}

function Test-MmtlForgeClasspathMojangLibraryPins {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ClasspathCatalog,[Parameter(Mandatory)][string]$MojangVersionJsonPath)
    $versionJson=Get-Content -LiteralPath $MojangVersionJsonPath -Raw|ConvertFrom-Json -ErrorAction Stop
    $minecraftVersion=([string]$ClasspathCatalog.catalog.targetId -replace '^Forge@','')
    if([string]$versionJson.id -cne $minecraftVersion){throw 'FORGE_BUILD_CLASSPATH_MOJANG_VERSION_ID_MISMATCH'}
    foreach($library in @($ClasspathCatalog.requiredLibraries|Where-Object source -eq 'MojangVersionJson')){
        $entries=@($versionJson.libraries|Where-Object{[string]$_.name -ceq [string]$library.coordinate -and $_.downloads.artifact})
        if($entries.Count -lt 1){throw 'FORGE_BUILD_MOJANG_REQUIRED_LIBRARY_PIN_MISMATCH'}
        foreach($entry in $entries){if([string]$entry.downloads.artifact.url -cne [string]$library.url -or [long]$entry.downloads.artifact.size -ne [long]$library.bytes -or [string]$entry.downloads.artifact.sha1 -cne [string]$library.sha1){throw 'FORGE_BUILD_MOJANG_REQUIRED_LIBRARY_PIN_MISMATCH'}}
    }
    return $true
}

function Initialize-MmtlForgePinnedProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)]$Pin,
        [Parameter(Mandatory)][string]$ForgeGradleJarPath,
        [Parameter(Mandatory)][string]$ForgeGradlePomPath,
        [string]$ClasspathArtifactCatalogPath,
        [string]$ClasspathMirrorRoot,
        [string]$ClasspathMcpVersionsPath,
        [string]$ClasspathMojangVersionPath,
        [hashtable]$ClasspathForgeUserdevFiles,
        [hashtable]$ClasspathMcpArtifacts,
        [string]$GradleHome,
        [object]$Fixture,
        [string]$FixtureOverlayRoot
    )
    Test-MmtlForgePinValue -Pin $Pin
    if([bool]$ClasspathArtifactCatalogPath -ne [bool]$ClasspathMirrorRoot){throw 'FORGE_BUILD_CLASSPATH_MIRROR_ARGUMENTS_INCOMPLETE'}
    if([bool]$ClasspathArtifactCatalogPath -ne [bool]$ClasspathMcpVersionsPath -or [bool]$ClasspathArtifactCatalogPath -ne [bool]$ClasspathMojangVersionPath -or [bool]$ClasspathArtifactCatalogPath -ne [bool]$ClasspathForgeUserdevFiles -or [bool]$ClasspathArtifactCatalogPath -ne [bool]$ClasspathMcpArtifacts -or [bool]$ClasspathArtifactCatalogPath -ne [bool]$GradleHome){throw 'FORGE_BUILD_CLASSPATH_MCP_ARGUMENTS_INCOMPLETE'}
    $classpathCatalog=$null
    if($ClasspathArtifactCatalogPath){
        if([string]$Pin.targetId -notin @('Forge@1.8.8','Forge@1.8.9','Forge@1.9','Forge@1.10','Forge@1.10.2','Forge@1.11','Forge@1.11.2','Forge@1.12','Forge@1.12.1')){throw 'FORGE_BUILD_CLASSPATH_TARGET_UNSUPPORTED'}
        $classpathCatalog=Get-MmtlForgeBuildClasspathArtifactCatalog -CatalogPath $ClasspathArtifactCatalogPath
        if([string]$classpathCatalog.catalog.targetId -cne [string]$Pin.targetId){throw 'FORGE_BUILD_CLASSPATH_PIN_TARGET_MISMATCH'}
        if(-not(Test-Path -LiteralPath $ClasspathMirrorRoot -PathType Container)){throw 'FORGE_BUILD_CLASSPATH_MIRROR_MISSING'}
    }
    $root=[IO.Path]::GetFullPath($SessionRoot)
    if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'FORGE_SESSION_ROOT_MISSING'}
    $buildPath=Join-Path $root 'build.gradle'
    if(-not(Test-Path -LiteralPath $buildPath -PathType Leaf)){throw 'FORGE_BUILD_GRADLE_MISSING'}
    $buildGradleHash=Get-MmtlForgePinFileHash -Path $buildPath
    $expectedBuildGradleHash=Get-MmtlForgeExpectedBuildGradleSha256 -Pin $Pin -Fixture $Fixture -FixtureOverlayRoot $FixtureOverlayRoot
    if($buildGradleHash -cne $expectedBuildGradleHash){throw 'FORGE_BUILD_GRADLE_HASH_MISMATCH'}
    $wrapperPropertiesPath=Join-Path $root 'gradle/wrapper/gradle-wrapper.properties'
    if(-not(Test-Path -LiteralPath $wrapperPropertiesPath -PathType Leaf)){throw 'FORGE_GRADLE_WRAPPER_PROPERTIES_MISSING'}
    $distributionLine=Get-Content -LiteralPath $wrapperPropertiesPath | Where-Object {$_ -match '^distributionUrl='} | Select-Object -First 1
    if(-not $distributionLine){throw 'FORGE_GRADLE_WRAPPER_DISTRIBUTION_MISSING'}
    $wrapperDistributionUrl=([string]$distributionLine.Substring('distributionUrl='.Length)).Replace('\:',':')
    if($wrapperDistributionUrl -cne [string]$Pin.gradleDistributionUrl){throw 'FORGE_GRADLE_WRAPPER_DISTRIBUTION_MISMATCH'}
    if((Get-MmtlForgePinFileHash -Path $ForgeGradleJarPath) -cne [string]$Pin.forgeGradleJarSha256){throw 'FORGE_PINNED_PLUGIN_JAR_HASH_MISMATCH'}
    if((Get-MmtlForgePinFileHash -Path $ForgeGradlePomPath) -cne [string]$Pin.forgeGradlePomSha256){throw 'FORGE_PINNED_PLUGIN_POM_HASH_MISMATCH'}
    [xml]$pom=Get-Content -LiteralPath $ForgeGradlePomPath -Raw -ErrorAction Stop
    $expectedPluginVersion=if($Pin.PSObject.Properties['forgeGradleResolvedVersion']){[string]$Pin.forgeGradleResolvedVersion}else{[string]$Pin.forgeGradleSpec}
    if($pom.project.groupId -cne 'net.minecraftforge.gradle' -or $pom.project.artifactId -cne 'ForgeGradle' -or $pom.project.version -cne $expectedPluginVersion){throw 'FORGE_PINNED_PLUGIN_POM_COORDINATE_MISMATCH'}

    $sourceText=[IO.File]::ReadAllText($buildPath)
    $declarations=Get-MmtlForgeBuildScriptDeclarations -BuildScriptText $sourceText
    foreach($pluginDeclaration in $declarations.plugins){if([string]$pluginDeclaration.version -cne [string]$Pin.forgeGradleSpec){throw 'FORGE_BUILD_GRADLE_PLUGIN_SPEC_MISMATCH'}}
    if($declarations.plugins.Count){throw 'FORGE_BUILD_GRADLE_PLUGIN_DSL_UNSUPPORTED'}
    if($declarations.classpath.Count -ne 1 -or [string]$declarations.classpath[0].version -cne [string]$Pin.forgeGradleSpec){throw 'FORGE_BUILD_GRADLE_PLUGIN_SPEC_MISMATCH'}
    $patched=ConvertTo-MmtlForgeSecureBuildScript -SourceText $sourceText
    $separator=if($sourceText.Contains("`r`n")){"`r`n"}else{"`n"}
    if($classpathCatalog){$pluginApply=[regex]::Matches($patched,"(?m)^apply plugin: 'net\.minecraftforge\.gradle\.forge'\s*$`r?`n");if($pluginApply.Count -ne 1){throw 'FORGE_BUILD_PLUGIN_APPLY_SHAPE_UNEXPECTED'};$projectRepository="repositories { maven { url uri('.mmtl-forge-secure/repository') } }"+$separator;$patched=$patched.Insert($pluginApply[0].Index+$pluginApply[0].Length,$projectRepository)}
    $secureRoot=Join-Path $root '.mmtl-forge-secure'
    $mojangDirectory=Join-Path $secureRoot 'mojang'
    $repositoryRoot=Join-Path $secureRoot 'repository'
    $modulePath=Join-Path $repositoryRoot ('net/minecraftforge/gradle/ForgeGradle/'+[string]$Pin.forgeGradleSpec)
    $jarName='ForgeGradle-'+[string]$Pin.forgeGradleTimestamp+'.jar';$pomName='ForgeGradle-'+[string]$Pin.forgeGradleTimestamp+'.pom'
    [void][IO.Directory]::CreateDirectory($modulePath)
    $pluginJarPath=Join-Path $modulePath $jarName;$pluginPomPath=Join-Path $modulePath $pomName
    [IO.File]::Copy([IO.Path]::GetFullPath($ForgeGradleJarPath),$pluginJarPath,$false)
    [IO.File]::Copy([IO.Path]::GetFullPath($ForgeGradlePomPath),$pluginPomPath,$false)
    if($classpathCatalog){
        $mirrorRoot=[IO.Path]::GetFullPath($ClasspathMirrorRoot)
        if((Get-Item -LiteralPath $mirrorRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FORGE_BUILD_CLASSPATH_MIRROR_REPARSE_POINT'}
        foreach($artifact in $classpathCatalog.artifacts){
            $relative=Join-Path (Join-Path ([string]$artifact.group).Replace('.', [IO.Path]::DirectorySeparatorChar) ([string]$artifact.artifact)) ([string]$artifact.version)
            $source=[IO.Path]::GetFullPath((Join-Path (Join-Path $mirrorRoot $relative) ([string]$artifact.file)))
            if(-not(Test-MmtlPlatformPathInsideRoot -Root $mirrorRoot -Target $source) -or -not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'FORGE_BUILD_CLASSPATH_MIRROR_ARTIFACT_MISSING'}
            $sourceItem=Get-Item -LiteralPath $source -Force
            if(($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$sourceItem.Length -ne [long]$artifact.bytes -or (Get-MmtlForgePinFileHash -Path $source) -cne [string]$artifact.sha256){throw 'FORGE_BUILD_CLASSPATH_MIRROR_ARTIFACT_HASH_MISMATCH'}
            $destinationDirectory=[IO.Path]::GetFullPath((Join-Path (Join-Path $repositoryRoot $relative) ''))
            if(-not(Test-MmtlPlatformPathInsideRoot -Root $repositoryRoot -Target $destinationDirectory)){throw 'FORGE_BUILD_CLASSPATH_REPOSITORY_PATH_ESCAPE'}
            [void][IO.Directory]::CreateDirectory($destinationDirectory)
            $destination=[IO.Path]::GetFullPath((Join-Path $destinationDirectory ([string]$artifact.file)))
            if(-not(Test-MmtlPlatformPathInsideRoot -Root $repositoryRoot -Target $destination)){throw 'FORGE_BUILD_CLASSPATH_REPOSITORY_PATH_ESCAPE'}
            if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne [string]$artifact.sha256){throw 'FORGE_BUILD_CLASSPATH_REPOSITORY_COLLISION'}}else{[IO.File]::Copy($source,$destination,$false)}
        }
        foreach($library in $classpathCatalog.requiredLibraries){
            $parts=([string]$library.coordinate).Split(':');$moduleRoot=Join-Path (Join-Path (Join-Path $repositoryRoot $parts[0].Replace('.', [IO.Path]::DirectorySeparatorChar)) $parts[1]) $parts[2]
            if(-not(Test-MmtlPlatformPathInsideRoot -Root $repositoryRoot -Target $moduleRoot)){throw 'FORGE_BUILD_REQUIRED_LIBRARY_REPOSITORY_PATH_ESCAPE'}
            [void][IO.Directory]::CreateDirectory($moduleRoot)
            $pomPath=Join-Path $moduleRoot ($parts[1]+'-'+$parts[2]+'.pom')
            $pomText='<?xml version="1.0" encoding="UTF-8"?><project><modelVersion>4.0.0</modelVersion><groupId>'+$parts[0]+'</groupId><artifactId>'+$parts[1]+'</artifactId><version>'+$parts[2]+'</version><packaging>jar</packaging></project>'
            if(Test-Path -LiteralPath $pomPath -PathType Leaf){if([IO.File]::ReadAllText($pomPath) -cne $pomText){throw 'FORGE_BUILD_REQUIRED_LIBRARY_POM_COLLISION'}}else{[IO.File]::WriteAllText($pomPath,$pomText,[Text.UTF8Encoding]::new($false))}
        }
        New-MmtlForgeClasspathSnapshotMetadata -ClasspathCatalog $classpathCatalog -RepositoryRoot $repositoryRoot | Out-Null
        if($classpathCatalog.catalog.PSObject.Properties['dynamicVersionResolutions']){New-MmtlForgeClasspathDynamicVersionMetadata -ClasspathCatalog $classpathCatalog -RepositoryRoot $repositoryRoot | Out-Null}
        $mcpMetadataSource=[IO.Path]::GetFullPath($ClasspathMcpVersionsPath)
        if(-not(Test-Path -LiteralPath $mcpMetadataSource -PathType Leaf)){throw 'FORGE_BUILD_CLASSPATH_MCP_VERSIONS_MISSING'}
        $mcpMetadataItem=Get-Item -LiteralPath $mcpMetadataSource -Force
        if(($mcpMetadataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$mcpMetadataItem.Length -ne [long]$classpathCatalog.mcpVersions.bytes -or (Get-MmtlForgePinFileHash -Path $mcpMetadataSource) -cne [string]$classpathCatalog.mcpVersions.sha256){throw 'FORGE_BUILD_CLASSPATH_MCP_VERSIONS_HASH_MISMATCH'}
        $mcpJson=Get-Content -LiteralPath $mcpMetadataSource -Raw|ConvertFrom-Json -ErrorAction Stop
        $minecraftVersion=([string]$Pin.targetId -replace '^Forge@','')
        $mcpMetadataProperty=$mcpJson.PSObject.Properties[[string]$minecraftVersion]
        $mcpMetadataTarget=if($mcpMetadataProperty){$mcpMetadataProperty.Value}else{$null}
        $stableMapping=[regex]::Match([string]$classpathCatalog.catalog.mcpMapping,'^stable_(\d+)$')
        if($stableMapping.Success){
            if(-not $mcpMetadataTarget){throw 'FORGE_BUILD_CLASSPATH_MCP_TARGET_MISSING'}
            if(@($mcpMetadataTarget.stable|ForEach-Object{[string]$_}) -cnotcontains $stableMapping.Groups[1].Value){throw 'FORGE_BUILD_CLASSPATH_MCP_STABLE_MAPPING_NOT_PUBLISHED'}
        }else{
            $snapshotMapping=[regex]::Match([string]$classpathCatalog.catalog.mcpMapping,'^snapshot_(\d{8})$')
            $snapshotArtifact=@($classpathCatalog.mcpArtifacts|Where-Object coordinate -eq 'de.oceanlabs.mcp:mcp_snapshot')
            $snapshotFallback=[regex]::Match([string]$snapshotArtifact[0].version,'^(\d{8})-(\d+\.\d+(?:\.\d+)?)$')
            if(-not $snapshotMapping.Success -or $snapshotArtifact.Count -ne 1 -or -not $snapshotFallback.Success -or $snapshotFallback.Groups[1].Value -cne $snapshotMapping.Groups[1].Value){throw 'FORGE_BUILD_CLASSPATH_MCP_SNAPSHOT_FALLBACK_INVALID'}
            if($mcpMetadataTarget -and @($mcpMetadataTarget.snapshot|ForEach-Object{[string]$_}) -ccontains $snapshotMapping.Groups[1].Value){$snapshotFallback=[regex]::Match([string]$snapshotArtifact[0].version,'^(\d{8})-(\d+\.\d+(?:\.\d+)?)$');if($snapshotFallback.Groups[2].Value -cne $minecraftVersion){throw 'FORGE_BUILD_CLASSPATH_MCP_SNAPSHOT_TARGET_MISMATCH'}}
            $fallbackMetadata=$mcpJson.PSObject.Properties[[string]$snapshotFallback.Groups[2].Value].Value
            if(-not $fallbackMetadata -or @($fallbackMetadata.snapshot|ForEach-Object{[string]$_}) -cnotcontains $snapshotMapping.Groups[1].Value){throw 'FORGE_BUILD_CLASSPATH_MCP_SNAPSHOT_FALLBACK_NOT_PUBLISHED'}
        }
        if($classpathCatalog.mcpArtifacts.Count -eq 3){
            $snapshotVersion=[string]$classpathCatalog.mcpArtifacts[2].version
            $snapshotMatch=[regex]::Match($snapshotVersion,'^(?<date>\d{8})-(?<minecraft>[0-9]+\.[0-9]+(?:\.[0-9]+)?)$')
            $snapshotMinecraft=[string]$snapshotMatch.Groups['minecraft'].Value
            $snapshotMetadataProperty=$mcpJson.PSObject.Properties[[string]$snapshotMinecraft]
            $snapshotMetadataTarget=if($snapshotMetadataProperty){$snapshotMetadataProperty.Value}else{$null}
            if(-not $snapshotMatch.Success -or $snapshotMinecraft -cne [string]$classpathCatalog.catalog.mcpArtifacts[2].version.Split('-')[-1] -or -not $snapshotMetadataTarget -or @($snapshotMetadataTarget.snapshot|ForEach-Object{[string]$_}) -cnotcontains $snapshotMatch.Groups['date'].Value){throw 'FORGE_BUILD_CLASSPATH_MCP_SNAPSHOT_MAPPING_NOT_PUBLISHED'}
        }
        $gradleHomePath=[IO.Path]::GetFullPath($GradleHome);[void][IO.Directory]::CreateDirectory($gradleHomePath)
        $mcpCache=Join-Path $gradleHomePath 'caches/minecraft';[void][IO.Directory]::CreateDirectory($mcpCache)
        foreach($protectedPath in @($gradleHomePath,(Join-Path $gradleHomePath 'caches'),$mcpCache)){if((Get-Item -LiteralPath $protectedPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FORGE_BUILD_CLASSPATH_GRADLE_HOME_REPARSE_POINT'}}
        $mcpCacheFile=Join-Path $mcpCache 'McpMappings.json'
        if(Test-Path -LiteralPath $mcpCacheFile -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $mcpCacheFile) -cne [string]$classpathCatalog.mcpVersions.sha256){throw 'FORGE_BUILD_CLASSPATH_MCP_CACHE_HASH_MISMATCH'}}else{[IO.File]::Copy($mcpMetadataSource,$mcpCacheFile,$false)}
        $userdevDirectory=Join-Path $repositoryRoot ('net/minecraftforge/forge/'+[string]$classpathCatalog.forgeUserdev.version);[void][IO.Directory]::CreateDirectory($userdevDirectory)
        foreach($kind in @('pom','userdev','universal')){$entry=$classpathCatalog.forgeUserdev.$kind;$source=[IO.Path]::GetFullPath([string]$ClasspathForgeUserdevFiles[$kind]);if(-not(Test-Path -LiteralPath $source -PathType Leaf) -or (Get-MmtlForgePinFileHash -Path $source) -cne [string]$entry.sha256){throw 'FORGE_BUILD_USERDEV_SOURCE_INVALID'};$destination=Join-Path $userdevDirectory ([string]$entry.file);if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne [string]$entry.sha256){throw 'FORGE_BUILD_USERDEV_REPOSITORY_COLLISION'}}else{[IO.File]::Copy($source,$destination,$false)}}
        $verifiedUserdevConfig=Get-MmtlForgeUserdevConfiguration -ArchivePath ([string]$ClasspathForgeUserdevFiles.userdev) -EntryName ([string]$classpathCatalog.forgeUserdev.devJson.entry) -ExpectedBytes ([long]$classpathCatalog.forgeUserdev.devJson.bytes) -ExpectedSha256 ([string]$classpathCatalog.forgeUserdev.devJson.sha256) -ExpectedLibraries @($classpathCatalog.forgeUserdev.devLibraries)
        $devJson=$verifiedUserdevConfig.config
        $archiveDevCoordinates=@($verifiedUserdevConfig.libraries|Sort-Object -Unique)
        foreach($library in @($classpathCatalog.requiredLibraries|Where-Object source -eq 'ForgeUserdevDevJson')){
            $entry=@($devJson.libraries|Where-Object{[string]$_.name -ceq [string]$library.coordinate})
            if($entry.Count -ne 1){throw 'FORGE_BUILD_USERDEV_REQUIRED_LIBRARY_MISSING'}
            $parts=([string]$library.coordinate).Split(':');$base=if($entry[0].PSObject.Properties['url'] -and $entry[0].url){([string]$entry[0].url).Replace('http://','https://')}else{'https://libraries.minecraft.net'}
            $expectedUrl=$base.TrimEnd('/')+'/'+$parts[0].Replace('.','/')+'/'+$parts[1]+'/'+$parts[2]+'/'+[string]$library.file
            if([string]$library.url -cne $expectedUrl){throw 'FORGE_BUILD_USERDEV_REQUIRED_LIBRARY_URL_MISMATCH'}
        }
        foreach($entry in $classpathCatalog.mcpArtifacts){$parts=([string]$entry.coordinate).Split(':');$moduleRoot=Join-Path (Join-Path (Join-Path $repositoryRoot 'de/oceanlabs/mcp') $parts[1]) ([string]$entry.version);[void][IO.Directory]::CreateDirectory($moduleRoot);$source=[IO.Path]::GetFullPath([string]$ClasspathMcpArtifacts[[string]$entry.coordinate]);if(-not(Test-Path -LiteralPath $source -PathType Leaf) -or (Get-MmtlForgePinFileHash -Path $source) -cne [string]$entry.sha256){throw 'FORGE_BUILD_MCP_ARTIFACT_SOURCE_INVALID'};$destination=Join-Path $moduleRoot ([string]$entry.file);if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne [string]$entry.sha256){throw 'FORGE_BUILD_MCP_ARTIFACT_REPOSITORY_COLLISION'}}else{[IO.File]::Copy($source,$destination,$false)};$pomName=$parts[1]+'-'+[string]$entry.version+'.pom';$pomText='<?xml version="1.0" encoding="UTF-8"?><project><modelVersion>4.0.0</modelVersion><groupId>de.oceanlabs.mcp</groupId><artifactId>'+$parts[1]+'</artifactId><version>'+[string]$entry.version+'</version><packaging>zip</packaging></project>';$pomPath=Join-Path $moduleRoot $pomName;if(-not(Test-Path -LiteralPath $pomPath -PathType Leaf)){[IO.File]::WriteAllText($pomPath,$pomText,[Text.UTF8Encoding]::new($false))}}
        $mojangSource=[IO.Path]::GetFullPath($ClasspathMojangVersionPath);$mojangPin=$classpathCatalog.mojangVersion
        if(-not(Test-Path -LiteralPath $mojangSource -PathType Leaf)){throw 'FORGE_BUILD_CLASSPATH_MOJANG_VERSION_MISSING'}
        $mojangFile=Get-Item -LiteralPath $mojangSource -Force
        if(($mojangFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$mojangFile.Length -ne [long]$mojangPin.bytes -or (Get-MmtlForgePinFileHash -Path $mojangSource) -cne [string]$mojangPin.sha256 -or [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([IO.File]::ReadAllBytes($mojangSource))).ToLowerInvariant() -cne [string]$mojangPin.sha1){throw 'FORGE_BUILD_CLASSPATH_MOJANG_VERSION_HASH_MISMATCH'}
        $versionJson=Get-Content -LiteralPath $mojangSource -Raw|ConvertFrom-Json -ErrorAction Stop
        if([string]$versionJson.id -cne $minecraftVersion){throw 'FORGE_BUILD_CLASSPATH_MOJANG_VERSION_ID_MISMATCH'}
        Test-MmtlForgeClasspathMojangLibraryPins -ClasspathCatalog $classpathCatalog -MojangVersionJsonPath $mojangSource | Out-Null
        $manifestEntry=[ordered]@{latest=[ordered]@{release=$minecraftVersion;snapshot=$minecraftVersion};versions=@([ordered]@{id=$minecraftVersion;type='release';url=[string]$mojangPin.url;time=[string]$versionJson.time;releaseTime=[string]$versionJson.releaseTime;sha1=[string]$mojangPin.sha1;complianceLevel=0})}
        $manifestBytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $manifestEntry -Depth 8 -Compress));$manifestPath=Join-Path $mcpCache 'McManifest.json'
        if(Test-Path -LiteralPath $manifestPath -PathType Leaf){$existing=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json;if(@($existing.versions|Where-Object id -eq $minecraftVersion).Count -ne 1){throw 'FORGE_BUILD_CLASSPATH_MOJANG_MANIFEST_CACHE_INVALID'}}else{[IO.File]::WriteAllBytes($manifestPath,$manifestBytes)}
    }
    $timestampMatch=[regex]::Match([string]$Pin.forgeGradleTimestamp,'^[0-9]+\.[0-9]+-(?<stamp>[0-9]{8}\.[0-9]{6})-(?<build>[0-9]+)$')
    $updated=$timestampMatch.Groups['stamp'].Value.Replace('.','')+$timestampMatch.Groups['build'].Value.PadLeft(4,'0')
    $metadata=@"
<?xml version="1.0" encoding="UTF-8"?>
<metadata><groupId>net.minecraftforge.gradle</groupId><artifactId>ForgeGradle</artifactId><version>$([System.Security.SecurityElement]::Escape([string]$Pin.forgeGradleSpec))</version><versioning><snapshot><timestamp>$($timestampMatch.Groups['stamp'].Value)</timestamp><buildNumber>$($timestampMatch.Groups['build'].Value)</buildNumber></snapshot><lastUpdated>$updated</lastUpdated><snapshotVersions><snapshotVersion><extension>pom</extension><value>$([System.Security.SecurityElement]::Escape([string]$Pin.forgeGradleTimestamp))</value><updated>$updated</updated></snapshotVersion><snapshotVersion><extension>jar</extension><value>$([System.Security.SecurityElement]::Escape([string]$Pin.forgeGradleTimestamp))</value><updated>$updated</updated></snapshotVersion></snapshotVersions></versioning></metadata>
"@
    [IO.File]::WriteAllText((Join-Path $modulePath 'maven-metadata.xml'),$metadata.Trim()+$separator,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($buildPath,$patched,[Text.UTF8Encoding]::new($false))

    $initScriptPath=Join-Path $secureRoot 'mojang.init.gradle'
    $setDownloadUrlScript=if([string]$Pin.forgeGradleSpec -ceq '1.2-SNAPSHOT'){@"
   def setMmtlDownloadUrl = { taskName, value ->
    def downloadTask = p.tasks.getByName(taskName)
    def setter = downloadTask.class.methods.find { it.name == 'setUrl' && it.parameterTypes.length == 1 }
    if (setter == null) { throw new GradleException('MMTL_FORGE_DOWNLOAD_URL_SETTER_MISSING:' + taskName) }
    def parameterType = setter.parameterTypes[0]
    if (parameterType.name == 'net.minecraftforge.gradle.delayed.DelayedString') {
      def delayedType = downloadTask.class.classLoader.loadClass(parameterType.name)
      def delayedValue = delayedType.getConstructor(org.gradle.api.Project, String).newInstance(p, value)
      setter.invoke(downloadTask, delayedValue)
    } else { setter.invoke(downloadTask, value) }
  }
  setMmtlDownloadUrl('downloadClient', '__MMTL_CLIENT_URL__')
  setMmtlDownloadUrl('downloadServer', '__MMTL_SERVER_URL__')
"@}else{@"
  __MMTL_VERSION_JSON_SETUP__
  p.tasks.getByName('downloadClient').setUrl('__MMTL_CLIENT_URL__')
  p.tasks.getByName('downloadServer').setUrl('__MMTL_SERVER_URL__')
"@}
    $script=@"
gradle.projectsEvaluated {
  def p = gradle.rootProject
$setDownloadUrlScript
  println('MMTL_FORGE_PINNED_MOJANG_URLS_SET')
}
"@
    $versionJsonUrl=Get-MmtlForgePinnedVersionJsonUrl -Pin $Pin -ClasspathCatalog $classpathCatalog
    $versionJsonSetup=if($versionJsonUrl){"p.tasks.getByName('getVersionJson').setUrl('"+[System.Security.SecurityElement]::Escape($versionJsonUrl)+"')"}else{'// Version JSON URL is provided by the pinned metadata cache'}
    $script=$script.Replace('__MMTL_VERSION_JSON_SETUP__',$versionJsonSetup).Replace('__MMTL_VERSION_JSON_URL__',[System.Security.SecurityElement]::Escape([string]$versionJsonUrl)).Replace('__MMTL_CLIENT_URL__',[System.Security.SecurityElement]::Escape([string]$Pin.client.url)).Replace('__MMTL_SERVER_URL__',[System.Security.SecurityElement]::Escape([string]$Pin.server.url))
    [IO.File]::WriteAllText($initScriptPath,$script.Trim()+$separator,[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{buildScriptPath=$buildPath;repositoryPath=$repositoryRoot;pluginJarPath=$pluginJarPath;pluginPomPath=$pluginPomPath;initScriptPath=$initScriptPath;requiresOffline=[bool]$classpathCatalog;classpathCatalogHash=if($classpathCatalog){[string]$classpathCatalog.catalogHash}else{$null};classpathArtifactCount=if($classpathCatalog){$classpathCatalog.artifacts.Count+5}else{0};classpathMcpVersionsSha256=if($classpathCatalog){[string]$classpathCatalog.mcpVersions.sha256}else{$null};classpathMcpMapping=if($classpathCatalog){[string]$classpathCatalog.catalog.mcpMapping}else{$null};classpathMojangVersionSha256=if($classpathCatalog){[string]$classpathCatalog.mojangVersion.sha256}else{$null};classpathForgeUserdevSha256=if($classpathCatalog){[string]$classpathCatalog.forgeUserdev.userdev.sha256}else{$null};classpathMcpSrgSha256=if($classpathCatalog){[string]$classpathCatalog.mcpArtifacts[0].sha256}else{$null};classpathMcpStableSha256=if($classpathCatalog){[string]$classpathCatalog.mcpArtifacts[1].sha256}else{$null};mojangDirectory=$mojangDirectory;minecraftVersion=[string]$Pin.minecraftId;client=$Pin.client;server=$Pin.server}
}

function Initialize-MmtlForgeGradle3PinnedProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionRoot,[Parameter(Mandatory)]$Pin,[Parameter(Mandatory)][string]$ForgeGradleJarPath,[Parameter(Mandatory)][string]$ForgeGradlePomPath,[Parameter(Mandatory)][string]$ClasspathMirrorRoot,[Parameter(Mandatory)][string]$TargetMirrorRoot,[Parameter(Mandatory)][string]$MojangVersionUrl,[Parameter(Mandatory)][string]$MojangVersionJsonPath,[Parameter(Mandatory)]$PinnedMojangArtifacts,[Parameter(Mandatory)][string]$GradleHome,[string]$RuntimeLibraryMirrorRoot,[AllowEmptyCollection()][object[]]$RuntimeVersionResolutions=@())
    Test-MmtlForgePinValue -Pin $Pin
    if([string]$Pin.targetId -notin @('Forge@1.12.2','Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4') -or [string]$Pin.targetId -cne ('Forge@'+[string]$Pin.minecraftId) -or [string]$Pin.forgeGradleResolvedVersion -cne '3.0.197' -or [string]$Pin.forgeGradleSpec -cne '3.+'){throw 'FORGE_GRADLE3_PIN_IDENTITY_INVALID'}
    $root=[IO.Path]::GetFullPath($SessionRoot);$buildPath=Join-Path $root 'build.gradle';if(-not(Test-Path -LiteralPath $buildPath -PathType Leaf) -or (Get-MmtlForgePinFileHash -Path $buildPath) -cne [string]$Pin.buildGradleSha256){throw 'FORGE_GRADLE3_BUILD_GRADLE_HASH_MISMATCH'}
    $wrapperPropertiesPath=Join-Path $root 'gradle/wrapper/gradle-wrapper.properties';$distributionLine=Get-Content -LiteralPath $wrapperPropertiesPath|Where-Object{$_ -match '^distributionUrl='}|Select-Object -First 1;if(-not$distributionLine -or ([string]$distributionLine.Substring('distributionUrl='.Length)).Replace('\:',':') -cne [string]$Pin.gradleDistributionUrl){throw 'FORGE_GRADLE3_WRAPPER_DISTRIBUTION_MISMATCH'}
    if((Get-MmtlForgePinFileHash -Path $ForgeGradleJarPath) -cne [string]$Pin.forgeGradleJarSha256 -or (Get-MmtlForgePinFileHash -Path $ForgeGradlePomPath) -cne [string]$Pin.forgeGradlePomSha256){throw 'FORGE_GRADLE3_PLUGIN_HASH_MISMATCH'}
    if([string]$Pin.mojangMetadataSnapshot -notmatch '^(?i:[a-f0-9]{64})$' -or (Get-MmtlForgePinFileHash -Path $MojangVersionJsonPath) -cne [string]$Pin.mojangMetadataSnapshot){throw 'FORGE_GRADLE3_MOJANG_VERSION_JSON_HASH_MISMATCH'}
    $versionMetadata=[IO.File]::ReadAllText($MojangVersionJsonPath)|ConvertFrom-Json -ErrorAction Stop
    if([string]$versionMetadata.id -cne [string]$Pin.minecraftId){throw 'FORGE_GRADLE3_MOJANG_VERSION_JSON_ID_MISMATCH'}
    foreach($name in @('client','server')){$download=$versionMetadata.downloads.$name;$expected=$Pin.$name;if([string]$download.url -cne [string]$expected.url -or [string]$download.sha1 -cne [string]$expected.sha1 -or [long]$download.size -ne [long]$expected.sizeBytes){throw "FORGE_GRADLE3_MOJANG_VERSION_JSON_DOWNLOAD_MISMATCH:$name"}}
    $metaDirectory=Join-Path $root 'build/downloadMCMeta';if(-not(Test-MmtlPlatformPathInsideRoot -Root $root -Target $metaDirectory)){throw 'FORGE_GRADLE3_MOJANG_METADATA_PATH_ESCAPE'};if((Test-Path -LiteralPath $metaDirectory -PathType Container) -and ((Get-Item -LiteralPath $metaDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'FORGE_GRADLE3_MOJANG_METADATA_DIRECTORY_REPARSE'};[void][IO.Directory]::CreateDirectory($metaDirectory)
    $seededVersionJson=Join-Path $metaDirectory 'version.json';if(Test-Path -LiteralPath $seededVersionJson -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $seededVersionJson) -cne [string]$Pin.mojangMetadataSnapshot){throw 'FORGE_GRADLE3_MOJANG_METADATA_SEED_CONFLICT'}}else{[IO.File]::Copy([IO.Path]::GetFullPath($MojangVersionJsonPath),$seededVersionJson,$false)}
    $gradleCache=[IO.Path]::GetFullPath($GradleHome);$minecraftVersion=if($Pin.PSObject.Properties['minecraftId']){[string]$Pin.minecraftId}else{([string]$Pin.targetId -replace '^Forge@','')};foreach($kind in @('client','server')){$matches=@($PinnedMojangArtifacts|Where-Object kind -CEQ $kind);if($matches.Count -ne 1){throw "FORGE_GRADLE3_MOJANG_ARTIFACT_MISSING:$kind"};$record=$matches[0];$expected=$Pin.$kind;if([string]$record.sha1 -cne [string]$expected.sha1 -or [long]$record.sizeBytes -ne [long]$expected.sizeBytes -or (Get-FileHash -LiteralPath ([string]$record.path) -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$expected.sha1){throw "FORGE_GRADLE3_MOJANG_ARTIFACT_PIN_MISMATCH:$kind"};$relative=if($kind -ceq 'client'){"caches/minecraft/net/minecraft/minecraft/$minecraftVersion/minecraft-$minecraftVersion.jar"}else{"caches/minecraft/net/minecraft/minecraft_server/$minecraftVersion/minecraft_server-$minecraftVersion.jar"};$destination=[IO.Path]::GetFullPath((Join-Path $gradleCache $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $gradleCache -Target $destination)){throw 'FORGE_GRADLE3_MOJANG_ARTIFACT_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination));if(Test-Path -LiteralPath $destination -PathType Leaf){if([long](Get-Item -LiteralPath $destination).Length -ne [long]$expected.sizeBytes -or (Get-FileHash -LiteralPath $destination -Algorithm SHA1).Hash.ToLowerInvariant() -cne [string]$expected.sha1){throw "FORGE_GRADLE3_MOJANG_ARTIFACT_CACHE_CONFLICT:$kind"}}else{[IO.File]::Copy([IO.Path]::GetFullPath([string]$record.path),$destination,$false)}}
    $source=[IO.File]::ReadAllText($buildPath);$declarations=Get-MmtlForgeBuildScriptDeclarations -BuildScriptText $source;if($declarations.plugins.Count -or $declarations.classpath.Count -ne 1 -or [string]$declarations.classpath[0].version -cne '3.+'){throw 'FORGE_GRADLE3_PLUGIN_DECLARATION_INVALID'}
    $repoRoot=Join-Path $root '.mmtl-forge-secure/repository';[void][IO.Directory]::CreateDirectory($repoRoot)
    $sourceRootValues=@($ClasspathMirrorRoot,$TargetMirrorRoot);if($RuntimeLibraryMirrorRoot){$sourceRootValues+=,$RuntimeLibraryMirrorRoot};foreach($sourceRootValue in $sourceRootValues){$sourceRoot=[IO.Path]::GetFullPath($sourceRootValue);if(-not(Test-Path -LiteralPath $sourceRoot -PathType Container) -or (Get-Item -LiteralPath $sourceRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'FORGE_GRADLE3_MIRROR_INVALID'};foreach($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force){if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.LinkType){throw 'FORGE_GRADLE3_MIRROR_REPARSE_FILE'};$relative=[IO.Path]::GetRelativePath($sourceRoot,$file.FullName);$destination=[IO.Path]::GetFullPath((Join-Path $repoRoot $relative));if(-not(Test-MmtlPlatformPathInsideRoot -Root $repoRoot -Target $destination)){throw 'FORGE_GRADLE3_MIRROR_PATH_ESCAPE'};[void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination));if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne (Get-MmtlForgePinFileHash -Path $file.FullName)){throw 'FORGE_GRADLE3_MIRROR_COLLISION'}}else{[IO.File]::Copy($file.FullName,$destination,$false)}}}
    if($RuntimeLibraryMirrorRoot){$runtimeRoot=[IO.Path]::GetFullPath($RuntimeLibraryMirrorRoot);foreach($jar in Get-ChildItem -LiteralPath $runtimeRoot -File -Filter '*.jar' -Recurse -Force){if(($jar.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $jar.LinkType){throw 'FORGE_GRADLE3_RUNTIME_MIRROR_REPARSE_FILE'};$relative=[IO.Path]::GetRelativePath($runtimeRoot,$jar.FullName);$segments=$relative -split '[\\/]';if($segments.Count -lt 4){throw 'FORGE_GRADLE3_RUNTIME_MIRROR_COORDINATE_INVALID'};$module=$segments[$segments.Count-3];$version=$segments[$segments.Count-2];$group=$segments[0..($segments.Count-4)] -join '.';if($module -notmatch '^[A-Za-z0-9_.-]+$' -or $version -notmatch '^[A-Za-z0-9_.+-]+$' -or $group -notmatch '^[A-Za-z0-9_.-]+$'){throw 'FORGE_GRADLE3_RUNTIME_MIRROR_COORDINATE_INVALID'};if($jar.Name -cne ($module+'-'+$version+'.jar')){continue};$relativePom=[IO.Path]::ChangeExtension($relative,'.pom');$pom=[IO.Path]::GetFullPath((Join-Path $repoRoot $relativePom));if(-not(Test-MmtlPlatformPathInsideRoot -Root $repoRoot -Target $pom)){throw 'FORGE_GRADLE3_RUNTIME_MIRROR_PATH_ESCAPE'};if(-not(Test-Path -LiteralPath $pom -PathType Leaf)){$pomText='<?xml version="1.0" encoding="UTF-8"?><project><modelVersion>4.0.0</modelVersion><groupId>'+$group+'</groupId><artifactId>'+$module+'</artifactId><version>'+$version+'</version><packaging>jar</packaging></project>';[IO.File]::WriteAllText($pom,$pomText,[Text.UTF8Encoding]::new($false))}}}
    $pluginDir=Join-Path $repoRoot 'net/minecraftforge/gradle/ForgeGradle/3.0.197';[void][IO.Directory]::CreateDirectory($pluginDir);foreach($item in @([pscustomobject]@{source=[IO.Path]::GetFullPath($ForgeGradleJarPath);name='ForgeGradle-3.0.197.jar';hash=[string]$Pin.forgeGradleJarSha256},[pscustomobject]@{source=[IO.Path]::GetFullPath($ForgeGradlePomPath);name='ForgeGradle-3.0.197.pom';hash=[string]$Pin.forgeGradlePomSha256})){$destination=Join-Path $pluginDir $item.name;if(Test-Path -LiteralPath $destination -PathType Leaf){if((Get-MmtlForgePinFileHash -Path $destination) -cne $item.hash){throw 'FORGE_GRADLE3_PLUGIN_REPOSITORY_COLLISION'}}else{[IO.File]::Copy($item.source,$destination,$false)}}
    $separator=if($source.Contains("`r`n")){"`r`n"}else{"`n"};$buildscript=[regex]::Matches($source,'buildscript\s*\{\s*repositories\s*\{');if($buildscript.Count -ne 1){throw 'FORGE_GRADLE3_BUILD_SCRIPT_SHAPE_INVALID'};$insert=$buildscript[0].Index+$buildscript[0].Length;$repositoryLine="`r`n        maven { url uri('.mmtl-forge-secure/repository') }";$patched=$source.Insert($insert,$repositoryLine).Replace('mavenCentral()',"maven { url uri('.mmtl-forge-secure/repository') }");$pluginApply=[regex]::Matches($patched,"(?m)^apply plugin: 'net\.minecraftforge\.gradle'\s*$`r?`n");if($pluginApply.Count -ne 1){throw 'FORGE_GRADLE3_PLUGIN_APPLY_SHAPE_INVALID'};$patched=$patched.Insert($pluginApply[0].Index+$pluginApply[0].Length,"repositories { maven { url uri('.mmtl-forge-secure/repository') } }"+$separator);$patched=$patched.Replace('classpath ''net.minecraftforge.gradle:ForgeGradle:3.+''','classpath ''net.minecraftforge.gradle:ForgeGradle:3.0.197''');[IO.File]::WriteAllText($buildPath,$patched,[Text.UTF8Encoding]::new($false))
    $secureRoot=Join-Path $root '.mmtl-forge-secure';$initPath=Join-Path $secureRoot 'mojang.init.gradle';$lines=[Collections.Generic.List[string]]::new();if($RuntimeVersionResolutions.Count){$resolutionMap=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal);foreach($resolution in $RuntimeVersionResolutions){$group=[string]$resolution.group;$artifact=[string]$resolution.artifact;$selector=[string]$resolution.selector;$version=[string]$resolution.version;if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $artifact -notmatch '^[A-Za-z0-9_.-]+$' -or $selector -notmatch '^[0-9]+(?:\.[0-9]+)*\.\+$' -or $version -notmatch '^[0-9]+(?:\.[0-9]+)*(?:[-+][A-Za-z0-9_.+-]+)?$'){throw 'FORGE_GRADLE3_RUNTIME_VERSION_RESOLUTION_INVALID'};$key=$group+':'+$artifact+':'+$selector;if($resolutionMap.ContainsKey($key)){throw 'FORGE_GRADLE3_RUNTIME_VERSION_RESOLUTION_DUPLICATE'};$resolutionMap.Add($key,$version)};$lines.Add('allprojects {');$lines.Add('  configurations.all {');$lines.Add('    resolutionStrategy.eachDependency { details ->');$lines.Add('      def mmtlVersionPins = [');foreach($key in @($resolutionMap.Keys|Sort-Object -CaseSensitive)){$lines.Add("        '$key': '$($resolutionMap[$key])',")};$lines.Add('      ]');$lines.Add("      def mmtlRequested = details.requested.group + ':' + details.requested.name + ':' + details.requested.version");$lines.Add('      if (mmtlVersionPins.containsKey(mmtlRequested)) { details.useVersion(mmtlVersionPins[mmtlRequested]) }');$lines.Add('    }');$lines.Add('  }');$lines.Add('}')};$lines.Add('gradle.projectsEvaluated {');$lines.Add("  println('MMTL_FORGE_GRADLE3_PINNED_MOJANG_METADATA_SEEDED')");$lines.Add('}');[IO.File]::WriteAllText($initPath,($lines.ToArray() -join $separator)+$separator,[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{buildScriptPath=$buildPath;repositoryPath=$repoRoot;initScriptPath=$initPath;requiresOffline=$true;preparationTasks=@();gradleHome=[IO.Path]::GetFullPath($GradleHome);mojangDirectory=(Join-Path $secureRoot 'mojang');minecraftVersion=[string]$Pin.minecraftId;client=$Pin.client;server=$Pin.server;classpathArtifactCount=0;classpathCatalogHash=$null;targetInputCatalogHash=$null}
}

function Test-MmtlForgeMojangArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$PreparedProject,[string]$GradleHome)
    $records=@()
    foreach($name in @('client','server')){
        $expected=$PreparedProject.$name;$path=Join-Path $PreparedProject.mojangDirectory ($name+'.jar')
        $relativePath=$name+'.jar'
        if($GradleHome){
            $minecraftVersion=[string]$PreparedProject.minecraftVersion
            if($minecraftVersion -notmatch '^[0-9]+(?:\.[0-9]+)*$'){throw 'FORGE_MOJANG_ARTIFACT_VERSION_INVALID'}
            $relativePath=if($name -eq 'client'){"caches/minecraft/net/minecraft/minecraft/$minecraftVersion/minecraft-$minecraftVersion.jar"}else{"caches/minecraft/net/minecraft/minecraft_server/$minecraftVersion/minecraft_server-$minecraftVersion.jar"}
            $path=Join-Path $GradleHome $relativePath
        }
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "FORGE_MOJANG_ARTIFACT_MISSING:$name"}
        $item=Get-Item -LiteralPath $path
        if([long]$item.Length -ne [long]$expected.sizeBytes){throw "FORGE_MOJANG_ARTIFACT_SIZE_MISMATCH:$name"}
        $sha1=(Get-FileHash -LiteralPath $path -Algorithm SHA1 -ErrorAction Stop).Hash.ToLowerInvariant()
        if($sha1 -cne [string]$expected.sha1){throw "FORGE_MOJANG_ARTIFACT_SHA1_MISMATCH:$name"}
        $records+=,[pscustomobject]@{kind=$name;path=$relativePath;sha1=$sha1;sizeBytes=[long]$item.Length}
    }
    return @($records)
}

Export-ModuleMember -Function Initialize-MmtlForgePinnedProject,Initialize-MmtlForgeGradle3PinnedProject,Initialize-MmtlForgeGradle6PinnedProject,Initialize-MmtlForgePluginDslProject,Get-MmtlForgePluginArtifactMirror,Get-MmtlForgePluginMcpVersions,Get-MmtlForgeBuildArtifactCatalog,Get-MmtlForgeBuildArtifactMirror,Get-MmtlForgeBuildClasspathArtifactCatalog,Get-MmtlForgeGradle6CatalogFileNames,Get-MmtlForgeGradle6BuildClasspathArtifactCatalog,Get-MmtlForgeGradle6BuildClasspathArtifactMirror,Get-MmtlForgeGradle6RuntimeArtifactCatalog,Get-MmtlForgeGradle6RuntimeArtifactMirror,Get-MmtlForgeGradle6TargetInputCatalog,Get-MmtlForgeGradle6TargetInputMirror,Get-MmtlForgeGradle3TargetInputCatalog,Get-MmtlForgeGradle3TargetInputMirror,Get-MmtlForgeGradle3RuntimeArtifactCatalog,Get-MmtlForgeGradle3RuntimeArtifactMirror,Get-MmtlForgeGradle3PinnedMojangArtifacts,Get-MmtlForgeGradle6PinnedMojangArtifacts,Get-MmtlForgeGradle3BuildClasspathArtifactCatalog,Get-MmtlForgeBuildClasspathArtifactMirror,Get-MmtlForgeGradle3BuildClasspathArtifactMirror,Get-MmtlForgeUserdevConfiguration,Get-MmtlForgeBuildUserdevArtifacts,Get-MmtlForgeBuildMcpArtifacts,Get-MmtlForgePinnedArtifacts,Get-MmtlForgePinnedGradle,Get-MmtlForgeBuildPin,Get-MmtlForgePluginBuildPin,Get-MmtlForgeBuildScriptDeclarations,Test-MmtlForgeMojangArtifacts,New-MmtlForgeClasspathSnapshotMetadata,New-MmtlForgeClasspathDynamicVersionMetadata,Test-MmtlForgeClasspathMojangLibraryPins
