Import-Module (Join-Path $PSScriptRoot '../../common/src/WindowLayout.psm1') -Force
if(-not('MMTL.WindowApi' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace MMTL {
  public sealed class WindowEntry { public IntPtr Handle; public int ProcessId; }
  public static class WindowApi {
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    public static List<WindowEntry> GetVisibleWindows() {
      var windows = new List<WindowEntry>();
      EnumWindows(delegate(IntPtr handle, IntPtr data) {
        if (IsWindowVisible(handle)) { uint pid; GetWindowThreadProcessId(handle, out pid); if(pid > 0) windows.Add(new WindowEntry { Handle=handle, ProcessId=(int)pid }); }
        return true;
      }, IntPtr.Zero);
      return windows;
    }
    public static bool Place(IntPtr handle, int x, int y, int width, int height) { return SetWindowPos(handle, IntPtr.Zero, x, y, width, height, 0x0004|0x0010); }
    public static int ScreenWidth { get { return GetSystemMetrics(0); } }
    public static int ScreenHeight { get { return GetSystemMetrics(1); } }
  }
}
'@
}
function Get-MmtlWindowLayout {
    param([ValidateSet('Auto','Tile','Cascade','None')][string]$Mode='Auto')
    if($Mode -eq 'None'){return 'None'}
    if($env:OS -eq 'Windows_NT' -and ('MMTL.WindowApi' -as [type])){return 'Available'}
    return 'UnavailableFallbackNone'
}


function Set-MmtlSessionWindowLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[ValidateSet('Auto','Tile','Cascade','None')][string]$Mode='Auto',[ValidateRange(1,300)][int]$TimeoutSeconds=45,[ValidateRange(100,2000)][int]$PollMilliseconds=500)
    if($Mode -eq 'None'){return [pscustomobject]@{Status='Skipped';Reason='Layout disabled';Windows=0}}
    if((Get-MmtlWindowLayout -Mode $Mode) -ne 'Available'){return [pscustomobject]@{Status='UnavailableFallbackNone';Reason='Windows 窗口 API 不可用';Windows=0}}
    $pidPath=Join-Path $SessionPath 'pids.json';if(-not(Test-Path -LiteralPath $pidPath)){throw 'Session 缺少进程登记清单。'}
    $entries=@(Get-Content -LiteralPath $pidPath -Raw|ConvertFrom-Json|Where-Object Role -in @('Host','Client'))
    if(-not $entries.Count){return [pscustomobject]@{Status='Skipped';Reason='没有已登记的客户端进程';Windows=0}}
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds);$matched=@()
    do{
        $cim=@(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue);$candidatePids=[Collections.Generic.HashSet[int]]::new()
        foreach($entry in $entries){$root=$cim|Where-Object{[int]$_.ProcessId -eq [int]$entry.PID}|Select-Object -First 1;if(-not $root -or -not(Test-MmtlProcessIdentity -Process $root -Record $entry)){continue};$queue=[Collections.Generic.Queue[int]]::new();$queue.Enqueue([int]$entry.PID);while($queue.Count){$parent=$queue.Dequeue();foreach($child in @($cim|Where-Object{[int]$_.ParentProcessId -eq $parent})){if($candidatePids.Add([int]$child.ProcessId)){$queue.Enqueue([int]$child.ProcessId)}}}}
        $javaPids=@($cim|Where-Object{[int]$_.ProcessId -in $candidatePids -and $_.Name -match '^javaw?\.exe$'}|Select-Object -ExpandProperty ProcessId)
        $windows=@([MMTL.WindowApi]::GetVisibleWindows()|Where-Object{[int]$_.ProcessId -in $javaPids}|Sort-Object ProcessId -Unique)
        $matched=$windows
        if($windows.Count -ge $entries.Count -or [DateTime]::UtcNow -ge $deadline){break}
        Start-Sleep -Milliseconds $PollMilliseconds
    }while([DateTime]::UtcNow -lt $deadline)
    if(-not $matched.Count){return [pscustomobject]@{Status='Skipped';Reason='没有找到可见的 Minecraft 窗口';Windows=0}}
    if($Mode -eq 'Auto' -and $matched.Count -lt 2){return [pscustomobject]@{Status='Skipped';Reason='自动布局需要多个客户端';Windows=$matched.Count}}
    $width=[MMTL.WindowApi]::ScreenWidth;$height=[MMTL.WindowApi]::ScreenHeight
    if($width -lt 1 -or $height -lt 1){return [pscustomobject]@{Status='UnavailableFallbackNone';Reason='无法获取屏幕尺寸';Windows=$matched.Count}}
    $rectangles=if($Mode -eq 'Cascade'){Get-MmtlCascadeRectangles -Count $matched.Count -ScreenWidth $width -ScreenHeight $height}else{Get-MmtlTileRectangles -Count $matched.Count -ScreenWidth $width -ScreenHeight $height}
    $moved=0
    for($i=0;$i -lt $matched.Count;$i++){$rect=$rectangles[$i];if([MMTL.WindowApi]::Place($matched[$i].Handle,$rect.X,$rect.Y,$rect.Width,$rect.Height)){$moved++}}
    return [pscustomobject]@{Status=$(if($moved -eq $matched.Count){'Applied'}else{'Partial'});Reason='';Windows=$matched.Count;Moved=$moved;Mode=$(if($Mode -eq 'Auto'){'Tile'}else{$Mode})}
}
Export-ModuleMember -Function Get-MmtlWindowLayout,Set-MmtlSessionWindowLayout
