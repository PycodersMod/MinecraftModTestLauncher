function New-MmtlSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)]$Metadata)
    if ($Name -notmatch '^[A-Za-z0-9_-]{1,40}$') { throw 'Session 名称只允许字母、数字、下划线和短横线。' }
    $sessions=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'sessions'
    $id=(Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')+'_'+$Name+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $path=Join-Path $sessions $id
    New-Item -ItemType Directory -Path (Join-Path $path 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $path 'mods') -Force | Out-Null
    $hostName=if($Metadata.hostUsername){[string]$Metadata.hostUsername}else{'Dev'}
    $clientPrefix=if($Metadata.clientPrefix){[string]$Metadata.clientPrefix}else{'Dev_'}
    $players=@($hostName)
    for($i=1;$i -lt [int]$Metadata.players;$i++){$players+=("$clientPrefix$i")}
    foreach($player in $players){New-Item -ItemType Directory -Path (Join-Path $path $player) -Force | Out-Null}
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1');$platform=Get-MmtlPlatformProvider
    if($Metadata -is [System.Collections.IDictionary]){$Metadata['platform']=$platform.OS;$Metadata['arch']=$platform.Arch;$Metadata['isWSL']=$platform.IsWSL}else{$Metadata|Add-Member -NotePropertyName platform -NotePropertyValue $platform.OS -Force;$Metadata|Add-Member -NotePropertyName arch -NotePropertyValue $platform.Arch -Force;$Metadata|Add-Member -NotePropertyName isWSL -NotePropertyValue $platform.IsWSL -Force}
    $record=[ordered]@{sessionId=$id;createdUtc=(Get-Date).ToUniversalTime().ToString('o');metadata=$Metadata;players=$players;ports=@();processes=@()}
    $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $path 'session.json') -Encoding utf8
    '[]' | Set-Content -LiteralPath (Join-Path $path 'pids.json') -Encoding utf8
    "# Session $id`n`n状态：已创建`n" | Set-Content -LiteralPath (Join-Path $path 'report.md') -Encoding utf8
    return $path
}
function Update-MmtlSessionReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=[IO.Path]::GetFullPath($SessionPath);Assert-MmtlNoReparsePath -Path $session|Out-Null
    $statePath=Join-Path $session 'session.json';$pidPath=Join-Path $session 'pids.json';$reportPath=Join-Path $session 'report.md'
    if(-not(Test-Path -LiteralPath $statePath) -or -not(Test-Path -LiteralPath $pidPath)){throw 'Session 缺少 session.json 或 pids.json。'}
    $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json;$entries=@(Get-Content -LiteralPath $pidPath -Raw|ConvertFrom-Json);$statuses=[Collections.Generic.List[object]]::new()
    Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1');Import-Module (Join-Path $PSScriptRoot 'ProcessManager.psm1');$platform=Get-MmtlPlatformProvider
    foreach($entry in $entries){
        $statusPath=if($entry.StatePath){[string]$entry.StatePath}else{Join-Path $session "process-$([int]$entry.PID).exit.json"};$processState='ExitedUnknown';$exitCode=$null;$finished=$null;$errorMessage=$null
        if(Test-Path -LiteralPath $statusPath){$exit=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json;$exitCode=if($null -eq $exit.ExitCode){$null}else{[int]$exit.ExitCode};$finished=[string]$exit.FinishedUtc;$errorMessage=[string]$exit.Error;$processState=if($exit.StopRequested){'StoppedByUser'}elseif($exitCode -eq 0){'Completed'}else{'Failed'}}
        else{
            $current=if($platform.ProcessManagement -eq 'Native'){Get-MmtlProcessRecord -ProcessId ([int]$entry.PID)}else{$null}
            $same=if($current){Test-MmtlProcessIdentity -Process $current -Record $entry}else{$false}
            if($same){$processState='Running'}
            elseif($current){$processState='PIDReused'}
            elseif($entry.LogPath){$logText='';foreach($candidateLog in @([string]$entry.LogPath,([string]$entry.LogPath+'.err'))){if(Test-Path -LiteralPath $candidateLog){$logText+=(Get-Content -LiteralPath $candidateLog -Tail 12000 -ErrorAction SilentlyContinue)-join "`n"}};if($logText -match '(?im)^BUILD FAILED'){ $processState='Failed';$errorMessage='Gradle logs report BUILD FAILED; exact wrapper exit code was not recorded.'}elseif($logText -match '(?im)^BUILD SUCCESSFUL'){$processState='Completed';$exitCode=0}}
        }
        $entry|Add-Member -NotePropertyName Status -NotePropertyValue $processState -Force
        $entry|Add-Member -NotePropertyName ExitCode -NotePropertyValue $exitCode -Force
        $entry|Add-Member -NotePropertyName FinishedUtc -NotePropertyValue $finished -Force
        $entry|Add-Member -NotePropertyName Error -NotePropertyValue $errorMessage -Force
        $statuses.Add([pscustomobject]@{PID=[int]$entry.PID;Role=[string]$entry.Role;Username=[string]$entry.Username;Status=$processState;ExitCode=$exitCode;FinishedUtc=$finished;Error=$errorMessage;LogPath=[string]$entry.LogPath})
    }
    $processLines=@($statuses|ForEach-Object{"- PID $($_.PID) $($_.Role) $($_.Username): $($_.Status); exit=$($_.ExitCode); log=$($_.LogPath)";if($_.Error){"  - Error: $($_.Error)"}})
    $crashes=@(Get-ChildItem -LiteralPath $session -Directory -Recurse -Filter 'crash-reports' -ErrorAction SilentlyContinue|ForEach-Object{Get-ChildItem -LiteralPath $_.FullName -File -Filter 'crash-*.txt' -ErrorAction SilentlyContinue}|Select-Object -ExpandProperty FullName)
    $base='# Session '+[string]$state.sessionId
    if(Test-Path -LiteralPath $reportPath){$old=Get-Content -LiteralPath $reportPath -Raw;$base=($old -split '(?m)^## (?:Processes|Process Results)\s*$',2)[0].TrimEnd()}
    $body=@($base,'','## Process Results')+$processLines+@('','## Crash Reports')
    if($crashes.Count){$body+=@($crashes|ForEach-Object{"- $_"})}else{$body+='- None detected.'}
    Set-Content -LiteralPath $reportPath -Value $body -Encoding utf8
    Write-MmtlPidRegistry -Path $pidPath -Entries $entries
    $state|Add-Member -NotePropertyName processStatuses -NotePropertyValue @($statuses) -Force
    if($state.metadata){$state.metadata|Add-Member -NotePropertyName processes -NotePropertyValue @($statuses) -Force}
    $state|Add-Member -NotePropertyName crashReports -NotePropertyValue $crashes -Force
    $state|Add-Member -NotePropertyName reportUpdatedUtc -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    $state|ConvertTo-Json -Depth 30|Set-Content -LiteralPath $statePath -Encoding utf8
    $overall=if($crashes.Count -or @($statuses|Where-Object Status -eq 'Failed').Count){'Failed'}elseif(@($statuses|Where-Object Status -eq 'Running').Count){'Running'}elseif($statuses.Count -and @($statuses|Where-Object Status -eq 'StoppedByUser').Count){'Stopped'}elseif($statuses.Count -and @($statuses|Where-Object Status -eq 'Completed').Count -eq $statuses.Count){'Completed'}else{'ExitedUnknown'}
    [pscustomobject]@{SessionPath=$session;Status=$overall;Processes=@($statuses);CrashReports=$crashes;ReportPath=$reportPath}
}
Export-ModuleMember -Function New-MmtlSession,Update-MmtlSessionReport
