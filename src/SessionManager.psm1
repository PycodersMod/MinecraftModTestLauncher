function New-MmtlSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)]$Metadata)
    if ($Name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw 'Session 名称只允许字母、数字、下划线和短横线。' }
    $sessions=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'sessions'
    $id=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')+'_'+$Name
    $path=Join-Path $sessions $id
    New-Item -ItemType Directory -Path (Join-Path $path 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $path 'mods') -Force | Out-Null
    $players=@('Dev')
    1..([Math]::Max(0,[int]$Metadata.players-1)) | ForEach-Object {$players += "Dev_$_"}
    foreach($player in $players){New-Item -ItemType Directory -Path (Join-Path $path $player) -Force | Out-Null}
    $record=[ordered]@{sessionId=$id;createdUtc=(Get-Date).ToUniversalTime().ToString('o');metadata=$Metadata;players=$players;ports=@();processes=@()}
    $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $path 'session.json') -Encoding utf8
    '[]' | Set-Content -LiteralPath (Join-Path $path 'pids.json') -Encoding utf8
    "# Session $id`n`n状态：已创建`n" | Set-Content -LiteralPath (Join-Path $path 'report.md') -Encoding utf8
    return $path
}
Export-ModuleMember -Function New-MmtlSession
