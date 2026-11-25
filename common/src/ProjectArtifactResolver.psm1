function Get-MmtlProjectOutputArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)

    $projectRoot=[IO.Path]::GetFullPath([string]$Project.Root)
    if(-not(Test-Path -LiteralPath $projectRoot -PathType Container)){throw 'PROJECT_OUTPUT_ROOT_MISSING'}
    $projectItem=Get-Item -LiteralPath $projectRoot -Force
    if($projectItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'PROJECT_OUTPUT_ROOT_REPARSE'}
    $extension=if([string]$Project.Loader -ceq 'LiteLoader'){'.litemod'}else{'.jar'}
    $artifactDirectory=[IO.Path]::GetFullPath((Join-Path $projectRoot 'build/libs'))
    $prefix=$projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $artifactDirectory.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'PROJECT_OUTPUT_PATH_ESCAPE'}
    if(-not(Test-Path -LiteralPath $artifactDirectory -PathType Container)){throw 'PROJECT_OUTPUT_ARTIFACT_MISSING'}
    $directoryItem=Get-Item -LiteralPath $artifactDirectory -Force
    if($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'PROJECT_OUTPUT_DIRECTORY_REPARSE'}
    $candidates=@(Get-ChildItem -LiteralPath $artifactDirectory -File -Filter ('*'+$extension) -ErrorAction SilentlyContinue|Where-Object{$_.Name -notmatch '(?i)(sources|javadoc|dev)(?:[-.]|\.'+[regex]::Escape($extension.TrimStart('.'))+'$)'})
    if($candidates.Count -eq 0){throw "PROJECT_OUTPUT_ARTIFACT_MISSING:$extension"}
    $selected=$null;$selection='SingleCandidate'
    if($candidates.Count -eq 1){$selected=$candidates[0]}
    else{
        $ordered=@($candidates|Sort-Object LastWriteTimeUtc -Descending)
        if($ordered[0].LastWriteTimeUtc -eq $ordered[1].LastWriteTimeUtc){throw 'PROJECT_OUTPUT_ARTIFACT_AMBIGUOUS'}
        $selected=$ordered[0];$selection='NewestOutput'
    }
    if($selected.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'PROJECT_OUTPUT_ARTIFACT_REPARSE'}
    return [pscustomobject]@{path=[IO.Path]::GetFullPath($selected.FullName);extension=$extension;loader=[string]$Project.Loader;selection=$selection;lastWriteTimeUtc=$selected.LastWriteTimeUtc.ToUniversalTime().ToString('o')}
}

Export-ModuleMember -Function Get-MmtlProjectOutputArtifact
