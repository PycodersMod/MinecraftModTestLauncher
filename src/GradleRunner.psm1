function Get-MmtlGradleCommand {
    param([Parameter(Mandatory)]$Project,[ValidateSet('build','runClient','runServer')][string]$Task='build',[switch]$Clean)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    $provider=Get-MmtlPlatformProvider
    $wrapper=Join-Path $Project.Root $provider.GradleWrapper
    if (-not (Test-Path $wrapper)) { throw '项目缺少 Gradle Wrapper。' }
    $tasks=if($Clean -and $Task -eq 'build'){@('clean','build')}else{@($Task)}
    $file=$wrapper;$arguments=@('--no-daemon')+$tasks;$invocation='direct'
    if($provider.OS -ne 'Windows'){
        $mode=(Get-Item -LiteralPath $wrapper).UnixFileMode
        if(($mode -band [IO.UnixFileMode]::UserExecute) -eq 0 -and ($mode -band [IO.UnixFileMode]::GroupExecute) -eq 0 -and ($mode -band [IO.UnixFileMode]::OtherExecute) -eq 0){$file='sh';$arguments=@($wrapper)+$arguments;$invocation='sh'}
        else{$file='./'+$provider.GradleWrapper;$invocation='direct'}
    }
    return [pscustomobject]@{ File=$file; Arguments=$arguments; WorkingDirectory=$Project.Root; WrapperPath=$wrapper; Invocation=$invocation }
}
function ConvertTo-MmtlArgumentPayload {
    param([string[]]$Values=@())
    return (@($Values|ForEach-Object{if([string]::IsNullOrEmpty([string]$_)){'_'}else{[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$_))}})-join '.')
}
function New-MmtlGradleRunPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)][ValidateSet('Single','IntegratedLAN','Dedicated')][string]$Mode,[Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][ValidateSet('Host','Client','Server')][string]$Role,[string]$Username,[int]$Port=0,[Parameter(Mandatory)]$Profile)
    if($Role -ne 'Server' -and $Username -notmatch '^[A-Za-z0-9_]{1,16}$'){throw '测试玩家名必须为 1 到 16 位 ASCII 字母、数字或下划线。'}
    if($Role -eq 'Server' -and $Mode -ne 'Dedicated'){throw '只有 Dedicated 模式支持 Server 角色。'}
    if($Role -eq 'Host' -and $Mode -ne 'IntegratedLAN'){throw 'Host 角色只能用于 IntegratedLAN 模式。'}
    $networkClient=($Mode -eq 'Dedicated' -and $Role -eq 'Client') -or ($Mode -eq 'IntegratedLAN' -and $Role -eq 'Client')
    if($networkClient -and $Port -notin 1..65535){throw '联机客户端必须提供有效服务端口。'}
    $safeName=if($Role -eq 'Server'){'Server'}else{$Username}
    $runtimeDirectory=[IO.Path]::GetFullPath((Join-Path $RuntimeRoot $safeName))
    $gameArgs=@($Profile.gameArgs|Where-Object{$null -ne $_}|ForEach-Object{[string]$_})
    if($Role -ne 'Server' -and [string]$Profile.resolution -match '^(\d{3,5})x(\d{3,5})$'){$gameArgs+=@('--width',$Matches[1],'--height',$Matches[2])}
    if($networkClient){
        if([version]$Project.MinecraftVersion -ge [version]'1.20.0'){$gameArgs+=@('--quickPlayMultiplayer',('127.0.0.1:{0}' -f $Port))}
        else{$gameArgs+=@('--server','127.0.0.1','--port',[string]$Port)}
    }
    $jvmArgs=@($Profile.jvmArgs|Where-Object{$null -ne $_}|ForEach-Object{[string]$_})
    $memoryProperty=if($Role -eq 'Server'){'serverMemoryMb'}elseif($Mode -eq 'Single' -or $Role -eq 'Host'){'hostMemoryMb'}else{'clientMemoryMb'}
    $instanceMemory=if($Profile.$memoryProperty){[int]$Profile.$memoryProperty}elseif($Profile.memoryMb){[int]$Profile.memoryMb}else{0}
    if($instanceMemory -gt 0){$jvmArgs+=('-Xmx{0}M' -f $instanceMemory)}
    $task=if($Role -eq 'Server'){'runServer'}else{'runClient'}
    $arguments=@('--no-daemon','--console=plain',"-PpycodersRuntimeDir=$runtimeDirectory")
    if($Role -ne 'Server'){$arguments+="-PpycodersUsername=$Username"}
    $gamePayload=ConvertTo-MmtlArgumentPayload $gameArgs
    $jvmPayload=ConvertTo-MmtlArgumentPayload $jvmArgs
    if($gamePayload){$arguments+="-PpycodersGameArgsB64=$gamePayload"}
    if($jvmPayload){$arguments+="-PpycodersJavaArgsB64=$jvmPayload"}
    $arguments+=$task
    $guiScale=if($Profile.PSObject.Properties['guiScale']){$Profile.guiScale}else{$null}
    return [pscustomobject]@{Project=$Project.Root;Mode=$Mode;Role=$Role;Username=$Username;Task=$task;RuntimeDirectory=$runtimeDirectory;GameArguments=$gameArgs;JvmArguments=$jvmArgs;GuiScale=$guiScale;Arguments=$arguments}
}
Export-ModuleMember -Function Get-MmtlGradleCommand,ConvertTo-MmtlArgumentPayload,New-MmtlGradleRunPlan
