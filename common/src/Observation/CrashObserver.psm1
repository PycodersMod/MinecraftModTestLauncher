Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimeEvents.psm1')
Import-Module (Join-Path $PSScriptRoot 'RuntimeEventStore.psm1')
$script:MmtlCrashSafetyModule=Import-Module (Join-Path $PSScriptRoot 'ObservationSafety.psm1') -PassThru
function Resolve-MmtlCrashSafePath {param([string]$Session,[string]$Target,[switch]$AllowMissing)return & $script:MmtlCrashSafetyModule {param($s,$t,$missing)Resolve-MmtlObserverSafePath -SessionPath $s -Target $t -AllowMissing:$missing} $Session $Target $AllowMissing.IsPresent}

function Invoke-MmtlCrashObserver {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=[IO.Path]::GetFullPath($SessionPath);$sessionId=[IO.Path]::GetFileName($session)
    $registryPath=Resolve-MmtlCrashSafePath -Session $session -Target (Join-Path $session 'pids.json')
    $entries=@(Get-Content -LiteralPath $registryPath -Raw|ConvertFrom-Json -ErrorAction Stop)
    $events=@(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines)
    $classifications=[Collections.Generic.List[object]]::new()
    foreach($entry in $entries){
        $role=[string]$entry.Role;$runtimeProperty=$entry.PSObject.Properties['RuntimeDirectory'];$runtime=if($runtimeProperty){[string]$runtimeProperty.Value}else{''}
        $crashPresent=$false
        if($runtime){$crashDirectory=Join-Path $runtime 'crash-reports';if(Test-Path -LiteralPath $crashDirectory -PathType Container){$crashDirectory=Resolve-MmtlCrashSafePath -Session $session -Target $crashDirectory;$crashPresent=@(Get-ChildItem -LiteralPath $crashDirectory -File -Filter 'crash-*.txt' -ErrorAction Stop).Count -gt 0}}
        $statePath=Join-Path $session "process-$([int]$entry.PID).exit.json";$statePath=Resolve-MmtlCrashSafePath -Session $session -Target $statePath -AllowMissing
        $exit=$null;if(Test-Path -LiteralPath $statePath -PathType Leaf){$exit=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -ErrorAction Stop}
        $started=@($events|Where-Object{[int]$_.pid -eq [int]$entry.PID -and [string]$_.eventCode -eq 'PROCESS_STARTED'}).Count -gt 0
        $initialized=@($events|Where-Object{[int]$_.pid -eq [int]$entry.PID -and [string]$_.eventCode -in @('CLIENT_INIT_DETECTED','CLIENT_LAUNCH_VERIFIED')}).Count -gt 0
        $code=$null
        if($crashPresent){$code=if($role -eq 'Server'){'SERVER_CRASH'}elseif($role -in @('Client','Host','Guest')){'CLIENT_CRASH'}else{'CRASH_DETECTED'}}
        elseif($exit -and -not [bool]$exit.StopRequested -and $null -ne $exit.ExitCode -and [int]$exit.ExitCode -ne 0){
            if($role -eq 'Build'){$code='BUILD_FAILED'}elseif($role -in @('Client','Host','Guest')){$code=if($initialized){'CLIENT_CRASH'}else{'CLIENT_EXITED_BEFORE_INITIALIZATION'}}elseif($role -eq 'Server'){$code='SERVER_CRASH'}else{$code='PROCESS_START_FAILED'}
        }
        if($code){
            $eventCodes=@($code);if($code -in @('CLIENT_CRASH','SERVER_CRASH')){$eventCodes+='CRASH_DETECTED'}
            foreach($eventCode in $eventCodes){
                if(-not @($events|Where-Object{[int]$_.pid -eq [int]$entry.PID -and [string]$_.processIdentity -ceq [string]$entry.StartIdentity -and [string]$_.eventCode -ceq $eventCode}).Count){
                    $event=New-MmtlRuntimeEvent -SessionId $sessionId -Role $role -ProcessId ([int]$entry.PID) -ProcessIdentity ([string]$entry.StartIdentity) -SourceType $(if($crashPresent){'CrashReport'}else{'Process'}) -EventCode $eventCode -Summary "Session 登记的 $role 角色失败分类：$eventCode。"
                    Write-MmtlRuntimeEvent -SessionPath $session -Event $event|Out-Null;$events+=$event
                }
            }
            $classifications.Add([pscustomobject]@{pid=[int]$entry.PID;role=$role;code=$code;crashReportPresent=[bool]$crashPresent;processStarted=[bool]$started;clientInitialized=[bool]$initialized})
        }
    }
    return [pscustomobject]@{sessionId=$sessionId;classifications=@($classifications.ToArray());observedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
}

Export-ModuleMember -Function Invoke-MmtlCrashObserver
