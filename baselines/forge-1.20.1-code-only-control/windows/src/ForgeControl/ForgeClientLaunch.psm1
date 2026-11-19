Set-StrictMode -Version Latest
$script:ForgeControlCommonRoot=Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'common'
Import-Module (Join-Path $script:ForgeControlCommonRoot 'src/Agent/AgentProvider.psm1') -Force
Import-Module (Join-Path $script:ForgeControlCommonRoot 'src/TestIdentity.psm1') -Force

function Get-MmtlForgeProperty {
    param($Object,[string]$Name,$Default)
    if($null -eq $Object){return $Default}
    $property=$Object.PSObject.Properties[$Name]
    if($null -ne $property){return $property.Value}
    return $Default
}

function Test-MmtlForgeArgumentRule {
    param($Rules,[hashtable]$Features,[string]$OsName='windows',[string]$Arch='x86_64')
    if(-not $Rules){return $true}
    $allowed=$false
    foreach($rule in $Rules){
        $match=$true
        $os=Get-MmtlForgeProperty $rule 'os' $null
        $ruleOsName=Get-MmtlForgeProperty $os 'name' '';$ruleArch=Get-MmtlForgeProperty $os 'arch' ''
        if($ruleOsName -and [string]$ruleOsName -cne $OsName){$match=$false}
        if($ruleArch -and [string]$ruleArch -notin @($Arch,'amd64')){$match=$false}
        $ruleFeatures=Get-MmtlForgeProperty $rule 'features' $null
        if($ruleFeatures){foreach($feature in $ruleFeatures.PSObject.Properties){$actual=$Features[$feature.Name];if($null -eq $actual -or [bool]$actual -ne [bool]$feature.Value){$match=$false}}}
        if($match){$allowed=([string]$rule.action -ceq 'allow')}
    }
    return $allowed
}

function Expand-MmtlForgeArguments {
    param([object[]]$Entries,[hashtable]$Values,[hashtable]$Features,[switch]$GameArguments)
    $result=[Collections.Generic.List[string]]::new()
    foreach($entry in $Entries){
        $items=@();$enabled=$true
        if($entry -is [string]){$items=@([string]$entry)}else{
            $enabled=Test-MmtlForgeArgumentRule -Rules (Get-MmtlForgeProperty $entry 'rules' $null) -Features $Features
            $entryValue=Get-MmtlForgeProperty $entry 'value' ''
            if($enabled){if($entryValue -is [array]){$items=@($entryValue)}else{$items=@([string]$entryValue)}}
        }
        if(-not $enabled){continue}
        foreach($item in $items){
            $argument=[string]$item
            foreach($key in $Values.Keys){$argument=$argument.Replace('${'+$key+'}',[string]$Values[$key])}
            if($argument -match '\$\{[^}]+\}'){throw "FORGE_ARGUMENT_PLACEHOLDER_UNRESOLVED: $argument"}
            $result.Add($argument)
        }
    }
    return ,@($result.ToArray())
}

function Expand-MmtlForgeNativeArchive {
    param([Parameter(Mandatory)][string]$ArchivePath,[Parameter(Mandatory)][string]$Destination)
    $root=[IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $comparison=if([IO.Path]::DirectorySeparatorChar -eq '\'){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    $archive=[IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try{
        foreach($entry in $archive.Entries){
            if([string]::IsNullOrEmpty($entry.Name)){continue}
            if($entry.FullName -match '(^|/)META-INF/'){continue}
            $target=[IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if(-not $target.StartsWith($root,$comparison)){throw 'FORGE_NATIVE_PATH_ESCAPE'}
            $parent=Split-Path -Parent $target;New-Item -ItemType Directory -Path $parent -Force|Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
        }
    }finally{$archive.Dispose()}
}

function New-MmtlForgeClientLaunchPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][ValidateSet('Client','Host','Guest')][string]$Role,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_]{1,16}$')][string]$PlayerName,
        [Parameter(Mandatory)][string]$ProviderRoot,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{32,128}$')][string]$SessionToken,
        [ValidateRange(0,65535)][int]$IntegratedLanPort=0,
        [ValidateRange(0,65535)][int]$ExpectedLoopbackPort=0,
        [ValidateSet('QuickPlay','AgentAfterMainMenu')][string]$GuestConnectionMode=[string](Get-MmtlForgeProperty $Config 'guestConnectionMode' 'AgentAfterMainMenu')
    )
    $session=[IO.Path]::GetFullPath($SessionPath)
    if(-not(Test-Path -LiteralPath (Join-Path $session 'session.json') -PathType Leaf)){throw 'FORGE_SESSION_METADATA_MISSING'}
    $sessionRecord=Get-Content -LiteralPath (Join-Path $session 'session.json') -Raw|ConvertFrom-Json -ErrorAction Stop
    $sessionId=[string]$sessionRecord.sessionId
    if(-not $sessionId -or $sessionId -cne (Split-Path -Leaf $session)){throw 'FORGE_SESSION_ID_MISMATCH'}
    $identity=@($sessionRecord.testIdentities|Where-Object{[string]$_.role -ceq $Role -and [string]$_.username -ceq $PlayerName}|Select-Object -First 1)
    if(-not $identity.Count){throw 'FORGE_SESSION_IDENTITY_NOT_REGISTERED'}
    if($Role -eq 'Host' -and $IntegratedLanPort -lt 1){throw 'FORGE_HOST_LAN_PORT_REQUIRED'}
    if($Role -ne 'Host' -and $IntegratedLanPort -gt 0){throw 'FORGE_LAN_PORT_HOST_ONLY'}
    if($Role -eq 'Guest' -and $ExpectedLoopbackPort -lt 1){throw 'FORGE_GUEST_LOOPBACK_PORT_REQUIRED'}
    if($Role -ne 'Guest' -and $ExpectedLoopbackPort -gt 0){throw 'FORGE_GUEST_LOOPBACK_PORT_ONLY'}
    $minecraftRoot=[IO.Path]::GetFullPath([string]$Config.minecraftRoot)
    $versionId=[string]$Config.versionDirectory
    $versionRoot=Join-Path (Join-Path $minecraftRoot 'versions') $versionId
    $versionJsonPath=Join-Path $versionRoot ($versionId+'.json')
    if(-not(Test-Path -LiteralPath $versionJsonPath -PathType Leaf)){throw "FORGE_VERSION_MANIFEST_MISSING: $versionJsonPath"}
    try{$version=Get-Content -LiteralPath $versionJsonPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{throw 'FORGE_VERSION_MANIFEST_INVALID'}
    if([string]$version.id -cne $versionId -or [string]$version.mainClass -eq '' -or $version.arguments -eq $null){throw 'FORGE_VERSION_MANIFEST_INVALID'}
    $forgeVersion=$null
    for($i=0;$i -lt $version.arguments.game.Count;$i++){if([string]$version.arguments.game[$i] -ceq '--fml.forgeVersion' -and $i+1 -lt $version.arguments.game.Count){$forgeVersion=[string]$version.arguments.game[$i+1];break}}
    if($forgeVersion -cne '47.4.23'){throw "TARGET_UNSUPPORTED: expected Forge 47.4.23, found $forgeVersion"}
    $libraryRoot=Join-Path $minecraftRoot 'libraries';$assetRoot=Join-Path $minecraftRoot 'assets'
    if(-not(Test-Path -LiteralPath $libraryRoot -PathType Container) -or -not(Test-Path -LiteralPath $assetRoot -PathType Container)){throw 'FORGE_GAME_DATA_MISSING'}
    $gameDirectory=[IO.Path]::GetFullPath([string]$identity[0].gameDir)
    if(-not(Test-MmtlAgentPathInsideRoot -Root $session -Target $gameDirectory)){throw 'FORGE_INSTANCE_PATH_OUTSIDE_SESSION'}
    if(-not(Test-Path -LiteralPath $gameDirectory -PathType Container)){New-Item -ItemType Directory -Path $gameDirectory -Force|Out-Null}
    $modsDirectory=Join-Path $gameDirectory 'mods'
    if((Test-Path -LiteralPath $modsDirectory -PathType Container) -and @(Get-ChildItem -LiteralPath $modsDirectory -File -Force).Count){throw 'FORGE_INSTANCE_HAS_UNEXPECTED_MODS'}
    $provider=Get-MmtlAgentProviderStatus -AgentRoot $ProviderRoot -LoaderId Forge -MinecraftVersion '1.20.1'
    if($provider.status -cne 'Supported'){throw "FORGE_AGENT_PROVIDER_UNAVAILABLE: $($provider.reason)"}
    $autoCreateWorld=$Role -in @('Host','Client')
    $binding=New-MmtlAgentLaunchBinding -Provider $provider -SessionPath $session -SessionId $sessionId -Role $Role -SessionToken $SessionToken -IntegratedLanPort $IntegratedLanPort -ExpectedLoopbackPort $ExpectedLoopbackPort -GuestConnectionMode $GuestConnectionMode -GuestHandshakeDiagnostics:($Role -ceq 'Guest' -and [bool](Get-MmtlForgeProperty $Config 'guestHandshakeDiagnostics' $false)) -InstanceId ([string]$identity[0].instanceId) -AutoCreateWorld:$autoCreateWorld -WorldName ([string]$Config.worldName) -WorldGameMode ([string]$Config.worldGameMode) -WorldDifficulty ([string]$Config.worldDifficulty) -WorldSeed ([string]$Config.worldSeed) -WorldAllowCommands:([bool]$Config.worldAllowCommands)
    $instanceArtifact=Copy-MmtlArtifactToTestIdentity -SourcePath $binding.artifactPath -Identity $identity[0]
    if([string]$instanceArtifact.sourceName -notlike 'mmtl-agent*.jar'){throw 'FORGE_AGENT_INSTANCE_COPY_INVALID'}
    $instanceArtifactPath=[string]$instanceArtifact.destination
    $clientJar=Join-Path $versionRoot ($versionId+'.jar')
    if(-not(Test-Path -LiteralPath $clientJar -PathType Leaf)){throw 'FORGE_CLIENT_JAR_MISSING'}
    $nativesDirectory=Join-Path $session ('natives/'+$PlayerName)
    New-Item -ItemType Directory -Path $nativesDirectory -Force|Out-Null
    $classPath=[Collections.Generic.List[string]]::new()
    foreach($library in @($version.libraries)){
        if(-not(Test-MmtlForgeArgumentRule -Rules (Get-MmtlForgeProperty $library 'rules' $null) -Features @{})){continue}
        $downloads=Get-MmtlForgeProperty $library 'downloads' $null;$artifact=Get-MmtlForgeProperty $downloads 'artifact' $null
        $artifactPath=[string](Get-MmtlForgeProperty $artifact 'path' '')
        if(-not $artifactPath){continue}
        $fullLibrary=Join-Path $libraryRoot ($artifactPath.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if(-not(Test-Path -LiteralPath $fullLibrary -PathType Leaf)){throw "FORGE_LIBRARY_MISSING: $fullLibrary"}
        $libraryName=[string](Get-MmtlForgeProperty $library 'name' '')
        if($libraryName -match ':natives-windows(?:-x86_64)?$'){
            Expand-MmtlForgeNativeArchive -ArchivePath $fullLibrary -Destination $nativesDirectory
            continue
        }
        $classPath.Add($fullLibrary)
    }
    $classPath.Add($clientJar)
    $classpathText=($classPath -join [IO.Path]::PathSeparator)
    $uuid=Get-MmtlOfflinePlayerUuid -Username $PlayerName
    $values=@{natives_directory=$nativesDirectory;launcher_name='MMTL';launcher_version='1';classpath=$classpathText;classpath_separator=[IO.Path]::PathSeparator;library_directory=$libraryRoot;version_name=$versionId;auth_player_name=$PlayerName;game_directory=$gameDirectory;assets_root=$assetRoot;assets_index_name=[string]$version.assetIndex.id;auth_uuid=$uuid;auth_access_token='0';clientid='';auth_xuid='';user_type='legacy';version_type='release';resolution_width='1280';resolution_height='720'}
    $features=@{has_custom_resolution=$true;is_demo_user=$false}
    $jvmArgs=[Collections.Generic.List[string]]::new();$jvmArgs.Add("-Xms512M");$jvmArgs.Add("-Xmx$([int]$Config.memoryMb)M")
    foreach($argument in (Expand-MmtlForgeArguments -Entries @($version.arguments.jvm) -Values $values -Features $features)){$jvmArgs.Add($argument)}
    foreach($argument in $binding.jvmArgs){$jvmArgs.Add([string]$argument)}
    $gameArgs=[Collections.Generic.List[string]]::new()
    foreach($argument in (Expand-MmtlForgeArguments -Entries @($version.arguments.game) -Values $values -Features $features -GameArguments)){$gameArgs.Add($argument)}
    if($Role -eq 'Guest' -and $GuestConnectionMode -ceq 'QuickPlay'){$gameArgs.Add('--quickPlayMultiplayer');$gameArgs.Add("127.0.0.1:$ExpectedLoopbackPort")}
    $arguments=[Collections.Generic.List[string]]::new();foreach($argument in $jvmArgs){$arguments.Add($argument)};$arguments.Add([string]$version.mainClass);foreach($argument in $gameArgs){$arguments.Add($argument)}
    return [pscustomobject][ordered]@{role=$Role;playerName=$PlayerName;instanceId=[string]$identity[0].instanceId;javaPath=[IO.Path]::GetFullPath([string]$Config.javaPath);workingDirectory=$gameDirectory;gameDirectory=$gameDirectory;versionDirectory=$versionRoot;versionId=$versionId;forgeVersion=$forgeVersion;mainClass=[string]$version.mainClass;arguments=@($arguments.ToArray());agentArtifact=$binding.artifactPath;agentSha256=$binding.artifactSha256;mods=@($instanceArtifactPath);offlineUuid=$uuid;eventSink=$binding.eventSink;integratedLanPort=$IntegratedLanPort;expectedLoopbackPort=$ExpectedLoopbackPort;guestConnectionMode=$GuestConnectionMode;nativesDirectory=$nativesDirectory;classpath=@($classPath.ToArray())}
}

Export-ModuleMember -Function New-MmtlForgeClientLaunchPlan
