function Assert-MmtlCompatible {
    param([Parameter(Mandatory)][object[]]$Projects)
    if ($Projects.Count -lt 1) { throw '至少需要一个项目。' }
    $first=$Projects[0]
    foreach($project in $Projects | Select-Object -Skip 1) {
        if (-not $first.MinecraftVersion -or $project.MinecraftVersion -ne $first.MinecraftVersion) { throw '多项目 Minecraft 版本不兼容或无法确认。' }
        if ($project.Loader -ne $first.Loader) { throw '多项目 Loader 不兼容。' }
        if(-not $first.LoaderVersion -or -not $project.LoaderVersion){throw '多项目 Loader 版本无法确认。'}
        if($project.LoaderVersion -ne $first.LoaderVersion){throw '多项目 Loader 版本不一致。'}
        if (-not $project.JavaMajor -or $project.JavaMajor -ne $first.JavaMajor) { throw '多项目 Java 要求不兼容或无法确认。' }
    }
    return $true
}
Export-ModuleMember -Function Assert-MmtlCompatible
