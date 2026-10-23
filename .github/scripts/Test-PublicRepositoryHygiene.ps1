[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string[]]$SensitiveIdentities = @()
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) { throw 'REPOSITORY_ROOT_INVALID' }
Import-Module (Join-Path $PSScriptRoot 'PublicRepositoryHygiene.psm1') -Force

$isGitHubActions = $env:GITHUB_ACTIONS -eq 'true'
$identities = @(Get-MmtlPublicHygieneIdentityCandidates -SensitiveIdentities $SensitiveIdentities -EnvironmentUserName ([Environment]::UserName) -MachineName ([Environment]::MachineName) -UserProfile $env:USERPROFILE -GitHubActions:$isGitHubActions)
$paths = @(git -C $root ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'GIT_FILE_LIST_FAILED' }

$findings = [Collections.Generic.List[object]]::new()
$filesScanned = 0
foreach ($relative in $paths) {
    if (-not $relative) { continue }
    $file = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    try {
        $bytes = [IO.File]::ReadAllBytes($file)
        $filesScanned++
        foreach ($finding in @(Get-MmtlPublicHygieneFileFinding -RelativePath ($relative -replace '\\','/') -Bytes $bytes -SensitiveIdentities $identities)) {
            $findings.Add($finding)
        }
    } catch {
        $findings.Add([pscustomobject]@{ Path=($relative -replace '\\','/'); Line=0; Code='FILE_SCAN_FAILED' })
    }
}

if ($findings.Count) {
    $findings | Sort-Object Path, Line, Code | Format-Table -AutoSize | Out-String | Write-Error
    exit 1
}
Write-Output ("Public repository hygiene: PASS ({0} files scanned; text, binary strings, and nested ZIP/JAR entries checked)." -f $filesScanned)
