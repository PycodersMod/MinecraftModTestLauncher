[CmdletBinding()]
param([string]$OutputRoot)

$ErrorActionPreference='Stop'
$repoRoot=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$version=(Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
if($version -notmatch '^0\.\d+\.\d+-alpha\.\d+$'){throw 'ALPHA_VERSION_INVALID'}
$allowlistPath=Join-Path $PSScriptRoot 'public-alpha-allowlist.json'
$allowlist=Get-Content -LiteralPath $allowlistPath -Raw|ConvertFrom-Json -ErrorAction Stop
if([int]$allowlist.schemaVersion -ne 1 -or -not @($allowlist.paths).Count){throw 'ALPHA_ALLOWLIST_INVALID'}
if(-not $OutputRoot){$OutputRoot=Join-Path $repoRoot 'artifacts/public-alpha'}
$outputFull=[IO.Path]::GetFullPath($OutputRoot)
if(-not(Test-Path -LiteralPath $outputFull -PathType Container)){New-Item -ItemType Directory -Path $outputFull -Force|Out-Null}
$null=Get-Item -LiteralPath $outputFull -Force
$stageRoot=Join-Path ([IO.Path]::GetTempPath()) ('mmtl-alpha-stage-'+[guid]::NewGuid().ToString('N'))
$extractRoot=Join-Path ([IO.Path]::GetTempPath()) ('mmtl-alpha-extract-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageRoot,$extractRoot -Force|Out-Null
$forbiddenPathPattern='(^|/)(\.git|\.worktrees|\.codex|\.superpowers|\.runtime|runtime|sessions|logs|saves|world|worlds|build|\.gradle|cache|jdk|jre|minecraft)(/|$)'
$generatedNamePattern='(?i)(^|/)(launcher\.config\.json|project-registry\.json|testResults\.xml|.*\.log)$'
$zipPath=Join-Path $outputFull ("MinecraftModTestLauncher-$version-source.zip")
$zipHashPath=$zipPath+'.sha256'
try{
    $included=[Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($entry in @($allowlist.paths)){
        $relative=[string]$entry
        if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)'){throw 'ALPHA_ALLOWLIST_PATH_INVALID'}
        $source=Join-Path $repoRoot $relative
        if(-not(Test-Path -LiteralPath $source)){throw "ALPHA_ALLOWLIST_MISSING: $relative"}
        $item=Get-Item -LiteralPath $source -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "ALPHA_REPARSE_POINT_BLOCKED: $relative"}
        $files=if($item.PSIsContainer){@(Get-ChildItem -LiteralPath $source -Recurse -File -Force)}else{@($item)}
        foreach($file in $files){
            $full=[IO.Path]::GetFullPath($file.FullName)
            $prefix=[IO.Path]::GetFullPath($source).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
            if($item.PSIsContainer -and -not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'ALPHA_FILE_OUTSIDE_ALLOWLIST_ROOT'}
            if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "ALPHA_REPARSE_POINT_BLOCKED: $relative"}
            $rel=[IO.Path]::GetRelativePath($repoRoot,$full).Replace('\','/')
            if($rel -match $generatedNamePattern -or $rel -cmatch $forbiddenPathPattern){throw "ALPHA_FORBIDDEN_CONTENT: $rel"}
            if($included.ContainsKey($rel)){continue}
            $included.Add($rel,$full)
        }
    }
    if(-not $included.ContainsKey('VERSION') -or -not $included.ContainsKey('LICENSE')){throw 'ALPHA_REQUIRED_FILES_MISSING'}
    foreach($relative in $included.Keys){
        $target=Join-Path $stageRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
        [IO.File]::Copy($included[$relative],$target,$false)
    }
    $providerManifests=@(Get-ChildItem -LiteralPath (Join-Path $stageRoot 'common/agent/providers') -Filter agent-manifest.json -File -Recurse -ErrorAction SilentlyContinue)
    foreach($manifestFile in $providerManifests){
        $manifest=Get-Content -LiteralPath $manifestFile.FullName -Raw|ConvertFrom-Json -ErrorAction Stop
        $artifactRelative=('common/agent/'+[string]$manifest.artifact).Replace('\\','/')
        $artifactSource=Join-Path $repoRoot $artifactRelative
        if(-not $included.ContainsKey($artifactRelative)){throw "ALPHA_AGENT_ARTIFACT_NOT_ALLOWLISTED: $($manifest.providerId)"}
        $artifact=Join-Path $stageRoot $artifactRelative
        if(-not(Test-Path -LiteralPath $artifact -PathType Leaf)){throw "ALPHA_AGENT_ARTIFACT_MISSING: $($manifest.providerId)"}
        if((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash -ine [string]$manifest.sha256 -or (Get-FileHash -LiteralPath $artifactSource -Algorithm SHA256).Hash -ine [string]$manifest.sha256){throw "ALPHA_AGENT_HASH_MISMATCH: $($manifest.providerId)"}
    }
    $manifestLines=[Collections.Generic.List[string]]::new()
    foreach($relative in $included.Keys){$hash=(Get-FileHash -LiteralPath $included[$relative] -Algorithm SHA256).Hash.ToLowerInvariant();$manifestLines.Add("$hash  $relative")}
    [IO.File]::WriteAllText((Join-Path $stageRoot 'MANIFEST.sha256'),($manifestLines -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $zipPath -PathType Leaf){[IO.File]::Delete($zipPath)}
    Add-Type -AssemblyName System.IO.Compression
    $stream=[IO.File]::Open($zipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{
        $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try{
            foreach($file in @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File|Sort-Object { [IO.Path]::GetRelativePath($stageRoot,$_.FullName).Replace('\','/') })){
                $relative=[IO.Path]::GetRelativePath($stageRoot,$file.FullName).Replace('\','/')
                $entry=$archive.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                $entry.ExternalAttributes=0
                $input=[IO.File]::OpenRead($file.FullName)
                try{$output=$entry.Open();try{$input.CopyTo($output)}finally{$output.Dispose()}}finally{$input.Dispose()}
            }
        }finally{$archive.Dispose()}
    }finally{$stream.Dispose()}
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath,$extractRoot)
    foreach($relative in @($included.Keys)+@('MANIFEST.sha256')){
        $original=Join-Path $stageRoot $relative;$unzipped=Join-Path $extractRoot $relative
        if(-not(Test-Path -LiteralPath $unzipped -PathType Leaf)){throw "ALPHA_UNZIP_MISSING: $relative"}
        if((Get-FileHash $original -Algorithm SHA256).Hash -cne (Get-FileHash $unzipped -Algorithm SHA256).Hash){throw "ALPHA_UNZIP_HASH_MISMATCH: $relative"}
    }
    $zipHash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipHashPath,"$zipHash  $([IO.Path]::GetFileName($zipPath))`n",[Text.UTF8Encoding]::new($false))
    [pscustomobject][ordered]@{status='PASS';version=$version;package=$zipPath;sha256=$zipHash;fileCount=$included.Count+1;agentProviderCount=$providerManifests.Count;archiveSmoke='PASS';outputRoot=$outputFull}|ConvertTo-Json -Depth 5 -Compress
}finally{
    foreach($tempPath in @($stageRoot,$extractRoot)){
        $full=[IO.Path]::GetFullPath($tempPath);$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if($full.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -match '^mmtl-alpha-(stage|extract)-[a-f0-9]{32}$'){
            Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue|Where-Object{($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|ForEach-Object{throw 'ALPHA_TEMP_REPARSE_POINT_BLOCKED'}
            Remove-Item -LiteralPath $full -Recurse -Force
        }
    }
}
