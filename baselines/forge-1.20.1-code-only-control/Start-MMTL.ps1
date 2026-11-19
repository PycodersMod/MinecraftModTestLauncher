[CmdletBinding()]
param(
    [string]$ConfigPath,
    [ValidateRange(1,8)][int]$ClientCount=0,
    [string[]]$PlayerNames,
    [string]$MinecraftRoot,
    [string]$JavaPath,
    [string]$VersionDirectory,
    [string]$RuntimeRoot,
    [string]$WorldName,
    [ValidateSet('QuickPlay','AgentAfterMainMenu')][string]$GuestConnectionMode,
    [Nullable[bool]]$LanEnabled,
    [switch]$ValidateOnly,
    [switch]$NonInteractive,
    [string]$StopSessionId,
    [string]$StatusSessionId
)
$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath($PSScriptRoot)
$configModule=Join-Path $repoRoot 'windows/src/ForgeControl/ForgeControlConfig.psm1'
Import-Module $configModule -Force
Import-Module (Join-Path $repoRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
Register-MmtlWindowsPlatform -RepositoryRoot $repoRoot
Import-Module (Join-Path $repoRoot 'windows/src/ForgeControl/ForgeControlSession.psm1') -Force
$profileRoot=Join-Path $PSScriptRoot 'config'
$defaultProfile=Join-Path $profileRoot 'forge-1.20.1-default.json'

function Resolve-SelectedConfig {
    param([string]$Path,[int]$Count,[string[]]$Names,[string]$GameRoot,[string]$Java,[string]$VersionFolder,[string]$Runtime,[string]$World,[string]$GuestMode,[Nullable[bool]]$Lan)
    $args=@{ConfigPath=$Path;RootPath=$repoRoot}
    if($Count -gt 0){$args.ClientCount=$Count};if($Names){$args.PlayerNames=$Names};if($GameRoot){$args.MinecraftRoot=$GameRoot};if($Java){$args.JavaPath=$Java};if($VersionFolder){$args.VersionDirectory=$VersionFolder};if($Runtime){$args.RuntimeRoot=$Runtime};if($World){$args.WorldName=$World};if($GuestMode){$args.GuestConnectionMode=$GuestMode};if($null -ne $Lan){$args.LanEnabled=$Lan}
    return Resolve-MmtlForgeControlConfig @args
}

try {
    $effectiveRuntimeRoot=if($RuntimeRoot){if([IO.Path]::IsPathRooted($RuntimeRoot)){[IO.Path]::GetFullPath($RuntimeRoot)}else{[IO.Path]::GetFullPath((Join-Path $repoRoot $RuntimeRoot))}}else{Join-Path $repoRoot 'runtime'}
    $env:MMTL_FORGE_CONTROL_RUNTIME=$effectiveRuntimeRoot
    if($StopSessionId){Stop-MmtlForgeControlSession -SessionId $StopSessionId|ConvertTo-Json -Depth 12;return}
    if($StatusSessionId){Get-MmtlForgeControlSessionStatus -SessionId $StatusSessionId|ConvertTo-Json -Depth 12;return}
    if(-not $ConfigPath){
        Write-Host ''
        Write-Host 'MMTL Forge 1.20.1 本地测试控制台' -ForegroundColor Cyan
        Write-Host '1. 使用临时启动配置'
        Write-Host '2. 读取已有启动配置文件'
        Write-Host '3. 使用默认配置快速启动'
        $choice=(Read-Host '请选择 [3]').Trim()
        if(-not $choice){$choice='3'}
        switch($choice){
            '1' {
                $CountText=Read-Host '窗口数量 [1]';$count=1;if($CountText -and -not[int]::TryParse($CountText,[ref]$count)){throw '窗口数量必须是 1 到 8 的整数。'}
                if($count -lt 1 -or $count -gt 8){throw '窗口数量必须是 1 到 8。'}
                $defaults=@('Dev');for($i=1;$i -lt $count;$i++){$defaults+=('Dev_'+$i)}
                $nameText=Read-Host "玩家名称，逗号分隔 [$($defaults -join ',')]"
                $names=if($nameText){@($nameText.Split(',')|ForEach-Object{$_.Trim()})}else{$defaults}
                $ConfigPath=$defaultProfile
                $resolved=Resolve-SelectedConfig -Path $ConfigPath -Count $count -Names $names -GameRoot $MinecraftRoot -Java $JavaPath -VersionFolder $VersionDirectory -Runtime $RuntimeRoot -World $WorldName -GuestMode $GuestConnectionMode -Lan $LanEnabled
            }
            '2' {
                $profiles=@(Get-ChildItem -LiteralPath $profileRoot -Filter '*.json' -File|Sort-Object Name)
                for($i=0;$i -lt $profiles.Count;$i++){Write-Host ("{0}. {1}" -f ($i+1),$profiles[$i].Name)}
                $selection=(Read-Host '输入序号或配置文件完整路径').Trim()
                $index=0
                if([int]::TryParse($selection,[ref]$index) -and $index -ge 1 -and $index -le $profiles.Count){$ConfigPath=$profiles[$index-1].FullName}
                else{$candidate=if([IO.Path]::IsPathRooted($selection)){$selection}else{Join-Path $repoRoot $selection};if(Test-Path -LiteralPath $candidate -PathType Leaf){$ConfigPath=[IO.Path]::GetFullPath($candidate)}else{throw '配置文件不存在或序号无效。'}}
                $resolved=Resolve-SelectedConfig -Path $ConfigPath -Count $ClientCount -Names $PlayerNames -GameRoot $MinecraftRoot -Java $JavaPath -VersionFolder $VersionDirectory -Runtime $RuntimeRoot -World $WorldName -GuestMode $GuestConnectionMode -Lan $LanEnabled
            }
            '3' {$ConfigPath=$defaultProfile;$resolved=Resolve-SelectedConfig -Path $ConfigPath -Count $ClientCount -Names $PlayerNames -GameRoot $MinecraftRoot -Java $JavaPath -VersionFolder $VersionDirectory -Runtime $RuntimeRoot -World $WorldName -GuestMode $GuestConnectionMode -Lan $LanEnabled}
            default {throw '无效菜单选项。'}
        }
    } else {
        $resolved=Resolve-SelectedConfig -Path $ConfigPath -Count $ClientCount -Names $PlayerNames -GameRoot $MinecraftRoot -Java $JavaPath -VersionFolder $VersionDirectory -Runtime $RuntimeRoot -World $WorldName -GuestMode $GuestConnectionMode -Lan $LanEnabled
    }
    Write-Host ("目标：Minecraft {0} / {1} {2} / Java {3}" -f $resolved.target.minecraftVersion,$resolved.target.loader,$resolved.target.loaderVersion,$resolved.javaMajor)
    Write-Host ("玩家数：{0}；联机：{1}；运行数据：{2}" -f $resolved.clientCount,$resolved.lanEnabled,$resolved.runtimeRoot)
    if($ValidateOnly){$resolved|ConvertTo-Json -Depth 12;exit 0}
    $session=Start-MmtlForgeControlSession -Config $resolved
    Write-Host "Session: $($session.sessionId)"
    if($NonInteractive -or [Console]::IsInputRedirected){$session|ConvertTo-Json -Depth 16;return}
    Write-Host '输入 Q 后按回车以安全关闭所有受管客户端；关闭本终端不会触发清理以外的 Session 操作。'
    do { $status=Get-MmtlForgeControlSessionStatus -SessionId $session.sessionId; Write-Host ($status|ConvertTo-Json -Depth 12 -Compress); $inputLine=Read-Host 'Q=停止；回车=刷新状态' } while($inputLine -ne 'Q' -and $inputLine -ne 'q')
    Stop-MmtlForgeControlSession -SessionId $session.sessionId|Out-Null
} catch {
    if($session -and $session.sessionId){try{Stop-MmtlForgeControlSession -SessionId $session.sessionId|Out-Null;Write-Host '已按安全退出流程关闭本 Session。'}catch{Write-Host "自动安全退出未完成：$($_.Exception.Message)" -ForegroundColor Yellow}}
    [Console]::Error.WriteLine("MMTL 启动失败：$($_.Exception.Message)")
    exit 2
}
