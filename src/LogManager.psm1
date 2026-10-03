Import-Module (Join-Path $PSScriptRoot 'RuntimeManager.psm1')

function New-MmtlLogPath {
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw '日志名称无效。' }
    $sessionsRoot=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'sessions'
    if (-not (Test-MmtlInsideRoot -Root $sessionsRoot -Target $SessionPath)) { throw '日志 Session 不在 Runtime Root 的 sessions 内。' }
    if ([IO.Path]::GetFullPath((Split-Path $SessionPath -Parent)) -ne [IO.Path]::GetFullPath($sessionsRoot)) { throw '日志 Session 必须是 sessions 的直接子目录。' }
    $logs=Join-Path $SessionPath 'logs'; New-Item -ItemType Directory -Path $logs -Force | Out-Null
    return Join-Path $logs "$Name.log"
}
Export-ModuleMember -Function New-MmtlLogPath
