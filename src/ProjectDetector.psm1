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
    if($hasQuiltLoom){$evidence.Add([pscustomobject]@{loaderId='Quilt';source='GradlePlugin';path=$gradle;confidence='High';detail='Quilt Loom plugin'})}
    if($files.Name -contains 'fabric.mod.json' -and -not $hasQuiltLoom){$evidence.Add([pscustomobject]@{loaderId='Fabric';source='ModMetadata';path='src/main/resources/fabric.mod.json';confidence='High';detail='Fabric mod metadata'})}
    if($files.Name -contains 'neoforge.mods.toml'){$evidence.Add([pscustomobject]@{loaderId='NeoForge';source='ModMetadata';path='src/main/resources/META-INF/neoforge.mods.toml';confidence='High';detail='NeoForge mod metadata'})}
    if(($files.Name -contains 'mods.toml') -or $allBuildText -match '(?i)(net\.minecraftforge\.gradle|ForgeGradle)'){$evidence.Add([pscustomobject]@{loaderId='Forge';source=if($files.Name -contains 'mods.toml'){'ModMetadata'}else{'GradlePlugin'};path=if($files.Name -contains 'mods.toml'){'src/main/resources/META-INF/mods.toml'}else{$gradle};confidence='High';detail='Forge project marker'})}
    Import-Module (Join-Path $PSScriptRoot 'Adapters/ContractV2.psm1') -Force
    $stackResolution=Resolve-MmtlProjectStack -Evidence @($evidence)
    $loader=$stackResolution.loaderId
    $toolchainId=if($hasQuiltLoom){'QuiltLoom'}elseif($allBuildText -match '(?i)(net\.minecraftforge\.gradle|ForgeGradle)'){'ForgeGradle'}elseif($allBuildText -match '(?i)(net\.neoforged\.moddev|net\.neoforged\.gradle|NeoGradle)'){'NeoGradle'}elseif($allBuildText -match '(?i)(fabric-loom|net\.fabricmc\.fabric-loom)'){'FabricLoom'}elseif($allBuildText -match '(?i)(net\.neoforged\.moddev\.legacyforge|moddevgradle)'){'ModDevGradle'}else{'Unknown'}
    $mc = [regex]::Match($props, '(?m)^minecraft_version\s*=\s*([^\r\n]+)')
    if (-not $mc.Success) { $mc=[regex]::Match($allBuildText,'(?i)(?:net\.minecraftforge:forge:|com\.mojang:minecraft:|minecraft\s*\(\s*["''])(\d+\.\d+(?:\.\d+)?)') }
    if(-not $mc.Success){$mc=[regex]::Match($versionCatalog,'(?m)^\s*minecraft\s*=\s*["''](\d+\.\d+(?:\.\d+)?)["'']')}
    $java=[regex]::Match($props,'(?m)^java_version\s*=\s*(\d+)')
    if (-not $java.Success) { $java=[regex]::Match($allBuildText,'(?i)(?:JavaLanguageVersion\.of\(|VERSION_|languageVersion\.set\([^\d]*)(\d{2})') }
    $mcVersion=if($mc.Success){$mc.Groups[1].Value.Trim()}else{$null}
    $major=if($java.Success){[int]$java.Groups[1].Value}else{$null}
    $javaSource=if($java.Success){'ProjectConfiguration'}else{'Unknown'}
    if(-not $major -and $mcVersion){Import-Module (Join-Path $PSScriptRoot 'BuildJavaResolver.psm1') -Force;$fallback=Get-MmtlBuildJavaCompatibilityFallback -MinecraftId $mcVersion;$major=$fallback.major;$javaSource=$fallback.source}
    $loaderVersionKey=switch($loader){'Forge'{'forge_version'}'NeoForge'{'neo_version'}'Fabric'{'loader_version'}'Quilt'{'quilt_loader'}default{$null}}
    $loaderVersionMatch=if($loaderVersionKey -and $loader -eq 'Quilt'){[regex]::Match($versionCatalog,'(?m)^\s*'+$loaderVersionKey+'\s*=\s*["'']?([^"''\s#]+)')}elseif($loaderVersionKey){[regex]::Match($props,"(?m)^$loaderVersionKey\s*=\s*([^\r\n]+)")}else{[regex]::Match('','a^')}
    $loaderVersion=if($loaderVersionMatch.Success){$loaderVersionMatch.Groups[1].Value.Trim()}else{$null}
    $buildJavaRequirement=if($java.Success){[pscustomobject]@{major=$major;component=$null;source='ProjectConfiguration';confidence='High';requirementKind='ToolchainRequirement'}}elseif($major){$fallback}else{[pscustomobject]@{major=$null;component=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown'}}
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
    $toolchain=[pscustomobject]@{id=$toolchainId;version=$null;ecosystem='Gradle'}
    $project=[pscustomobject]@{ Root=$root; BuildFile=$gradle; Loader=$loader; LoaderVersion=$loaderVersion; MinecraftVersion=$mcVersion; JavaMajor=$major; BuildJavaMajor=$major; RuntimeJavaMajor=$null; BuildJavaRequirement=$buildJavaRequirement; RuntimeJavaRequirement=$runtimeJavaRequirement; ModId=$modId; Wrapper=(Test-Path $wrapper); WrapperPath=$wrapper; RunClient='runClient'; RunServer='runServer'; BuildTask='build';Evidence=@($evidence);DetectionStatus=$stackResolution.status;DetectionConflicts=@($stackResolution.conflicts);LoaderStack=$stackResolution.loaderStack;Toolchain=$toolchain;BuildSystem=$buildSystem}
    $project
}
Export-ModuleMember -Function Get-MmtlProject
