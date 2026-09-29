function Get-MmtlWindowLayout {
    param([ValidateSet('Auto','Tile','Cascade','None')][string]$Mode='Auto')
    if ($Mode -in @('Auto','Tile','Cascade') -and $env:OS -eq 'Windows_NT') { return 'UnavailableFallbackNone' }
    return 'None'
}
Export-ModuleMember -Function Get-MmtlWindowLayout
