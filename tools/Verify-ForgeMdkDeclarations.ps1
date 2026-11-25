[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [string]$CatalogPath,
    [string]$CacheRoot = (Join-Path ([IO.Path]::GetTempPath()) 'mmtl-forge-mdk-audit'),
    [switch]$Offline,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not $CatalogPath) { $CatalogPath = Join-Path $repo 'compatibility/forge-mdk-generations.json' }
$CatalogPath = [IO.Path]::GetFullPath($CatalogPath)
$CacheRoot = [IO.Path]::GetFullPath($CacheRoot)
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw 'FORGE_MDK_AUDIT_CATALOG_MISSING' }
[void][IO.Directory]::CreateDirectory($CacheRoot)

$modulePath = Join-Path $repo 'common/src/Adapters/ForgeSecureBuild.psm1'
Import-Module $modulePath -Force
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
if ([int]$catalog.schemaVersion -ne 1 -or [int]$catalog.targetCount -ne @($catalog.targets).Count) { throw 'FORGE_MDK_AUDIT_CATALOG_INVALID' }
$catalogCore = [pscustomobject][ordered]@{
    schemaVersion = [int]$catalog.schemaVersion
    generatedAt = [string]$catalog.generatedAt
    auditStatus = [string]$catalog.auditStatus
    universeHash = [string]$catalog.universeHash
    targetCount = [int]$catalog.targetCount
    targets = @($catalog.targets)
}
$catalogHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $catalogCore -Depth 20 -Compress)))).ToLowerInvariant()
if ($catalogHash -cne [string]$catalog.catalogHash) { throw 'FORGE_MDK_AUDIT_CATALOG_HASH_MISMATCH' }

function Get-ArchiveHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-MdkArchive([object]$Target, [string]$Path, [bool]$AllowNetwork) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
    if (-not $AllowNetwork) { throw "FORGE_MDK_AUDIT_ARCHIVE_NOT_CACHED:$($Target.targetId)" }
    $uri = [Uri][string]$Target.mdkUrl
    if ($uri.Scheme -cne 'https' -or $uri.Host -cne 'maven.minecraftforge.net' -or $uri.UserInfo) { throw "FORGE_MDK_AUDIT_URL_REJECTED:$($Target.targetId)" }
    $current = $uri
    for ($redirect = 0; $redirect -le 4; $redirect++) {
        if ($current.Scheme -cne 'https' -or $current.Host -cne 'maven.minecraftforge.net' -or $current.UserInfo) { throw "FORGE_MDK_AUDIT_REDIRECT_REJECTED:$($Target.targetId)" }
        $request = [Net.HttpWebRequest]::Create($current)
        $request.Method = 'GET'; $request.AllowAutoRedirect = $false; $request.Timeout = 120000; $request.ReadWriteTimeout = 120000
        $response = $null
        try { $response = $request.GetResponse() } catch [Net.WebException] { $response = $_.Exception.Response; if (-not $response) { throw } }
        if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
            $location = [string]$response.Headers['Location']; $response.Close()
            if (-not $location -or $redirect -eq 4) { throw "FORGE_MDK_AUDIT_REDIRECT_LIMIT:$($Target.targetId)" }
            $current = [Uri]::new($current, $location); continue
        }
        if ([int]$response.StatusCode -ne 200) { $status = [int]$response.StatusCode; $response.Close(); throw "FORGE_MDK_AUDIT_HTTP_STATUS:$($Target.targetId):$status" }
        try {
            $input = $response.GetResponseStream()
            $output = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        } finally { $response.Close() }
        return
    }
    throw "FORGE_MDK_AUDIT_REDIRECT_LIMIT:$($Target.targetId)"
}

$records = [Collections.Generic.List[object]]::new()
$errors = [Collections.Generic.List[string]]::new()
foreach ($target in @($catalog.targets | Where-Object { $_.status -ceq 'Available' })) {
    $fileName = ([string]$target.targetId).Replace('@', '_') + '.zip'
    $archivePath = Join-Path $CacheRoot $fileName
    try {
        Get-MdkArchive -Target $target -Path $archivePath -AllowNetwork (-not $Offline)
        $archiveHash = Get-ArchiveHash $archivePath
        if ($archiveHash -cne ([string]$target.archiveSha256).ToLowerInvariant()) { throw "FORGE_MDK_AUDIT_ARCHIVE_HASH_MISMATCH:$($target.targetId)" }
        $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $buildEntries = @($zip.Entries | Where-Object { $_.FullName -match '(^|/)build\.gradle$' })
            if ($buildEntries.Count -ne 1) { throw "FORGE_MDK_AUDIT_BUILD_GRADLE_ENTRY_COUNT:$($target.targetId):$($buildEntries.Count)" }
            $reader = [IO.StreamReader]::new($buildEntries[0].Open(), [Text.Encoding]::UTF8, $true)
            try { $buildText = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
        $buildHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($buildText))).ToLowerInvariant()
        if ($buildHash -cne ([string]$target.buildGradleSha256).ToLowerInvariant()) { throw "FORGE_MDK_AUDIT_BUILD_GRADLE_HASH_MISMATCH:$($target.targetId)" }
        $declarations = Get-MmtlForgeBuildScriptDeclarations -BuildScriptText $buildText
        $allDeclarations = @($declarations.classpath) + @($declarations.plugins)
        if (@($declarations.plugins).Count -eq 1 -and @($declarations.classpath).Count -eq 0) { $active = $declarations.plugins[0] }
        elseif (@($declarations.classpath).Count -eq 1 -and @($declarations.plugins).Count -eq 0) { $active = $declarations.classpath[0] }
        else { throw "FORGE_MDK_AUDIT_DECLARATION_AMBIGUOUS:$($target.targetId):$($allDeclarations.Count)" }
        if ([string]$active.version -cne [string]$target.forgeGradleSpec) { throw "FORGE_MDK_AUDIT_DECLARATION_MISMATCH:$($target.targetId):$($active.version):$($target.forgeGradleSpec)" }
        $records.Add([pscustomobject][ordered]@{ targetId = [string]$target.targetId; archiveSha256 = $archiveHash; buildGradleSha256 = $buildHash; activeDeclarationKind = [string]$active.kind; activeForgeGradleSpec = [string]$active.version })
    } catch { $errors.Add($_.Exception.Message) }
}

$result = [pscustomobject][ordered]@{
    status = $(if ($errors.Count -eq 0 -and $records.Count -eq @($catalog.targets | Where-Object { $_.status -ceq 'Available' }).Count) { 'PASS' } else { 'FAIL' })
    catalogHash = $catalogHash
    availableTargetCount = @($catalog.targets | Where-Object { $_.status -ceq 'Available' }).Count
    verifiedTargetCount = $records.Count
    targets = @($records.ToArray())
    errors = @($errors.ToArray())
}
if ($OutputPath) {
    $outputFullPath = [IO.Path]::GetFullPath($OutputPath)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $outputFullPath))
    [IO.File]::WriteAllText($outputFullPath, (ConvertTo-Json -InputObject $result -Depth 20), [Text.UTF8Encoding]::new($false))
}
$result
if ($result.status -cne 'PASS') { throw ('FORGE_MDK_AUDIT_FAILED:' + ($errors -join ';')) }
