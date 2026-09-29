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
function Get-MmtlTileRectangles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,64)][int]$Count,[Parameter(Mandatory)][ValidateRange(1,32768)][int]$ScreenWidth,[Parameter(Mandatory)][ValidateRange(1,32768)][int]$ScreenHeight)
    $columns=[int][Math]::Ceiling([Math]::Sqrt($Count));$rows=[int][Math]::Ceiling($Count/$columns)
    $rects=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $Count;$i++){$column=$i%$columns;$row=[int][Math]::Floor($i/$columns);$x=[int][Math]::Floor($column*$ScreenWidth/$columns);$y=[int][Math]::Floor($row*$ScreenHeight/$rows);$right=[int][Math]::Floor(($column+1)*$ScreenWidth/$columns);$bottom=[int][Math]::Floor(($row+1)*$ScreenHeight/$rows);$rects.Add([pscustomobject]@{X=$x;Y=$y;Width=($right-$x);Height=($bottom-$y)})}
    return @($rects)
}
function Get-MmtlCascadeRectangles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,64)][int]$Count,[Parameter(Mandatory)][ValidateRange(1,32768)][int]$ScreenWidth,[Parameter(Mandatory)][ValidateRange(1,32768)][int]$ScreenHeight)
    $width=[int][Math]::Min(1280,[Math]::Max(400,$ScreenWidth*0.72));$height=[int][Math]::Min(800,[Math]::Max(300,$ScreenHeight*0.72));$step=36
    $maxX=[Math]::Max(1,$ScreenWidth-$width);$maxY=[Math]::Max(1,$ScreenHeight-$height);$rects=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $Count;$i++){$rects.Add([pscustomobject]@{X=(($i*$step)%$maxX);Y=(($i*$step)%$maxY);Width=$width;Height=$height})}
    return @($rects)
}
function Set-MmtlSessionWindowLayout {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[ValidateSet('Auto','Tile','Cascade','None')][string]$Mode='Auto',[ValidateRange(1,300)][int]$TimeoutSeconds=45,[ValidateRange(100,2000)][int]$PollMilliseconds=500)
    if($Mode -eq 'None'){return [pscustomobject]@{Status='Skipped';Reason='Layout disabled';Windows=0}}
    if((Get-MmtlWindowLayout -Mode $Mode) -ne 'Available'){return [pscustomobject]@{Status='UnavailableFallbackNone';Reason='Windows window API unavailable';Windows=0}}
    $pidPath=Join-Path $SessionPath 'pids.json';if(-not(Test-Path -LiteralPath $pidPath)){throw 'Session 缺少进程登记清单。'}
    $entries=@(Get-Content -LiteralPath $pidPath -Raw|ConvertFrom-Json|Where-Object Role -in @('Host','Client'))
    if(-not $entries.Count){return [pscustomobject]@{Status='Skipped';Reason='No registered client processes';Windows=0}}
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
    if(-not $matched.Count){return [pscustomobject]@{Status='Skipped';Reason='No visible Minecraft windows found';Windows=0}}
    if($Mode -eq 'Auto' -and $matched.Count -lt 2){return [pscustomobject]@{Status='Skipped';Reason='Auto layout requires multiple clients';Windows=$matched.Count}}
    $width=[MMTL.WindowApi]::ScreenWidth;$height=[MMTL.WindowApi]::ScreenHeight
    if($width -lt 1 -or $height -lt 1){return [pscustomobject]@{Status='UnavailableFallbackNone';Reason='Screen geometry unavailable';Windows=$matched.Count}}
    $rectangles=if($Mode -eq 'Cascade'){Get-MmtlCascadeRectangles -Count $matched.Count -ScreenWidth $width -ScreenHeight $height}else{Get-MmtlTileRectangles -Count $matched.Count -ScreenWidth $width -ScreenHeight $height}
    $moved=0
    for($i=0;$i -lt $matched.Count;$i++){$rect=$rectangles[$i];if([MMTL.WindowApi]::Place($matched[$i].Handle,$rect.X,$rect.Y,$rect.Width,$rect.Height)){$moved++}}
    return [pscustomobject]@{Status=$(if($moved -eq $matched.Count){'Applied'}else{'Partial'});Reason='';Windows=$matched.Count;Moved=$moved;Mode=$(if($Mode -eq 'Auto'){'Tile'}else{$Mode})}
}
Export-ModuleMember -Function Get-MmtlWindowLayout,Get-MmtlTileRectangles,Get-MmtlCascadeRectangles,Set-MmtlSessionWindowLayout
