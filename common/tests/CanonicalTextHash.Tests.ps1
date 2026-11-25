BeforeAll {
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Hashing.psm1'
    Import-Module $modulePath -Force
}

Describe 'Canonical text SHA-256' {
    It 'produces the same content hash for LF and CRLF text files' {
        $lfPath = Join-Path $TestDrive 'canonical-lf.txt'
        $crlfPath = Join-Path $TestDrive 'canonical-crlf.txt'
        [IO.File]::WriteAllText($lfPath, "alpha`nbeta`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($crlfPath, "alpha`r`nbeta`r`n", [Text.UTF8Encoding]::new($false))

        $expected = (Get-FileHash -LiteralPath $lfPath -Algorithm SHA256).Hash.ToLowerInvariant()
        (Get-MmtlCanonicalTextSha256 -LiteralPath $lfPath) | Should -BeExactly $expected
        (Get-MmtlCanonicalTextSha256 -LiteralPath $crlfPath) | Should -BeExactly $expected
    }
}
