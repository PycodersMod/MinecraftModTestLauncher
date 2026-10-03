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
    $hasOrnitheLoader=$allBuildText -match '(?i)net\.ornithemc:ornithe-loader'
    $hasRift=$allBuildText -match '(?i)(org\.dimdev:ForgeGradle|org\.dimdev\.riftloader|RiftLoaderClientTweaker|rift-loader)'
    $hasLiteLoaderMetadata=$files.Name -contains 'litemod.json'
    $hasLiteLoaderPlugin=$allBuildText -match '(?i)(com\.mumfrey:liteloader|net\.minecraftforge\.gradle\.liteloader|liteloader-gradle)'
    $hasLiteLoader=$hasLiteLoaderMetadata -or $hasLiteLoaderPlugin
    $forgeToolchainMarker=$allBuildText -match '(?i)(net\.minecraftforge\.gradle|ForgeGradle)'
    $hasForgeRuntime=($files.Name -contains 'mods.toml') -or ($allBuildText -match '(?i)net\.minecraftforge:forge(?::|@)') -or ($forgeToolchainMarker -and -not $hasLiteLoaderPlugin)
    $forgeMarker=(-not $hasRift) -and $hasForgeRuntime
    if($hasQuiltLoom){$evidence.Add([pscustomobject]@{loaderId='Quilt';source='GradlePlugin';path=$gradle;confidence='High';detail='Quilt Loom 插件'})}
    if($files.Name -contains 'fabric.mod.json' -and -not ($hasQuiltLoom -or $hasOrnitheLoader -or $hasLegacyLooming)){$evidence.Add([pscustomobject]@{loaderId='Fabric';source='ModMetadata';path='src/main/resources/fabric.mod.json';confidence='High';detail='Fabric 模组元数据'})}
    if($files.Name -contains 'neoforge.mods.toml'){$evidence.Add([pscustomobject]@{loaderId='NeoForge';source='ModMetadata';path='src/main/resources/META-INF/neoforge.mods.toml';confidence='High';detail='NeoForge 模组元数据'})}
    if($forgeMarker){$evidence.Add([pscustomobject]@{loaderId='Forge';source=if($files.Name -contains 'mods.toml'){'ModMetadata'}else{'GradlePlugin'};path=if($files.Name -contains 'mods.toml'){'src/main/resources/META-INF/mods.toml'}else{$gradle};confidence='High';detail='Forge 项目标记'})}
    if($hasLegacyLooming){$evidence.Add([pscustomobject]@{loaderId='LegacyFabric';source='GradlePlugin';path=$gradle;confidence='High';detail='Legacy Fabric Looming 插件';toolchainId='LegacyLooming'})}
    if($hasOrnitheLoader){$evidence.Add([pscustomobject]@{loaderId='OrnitheLoader';source='GradleDependency';path=$gradle;confidence='High';detail='Ornithe Loader 运行时制品';toolchainId=if($hasPloceus){'Ploceus'}else{$null}})}
    if($hasLiteLoader){$evidence.Add([pscustomobject]@{loaderId='LiteLoader';source=if($hasLiteLoaderMetadata){'ModMetadata'}else{'GradlePlugin'};path=if($hasLiteLoaderMetadata){'src/main/resources/litemod.json'}else{$gradle};confidence='High';detail='LiteLoader 项目标记';role=if($hasForgeRuntime){'Overlay'}else{'Primary'}})}
    if($hasRift){$evidence.Add([pscustomobject]@{loaderId='Rift';source='GradlePlugin';path=$gradle;confidence='High';detail='Rift tweaker/ForgeGradle marker'})}
    if($allBuildText -match '(?i)(modloadermp|modloader\.ModLoader)'){$evidence.Add([pscustomobject]@{loaderId=if($allBuildText -match '(?i)modloadermp'){'ModLoaderMP'}else{'ModLoader'};source='GradlePlugin';path=$gradle;confidence='Medium';detail='历史 ModLoader 依赖标记'})}
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
    $fallback=$null
    if(-not $major -and $mcVersion){$fallback=Get-MmtlBuildJavaCompatibilityFallback -MinecraftId $mcVersion;$major=$fallback.major;$javaSource=$fallback.source}
    $loaderVersionKey=switch($loader){'Forge'{'forge_version'}'NeoForge'{'neo_version'}'Fabric'{'loader_version'}'LegacyFabric'{'loader_version'}'OrnitheLoader'{'loader_version'}'LiteLoader'{'liteloader_version'}'Quilt'{'quilt_loader'}default{$null}}
    $loaderVersionMatch=if($loaderVersionKey -and $loader -eq 'Quilt'){[regex]::Match($versionCatalog,'(?m)^\s*'+$loaderVersionKey+'\s*=\s*["'']?([^"''\s#]+)')}elseif($loaderVersionKey){[regex]::Match($props,"(?m)^$loaderVersionKey\s*=\s*([^\r\n]+)")}else{[regex]::Match('','a^')}
    $loaderVersion=if($loaderVersionMatch.Success){$loaderVersionMatch.Groups[1].Value.Trim()}else{$null}
    if($loader -eq 'Rift'){$riftVersion=[regex]::Match($allBuildText,'(?im)^version\s+["''](\d+\.\d+\.\d+)');if($riftVersion.Success){$loaderVersion=$riftVersion.Groups[1].Value}}
    $gradleRuntimeJavaRequirement=Get-MmtlGradleWrapperRuntimeJavaRequirement -ProjectRoot $root
    $compilerTargetMajor=if($compilerTargetMatch.Success){[int]$(if($compilerTargetMatch.Groups[1].Success){$compilerTargetMatch.Groups[1].Value}else{$compilerTargetMatch.Groups[2].Value})}else{$null}
    $wrapperMinimum=if($gradleRuntimeJavaRequirement.major){[int]$gradleRuntimeJavaRequirement.major}else{$null}
    $compilerMinimum=if($compilerTargetMajor){[int]$compilerTargetMajor}else{$null}
    $hardMinimums=@(@($wrapperMinimum,$compilerMinimum)|Where-Object{$_ -gt 0})
    $minimumMajor=if($hardMinimums.Count){[int](($hardMinimums|Measure-Object -Maximum).Maximum)}else{$null}
    if($minimumMajor){
        $buildMajor=if($configuredJavaMajor){[math]::Max([int]$configuredJavaMajor,$minimumMajor)}elseif($major){[math]::Max([int]$major,$minimumMajor)}else{$minimumMajor}
        $major=$buildMajor
        $buildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=$minimumMajor;requirementKind='Minimum';minimumMajor=$minimumMajor;preferredMajor=if($configuredJavaMajor -gt $minimumMajor){[int]$configuredJavaMajor}elseif($fallback -and $fallback.preferredMajor -gt $minimumMajor){[int]$fallback.preferredMajor}else{$null};exactMajor=$null;component=$null;source=if($wrapperMinimum -ge $compilerMinimum){$gradleRuntimeJavaRequirement.source}else{'GradleWrapperAndCompilerTarget'};confidence=if($compilerMinimum -and $compilerMinimum -gt $wrapperMinimum){'Medium'}else{'High'};requirementSourceKind=if($configuredJavaMajor){'ProjectConfiguration'}elseif($wrapperMinimum){'GradleRuntimeRequirement'}else{'CompilerTargetRequirement'};gradleVersion=$gradleRuntimeJavaRequirement.gradleVersion;gradleRuntimeMinimum=$wrapperMinimum;compilerTargetMajor=$compilerTargetMajor;reason=if($wrapperMinimum -and $compilerMinimum -and $compilerMinimum -gt $wrapperMinimum){'编译目标高于 Wrapper 的 JVM 运行最低要求。'}else{$gradleRuntimeJavaRequirement.reason}}
    }elseif($configuredJavaMajor){
        $buildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=[int]$configuredJavaMajor;requirementKind='Preferred';minimumMajor=$null;preferredMajor=[int]$configuredJavaMajor;exactMajor=$null;component=$null;source='ProjectConfiguration';confidence='High';requirementSourceKind='ToolchainRequirement';gradleRuntimeMinimum=$wrapperMinimum;compilerTargetMajor=$compilerTargetMajor}
    }elseif($major){
        $buildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=[int]$major;requirementKind='Preferred';minimumMajor=$null;preferredMajor=[int]$major;exactMajor=$null;component=$null;source=$javaSource;confidence='Low';requirementSourceKind='CompatibilityFallback';gradleRuntimeMinimum=$wrapperMinimum;compilerTargetMajor=$compilerTargetMajor;reason=$fallback.reason}
    }else{
        $buildJavaRequirement=[pscustomobject]@{purpose='BuildJava';major=$null;requirementKind='Unknown';minimumMajor=$null;preferredMajor=$null;exactMajor=$null;component=$null;source='Unknown';confidence='Unknown';requirementSourceKind='Unknown';gradleRuntimeMinimum=$null;compilerTargetMajor=$compilerTargetMajor}
    }
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
    $toolchainEcosystem=if($hasPloceus){'Ornithe'}elseif($loader -eq 'Rift'){'Rift'}else{'Gradle'}
    $toolchain=[pscustomobject]@{id=$toolchainId;version=$toolchainVersion;ecosystem=$toolchainEcosystem}
    if($toolchainId -in @('LegacyLooming','Ploceus')){
        $pluginName=if($toolchainId -eq 'LegacyLooming'){'legacy-looming'}else{'ploceus'}
        $pluginVersionPattern='(?is)id\s+["'']'+[regex]::Escape($pluginName)+'["'']\s+version\s+["'']([^"''\r\n]+)["'']'
        $pluginVersionMatch=[regex]::Match($allBuildText,$pluginVersionPattern)
        $pluginVersion=if($pluginVersionMatch.Success){$pluginVersionMatch.Groups[1].Value}else{$null}
        if($pluginVersion -match '^\$\{([^}]+)\}$'){$propertyName=$Matches[1];$propertyMatch=[regex]::Match($props,"(?m)^\s*$([regex]::Escape($propertyName))\s*=\s*([^\r\n]+)");$pluginVersion=if($propertyMatch.Success){$propertyMatch.Groups[1].Value.Trim()}else{$null}}
        $toolchain.version=$pluginVersion
        $toolchain.ecosystem=if($loader -eq 'LegacyFabric'){'LegacyFabric'}elseif($hasPloceus){'Ornithe'}else{'Gradle'}
    }
    $repositoryRoot=$root
    $ancestor=Get-Item -LiteralPath $root
    while($ancestor){
        if(Test-Path -LiteralPath (Join-Path $ancestor.FullName '.git')){$repositoryRoot=$ancestor.FullName;break}
        $ancestor=$ancestor.Parent
    }
    $project=[pscustomobject]@{ RepositoryRoot=$repositoryRoot; ProjectRoot=$root; Root=$root; BuildFile=$gradle; Loader=$loader; LoaderVersion=$loaderVersion; MinecraftVersion=$mcVersion; JavaMajor=$major; BuildJavaMajor=$major; RuntimeJavaMajor=$null; BuildJavaRequirement=$buildJavaRequirement; RuntimeJavaRequirement=$runtimeJavaRequirement; GradleRuntimeJavaRequirement=$gradleRuntimeJavaRequirement; CompilerTargetJavaMajor=$compilerTargetMajor; ModId=$modId; Wrapper=(Test-Path $wrapper); WrapperPath=$wrapper; RunClient='runClient'; RunServer='runServer'; BuildTask='build';Evidence=@($evidence);DetectionStatus=$stackResolution.status;DetectionConflicts=@($stackResolution.conflicts);LoaderStack=$stackResolution.loaderStack;Toolchain=$toolchain;BuildSystem=$buildSystem}
    $project
}

function Find-MmtlGradleProjects {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $start=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $excludedNames=@('.git','.gradle','build','run','out','runtime','node_modules','cache','temp','tmp','fixture','fixtures')
    $repositoryRoots=[Collections.Generic.List[string]]::new()
    if(Test-Path -LiteralPath (Join-Path $start '.git')){
        $repositoryRoots.Add($start)
    }else{
        foreach($child in @(Get-ChildItem -LiteralPath $start -Directory -Force -ErrorAction SilentlyContinue)){
            if($child.Name -in $excludedNames){continue}
            if(Test-Path -LiteralPath (Join-Path $child.FullName '.git')){$repositoryRoots.Add($child.FullName)}
        }
        if($repositoryRoots.Count -eq 0 -and ((Test-Path -LiteralPath (Join-Path $start 'build.gradle')) -or (Test-Path -LiteralPath (Join-Path $start 'build.gradle.kts')))){
            $repositoryRoots.Add($start)
        }
    }

    foreach($repositoryRoot in $repositoryRoots){
        $pending=[Collections.Generic.Stack[string]]::new()
        $pending.Push($repositoryRoot)
        while($pending.Count -gt 0){
            $directory=$pending.Pop()
            $buildFile=@('build.gradle','build.gradle.kts')|Where-Object { Test-Path -LiteralPath (Join-Path $directory $_) }|Select-Object -First 1
            if($buildFile){
                $project=Get-MmtlProject -Path $directory
                $project.RepositoryRoot=$repositoryRoot
                $project.ProjectRoot=$project.Root
                $project
            }
            foreach($child in @(Get-ChildItem -LiteralPath $directory -Directory -Force -ErrorAction SilentlyContinue)){
                if($child.Name -in $excludedNames){continue}
                if(($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
                if(Test-Path -LiteralPath (Join-Path $child.FullName '.git')){continue}
                $pending.Push($child.FullName)
            }
        }
    }
}

Export-ModuleMember -Function Get-MmtlProject, Find-MmtlGradleProjects
