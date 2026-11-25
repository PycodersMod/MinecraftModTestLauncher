function Get-MmtlCanonicalTextSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    $content = [IO.File]::ReadAllText($LiteralPath)
    $normalized = $content -replace "`r`n?", "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($normalized)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

Export-ModuleMember -Function Get-MmtlCanonicalTextSha256
