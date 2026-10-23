Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1') -Force
function Get-MmtlWindowLayout {
    [CmdletBinding()]
    param([ValidateSet('Auto','Tile','Cascade','None')][string]$Mode='Auto')
    if($Mode -eq 'None'){return 'None'}
    if((Get-MmtlPlatformProvider).WindowManagement -eq 'Native'){return 'Available'}
    return 'UnavailableFallbackNone'
}
function Get-MmtlTileRectangles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,64)][int]$Count,[Parameter(Mandatory)][ValidateRange(1,32768)][int]$ScreenWidth,[Parameter(Mandatory)][ValidateRange(1,32768)][int]$ScreenHeight)
    $columns=[int][Math]::Ceiling([Math]::Sqrt($Count));$rows=[int][Math]::Ceiling($Count/$columns);$rects=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $Count;$i++){$column=$i%$columns;$row=[int][Math]::Floor($i/$columns);$x=[int][Math]::Floor($column*$ScreenWidth/$columns);$y=[int][Math]::Floor($row*$ScreenHeight/$rows);$right=[int][Math]::Floor(($column+1)*$ScreenWidth/$columns);$bottom=[int][Math]::Floor(($row+1)*$ScreenHeight/$rows);$rects.Add([pscustomobject]@{X=$x;Y=$y;Width=($right-$x);Height=($bottom-$y)})}
    return @($rects)
}
function Get-MmtlCascadeRectangles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,64)][int]$Count,[Parameter(Mandatory)][ValidateRange(1,32768)][int]$ScreenWidth,[Parameter(Mandatory)][ValidateRange(1,32768)][int]$ScreenHeight)
    $width=[int][Math]::Min(1280,[Math]::Max(400,$ScreenWidth*0.72));$height=[int][Math]::Min(800,[Math]::Max(300,$ScreenHeight*0.72));$step=36;$maxX=[Math]::Max(1,$ScreenWidth-$width);$maxY=[Math]::Max(1,$ScreenHeight-$height);$rects=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt $Count;$i++){$rects.Add([pscustomobject]@{X=(($i*$step)%$maxX);Y=(($i*$step)%$maxY);Width=$width;Height=$height})}
    return @($rects)
}
Export-ModuleMember -Function Get-MmtlWindowLayout,Get-MmtlTileRectangles,Get-MmtlCascadeRectangles
