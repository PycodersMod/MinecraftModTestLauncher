function Resolve-MmtlRuntimeRoot {
    param([Parameter(Mandatory)][string]$Path,[switch]$Portable,[string]$LauncherRoot)
    if ($Portable) { $Path=Join-Path $LauncherRoot '.runtime' }
    $expanded=[Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded)
}
function Test-MmtlInsideRoot {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Target)
    $r=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
    $t=[IO.Path]::GetFullPath($Target)
    return $t.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)
}
function Assert-MmtlNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $drive=[IO.Path]::GetPathRoot($full)
    $current=$drive
    foreach($part in $full.Substring($drive.Length).Split('\',[StringSplitOptions]::RemoveEmptyEntries)){
        $current=Join-Path $current $part
        if(Test-Path -LiteralPath $current){
            $item=Get-Item -LiteralPath $current -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "拒绝访问包含 junction/symlink 的路径：$current"}
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
    if (-not $item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '拒绝删除非目录、junction 或 symlink。' }
    $registry=Join-Path $target 'pids.json'
    if(Test-Path $registry){
        foreach($entry in @(Get-Content $registry -Raw | ConvertFrom-Json)){
            try{$proc=Get-Process -Id ([int]$entry.PID) -ErrorAction Stop}catch{continue}
            if($proc.StartTime.ToUniversalTime().ToString('o') -eq [string]$entry.StartTimeUtc -and $proc.Path -eq [string]$entry.Executable){throw "Session 仍有启动器登记进程 PID $($entry.PID)，请先停止。"}
        }
    }
    Remove-Item -LiteralPath $target -Recurse -Force
}
Export-ModuleMember -Function Resolve-MmtlRuntimeRoot,Test-MmtlInsideRoot,Assert-MmtlNoReparsePath,Remove-MmtlSession
