Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\..\SessionLifecycle.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\AtomicFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\..\SessionLock.psm1') -Force

$script:JarModMaxArchiveBytes=268435456L
$script:JarModMaxExpandedBytes=1073741824L
$script:JarModMaxEntries=100000

function Assert-MmtlJarModNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetPathRoot($full);$current=$root
    foreach($part in ($full.Substring($root.Length) -split '[\\/]' | Where-Object {$_})){
        $current=Join-Path $current $part
        if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw 'JARMOD_PATH_REPARSE_POINT'}}
    }
    return $true
}

function Get-MmtlJarModArchiveInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Role)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.PSIsContainer){throw "JARMOD_ARCHIVE_NOT_FILE: $Role"}
    if($item.Length -le 0 -or $item.Length -gt $script:JarModMaxArchiveBytes){throw "JARMOD_ARCHIVE_SIZE_INVALID: $Role"}
    $archive=$null
    try{
        $archive=[IO.Compression.ZipFile]::OpenRead($Path)
        if($archive.Entries.Count -gt $script:JarModMaxEntries){throw "JARMOD_ARCHIVE_ENTRY_LIMIT: $Role"}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $expanded=0L;$names=[Collections.Generic.List[string]]::new();$hasSignature=$false
        foreach($entry in $archive.Entries){
            $name=[string]$entry.FullName
            if($name.Contains([char]0) -or $name.Contains('\') -or $name.StartsWith('/') -or $name.Contains(':')){throw "JARMOD_ENTRY_PATH_INVALID: $Role"}
            $trimmed=$name.TrimEnd('/')
            if(-not $trimmed){throw "JARMOD_ENTRY_PATH_INVALID: $Role"}
            foreach($segment in ($trimmed -split '/')){if(-not $segment -or $segment -in @('.','..')){throw "JARMOD_ENTRY_PATH_INVALID: $Role"}}
            if(-not $seen.Add($name)){throw "JARMOD_ENTRY_DUPLICATE: $Role"}
            $unixType=($entry.ExternalAttributes -shr 16) -band 0xF000
            if($unixType -eq 0xA000){throw "JARMOD_ENTRY_SYMLINK_UNSUPPORTED: $Role"}
            $expanded+=[long]$entry.Length
            if($expanded -gt $script:JarModMaxExpandedBytes){throw "JARMOD_ARCHIVE_EXPANDED_LIMIT: $Role"}
            if($name -match '(?i)^META-INF/(?:[^/]+\.(?:SF|RSA|DSA|EC)|SIG-[^/]+)$' -or $name -match '(?i)^META-INF/INDEX\.LIST$'){$hasSignature=$true}
            if(-not $entry.FullName.EndsWith('/')){$names.Add($name)}
        }
        return [pscustomobject]@{path=$Path;sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant();length=[long]$item.Length;expandedBytes=$expanded;entryCount=$archive.Entries.Count;fileEntries=@($names.ToArray());hasSignature=$hasSignature}
    }catch{
        if($_.Exception.Message -like 'JARMOD_*'){throw}
        throw "JARMOD_ARCHIVE_INVALID: $Role"
    }finally{if($archive){$archive.Dispose()}}
}

function Assert-MmtlJarModArchivePath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Role)
    $resolved=Resolve-Path -LiteralPath $Path -ErrorAction Stop
    Assert-MmtlJarModNoReparsePath -Path $resolved.Path|Out-Null
    $item=Get-Item -LiteralPath $resolved.Path -Force
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw "JARMOD_INPUT_REPARSE_POINT: $Role"}
    return $resolved.Path
}

function Test-MmtlJarModPathWithinSession {
    param([Parameter(Mandatory)][string]$SessionRoot,[Parameter(Mandatory)][string]$Path)
    $relative=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($SessionRoot),[IO.Path]::GetFullPath($Path))
    if([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or $relative.StartsWith('..'+[IO.Path]::AltDirectorySeparatorChar,[StringComparison]::Ordinal)){throw 'JARMOD_SESSION_PATH_ESCAPE'}
    return $relative
}

function Copy-MmtlJarModEntryBounded {
    param([Parameter(Mandatory)][IO.Stream]$Source,[Parameter(Mandatory)][IO.Stream]$Target,[Parameter(Mandatory)][long]$RemainingBytes)
    $buffer=[byte[]]::new(65536);$copied=0L
    while(($read=$Source.Read($buffer,0,$buffer.Length)) -gt 0){
        $copied+=$read
        if($copied -gt $RemainingBytes){throw 'JARMOD_ARCHIVE_EXPANDED_LIMIT'}
        $Target.Write($buffer,0,$read)
    }
    return $copied
}

function Remove-MmtlJarModWorkDirectory {
    param([Parameter(Mandatory)][string]$SessionRoot,[Parameter(Mandatory)][string]$WorkDirectory)
    if(-not(Test-Path -LiteralPath $WorkDirectory)){return}
    $null=Test-MmtlJarModPathWithinSession -SessionRoot $SessionRoot -Path $WorkDirectory
    Assert-MmtlJarModNoReparsePath -Path $WorkDirectory|Out-Null
    Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

function New-MmtlJarModSessionOverlay {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$BaseJarPath,
        [Parameter(Mandatory)][string]$PatchArchivePath,
        [Parameter(Mandatory)][ValidateSet('OverlayRejectConflicts','OverlayReplaceConflicts')][string]$PatchStrategy
    )
    $session=[IO.Path]::GetFullPath($SessionPath)
    if(-not(Test-Path -LiteralPath $session -PathType Container)){throw 'JARMOD_SESSION_MISSING'}
    Assert-MmtlJarModNoReparsePath -Path $session|Out-Null
    $basePath=Assert-MmtlJarModArchivePath -Path $BaseJarPath -Role 'Base'
    $patchPath=Assert-MmtlJarModArchivePath -Path $PatchArchivePath -Role 'Patch'
    if([string]::Equals($basePath,$patchPath,[StringComparison]::OrdinalIgnoreCase)){throw 'JARMOD_INPUTS_MUST_BE_DISTINCT'}
    $lock=New-MmtlSessionLock -LockPath (Join-Path $session '.session.lock') -AllowedRoot $session
    $work=$null;$manifestPath=Join-Path $session 'session.v2.json';$originalManifest=$null;$manifestUpdated=$false
    try{
        $sessionCheck=Test-MmtlSessionV2 -SessionPath $session
        if(-not $sessionCheck.valid){throw 'JARMOD_SESSION_INVALID'}
        if($sessionCheck.state -notin @('Created','Preparing','Building')){throw 'JARMOD_SESSION_STATE_UNSUPPORTED'}
        $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json -ErrorAction Stop
        $originalManifest=Get-Content -LiteralPath $manifestPath -Raw
        $baseInfo=Get-MmtlJarModArchiveInfo -Path $basePath -Role 'Base'
        $patchInfo=Get-MmtlJarModArchiveInfo -Path $patchPath -Role 'Patch'
        if($baseInfo.hasSignature -or $patchInfo.hasSignature){throw 'JARMOD_SIGNED_ARCHIVE_UNSUPPORTED'}

        $artifactRoot=Join-Path $session 'artifacts/jarmod'
        if(Test-Path -LiteralPath $artifactRoot){Assert-MmtlJarModNoReparsePath -Path $artifactRoot|Out-Null}
        [IO.Directory]::CreateDirectory($artifactRoot)|Out-Null
        $work=Join-Path $artifactRoot ('overlay-'+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($work)|Out-Null
        Assert-MmtlJarModNoReparsePath -Path $work|Out-Null
        $baseCopy=Join-Path $work 'base.jar';$patchCopy=Join-Path $work 'patch.zip';$outputTemp=Join-Path $work 'patched.tmp.jar';$outputPath=Join-Path $work 'patched.jar'
        [IO.File]::Copy($basePath,$baseCopy,$false);[IO.File]::Copy($patchPath,$patchCopy,$false)
        if((Get-FileHash -LiteralPath $baseCopy -Algorithm SHA256).Hash.ToLowerInvariant() -cne $baseInfo.sha256 -or (Get-FileHash -LiteralPath $patchCopy -Algorithm SHA256).Hash.ToLowerInvariant() -cne $patchInfo.sha256){throw 'JARMOD_INPUT_COPY_HASH_MISMATCH'}
        [IO.File]::Copy($baseCopy,$outputTemp,$false)

        $baseNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($name in $baseInfo.fileEntries){$null=$baseNames.Add($name)}
        $conflicts=@($patchInfo.fileEntries|Where-Object{$baseNames.Contains($_)})
        if($conflicts.Count -and $PatchStrategy -eq 'OverlayRejectConflicts'){throw "JARMOD_ENTRY_CONFLICT: $($conflicts -join ',')"}
        $addedCount=$patchInfo.fileEntries.Count-$conflicts.Count;$replacedCount=$conflicts.Count
        $baseArchive=$null;$patchArchive=$null
        try{
            $outputStream=[IO.File]::Open($outputTemp,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try{
                $baseArchive=[IO.Compression.ZipArchive]::new($outputStream,[IO.Compression.ZipArchiveMode]::Update,$false)
                $patchArchive=[IO.Compression.ZipFile]::OpenRead($patchCopy)
                $actualPatchExpanded=0L
                foreach($patchEntry in $patchArchive.Entries){
                    if($patchEntry.FullName.EndsWith('/')){continue}
                    if($baseNames.Contains($patchEntry.FullName)){$existing=@($baseArchive.Entries|Where-Object FullName -CEQ $patchEntry.FullName);foreach($entry in $existing){$entry.Delete()}}
                    $newEntry=$baseArchive.CreateEntry($patchEntry.FullName,[IO.Compression.CompressionLevel]::Optimal)
                    $sourceStream=$patchEntry.Open();$targetStream=$newEntry.Open()
                    try{$actualPatchExpanded+=Copy-MmtlJarModEntryBounded -Source $sourceStream -Target $targetStream -RemainingBytes ($script:JarModMaxExpandedBytes-$actualPatchExpanded)}finally{$targetStream.Dispose();$sourceStream.Dispose()}
                }
            }finally{if($patchArchive){$patchArchive.Dispose()};if($baseArchive){$baseArchive.Dispose()};$outputStream.Dispose()}
        }catch{throw}
        [IO.File]::Move($outputTemp,$outputPath,$false)
        if((Get-FileHash -LiteralPath $basePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $baseInfo.sha256 -or (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $patchInfo.sha256){throw 'JARMOD_SOURCE_CHANGED_DURING_PATCH'}
        $outputInfo=Get-MmtlJarModArchiveInfo -Path $outputPath -Role 'Output'
        $relativeBase=Test-MmtlJarModPathWithinSession -SessionRoot $session -Path $baseCopy
        $relativePatch=Test-MmtlJarModPathWithinSession -SessionRoot $session -Path $patchCopy
        $relativeOutput=Test-MmtlJarModPathWithinSession -SessionRoot $session -Path $outputPath
        $plan=[ordered]@{schemaVersion=1;sessionId=$sessionCheck.sessionId;loaderId='JarMod';minecraftId=[string]$((Get-Content (Join-Path $session 'execution-plan.json') -Raw|ConvertFrom-Json).project.minecraftId);patchStrategy=$PatchStrategy;base=[ordered]@{sessionPath=$relativeBase;sha256=$baseInfo.sha256;bytes=$baseInfo.length};patch=[ordered]@{sessionPath=$relativePatch;sha256=$patchInfo.sha256;bytes=$patchInfo.length};output=[ordered]@{sessionPath=$relativeOutput;sha256=$outputInfo.sha256;bytes=$outputInfo.length};entryCounts=[ordered]@{base=$baseInfo.fileEntries.Count;patch=$patchInfo.fileEntries.Count;added=$addedCount;replaced=$replacedCount};patchApplied=$true;executePermission='Denied';sourcePathsRecorded=$false;createdUtc=[DateTimeOffset]::UtcNow.ToString('o')}
        $planPath=Join-Path $work 'jarmod-plan.json'
        Write-MmtlAtomicTextFile -Path $planPath -Content ((ConvertTo-Json -InputObject $plan -Depth 20)+"`n")
        $artifacts=[Collections.Generic.List[object]]::new();foreach($item in @($manifest.artifacts)){$artifacts.Add($item)}
        foreach($record in @(@{path=$relativeBase;sha256="sha256:$($baseInfo.sha256)";kind='JarModBaseCopy'},@{path=$relativePatch;sha256="sha256:$($patchInfo.sha256)";kind='JarModPatchCopy'},@{path=$relativeOutput;sha256="sha256:$($outputInfo.sha256)";kind='JarModOverlayOutput'},@{path=(Test-MmtlJarModPathWithinSession -SessionRoot $session -Path $planPath);sha256="sha256:$((Get-FileHash $planPath -Algorithm SHA256).Hash.ToLowerInvariant())";kind='JarModPlan'})){$artifacts.Add([pscustomobject]$record)}
        $manifest.artifacts=@($artifacts.ToArray());$manifest.updatedUtc=[DateTimeOffset]::UtcNow.ToString('o')
        Write-MmtlAtomicTextFile -Path $manifestPath -Content (($manifest|ConvertTo-Json -Depth 50)+"`n");$manifestUpdated=$true
        $finalCheck=Test-MmtlSessionV2 -SessionPath $session
        if(-not $finalCheck.valid){throw "JARMOD_SESSION_ARTIFACT_VALIDATION_FAILED: $($finalCheck.errors -join ',')"}
        return [pscustomobject][ordered]@{sessionId=$sessionCheck.sessionId;patchStrategy=$PatchStrategy;baseSha256=$baseInfo.sha256;patchSha256=$patchInfo.sha256;outputSha256=$outputInfo.sha256;baseCopyPath=$baseCopy;patchCopyPath=$patchCopy;outputPath=$outputPath;planPath=$planPath;entryCounts=$plan.entryCounts;patchApplied=$true;executePermission='Denied';sessionValid=$true}
    }catch{
        if($manifestUpdated -and $originalManifest){try{Write-MmtlAtomicTextFile -Path $manifestPath -Content $originalManifest}catch{}}
        if($work){Remove-MmtlJarModWorkDirectory -SessionRoot $session -WorkDirectory $work}
        throw
    }finally{Remove-MmtlSessionLock -Lock $lock}
}

Export-ModuleMember -Function New-MmtlJarModSessionOverlay
