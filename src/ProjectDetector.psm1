function Get-MmtlProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $gradle = @('build.gradle','build.gradle.kts') | Where-Object { Test-Path (Join-Path $root $_) } | Select-Object -First 1
    if (-not $gradle) { throw "无 Gradle 构建文件：$root" }
    $propsPath = Join-Path $root 'gradle.properties'
    $props = if (Test-Path $propsPath) { Get-Content $propsPath -Raw } else { '' }
    $buildPath=Join-Path $root $gradle
    $build=Get-Content -LiteralPath $buildPath -Raw
    $settingsPath=Join-Path $root 'settings.gradle';if(-not(Test-Path $settingsPath)){$settingsPath=Join-Path $root 'settings.gradle.kts'}
    $settings=if(Test-Path $settingsPath){Get-Content -LiteralPath $settingsPath -Raw}else{''}
    $versionCatalogPath=Join-Path $root 'gradle/libs.versions.toml';$versionCatalog=if(Test-Path $versionCatalogPath){Get-Content -LiteralPath $versionCatalogPath -Raw}else{''}
    $allBuildText="$build`n$settings`n$versionCatalog"
    $files = @(Get-ChildItem (Join-Path $root 'src/main/resources') -Recurse -File -ErrorAction SilentlyContinue)
    $evidence=[Collections.Generic.List[object]]::new()
    $hasQuiltLoom=$allBuildText -match '(?i)(org\.quiltmc\.loom|quilt-loom)'
    $hasLegacyLooming=$allBuildText -match '(?i)(legacy-looming|net\.legacyfabric\.loom|legacyfabric-loom)'
    $hasPloceus=$allBuildText -match '(?i)(ploceus|net\.ornithemc)'
    $hasRift=$allBuildText -match '(?i)(org\.dimdev:ForgeGradle|org\.dimdev\.riftloader|RiftLoaderClientTweaker|rift-loader)'
    $forgeMarker=(-not $hasRift) -and (($files.Name -contains 'mods.toml') -or ($allBuildText -match '(?i)(net\.minecraftforge\.gradle|ForgeGradle)'))
    if($hasQuiltLoom){$evidence.Add([pscustomobject]@{loaderId='Quilt';source='GradlePlugin';path=$gradle;confidence='High';detail='Quilt Loom plugin'})}
    if($files.Name -contains 'fabric.mod.json' -and -not ($hasQuiltLoom -or $hasPloceus -or $hasLegacyLooming)){$evidence.Add([pscustomobject]@{loaderId='Fabric';source='ModMetadata';path='src/main/resources/fabric.mod.json';confidence='High';detail='Fabric mod metadata'})}
    if($files.Name -contains 'neoforge.mods.toml'){$evidence.Add([pscustomobject]@{loaderId='NeoForge';source='ModMetadata';path='src/main/resources/META-INF/neoforge.mods.toml';confidence='High';detail='NeoForge mod metadata'})}
    if($forgeMarker){$evidence.Add([pscustomobject]@{loaderId='Forge';source=if($files.Name -contains 'mods.toml'){'ModMetadata'}else{'GradlePlugin'};path=if($files.Name -contains 'mods.toml'){'src/main/resources/META-INF/mods.toml'}else{$gradle};confidence='High';detail='Forge project marker'})}
    if($hasLegacyLooming){$evidence.Add([pscustomobject]@{loaderId='LegacyFabric';source='GradlePlugin';path=$gradle;confidence='High';detail='Legacy Fabric Looming plugin';toolchainId='LegacyLooming'})}
    if($hasPloceus){$evidence.Add([pscustomobject]@{loaderId='OrnitheLoader';source='GradlePlugin';path=$gradle;confidence='High';detail='Ornithe Loader/Ploceus marker';toolchainId='Ploceus'})}
    if($allBuildText -match '(?i)(com\.mumfrey:liteloader|liteloader-gradle|litemod\.json)'){$evidence.Add([pscustomobject]@{loaderId='LiteLoader';source='GradlePlugin';path=$gradle;confidence='High';detail='LiteLoader project marker';role=if($forgeMarker){'Overlay'}else{'Primary'}})}
    if($hasRift){$evidence.Add([pscustomobject]@{loaderId='Rift';source='GradlePlugin';path=$gradle;confidence='High';detail='Rift tweaker/ForgeGradle marker'})}
    if($allBuildText -match '(?i)(modloadermp|modloader\.ModLoader)'){$evidence.Add([pscustomobject]@{loaderId=if($allBuildText -match '(?i)modloadermp'){'ModLoaderMP'}else{'ModLoader'};source='GradlePlugin';path=$gradle;confidence='Medium';detail='Historical ModLoader dependency marker'})}
    Import-Module (Join-Path $PSScriptRoot 'Adapters/ContractV2.psm1') -Force
    $stackResolution=Resolve-MmtlProjectStack -Evidence @($evidence)
    $loader=$stackResolution.loaderId
    $toolchainId=if($hasLegacyLooming){'LegacyLooming'}elseif($hasPloceus){'Ploceus'}elseif($hasQuiltLoom){'QuiltLoom'}elseif($allBuildText -match '(?i)(net\.minecraftforge\.gradle|ForgeGradle)'){'ForgeGradle'}elseif($allBuildText -match '(?i)(net\.neoforged\.moddev|net\.neoforged\.gradle|NeoGradle)'){'NeoGradle'}elseif($allBuildText -match '(?i)(fabric-loom|net\.fabricmc\.fabric-loom)'){'FabricLoom'}elseif($allBuildText -match '(?i)(net\.neoforged\.moddev\.legacyforge|moddevgradle)'){'ModDevGradle'}else{'Unknown'}
    $mc = [regex]::Match($props, '(?m)^minecraft_version\s*=\s*([^\r\n]+)')
    if (-not $mc.Success) { $mc=[regex]::Match($allBuildText,'(?i)(?:net\.minecraftforge:forge:|com\.mojang:minecraft:|minecraft\s*\(\s*["''])(\d+\.\d+(?:\.\d+)?)') }
    if(-not $mc.Success){$mc=[regex]::Match($versionCatalog,'(?m)^\s*minecraft\s*=\s*["''](\d+\.\d+(?:\.\d+)?)["'']')}
    if(-not $mc.Success -and $hasRift){$mc=[regex]::Match($allBuildText,'(?i)version\s*=\s*["''](1\.13(?:\.\d+)?)["'']')}
    $java=[regex]::Match($props,'(?m)^java_version\s*=\s*(\d+)')
    if (-not $java.Success) { $java=[regex]::Match($allBuildText,'(?i)(?:JavaLanguageVersion\.of\(|VERSION_|languageVersion\.set\([^\d]*)(\d{2})') }
    $compilerTargetMatch=[regex]::Match($allBuildText,'(?i)(?:sourceCompatibility|targetCompatibility)\s*=\s*(?:1\.(\d+)|JavaVersion\.VERSION_1_(\d+))')
    $mcVersion=if($mc.Success){$mc.Groups[1].Value.Trim()}else{$null}
    Import-Module (Join-Path $PSScriptRoot 'BuildJavaResolver.psm1') -Force
    $major=if($java.Success){[int]$java.Groups[1].Value}else{$null}
    $configuredJavaMajor=$major
    $javaSource=if($java.Success){'ProjectConfiguration'}else{'Unknown'}
    if(-not $major -and $mcVersion){$fallback=Get-MmtlBuildJavaCompatibilityFallback -MinecraftId $mcVersion;$major=$fallback.major;$javaSource=$fallback.source}
    $loaderVersionKey=switch($loader){'Forge'{'forge_version'}'NeoForge'{'neo_version'}'Fabric'{'loader_version'}'LegacyFabric'{'loader_version'}'OrnitheLoader'{'loader_version'}'LiteLoader'{'liteloader_version'}'Quilt'{'quilt_loader'}default{$null}}
    $loaderVersionMatch=if($loaderVersionKey -and $loader -eq 'Quilt'){[regex]::Match($versionCatalog,'(?m)^\s*'+$loaderVersionKey+'\s*=\s*["'']?([^"''\s#]+)')}elseif($loaderVersionKey){[regex]::Match($props,"(?m)^$loaderVersionKey\s*=\s*([^\r\n]+)")}else{[regex]::Match('','a^')}
    $loaderVersion=if($loaderVersionMatch.Success){$loaderVersionMatch.Groups[1].Value.Trim()}else{$null}
    if($loader -eq 'Rift'){$riftVersion=[regex]::Match($allBuildText,'(?im)^version\s+["''](\d+\.\d+\.\d+)');if($riftVersion.Success){$loaderVersion=$riftVersion.Groups[1].Value}}
    $gradleRuntimeJavaRequirement=Get-MmtlGradleWrapperRuntimeJavaRequirement -ProjectRoot $root
    $compilerTargetMajor=if($compilerTargetMatch.Success){[int]$(if($compilerTargetMatch.Groups[1].Success){$compilerTargetMatch.Groups[1].Value}else{$compilerTargetMatch.Groups[2].Value})}else{$null}
    $buildJavaRequirement=if($gradleRuntimeJavaRequirement.major -ge 17){$gradleMinimum=[int]$gradleRuntimeJavaRequirement.major;$buildMajor=if($major){[math]::Max([int]$major,$gradleMinimum)}else{$gradleMinimum};$major=$buildMajor;[pscustomobject]@{major=$buildMajor;component=$null;source=if($configuredJavaMajor -and $configuredJavaMajor -ge $gradleMinimum){'ProjectConfiguration'}else{$gradleRuntimeJavaRequirement.source};confidence='High';requirementKind='GradleRuntimeRequirement';gradleVersion=$gradleRuntimeJavaRequirement.gradleVersion;gradleRuntimeMinimum=$gradleMinimum;compilerTargetMajor=$compilerTargetMajor;reason=$gradleRuntimeJavaRequirement.reason}}elseif($java.Success){[pscustomobject]@{major=$major;component=$null;source='ProjectConfiguration';confidence='High';requirementKind='ToolchainRequirement';gradleRuntimeMinimum=$gradleRuntimeJavaRequirement.major}}elseif($gradleRuntimeJavaRequirement.major -and $compilerTargetMajor){$buildMajor=[math]::Max([int]$compilerTargetMajor,[int]$gradleRuntimeJavaRequirement.major);$major=$buildMajor;[pscustomobject]@{major=$buildMajor;component=$null;source='GradleWrapperAndCompilerTarget';confidence='Medium';requirementKind='CompatibilityRequirement';gradleVersion=$gradleRuntimeJavaRequirement.gradleVersion;gradleRuntimeMinimum=$gradleRuntimeJavaRequirement.major;compilerTargetMajor=$compilerTargetMajor}}elseif($major){$fallback|Add-Member -NotePropertyName gradleRuntimeMinimum -NotePropertyValue $gradleRuntimeJavaRequirement.major -Force;$fallback}elseif($gradleRuntimeJavaRequirement.major){[pscustomobject]@{major=$gradleRuntimeJavaRequirement.major;component=$null;source=$gradleRuntimeJavaRequirement.source;confidence=$gradleRuntimeJavaRequirement.confidence;requirementKind='GradleRuntimeRequirement'}}else{[pscustomobject]@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown'}}
    $runtimeJavaRequirement=[pscustomobject]@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown'}
    $modIdMatch=[regex]::Match($props,'(?m)^mod_id\s*=\s*([^\r\n]+)')
    $modId=if($modIdMatch.Success){$modIdMatch.Groups[1].Value.Trim()}else{$null}
    if(-not $modId){
        $fabricFile=$files|Where-Object Name -eq 'fabric.mod.json'|Select-Object -First 1
        if($fabricFile){try{$fabric=Get-Content -LiteralPath $fabricFile.FullName -Raw|ConvertFrom-Json -ErrorAction Stop;$modId=[string]$fabric.id}catch{}}
    }
    if(-not $modId){
        $tomlFile=$files|Where-Object Name -in @('mods.toml','neoforge.mods.toml')|Select-Object -First 1
        if($tomlFile){$toml=Get-Content -LiteralPath $tomlFile.FullName -Raw;$idMatch=[regex]::Match($toml,'(?m)^\s*modId\s*=\s*["'']([^"'']+)["'']');if($idMatch.Success -and $idMatch.Groups[1].Value -notmatch '^\$\{'){$modId=$idMatch.Groups[1].Value}}
    }
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    $wrapper=Join-Path $root (Get-MmtlPlatformProvider).GradleWrapper
    $buildSystem=if(Test-Path $wrapper){[pscustomobject]@{id='GradleWrapper';version=$null}}else{[pscustomobject]@{id='Custom';version=$null}}
    $toolchainVersion=if($hasRift){'2.3-SNAPSHOT'}else{$null}
    $toolchainEcosystem=if($loader -eq 'Rift'){'Rift'}else{'Gradle'}
    $toolchain=[pscustomobject]@{id=$toolchainId;version=$toolchainVersion;ecosystem=$toolchainEcosystem}
    if($toolchainId -in @('LegacyLooming','Ploceus')){
        $pluginName=if($toolchainId -eq 'LegacyLooming'){'legacy-looming'}else{'ploceus'}
        $pluginVersionPattern='(?is)id\s+["'']'+[regex]::Escape($pluginName)+'["'']\s+version\s+["'']([^"''\r\n]+)["'']'
        $pluginVersionMatch=[regex]::Match($allBuildText,$pluginVersionPattern)
        $pluginVersion=if($pluginVersionMatch.Success){$pluginVersionMatch.Groups[1].Value}else{$null}
        if($pluginVersion -match '^\$\{([^}]+)\}$'){$propertyName=$Matches[1];$propertyMatch=[regex]::Match($props,"(?m)^\s*$([regex]::Escape($propertyName))\s*=\s*([^\r\n]+)");$pluginVersion=if($propertyMatch.Success){$propertyMatch.Groups[1].Value.Trim()}else{$null}}
        $toolchain.version=$pluginVersion
        $toolchain.ecosystem=if($loader -eq 'LegacyFabric'){'LegacyFabric'}elseif($loader -eq 'OrnitheLoader'){'Ornithe'}else{'Gradle'}
    }
    $project=[pscustomobject]@{ Root=$root; BuildFile=$gradle; Loader=$loader; LoaderVersion=$loaderVersion; MinecraftVersion=$mcVersion; JavaMajor=$major; BuildJavaMajor=$major; RuntimeJavaMajor=$null; BuildJavaRequirement=$buildJavaRequirement; RuntimeJavaRequirement=$runtimeJavaRequirement; GradleRuntimeJavaRequirement=$gradleRuntimeJavaRequirement; CompilerTargetJavaMajor=$compilerTargetMajor; ModId=$modId; Wrapper=(Test-Path $wrapper); WrapperPath=$wrapper; RunClient='runClient'; RunServer='runServer'; BuildTask='build';Evidence=@($evidence);DetectionStatus=$stackResolution.status;DetectionConflicts=@($stackResolution.conflicts);LoaderStack=$stackResolution.loaderStack;Toolchain=$toolchain;BuildSystem=$buildSystem}
    $project
}
Export-ModuleMember -Function Get-MmtlProject
