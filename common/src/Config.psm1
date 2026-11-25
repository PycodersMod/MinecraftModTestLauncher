function Read-MmtlConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[switch]$AllowInvalidProfiles)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "配置文件不存在：$Path" }
    try { $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "配置 JSON 无效：$($_.Exception.Message)" }
    if ($null -ne $config.PSObject.Properties['configVersion'] -and [int]$config.configVersion -notin @(1, 2, 3)) {
        throw "不支持的 Config Schema 版本：$($config.configVersion)"
    }
    if (-not $config.profiles) { throw '配置必须包含 profiles。' }
    if (-not $config.javaHomes) { throw '配置必须包含 javaHomes。' }
    foreach ($javaHome in $config.javaHomes.PSObject.Properties) {
        $major = 0
        if (-not [int]::TryParse($javaHome.Name, [ref]$major) -or $major -lt 1 -or $javaHome.Value -isnot [string]) {
            throw "javaHomes 的键必须是正整数 major 且值必须为路径字符串：$($javaHome.Name)"
        }
    }
    if ($null -ne $config.PSObject.Properties['javaHomesByPlatform']) {
        foreach ($platform in $config.javaHomesByPlatform.PSObject.Properties) {
            if ($platform.Value -isnot [pscustomobject]) { throw "javaHomesByPlatform.$($platform.Name) 必须是 major 到路径的映射。" }
            foreach ($javaHome in $platform.Value.PSObject.Properties) {
                $major = 0
                if (-not [int]::TryParse($javaHome.Name, [ref]$major) -or $major -lt 1 -or $javaHome.Value -isnot [string]) {
                    throw "javaHomesByPlatform.$($platform.Name) 包含无效 Java home：$($javaHome.Name)"
                }
            }
        }
    }
    if(-not $config.defaultProfile -or -not $config.profiles.PSObject.Properties[$config.defaultProfile]){throw 'defaultProfile 必须引用 profiles 中存在的配置。'}
    foreach($profileProperty in $config.profiles.PSObject.Properties){
        $profile=$profileProperty.Value
        if($AllowInvalidProfiles){continue}
        $configVersion=if($null -ne $config.PSObject.Properties['configVersion']){[int]$config.configVersion}else{1}
        if($configVersion -eq 3){
            $null=Resolve-MmtlScenarioProfile -Config $config -ProfileName $profileProperty.Name
        }else{
            if($profile.mode -notin @('Single','IntegratedLAN','Dedicated')){throw "Profile $($profileProperty.Name) 的 mode 无效。"}
            $players=0;if(-not[int]::TryParse([string]$profile.players,[ref]$players) -or $players -lt 1 -or $players -gt 8){throw "Profile $($profileProperty.Name) 的 players 必须为 1 至 8。"}
        }
        if($null -ne $profile.PSObject.Properties['guiScale']){$guiScale=0;if([string]$profile.guiScale -ine 'Auto' -and (-not[int]::TryParse([string]$profile.guiScale,[ref]$guiScale) -or $guiScale -lt 0 -or $guiScale -gt 4)){throw "Profile $($profileProperty.Name) 的 guiScale 必须为 Auto 或 0 至 4。"}}
        if($profile.port -and [string]$profile.port -ne 'Auto'){$port=0;if(-not[int]::TryParse([string]$profile.port,[ref]$port) -or $port -lt 1 -or $port -gt 65535){throw "Profile $($profileProperty.Name) 的 port 必须是 Auto 或 1 至 65535。"}}
        if($null -ne $profile.PSObject.Properties['runtimeJavaOverride'] -and $null -ne $profile.runtimeJavaOverride){
            $runtimeMajor=0
            if(-not[int]::TryParse([string]$profile.runtimeJavaOverride.major,[ref]$runtimeMajor) -or $runtimeMajor -lt 1){throw "Profile $($profileProperty.Name) 的 runtimeJavaOverride.major 必须为正整数。"}
            if($null -ne $profile.runtimeJavaOverride.PSObject.Properties['component'] -and $profile.runtimeJavaOverride.component -isnot [string]){throw "Profile $($profileProperty.Name) 的 runtimeJavaOverride.component 必须为字符串。"}
        }
        if($null -ne $profile.PSObject.Properties['buildJavaOverride'] -and $null -ne $profile.buildJavaOverride){
            $buildMajor=0
            if(-not[int]::TryParse([string]$profile.buildJavaOverride.major,[ref]$buildMajor) -or $buildMajor -lt 1){throw "Profile $($profileProperty.Name) 的 buildJavaOverride.major 必须为正整数。"}
        }
    }
    return $config
}

function Get-MmtlProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [string]$Name)
    if (-not $Name) { $Name = [string]$Config.defaultProfile }
    if (-not $Name -or -not $Config.profiles.PSObject.Properties[$Name]) { throw "Profile 不存在：$Name" }
    return $Config.profiles.$Name
}

function Assert-MmtlProfile {
    param([Parameter(Mandatory)]$Profile)
    if (-not $Profile.project) { throw 'Profile 缺少 project。' }
    if ($Profile.mode -notin @('Single','IntegratedLAN','Dedicated')) { throw "不支持的运行模式：$($Profile.mode)" }
    if ([int]$Profile.players -lt 1) { throw 'players 必须大于 0。' }
    if($null -ne $Profile.PSObject.Properties['durationSeconds'] -and ([int]$Profile.durationSeconds -lt 1 -or [int]$Profile.durationSeconds -gt 600)){throw 'durationSeconds 必须为 1 至 600 秒。'}
    if($null -ne $Profile.PSObject.Properties['stopPolicy'] -and [string]$Profile.stopPolicy -cne 'Always'){throw '当前 Scenario 版本只支持 stopPolicy=Always。'}
    if($null -ne $Profile.PSObject.Properties['guiScale']){$guiScale=0;if([string]$Profile.guiScale -ine 'Auto' -and (-not[int]::TryParse([string]$Profile.guiScale,[ref]$guiScale) -or $guiScale -lt 0 -or $guiScale -gt 4)){throw 'guiScale 必须为 Auto 或 0 至 4。'}}
    return $true
}

function Resolve-MmtlScenarioProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config,[string]$ProfileName)

    $profile=Get-MmtlProfile -Config $Config -Name $ProfileName
    $name=if($ProfileName){$ProfileName}else{[string]$Config.defaultProfile}
    $version=if($null -ne $Config.PSObject.Properties['configVersion']){[int]$Config.configVersion}else{1}

    $identity=[ordered]@{kind='Offline';hostName='MMTL_Host';guestNamePattern='MMTL_G{index}'}
    $world=[ordered]@{name='';policy='CreateOrLoadManagedWorld'}
    $limits=[ordered]@{durationSeconds=60;memoryMb=$null;hostMemoryMb=$null;clientMemoryMb=$null}
    $clientCount=1
    $transport='None'
    $mode='Single'

    if($version -lt 3){
        if($profile.mode -notin @('Single','IntegratedLAN','Dedicated')){throw "Profile $name 的 mode 无效。"}
        $players=0
        if(-not[int]::TryParse([string]$profile.players,[ref]$players) -or $players -lt 1 -or $players -gt 8){throw "Profile $name 的 players 必须为 1 至 8。"}
        $mode=[string]$profile.mode
        $clientCount=$players
        if($mode -eq 'Single' -and $players -ne 1){throw 'CONFIG_SCENARIO_CLIENT_COUNT_CONFLICT: Legacy Single 必须恰好配置一个玩家。'}
        if($mode -eq 'IntegratedLAN' -and $players -lt 2){throw 'CONFIG_SCENARIO_CLIENT_COUNT_CONFLICT: Legacy IntegratedLAN 至少需要 Host 和一个 Guest。'}
        $transport=switch($mode){'Single'{'None'}'IntegratedLAN'{'IntegratedLAN'}'Dedicated'{'Dedicated'}}
        $identity.hostName=if($profile.hostUsername){[string]$profile.hostUsername}else{$identity.hostName}
        $identity.guestNamePattern=if($profile.clientPrefix){([string]$profile.clientPrefix)+'{index}'}else{$identity.guestNamePattern}
    }else{
        if($null -ne $profile.PSObject.Properties['clientCount']){
            if($profile.clientCount -is [bool] -or -not[int]::TryParse([string]$profile.clientCount,[ref]$clientCount) -or $clientCount -lt 1){throw "CONFIG_CLIENT_COUNT_INVALID: Profile $name 的 clientCount 必须为正整数。"}
        }
        if($null -ne $profile.PSObject.Properties['identity']){
            if($profile.identity.kind -and [string]$profile.identity.kind -cne 'Offline'){throw "CONFIG_IDENTITY_KIND_UNSUPPORTED: $($profile.identity.kind)"}
            if($profile.identity.hostName){$identity.hostName=[string]$profile.identity.hostName}
            if($profile.identity.guestNamePattern){$identity.guestNamePattern=[string]$profile.identity.guestNamePattern}
        }
        $pattern=[string]$identity.guestNamePattern
        if(([regex]::Matches($pattern,'\{index\}')).Count -ne 1 -or $pattern -replace '\{index\}','' -match '[{}]'){
            throw "CONFIG_GUEST_NAME_PATTERN_INVALID: $pattern"
        }
        $transportInput='Auto'
        if($null -ne $profile.PSObject.Properties['multiplayer'] -and $profile.multiplayer.transport){$transportInput=[string]$profile.multiplayer.transport}
        $allowed=@('Auto','None','IntegratedLAN','Dedicated','HistoricalDedicatedEquivalent')
        if($transportInput -cnotin $allowed){throw "CONFIG_TRANSPORT_INVALID: $transportInput"}
        $transport=if($transportInput -eq 'Auto'){if($clientCount -eq 1){'None'}else{'IntegratedLAN'}}else{$transportInput}
        if($transport -eq 'None' -and $clientCount -ne 1){throw 'CONFIG_SCENARIO_CLIENT_COUNT_CONFLICT: transport=None requires clientCount=1.'}
        if($transport -eq 'IntegratedLAN' -and $clientCount -lt 2){throw 'CONFIG_SCENARIO_CLIENT_COUNT_CONFLICT: IntegratedLAN requires clientCount>=2.'}
        $mode=switch($transport){'None'{'Single'}'IntegratedLAN'{'IntegratedLAN'}'Dedicated'{'Dedicated'}'HistoricalDedicatedEquivalent'{'HistoricalDedicatedEquivalent'}}
        if($profile.mode -and [string]$profile.mode -cne $mode){throw "CONFIG_SCENARIO_MODE_CONFLICT: mode=$($profile.mode), normalizedMode=$mode."}
        if($null -ne $profile.PSObject.Properties['worldName']){$world.name=[string]$profile.worldName}
        if($null -ne $profile.PSObject.Properties['multiplayer'] -and $profile.multiplayer.PSObject.Properties['worldPolicy']){$world.policy=[string]$profile.multiplayer.worldPolicy}
    }

    foreach($key in @('durationSeconds','memoryMb','hostMemoryMb','clientMemoryMb')){
        if($null -ne $profile.PSObject.Properties[$key]){$limits[$key]=$profile.$key}
    }
    return [pscustomobject][ordered]@{
        schemaVersion=1;sourceConfigVersion=$version;sourceProfileName=$name;project=[string]$profile.project
        mode=$mode;clientCount=$clientCount;transport=$transport
        identity=[pscustomobject]$identity;world=[pscustomobject]$world;limits=[pscustomobject]$limits
        provenance=[pscustomobject][ordered]@{sourceConfigVersion=$version;profileName=$name;modeSource=$(if($version -lt 3){'LegacyProfile'}else{'NormalizedTransport'});clientCountSource=$(if($version -lt 3){'LegacyPlayers'}elseif($null -ne $profile.PSObject.Properties['clientCount']){'Profile'}else{'BuiltInDefault'})}
        sourceProfile=$profile
    }
}

function ConvertFrom-MmtlScenarioCliOverrides {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Arguments=@())

    $values=[ordered]@{}
    $sources=[ordered]@{}
    $optionMap=@{
        '--client-count'='clientCount';'--multiplayer'='transport';'--host-name'='hostName'
        '--guest-name-pattern'='guestNamePattern';'--world'='world'
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for($index=0;$index -lt $Arguments.Count;$index++){
        $argument=[string]$Arguments[$index]
        if(-not $optionMap.ContainsKey($argument)){throw "CLI_ARGUMENT_UNKNOWN: $argument"}
        if(-not $seen.Add($argument)){throw "CLI_ARGUMENT_DUPLICATE: $argument"}
        if($index+1 -ge $Arguments.Count -or [string]$Arguments[$index+1] -match '^--') {throw "CLI_ARGUMENT_VALUE_REQUIRED: $argument"}
        $raw=[string]$Arguments[++$index]
        $field=$optionMap[$argument]
        switch($field){
            'clientCount' {
                $count=0
                if(-not[int]::TryParse($raw,[ref]$count) -or $count -lt 1){throw "CONFIG_CLIENT_COUNT_INVALID: $raw"}
                $values[$field]=$count
            }
            'transport' {
                $transportMap=@{'auto'='Auto';'none'='None';'integrated-lan'='IntegratedLAN';'dedicated'='Dedicated';'historical-dedicated-equivalent'='HistoricalDedicatedEquivalent'}
                $key=$raw.ToLowerInvariant()
                if(-not $transportMap.ContainsKey($key)){throw "CONFIG_TRANSPORT_INVALID: $raw"}
                $values[$field]=$transportMap[$key]
            }
            'hostName' {
                if($raw -notmatch '^[A-Za-z0-9_]{1,16}$'){throw 'CONFIG_OFFLINE_HOST_NAME_INVALID'}
                $values[$field]=$raw
            }
            'guestNamePattern' {
                if($raw -notmatch '^[A-Za-z0-9_]*\{index\}[A-Za-z0-9_]*$'){throw 'CONFIG_GUEST_NAME_PATTERN_INVALID'}
                $values[$field]=$raw
            }
            'world' {
                if($raw -notmatch '^[A-Za-z0-9 _.-]{1,64}$' -or $raw -in @('.','..')){throw 'CONFIG_WORLD_NAME_INVALID'}
                $values[$field]=$raw
            }
        }
        $sources[$field]='CommandLine'
    }
    [pscustomobject][ordered]@{values=[pscustomobject]$values;sources=[pscustomobject]$sources;arguments=@($Arguments)}
}

function Merge-MmtlScenarioConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)]$Overrides,
        [string]$ProfileName='default',
        [ValidateRange(1,3)][int]$SourceConfigVersion=3
    )

    $overrideValues=if($Overrides.PSObject.Properties['values']){$Overrides.values}else{$Overrides}
    $overrideSources=if($Overrides.PSObject.Properties['sources']){$Overrides.sources}else{$null}
    $profileCopy=$Profile|ConvertTo-Json -Depth 50 -Compress|ConvertFrom-Json -ErrorAction Stop
    $sourceConfig=[pscustomobject]@{configVersion=$SourceConfigVersion;defaultProfile=$ProfileName;javaHomes=[pscustomobject]@{};profiles=[pscustomobject]@{$ProfileName=$profileCopy}}
    $base=Resolve-MmtlScenarioProfile -Config $sourceConfig -ProfileName $ProfileName
    $hasClientOverride=$null -ne $overrideValues.PSObject.Properties['clientCount']
    $hasTransportOverride=$null -ne $overrideValues.PSObject.Properties['transport']
    $profileTransport=$null
    if($SourceConfigVersion -lt 3){$profileTransport=$base.transport}
    elseif($Profile.PSObject.Properties['multiplayer'] -and $Profile.multiplayer.transport){$profileTransport=[string]$Profile.multiplayer.transport}
    else{$profileTransport='Auto'}
    if($hasClientOverride -and -not $hasTransportOverride){$profileTransport='Auto'}

    $normalizedProfile=$Profile|ConvertTo-Json -Depth 50 -Compress|ConvertFrom-Json -ErrorAction Stop
    $count=if($hasClientOverride){[int]$overrideValues.clientCount}else{[int]$base.clientCount}
    $transport=if($hasTransportOverride){[string]$overrideValues.transport}else{$profileTransport}
    $hostName=if($null -ne $overrideValues.PSObject.Properties['hostName']){[string]$overrideValues.hostName}else{[string]$base.identity.hostName}
    $guestPattern=if($null -ne $overrideValues.PSObject.Properties['guestNamePattern']){[string]$overrideValues.guestNamePattern}else{[string]$base.identity.guestNamePattern}
    if($null -ne $overrideValues.PSObject.Properties['world']){$normalizedProfile|Add-Member -NotePropertyName worldName -NotePropertyValue ([string]$overrideValues.world) -Force}
    $normalizedProfile|Add-Member -NotePropertyName clientCount -NotePropertyValue $count -Force
    $normalizedProfile|Add-Member -NotePropertyName identity -NotePropertyValue ([pscustomobject]@{kind='Offline';hostName=$hostName;guestNamePattern=$guestPattern}) -Force
    $normalizedProfile|Add-Member -NotePropertyName multiplayer -NotePropertyValue ([pscustomobject]@{transport=$transport}) -Force
    $resolvedMode=switch($transport){'Auto'{if($count -eq 1){'Single'}else{'IntegratedLAN'}}'None'{'Single'}'IntegratedLAN'{'IntegratedLAN'}'Dedicated'{'Dedicated'}'HistoricalDedicatedEquivalent'{'HistoricalDedicatedEquivalent'}}
    $normalizedProfile|Add-Member -NotePropertyName mode -NotePropertyValue $resolvedMode -Force
    $normalizedProfile|Add-Member -NotePropertyName players -NotePropertyValue $count -Force
    $normalizedProfile|Add-Member -NotePropertyName hostUsername -NotePropertyValue $hostName -Force
    $normalizedProfile|Add-Member -NotePropertyName clientPrefix -NotePropertyValue ($guestPattern -replace '\{index\}','') -Force

    $mergedConfig=[pscustomobject]@{configVersion=3;defaultProfile=$ProfileName;javaHomes=[pscustomobject]@{};profiles=[pscustomobject]@{$ProfileName=$normalizedProfile}}
    $effective=Resolve-MmtlScenarioProfile -Config $mergedConfig -ProfileName $ProfileName
    $normalizedProfile.multiplayer.transport=[string]$effective.transport
    $countSource=if($hasClientOverride){'CommandLine'}elseif($SourceConfigVersion -lt 3 -or $Profile.PSObject.Properties['clientCount']){'Profile'}else{'BuiltInDefault'}
    $transportSource=if($hasTransportOverride){'CommandLine'}elseif($SourceConfigVersion -lt 3 -or ($Profile.PSObject.Properties['multiplayer'] -and $Profile.multiplayer.transport)){'Profile'}else{'BuiltInDefault'}
    $hostSource='BuiltInDefault';if($null -ne $overrideValues.PSObject.Properties['hostName']){$hostSource='CommandLine'}elseif(($Profile.PSObject.Properties['identity'] -and $Profile.identity.hostName) -or ($SourceConfigVersion -lt 3 -and $Profile.hostUsername)){$hostSource='Profile'}
    $guestSource='BuiltInDefault';if($null -ne $overrideValues.PSObject.Properties['guestNamePattern']){$guestSource='CommandLine'}elseif(($Profile.PSObject.Properties['identity'] -and $Profile.identity.guestNamePattern) -or ($SourceConfigVersion -lt 3 -and $Profile.clientPrefix)){$guestSource='Profile'}
    $worldSource='BuiltInDefault';if($null -ne $overrideValues.PSObject.Properties['world']){$worldSource='CommandLine'}elseif($Profile.worldName){$worldSource='Profile'}
    $valueSources=[ordered]@{
        clientCount=$countSource;transport=$transportSource;hostName=$hostSource;guestNamePattern=$guestSource;world=$worldSource
    }
    $profileSnapshot=[ordered]@{
        mode=$(if($Profile.PSObject.Properties['mode']){[string]$Profile.mode}else{$null})
        players=$(if($Profile.PSObject.Properties['players']){[int]$Profile.players}else{$null})
        clientCount=$(if($Profile.PSObject.Properties['clientCount']){[int]$Profile.clientCount}else{$null})
        transport=$(if($Profile.PSObject.Properties['multiplayer']){[string]$Profile.multiplayer.transport}else{$null})
        identity=$(if($Profile.PSObject.Properties['identity']){$Profile.identity}else{$null})
        worldName=$(if($Profile.PSObject.Properties['worldName']){[string]$Profile.worldName}else{$null})
    }
    $snapshotJson=ConvertTo-Json -InputObject $profileSnapshot -Depth 30 -Compress
    $snapshotHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($snapshotJson))).ToLowerInvariant()
    $scenarioMetadata=[pscustomobject][ordered]@{
        schemaVersion=1;sourceConfigVersion=$SourceConfigVersion;sourceProfileName=$ProfileName
        configDigest=('sha256:'+$snapshotHash);profileSnapshot=[pscustomobject]$profileSnapshot
        cliOverrides=$overrideValues;valueSources=[pscustomobject]$valueSources
        effective=[pscustomobject]@{mode=$effective.mode;clientCount=$effective.clientCount;transport=$effective.transport;identity=$effective.identity;world=$effective.world}
    }
    $normalizedProfile|Add-Member -NotePropertyName scenarioConfiguration -NotePropertyValue $scenarioMetadata -Force
    $effective.sourceProfile=$Profile
    $effective|Add-Member -NotePropertyName executionProfile -NotePropertyValue $normalizedProfile -Force
    $effective.provenance | Add-Member -NotePropertyName valueSources -NotePropertyValue ([pscustomobject]$valueSources) -Force
    $effective.provenance | Add-Member -NotePropertyName cliOverrides -NotePropertyValue $overrideValues -Force
    $effective|Add-Member -NotePropertyName scenarioConfiguration -NotePropertyValue $scenarioMetadata -Force
    return $effective
}

Export-ModuleMember -Function Read-MmtlConfig,Get-MmtlProfile,Assert-MmtlProfile,Resolve-MmtlScenarioProfile,ConvertFrom-MmtlScenarioCliOverrides,Merge-MmtlScenarioConfiguration
