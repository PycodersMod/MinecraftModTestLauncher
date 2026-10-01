function Resolve-MmtlRuntimeRoot {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path,[switch]$Portable,[string]$LauncherRoot)
    if ($Portable) { $Path=Join-Path $LauncherRoot '.runtime' }
    if ([string]::IsNullOrWhiteSpace($Path)) { Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1'); $Path=(Get-MmtlPlatformProvider).DefaultRuntimeRoot }
    $expanded=[Environment]::ExpandEnvironmentVariables($Path)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    return Get-MmtlCanonicalPath -Path $expanded
}
function Test-MmtlInsideRoot {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Target)
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1')
    return Test-MmtlPlatformPathInsideRoot -Root $Root -Target $Target
}
function Assert-MmtlNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $drive=[IO.Path]::GetPathRoot($full)
    $current=$drive
    $remainder=$full.Substring($drive.Length)
    foreach($part in ($remainder -split '[\\/]' | Where-Object {$_})){
        $current=Join-Path $current $part
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force
            if(Test-MmtlPathLink -Path $current){throw "拒绝访问包含 junction/symlink 的路径：$current"}
        }
    }
    return $true
}
function Remove-MmtlSession {
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$SessionPath)
    $root=[IO.Path]::GetFullPath($RuntimeRoot); $target=[IO.Path]::GetFullPath($SessionPath)
    if (-not (Test-MmtlInsideRoot -Root $root -Target $target)) { throw '拒绝删除 Runtime Root 之外的路径。' }
    Assert-MmtlNoReparsePath -Path $root | Out-Null
    Assert-MmtlNoReparsePath -Path $target | Out-Null
    $item=Get-Item -LiteralPath $target -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType) { throw '拒绝删除非目录、junction 或 symlink。' }
    $nestedLinks=@(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction Stop|Where-Object{($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.LinkType})
    if($nestedLinks.Count){throw "Session 内含 junction/symlink，拒绝递归删除：$($nestedLinks[0].FullName)"}
    $registry=Join-Path $target 'pids.json'
    if(Test-Path $registry){
        $entries=@(Get-Content $registry -Raw | ConvertFrom-Json)
        Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1');$platform=Get-MmtlPlatformProvider
        if($platform.OS -eq 'MacOS' -and $entries.Count){throw 'Cannot clean a session with registered processes because macOS ProcessManagement is unsupported.'}
        if($platform.OS -eq 'Linux'){Import-Module (Join-Path $PSScriptRoot 'Platform/Linux.Process.psm1')}elseif($platform.OS -eq 'Windows'){Import-Module (Join-Path $PSScriptRoot 'Platform/Windows.Process.psm1')}
        foreach($entry in $entries){
            $current=if($platform.OS -eq 'Linux'){Get-MmtlLinuxProcessRecord -ProcessId ([int]$entry.PID)}elseif($platform.OS -eq 'Windows'){Get-MmtlWindowsProcessRecord -ProcessId ([int]$entry.PID)}else{$null}
            if($current -and (Test-MmtlProcessIdentity -Process $current -Record $entry)){throw "Session 仍有启动器登记进程 PID $($entry.PID)，请先停止。"}
            foreach($tracked in @($entry.ProcessTree)){
                $descendant=if($platform.OS -eq 'Linux'){Get-MmtlLinuxProcessRecord -ProcessId ([int]$tracked.PID)}elseif($platform.OS -eq 'Windows'){Get-MmtlWindowsProcessRecord -ProcessId ([int]$tracked.PID)}else{$null}
                if($descendant -and (Test-MmtlProcessIdentity -Process $descendant -Record $tracked)){throw "Session 仍有登记子进程 PID $($tracked.PID)，请先停止。"}
            }
        }
        foreach($entry in $entries){
            if($entry.RuntimeLinkPath -and (Get-Command Remove-MmtlFabricRuntimeLink -ErrorAction SilentlyContinue)){
                Remove-MmtlFabricRuntimeLink -ProjectRoot $entry.WorkingDirectory -LinkPath $entry.RuntimeLinkPath -TargetPath $entry.RuntimeTargetPath|Out-Null
            }
        }
    }
    Remove-Item -LiteralPath $target -Recurse -Force
}
function Reset-MmtlSessionWorld {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$PlayerName,[Parameter(Mandatory)][string]$WorldName,[switch]$Reset)
    if(-not $Reset){return $false}
    if($PlayerName -notmatch '^[A-Za-z0-9_]{1,16}$'){throw '测试玩家名无效。'}
    if($WorldName -notmatch '^[A-Za-z0-9._ -]{1,64}$' -or $WorldName -in @('.','..')){throw '世界名称无效。'}
    $runtime=[IO.Path]::GetFullPath($RuntimeRoot);$session=[IO.Path]::GetFullPath($SessionPath)
    if(-not(Test-MmtlInsideRoot -Root (Join-Path $runtime 'sessions') -Target $session) -or [IO.Path]::GetFullPath((Split-Path $session -Parent)) -ne [IO.Path]::GetFullPath((Join-Path $runtime 'sessions'))){throw '世界重置目标 Session 不在 Runtime Root 内。'}
    $target=[IO.Path]::GetFullPath((Join-Path $session (Join-Path $PlayerName (Join-Path 'saves' $WorldName))))
    if(-not(Test-MmtlInsideRoot -Root $session -Target $target)){throw '世界重置目标越出当前 Session。'}
    Assert-MmtlNoReparsePath -Path $session|Out-Null
    if(-not(Test-Path -LiteralPath $target)){return $false}
    $item=Get-Item -LiteralPath $target -Force
    if(-not $item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw '拒绝重置非目录或链接世界。'}
    $nested=@(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction Stop|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint})
    if($nested.Count){throw '世界目录内含 junction/symlink，拒绝重置。'}
    if($PSCmdlet.ShouldProcess($target,'重置当前 Session 测试世界')){Remove-Item -LiteralPath $target -Recurse -Force;return $true}
    return $false
}
Export-ModuleMember -Function Resolve-MmtlRuntimeRoot,Test-MmtlInsideRoot,Assert-MmtlNoReparsePath,Remove-MmtlSession,Reset-MmtlSessionWorld
