function Get-MmtlGradleCommand {
    param([Parameter(Mandatory)]$Project,[ValidateSet('build','runClient','runServer')][string]$Task='build',[switch]$Clean)
    $wrapper=Join-Path $Project.Root 'gradlew.bat'
    if (-not (Test-Path $wrapper)) { throw '项目缺少 Gradle Wrapper。' }
    $tasks=if($Clean -and $Task -eq 'build'){@('clean','build')}else{@($Task)}
    return [pscustomobject]@{ File=$wrapper; Arguments=@('--no-daemon')+$tasks; WorkingDirectory=$Project.Root }
}
Export-ModuleMember -Function Get-MmtlGradleCommand
