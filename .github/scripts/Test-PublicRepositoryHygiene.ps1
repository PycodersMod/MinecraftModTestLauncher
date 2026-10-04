[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw 'REPOSITORY_ROOT_INVALID' }

$paths = @(git -C $root ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'GIT_FILE_LIST_FAILED' }
$identity = @('ZYQ-2020', 'Kite-P')
$patterns = @(
    @{ code = 'WINDOWS_USER_PATH'; regex = '(?i)[A-Z]:\\Users\\[^\\\s"<>]+' },
    @{ code = 'WORKSPACE_ABSOLUTE_PATH'; regex = '(?i)[A-Z]:\\[^\r\n"<>]*自制材质包和辅助mod' },
    @{ code = 'LINUX_HOME_PATH'; regex = '(?i)/(?:home|Users)/[A-Za-z0-9._-]+' },
    @{ code = 'LOCAL_PROXY_ENDPOINT'; regex = '(?i)(?:127\.0\.0\.1|localhost):7897' },
    @{ code = 'GITHUB_CREDENTIAL'; regex = '(?i)(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})' }
)
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
        if ($content -match $pattern.regex) { $findings.Add([pscustomobject]@{ path = $relative; code = $pattern.code }) }
    }
    if ($hostname.Length -ge 5 -and $content.IndexOf($hostname, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $findings.Add([pscustomobject]@{ path = $relative; code = 'LOCAL_HOSTNAME' })
    }
    if ($relative -notin @('CODEOWNERS', 'LICENSE', '.github/scripts/Test-PublicRepositoryHygiene.ps1')) {
        foreach ($name in $identity) {
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
