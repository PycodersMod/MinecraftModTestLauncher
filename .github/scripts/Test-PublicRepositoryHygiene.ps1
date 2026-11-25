[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string[]]$SensitiveIdentities = @()
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw 'REPOSITORY_ROOT_INVALID' }

$paths = @(git -C $root ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'GIT_FILE_LIST_FAILED' }
$patterns = @(
    @{ code = 'WINDOWS_USER_PATH'; regex = '(?i)[A-Z]:\\Users\\[^\\\s"<>]+' },
    @{ code = 'WORKSPACE_ABSOLUTE_PATH'; regex = '(?i)[A-Z]:\\[^\r\n"<>]*自制材质包和辅助mod' },
    @{ code = 'LINUX_HOME_PATH'; regex = '(?i)/(?:home|Users)/[A-Za-z0-9._-]+' },
    @{ code = 'LOCAL_PROXY_ENDPOINT'; regex = '(?i)(?:127\.0\.0\.1|localhost):7897' },
    @{ code = 'GITHUB_CREDENTIAL'; regex = '(?i)(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})' }
)
# These are verified upstream Forge changelog fixtures. Their scp URLs use a
# server-side files directory; allow only these exact bytes and paths.
$verifiedUpstreamPathFixtureHashes = @{
    'common/fixtures/forge/1.7.10-marker/forge-1.7.10-10.13.4.1614-1.7.10-changelog.txt' = 'EE9EBA9FA28404EF1491CE7B08C48967E0BC36D8B0EF64AC8CFE1B0690A63E62'
    'common/fixtures/forge/1.8.8-marker/forge-1.8.8-11.15.0.1655-changelog.txt' = 'D20F4FC55B37A7C957AD943CEE0321E1B40518236DA3831FA044FAC8CAFC580F'
}
$hostname = [string]$env:COMPUTERNAME
$findings = [Collections.Generic.List[object]]::new()
$textExtensions = @('.md', '.txt', '.json', '.yml', '.yaml', '.ps1', '.psm1', '.psd1', '.sh', '.toml', '.properties', '.xml', '.gradle', '.kts', '.java', '.kt', '.cs', '.py')

foreach ($relative in $paths) {
    if (-not $relative) { continue }
    $file = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    if ([IO.Path]::GetExtension($file).ToLowerInvariant() -notin $textExtensions -and [IO.Path]::GetFileName($file) -ne 'CODEOWNERS') { continue }
    try { $content = [IO.File]::ReadAllText($file) } catch { continue }
    foreach ($pattern in $patterns) {
        if ($content -match $pattern.regex) {
            if ($pattern.code -eq 'LINUX_HOME_PATH' -and $verifiedUpstreamPathFixtureHashes.ContainsKey($relative)) {
                $actualHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                if ($actualHash -ceq $verifiedUpstreamPathFixtureHashes[$relative]) { continue }
            }
            $findings.Add([pscustomobject]@{ path = $relative; code = $pattern.code })
        }
    }
    if ($hostname.Length -ge 5 -and $content.IndexOf($hostname, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $findings.Add([pscustomobject]@{ path = $relative; code = 'LOCAL_HOSTNAME' })
    }
    if ($relative -notin @('CODEOWNERS', 'LICENSE')) {
        foreach ($name in $SensitiveIdentities) {
            if ($content.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $findings.Add([pscustomobject]@{ path = $relative; code = 'PERSONAL_GITHUB_IDENTITY' })
                break
            }
        }
    }
}

if ($findings.Count) {
    $findings | Sort-Object path, code | Format-Table -AutoSize | Out-String | Write-Error
    exit 1
}
Write-Output ("Public repository hygiene: PASS ({0} files scanned)." -f $paths.Count)
