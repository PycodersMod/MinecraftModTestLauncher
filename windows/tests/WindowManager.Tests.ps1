BeforeAll {
    $script:repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot '../src/WindowManager.psm1') -Force
}
Describe 'Windows 窗口管理提供器' {
    It '提供平铺和层叠窗口排列，并允许显式关闭' {
        (Get-MmtlWindowLayout -Mode Tile) | Should -Be 'Available'
        (Set-MmtlSessionWindowLayout -SessionPath $TestDrive -Mode None).Status | Should -Be 'Skipped'
    }
}
