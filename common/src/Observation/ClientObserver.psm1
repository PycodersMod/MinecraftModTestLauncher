Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimeEvents.psm1')
Import-Module (Join-Path $PSScriptRoot 'RuntimeEventStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'AuthenticationObserver.psm1')
$script:MmtlClientSafetyModule = Import-Module (Join-Path $PSScriptRoot 'ObservationSafety.psm1') -PassThru
$script:MmtlClientJavaModule = Import-Module (Join-Path $PSScriptRoot 'JavaRuntimeObserver.psm1') -PassThru
function Assert-MmtlObserverNoReparsePath { param([string]$SessionPath,[string]$Target) return & $script:MmtlClientSafetyModule {param($s,$t) Resolve-MmtlObserverSafePath -SessionPath $s -Target $t} $SessionPath $Target }
function Test-MmtlClientJavaExecutable { param([string]$Observed,[string]$Expected) return & $script:MmtlClientJavaModule {param($o,$e) Test-MmtlSameExecutable -Observed $o -Expected $e} $Observed $Expected }

function Invoke-MmtlClientObserver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$MarkerHints,
        [ValidateSet('Client','Host','Guest')][string[]]$Roles=@('Client','Host','Guest'),
        [scriptblock]$ProcessLookup,
        [scriptblock]$ProcessSnapshot,
        [scriptblock]$IdentityCheck,
        [switch]$Rehearsal
    )
    $session = [IO.Path]::GetFullPath($SessionPath)
    $sessionId = [IO.Path]::GetFileName($session)
    $registry = Join-Path $session 'pids.json'
    if (-not (Test-Path -LiteralPath $registry -PathType Leaf)) { throw 'Session 缺少登记进程表。' }
    $registry = Assert-MmtlObserverNoReparsePath -SessionPath $session -Target $registry
    $lookupInjected = [bool]$ProcessLookup
    if (-not $ProcessLookup) { $ProcessLookup = { param($processId) Get-MmtlProcessRecord -ProcessId $processId } }
    if (-not $ProcessSnapshot -and -not $lookupInjected) { $ProcessSnapshot = { param($processId) Get-MmtlProcessSnapshot -RootProcessId $processId } }
    if (-not $IdentityCheck) { $IdentityCheck = { param($process,$entry) Test-MmtlProcessIdentity -Process $process -Record $entry } }
    $entries = @(Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json -ErrorAction Stop | Where-Object { [string]$_.Role -in $Roles })
    $events = @(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines)
    $observations = [Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $runtimeProperty = $entry.PSObject.Properties['RuntimeDirectory']
        $runtime = if ($runtimeProperty) { [string]$runtimeProperty.Value } else { '' }
        if (-not $runtime) { $observations.Add([pscustomobject]@{pid=[int]$entry.PID;role=[string]$entry.Role;status='RuntimeDirectoryUnavailable';initDetected=$false;mainMenuDetected=$false;crashDetected=$false;validationEligible=$false});continue }
        $runtime = Assert-MmtlObserverNoReparsePath -SessionPath $session -Target $runtime
        $logPath = Join-Path $runtime 'logs/latest.log'
        $markerPath = Join-Path $runtime 'mmtl-session.id'
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) { $markerPath = Assert-MmtlObserverNoReparsePath -SessionPath $session -Target $markerPath }
        $markerValid = (Test-Path -LiteralPath $markerPath -PathType Leaf) -and ((Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim() -ceq $sessionId)
        $logLines = @()
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $logPath = Assert-MmtlObserverNoReparsePath -SessionPath $session -Target $logPath
            $logLines = @(Get-Content -LiteralPath $logPath -Tail 4000 -ErrorAction Stop)
        }
        $joined = $logLines -join "`n"
        $initDetected = $false
        $mainMenuDetected = $false
        foreach ($hint in $MarkerHints) {
            if ([string]$hint.eventCode -notin @('CLIENT_INIT_DETECTED','CLIENT_MAIN_MENU_DETECTED')) { continue }
            try { $matched = [regex]::IsMatch($joined,[string]$hint.pattern,[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromMilliseconds(150)) } catch { $matched = $false }
            if ($matched) {
                $initDetected = $initDetected -or ([string]$hint.eventCode -eq 'CLIENT_INIT_DETECTED')
                $mainMenuDetected = $mainMenuDetected -or ([string]$hint.eventCode -eq 'CLIENT_MAIN_MENU_DETECTED')
                $seen = @($events | Where-Object { [int]$_.pid -eq [int]$entry.PID -and [string]$_.processIdentity -ceq [string]$entry.StartIdentity -and [string]$_.eventCode -ceq [string]$hint.eventCode }).Count -gt 0
                if (-not $seen) {
                    $event = New-MmtlRuntimeEvent -SessionId $sessionId -Role ([string]$entry.Role) -ProcessId ([int]$entry.PID) -ProcessIdentity ([string]$entry.StartIdentity) -SourceType RuntimeLog -EventCode ([string]$hint.eventCode) -Summary ([string]$hint.description)
                    Write-MmtlRuntimeEvent -SessionPath $session -Event $event | Out-Null
                    $events += $event
                }
            }
        }
        $authState = Get-MmtlAuthenticationObservation -SessionPath $session -SessionId $sessionId -Role ([string]$entry.Role) -ProcessId ([int]$entry.PID) -ProcessIdentity ([string]$entry.StartIdentity) -Text $joined
        $crashDirectory = Join-Path $runtime 'crash-reports'
        $crashDetected = $false
        if (Test-Path -LiteralPath $crashDirectory -PathType Container) {
            $crashDirectory = Assert-MmtlObserverNoReparsePath -SessionPath $session -Target $crashDirectory
            $crashDetected = @(Get-ChildItem -LiteralPath $crashDirectory -File -Filter 'crash-*.txt' -ErrorAction Stop).Count -gt 0
        }
        $currentProcess = & $ProcessLookup ([int]$entry.PID)
        $identityValid = $currentProcess -and (& $IdentityCheck $currentProcess $entry)
        $tree = if($ProcessSnapshot -and $identityValid){@(& $ProcessSnapshot ([int]$entry.PID))}elseif($identityValid){@($currentProcess)}else{@()}
        $javaClientProcess = $null
        foreach($candidate in $tree){
            $executableName = [IO.Path]::GetFileName([string]$candidate.Executable)
            $candidateCommand = [string]$candidate.CommandLine
            if($executableName -notmatch '^(?i:javaw?)(?:\.exe)?$' -or $candidateCommand -notmatch '(?i)(net\.minecraft\.client\.main\.Main|cpw\.mods\.bootstraplauncher\.BootstrapLauncher|net\.fabricmc\.loader\.impl\.launch\.knot\.KnotClient|org\.quiltmc\.loader\.impl\.launch\.knot\.KnotClient)'){continue}
            $candidatePidProperty = $candidate.PSObject.Properties['PID']; $candidatePid = if($candidatePidProperty){[int]$candidate.PID}else{[int]$candidate.ProcessId}
            $currentCandidate = & $ProcessLookup $candidatePid
            if($currentCandidate -and (& $IdentityCheck $currentCandidate $candidate)){$javaClientProcess=$candidate;break}
        }
        $bindingMatch = $false
        $planPath = Join-Path $session 'execution-plan.json'
        if($javaClientProcess -and (Test-Path -LiteralPath $planPath -PathType Leaf)){
            $planPath=Assert-MmtlObserverNoReparsePath -SessionPath $session -Target $planPath
            $plan=Get-Content -LiteralPath $planPath -Raw|ConvertFrom-Json -ErrorAction Stop
            $expectedJava=[string]$plan.runtimeJava.resolution.javaPath
            if([string]$plan.runtimeJava.bindingMode -eq 'SameAsBuildJvm'){$expectedJava=[string]$plan.buildJava.resolution.javaPath}
            if($expectedJava){$bindingMatch=Test-MmtlClientJavaExecutable -Observed ([string]$javaClientProcess.Executable) -Expected $expectedJava}
        }
        $rehearsalSession = $Rehearsal.IsPresent
        if ($entry.PSObject.Properties['Rehearsal']) { $rehearsalSession = $rehearsalSession -or [bool]$entry.Rehearsal }
        $eligible = [bool]($identityValid -and $javaClientProcess -and $bindingMatch -and $markerValid -and $initDetected -and -not $rehearsalSession)
        $clientProcessId = if($javaClientProcess -and $javaClientProcess.PSObject.Properties['PID']){[int]$javaClientProcess.PID}elseif($javaClientProcess){[int]$javaClientProcess.ProcessId}else{0}
        $clientIdentity = if($javaClientProcess){[string]$javaClientProcess.StartIdentity}else{''}
        if ($eligible -and -not @($events | Where-Object { [int]$_.pid -eq $clientProcessId -and [string]$_.processIdentity -ceq $clientIdentity -and [string]$_.eventCode -ceq 'CLIENT_LAUNCH_VERIFIED' }).Count) {
            $verified = New-MmtlRuntimeEvent -SessionId $sessionId -Role ([string]$entry.Role) -ProcessId $clientProcessId -ProcessIdentity $clientIdentity -SourceType Observer -EventCode CLIENT_LAUNCH_VERIFIED -Summary '登记的 Minecraft Java 子进程、Runtime Java binding、当前 Session marker 与客户端初始化 marker 均匹配。'
            Write-MmtlRuntimeEvent -SessionPath $session -Event $verified | Out-Null
        }
        $status = if ($crashDetected) { 'CrashDetected' } elseif ($initDetected) { 'Initialized' } elseif ($logLines.Count) { 'ProcessStarted' } else { 'LogUnavailable' }
        $observations.Add([pscustomobject]@{pid=[int]$entry.PID;role=[string]$entry.Role;status=$status;initDetected=[bool]$initDetected;mainMenuDetected=[bool]$mainMenuDetected;crashDetected=[bool]$crashDetected;authentication=$authState.code;observedClientProcessId=if($clientProcessId){$clientProcessId}else{$null};javaBindingMatch=[bool]$bindingMatch;validationEligible=$eligible})
    }
    return [pscustomobject]@{sessionId=$sessionId;clients=@($observations.ToArray());observedUtc=[DateTimeOffset]::UtcNow.ToString('o')}
}

Export-ModuleMember -Function Invoke-MmtlClientObserver
