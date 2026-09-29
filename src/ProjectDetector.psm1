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
    $files = @(Get-ChildItem (Join-Path $root 'src\main\resources') -Recurse -File -ErrorAction SilentlyContinue)
    $loader = if ($files.Name -contains 'fabric.mod.json') { 'Fabric' } elseif ($files.Name -contains 'neoforge.mods.toml') { 'NeoForge' } elseif ($files.Name -contains 'mods.toml') { 'Forge' } else { 'Unknown' }
    $mc = [regex]::Match($props, '(?m)^minecraft_version\s*=\s*([^\r\n]+)')
    if (-not $mc.Success) { $mc=[regex]::Match($build,'(?i)(?:net\.minecraftforge:forge:|com\.mojang:minecraft:|minecraft\s*\(\s*["''])(\d+\.\d+(?:\.\d+)?)') }
    $java=[regex]::Match($props,'(?m)^java_version\s*=\s*(\d+)')
    if (-not $java.Success) { $java=[regex]::Match($build,'(?i)(?:JavaLanguageVersion\.of\(|VERSION_|languageVersion\.set\([^\d]*)(\d{2})') }
    $mcVersion=if($mc.Success){$mc.Groups[1].Value.Trim()}else{$null}
    $major=if($java.Success){[int]$java.Groups[1].Value}else{$null}
    if(-not $major -and $mcVersion -match '^1\.(\d+)(?:\.(\d+))?'){
        $minor=[int]$Matches[1];$patch=if($Matches[2]){[int]$Matches[2]}else{0}
        $major=if($minor -gt 20 -or ($minor -eq 20 -and $patch -ge 5)){21}else{17}
    }
    $loaderVersionKey=switch($loader){'Forge'{'forge_version'}'NeoForge'{'neo_version'}'Fabric'{'loader_version'}default{$null}}
    $loaderVersionMatch=if($loaderVersionKey){[regex]::Match($props,"(?m)^$loaderVersionKey\s*=\s*([^\r\n]+)")}else{[regex]::Match('','a^')}
    $loaderVersion=if($loaderVersionMatch.Success){$loaderVersionMatch.Groups[1].Value.Trim()}else{$null}
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
    [pscustomobject]@{ Root=$root; BuildFile=$gradle; Loader=$loader; LoaderVersion=$loaderVersion; MinecraftVersion=$mcVersion; JavaMajor=$major; ModId=$modId; Wrapper=(Test-Path (Join-Path $root 'gradlew.bat')); RunClient='runClient'; RunServer='runServer'; BuildTask='build' }
}
Export-ModuleMember -Function Get-MmtlProject
