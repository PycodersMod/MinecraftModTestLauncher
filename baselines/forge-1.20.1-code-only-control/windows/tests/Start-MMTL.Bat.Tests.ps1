Describe 'Start-MMTL.bat PowerShell 7 requirement' {
    BeforeAll {
        $script:baselineRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $script:batchFile = Join-Path $script:baselineRoot 'Start-MMTL.bat'
        $script:batchText = [IO.File]::ReadAllText($script:batchFile)
    }

    It 'requires pwsh.exe and returns an error when PowerShell 7 is unavailable' {
        $script:batchText | Should -Match '(?im)^\s*where(?:\.exe)?\s+pwsh\.exe'
        $script:batchText | Should -Match '(?im)if\s+errorlevel\s+1'
        $script:batchText | Should -Match '(?i)PowerShell 7'
        $script:batchText | Should -Match '(?im)exit\s+/b\s+9009'
        $script:batchText | Should -Not -Match '(?im)^\s*powershell\.exe\s+.*Start-MMTL\.ps1'
    }

    It 'forwards the PowerShell exit code to the caller' {
        $script:batchText | Should -Match '(?im)pwsh\.exe\s+.*-File\s+"%~dp0Start-MMTL\.ps1"\s+%\*'
        $script:batchText | Should -Match '(?i)ERRORLEVEL'
        $script:batchText | Should -Match '(?im)exit\s+/b\s+%MMTL_EXIT_CODE%'
    }
}
