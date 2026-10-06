Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ProjectImport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RuntimeManager.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force

function Write-MmtlFirstRunFileIfMissing {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Content)
    $full=[IO.Path]::GetFullPath($Path)
    $directory=Split-Path -Parent $full
    if(-not(Test-Path -LiteralPath $directory -PathType Container)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
    Assert-MmtlNoReparsePath -Path $directory|Out-Null
    Assert-MmtlNoReparsePath -Path $full|Out-Null
    $stream=$null
    try{
        $stream=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        return $true
    }catch [IO.IOException]{
        if(Test-Path -LiteralPath $full){Assert-MmtlNoReparsePath -Path $full|Out-Null;return $false}
        throw
    }finally{if($stream){$stream.Dispose()}}
}

function Get-MmtlFirstRunExampleConfig {
    $profileDefaults=[ordered]@{
        project='';linkedProjects=@();players=1;hostUsername='MMTL_Host';clientPrefix='MMTL_G';hostCheats=$false
        clientPermissionLevel=0;gameMode='creative';difficulty='peaceful';worldName='MMTL-Test';seed='';newWorld=$true
        resetWorld=$false;port='Auto';autoBuild=$true;cleanBuild=$false;acceptEula=$false;extraMods=@();memoryMb=4096
        hostMemoryMb=4096;clientMemoryMb=4096;serverMemoryMb=4096;resolution='1280x720';guiScale='Auto';windowLayout='None'
        jvmArgs=@();gameArgs=@();runtimeJavaOverride=$null;durationSeconds=60;stopPolicy='Always'
    }
    $single=[ordered]@{};foreach($key in $profileDefaults.Keys){$single[$key]=$profileDefaults[$key]};$single.mode='Single';$single.players=1
    $lan=[ordered]@{};foreach($key in $profileDefaults.Keys){$lan[$key]=$profileDefaults[$key]};$lan.mode='IntegratedLAN';$lan.players=2
    $dedicated=[ordered]@{};foreach($key in $profileDefaults.Keys){$dedicated[$key]=$profileDefaults[$key]};$dedicated.mode='Dedicated';$dedicated.players=2;$dedicated.acceptEula=$false
    return [ordered]@{
        configVersion=2
        defaultProfile='integrated-lan-example'
        runtimeRoot=''
        javaHomes=[ordered]@{}
        javaHomesByPlatform=[ordered]@{Windows=[ordered]@{};Linux=[ordered]@{};MacOS=[ordered]@{}}
        profiles=[ordered]@{'single-example'=$single;'integrated-lan-example'=$lan;'dedicated-example'=$dedicated}
    }
}

function Initialize-MmtlFirstRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$RuntimeRoot)
    $configFull=[IO.Path]::GetFullPath($ConfigPath)
    $runtimeFull=[IO.Path]::GetFullPath($RuntimeRoot)
    foreach($path in @((Split-Path -Parent $configFull),$runtimeFull)){
        Assert-MmtlNoReparsePath -Path $path|Out-Null
        if(-not(Test-Path -LiteralPath $path -PathType Container)){New-Item -ItemType Directory -Path $path -Force|Out-Null}
        Assert-MmtlNoReparsePath -Path $path|Out-Null
    }
    $registryPath=Join-Path $runtimeFull 'project-registry.json'
    Assert-MmtlNoReparsePath -Path $registryPath|Out-Null
    $null=Get-MmtlProjectRegistry -RuntimeRoot $runtimeFull
    $registryCreated=$false
    if(-not(Test-Path -LiteralPath $registryPath -PathType Leaf)){
        $registryCreated=Write-MmtlFirstRunFileIfMissing -Path $registryPath -Content "{`"schemaVersion`":1,`"projects`":[]}`n"
    }
    $configCreated=$false
    Assert-MmtlNoReparsePath -Path $configFull|Out-Null
    if(-not(Test-Path -LiteralPath $configFull -PathType Leaf)){
        $config=Get-MmtlFirstRunExampleConfig
        $configCreated=Write-MmtlFirstRunFileIfMissing -Path $configFull -Content (($config|ConvertTo-Json -Depth 30)+"`n")
    }
    if(-not(Test-Path -LiteralPath $configFull -PathType Leaf)){throw 'FIRST_RUN_CONFIG_CREATE_FAILED'}
    $null=Read-MmtlConfig -Path $configFull
    $sessionsPath=Join-Path $runtimeFull 'sessions'
    if(-not(Test-Path -LiteralPath $sessionsPath -PathType Container)){New-Item -ItemType Directory -Path $sessionsPath -Force|Out-Null}
    Assert-MmtlNoReparsePath -Path $sessionsPath|Out-Null
    return [pscustomobject][ordered]@{
        status=if($configCreated -or $registryCreated){'Initialized'}else{'AlreadyInitialized'}
        configPath=$configFull;runtimeRoot=$runtimeFull;registryPath=$registryPath;sessionsPath=$sessionsPath
        configCreated=$configCreated;registryCreated=$registryCreated
        profileNames=@('single-example','integrated-lan-example','dedicated-example')
    }
}

Export-ModuleMember -Function Get-MmtlFirstRunExampleConfig,Initialize-MmtlFirstRun
