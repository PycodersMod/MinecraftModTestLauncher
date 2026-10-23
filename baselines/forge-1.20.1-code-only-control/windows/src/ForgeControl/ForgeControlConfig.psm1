Set-StrictMode -Version Latest
$script:ForgeControlRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))

function Get-MmtlForgeConfigValue {
    param([Parameter(Mandatory)]$Object,[Parameter(Mandatory)][string]$Name,$Default)
    $property=$Object.PSObject.Properties[$Name]
    if($null -ne $property -and $null -ne $property.Value){return $property.Value}
    return $Default
}

function Expand-MmtlForgeConfigPath {
    param([Parameter(Mandatory)][string]$Value,[Parameter(Mandatory)][string]$BasePath)
    $expanded=[Environment]::ExpandEnvironmentVariables($Value)
    if($expanded -match '%[^%]+%'){throw "CONFIG_ENVIRONMENT_VARIABLE_UNDEFINED: $Value"}
    if(-not [IO.Path]::IsPathRooted($expanded)){$expanded=Join-Path $BasePath $expanded}
    return [IO.Path]::GetFullPath($expanded)
}

function Resolve-MmtlForgeControlConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$RootPath=$script:ForgeControlRoot,
        [ValidateRange(1,8)][int]$ClientCount=0,
        [string[]]$PlayerNames,
        [string]$MinecraftRoot,
        [string]$JavaPath,
        [string]$VersionDirectory,
        [string]$RuntimeRoot,
        [string]$WorldName,
        [ValidateSet('QuickPlay','AgentAfterMainMenu')][string]$GuestConnectionMode,
        [Nullable[bool]]$LanEnabled
    )
    $root=[IO.Path]::GetFullPath($RootPath)
    $fullConfig=if([IO.Path]::IsPathRooted($ConfigPath)){[IO.Path]::GetFullPath($ConfigPath)}else{[IO.Path]::GetFullPath((Join-Path $root $ConfigPath))}
    if(-not(Test-Path -LiteralPath $fullConfig -PathType Leaf)){throw "CONFIG_NOT_FOUND: $fullConfig"}
    try{$file=Get-Content -LiteralPath $fullConfig -Raw|ConvertFrom-Json -ErrorAction Stop}catch{throw "CONFIG_JSON_INVALID: $($_.Exception.Message)"}
    if([int](Get-MmtlForgeConfigValue $file 'schemaVersion' 0) -ne 1){throw 'CONFIG_SCHEMA_UNSUPPORTED'}
    if($null -eq $file.target -or [string]$file.target.minecraftVersion -cne '1.20.1' -or [string]$file.target.loader -cne 'Forge' -or [string]$file.target.loaderVersion -cne '47.4.23'){
        throw 'TARGET_UNSUPPORTED: only Minecraft 1.20.1 Forge 47.4.23 is supported by this controller'
    }
    $javaMajor=[int](Get-MmtlForgeConfigValue $file 'javaMajor' 17)
    if($javaMajor -ne 17){throw 'JAVA_MAJOR_UNSUPPORTED: Forge 1.20.1 controller requires Java 17'}
    $count=if($PSBoundParameters.ContainsKey('ClientCount') -and $ClientCount -gt 0){$ClientCount}else{[int](Get-MmtlForgeConfigValue $file 'clientCount' 1)}
    if($count -lt 1 -or $count -gt 8){throw 'CLIENT_COUNT_OUT_OF_RANGE: clientCount must be from 1 through 8'}
    $fileNames=@()
    if($file.players){$fileNames=@($file.players|ForEach-Object{[string]$_})}
    if($PSBoundParameters.ContainsKey('PlayerNames')){$names=@($PlayerNames)}
    elseif($PSBoundParameters.ContainsKey('ClientCount') -and $fileNames.Count -ne $count){
        $names=@($fileNames|Select-Object -First $count)
        for($i=$names.Count;$i -lt $count;$i++){
            $candidate=if($i -eq 0){'Dev'}else{'Dev_'+$i}
            $suffix=1
            while($names -contains $candidate){$candidate='Dev_'+$i+'_'+$suffix;$suffix++}
            $names+= $candidate
        }
    }
    elseif($fileNames.Count -gt 0){$names=$fileNames}
    else{$names=@('Dev');for($i=1;$i -lt $count;$i++){$names+=('Dev_'+$i)}}
    if($names.Count -ne $count){throw 'PLAYER_COUNT_MISMATCH: supply exactly one unique player name per client'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($name in $names){if([string]$name -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'PLAYER_NAME_INVALID: names must use 1-16 ASCII letters, digits, or underscores'};if(-not $seen.Add([string]$name)){throw 'PLAYER_NAME_DUPLICATE: offline player names must be unique'} }
    $lan=if($PSBoundParameters.ContainsKey('LanEnabled') -and $null -ne $LanEnabled){[bool]$LanEnabled}elseif($PSBoundParameters.ContainsKey('ClientCount')){[bool]($count -ge 2)}else{[bool](Get-MmtlForgeConfigValue $file 'lanEnabled' ($count -ge 2))}
    if($count -eq 1 -and $lan){throw 'SINGLE_CLIENT_LAN_FORBIDDEN: a single-client Session must not publish LAN'}
    if($count -gt 1 -and -not $lan){throw 'MULTI_CLIENT_LAN_REQUIRED: multi-client Sessions require local Integrated LAN'}
    $configDirectory=Split-Path -Parent $fullConfig
    $rawJava=if($PSBoundParameters.ContainsKey('JavaPath')){$JavaPath}else{[string](Get-MmtlForgeConfigValue $file 'javaPath' '')}
    $rawMinecraft=if($PSBoundParameters.ContainsKey('MinecraftRoot')){$MinecraftRoot}else{[string](Get-MmtlForgeConfigValue $file 'minecraftRoot' '')}
    $rawRuntime=if($PSBoundParameters.ContainsKey('RuntimeRoot')){$RuntimeRoot}else{[string](Get-MmtlForgeConfigValue $file 'runtimeRoot' '')}
    if([string]::IsNullOrWhiteSpace($rawJava)){throw 'CONFIG_JAVA_PATH_REQUIRED: set javaPath to the full path of Java 17 java.exe'}
    if(-not [IO.Path]::IsPathRooted($rawJava)){throw 'CONFIG_JAVA_PATH_MUST_BE_ABSOLUTE: javaPath must point to java.exe'}
    if([string]::IsNullOrWhiteSpace($rawMinecraft)){throw 'CONFIG_MINECRAFT_ROOT_REQUIRED: set minecraftRoot to the Minecraft Java Edition game root'}
    if(-not [IO.Path]::IsPathRooted($rawMinecraft)){throw 'CONFIG_MINECRAFT_ROOT_MUST_BE_ABSOLUTE'}
    $versionDirectory=if($PSBoundParameters.ContainsKey('VersionDirectory')){$VersionDirectory}else{[string](Get-MmtlForgeConfigValue $file 'versionDirectory' '')}
    if([string]::IsNullOrWhiteSpace($versionDirectory)){throw 'CONFIG_VERSION_DIRECTORY_REQUIRED: set versionDirectory to the Forge version folder name'}
    if($versionDirectory -in @('.','..') -or [IO.Path]::IsPathRooted($versionDirectory) -or $versionDirectory -match '[\\/]' -or $versionDirectory.Length -gt 128){throw 'CONFIG_VERSION_DIRECTORY_INVALID: use one folder name from minecraftRoot/versions'}
    if([string]::IsNullOrWhiteSpace($rawRuntime)){$rawRuntime='runtime'}
    $world=if($PSBoundParameters.ContainsKey('WorldName')){$WorldName}else{[string](Get-MmtlForgeConfigValue $file 'worldName' 'MMTL-Test')}
    if($world -notmatch '^[A-Za-z0-9._ -]{1,64}$' -or $world -in @('.','..')){throw 'WORLD_NAME_INVALID'}
    $guestConnectionMode=if($PSBoundParameters.ContainsKey('GuestConnectionMode')){$GuestConnectionMode}else{[string](Get-MmtlForgeConfigValue $file 'guestConnectionMode' 'AgentAfterMainMenu')}
    if($guestConnectionMode -notin @('QuickPlay','AgentAfterMainMenu')){throw 'GUEST_CONNECTION_MODE_INVALID'}
    $resolved=[pscustomobject][ordered]@{
        schemaVersion=1
        configPath=$fullConfig
        target=[pscustomobject][ordered]@{minecraftVersion='1.20.1';loader='Forge';loaderVersion='47.4.23'}
        javaMajor=17
        javaPath=(Expand-MmtlForgeConfigPath -Value $rawJava -BasePath $root)
        minecraftRoot=(Expand-MmtlForgeConfigPath -Value $rawMinecraft -BasePath $root)
        runtimeRoot=(Expand-MmtlForgeConfigPath -Value $rawRuntime -BasePath $root)
        clientCount=$count
        players=@($names)
        identityMode='OfflineTestIdentity'
        lanEnabled=$lan
        worldName=$world
        guestConnectionMode=$guestConnectionMode
        guestHandshakeDiagnostics=[bool](Get-MmtlForgeConfigValue $file 'guestHandshakeDiagnostics' $false)
        worldGameMode=[string](Get-MmtlForgeConfigValue $file 'worldGameMode' 'survival')
        worldDifficulty=[string](Get-MmtlForgeConfigValue $file 'worldDifficulty' 'normal')
        worldSeed=[string](Get-MmtlForgeConfigValue $file 'worldSeed' '')
        worldAllowCommands=[bool](Get-MmtlForgeConfigValue $file 'worldAllowCommands' $false)
        memoryMb=[int](Get-MmtlForgeConfigValue $file 'memoryMb' 1024)
        reportRoot=(Expand-MmtlForgeConfigPath -Value ([string](Get-MmtlForgeConfigValue $file 'reportRoot' 'runtime/reports')) -BasePath $root)
        versionDirectory=$versionDirectory
    }
    if($resolved.worldGameMode -notin @('survival','creative','adventure','spectator')){throw 'WORLD_GAMEMODE_INVALID'}
    if($resolved.worldDifficulty -notin @('peaceful','easy','normal','hard')){throw 'WORLD_DIFFICULTY_INVALID'}
    if($resolved.memoryMb -lt 512 -or $resolved.memoryMb -gt 8192){throw 'MEMORY_OUT_OF_RANGE'}
    return $resolved
}

Export-ModuleMember -Function Resolve-MmtlForgeControlConfig
