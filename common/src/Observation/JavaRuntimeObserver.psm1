Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RuntimeEvents.psm1')
Import-Module (Join-Path $PSScriptRoot 'RuntimeEventStore.psm1')
Import-Module (Join-Path $PSScriptRoot 'ObservationSafety.psm1') -Force

function Get-MmtlJavaReleaseMetadata {
    param([Parameter(Mandatory)][string]$Executable)
    $home = Split-Path -Parent (Split-Path -Parent $Executable)
    $release = Join-Path $home 'release'
    $values = @{}
    if (Test-Path -LiteralPath $release -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($release)) { if ($line -match '^([A-Z0-9_]+)="?(.*?)"?$') { $values[$Matches[1]] = $Matches[2] } }
    }
    $version = if($values.ContainsKey('JAVA_VERSION')){[string]$values['JAVA_VERSION']}else{''}
    $major = $null
    if ($version -match '^(?:1\.)?(?<major>\d+)') { $major = [int]$Matches.major }
    $archValue=if($values.ContainsKey('OS_ARCH')){[string]$values['OS_ARCH']}else{''}
    $arch = switch -Regex ($archValue) { '^(amd64|x86_64|x64)$' {'x64'} '^(aarch64|arm64)$' {'ARM64'} default {$null} }
    $fingerprint = if (Test-Path -LiteralPath $Executable -PathType Leaf) { 'sha256:' + (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    return [pscustomobject]@{major=$major;exactVersion=$version;vendor=$(if($values.ContainsKey('IMPLEMENTOR')){[string]$values['IMPLEMENTOR']}else{$null});operatingSystem=$(if($values.ContainsKey('OS_NAME')){[string]$values['OS_NAME']}else{$null});architecture=$arch;fingerprint=$fingerprint}
}

function Test-MmtlSameExecutable {
    param([string]$Observed,[string]$Expected)
    if (-not $Observed -or -not $Expected) { return $false }
    try { $left=[IO.Path]::GetFullPath($Observed);$right=[IO.Path]::GetFullPath($Expected);return $left.Equals($right,[StringComparison]::OrdinalIgnoreCase) } catch { return $false }
}

function Invoke-MmtlJavaRuntimeObserver {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[scriptblock]$ProcessSnapshot,[scriptblock]$ProcessLookup,[scriptblock]$IdentityCheck)
    $session = [IO.Path]::GetFullPath($SessionPath); $sessionId = [IO.Path]::GetFileName($session)
    $registryPath = Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $session 'pids.json')
    $planPath = Resolve-MmtlObserverSafePath -SessionPath $session -Target (Join-Path $session 'execution-plan.json') -AllowMissing
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) { throw 'Session 缺少登记进程表。' }
    if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { return [pscustomobject]@{sessionId=$sessionId;runtimes=@();status='PLAN_UNAVAILABLE'} }
    if (-not $ProcessSnapshot) { $ProcessSnapshot = { param($processId) Get-MmtlProcessSnapshot -RootProcessId $processId } }
    if (-not $ProcessLookup) { $ProcessLookup = { param($processId) Get-MmtlProcessRecord -ProcessId $processId } }
    if (-not $IdentityCheck) { $IdentityCheck = { param($process,$record) Test-MmtlProcessIdentity -Process $process -Record $record } }
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $bindingMode = [string]$plan.runtimeJava.bindingMode
    $expectedPath = [string]$plan.runtimeJava.resolution.javaPath
    if ($bindingMode -eq 'SameAsBuildJvm') { $expectedPath = [string]$plan.buildJava.resolution.javaPath }
    $minecraftId = [string]$plan.project.loader.id
    $entries = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -ErrorAction Stop)
    $results = [Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        $root = & $ProcessLookup ([int]$entry.PID)
        if (-not $root -or -not (& $IdentityCheck $root $entry)) { continue }
        $snapshot = @(& $ProcessSnapshot ([int]$entry.PID))
        foreach ($candidate in $snapshot) {
            $executable = [string]$candidate.Executable
            if ([IO.Path]::GetFileName($executable) -notmatch '^(?i:javaw?)(?:\.exe)?$') { continue }
            $commandLine = [string]$candidate.CommandLine
            $isClient = $commandLine -match '(?i)(net\.minecraft\.client\.main\.Main|cpw\.mods\.bootstraplauncher\.BootstrapLauncher|net\.fabricmc\.loader\.impl\.launch\.knot\.KnotClient|org\.quiltmc\.loader\.impl\.launch\.knot\.KnotClient)'
            $isServer = $commandLine -match '(?i)(net\.minecraft\.server\.Main|cpw\.mods\.bootstraplauncher\.BootstrapLauncher.*server)'
            if (-not ($isClient -or $isServer)) { continue }
            $current = & $ProcessLookup ([int]$candidate.PID)
            if (-not $current -or -not (& $IdentityCheck $current $candidate)) { continue }
            $metadata = Get-MmtlJavaReleaseMetadata -Executable $executable
            $bindingMatch = Test-MmtlSameExecutable -Observed $executable -Expected $expectedPath
            $synthetic = if ($entry.PSObject.Properties['Rehearsal']) { [bool]$entry.Rehearsal } else { $false }
            $role = if ($isServer) { 'Server' } else { [string]$entry.Role }
            if ($role -notin @('Client','Host','Guest','Server')) { continue }
            $event = New-MmtlRuntimeEvent -SessionId $sessionId -Role $role -ProcessId ([int]$candidate.PID) -ProcessIdentity ([string]$candidate.StartIdentity) -SourceType Process -EventCode JAVA_RUNTIME_OBSERVED -Summary $(if($synthetic){'Dummy Java process evidence; not eligible for formal validation.'}else{'登记 Session 子树中的 Minecraft Java 进程运行时元数据。'}) -Metadata ([ordered]@{major=$metadata.major;exactVersion=$metadata.exactVersion;vendor=$metadata.vendor;operatingSystem=$metadata.operatingSystem;architecture=$metadata.architecture;bindingMode=$bindingMode;bindingMatch=$bindingMatch;executableFingerprint=$metadata.fingerprint;synthetic=$synthetic})
            $existing = @(Get-MmtlRuntimeEvents -SessionPath $session -SkipInvalidLines | Where-Object { [int]$_.pid -eq [int]$candidate.PID -and [string]$_.processIdentity -ceq [string]$candidate.StartIdentity -and [string]$_.eventCode -ceq 'JAVA_RUNTIME_OBSERVED' })
            if (-not $existing.Count) { Write-MmtlRuntimeEvent -SessionPath $session -Event $event | Out-Null }
            $results.Add([pscustomobject]@{pid=[int]$candidate.PID;role=$role;processIdentity=[string]$candidate.StartIdentity;major=$metadata.major;exactVersion=$metadata.exactVersion;vendor=$metadata.vendor;operatingSystem=$metadata.operatingSystem;architecture=$metadata.architecture;bindingMode=$bindingMode;bindingMatch=[bool]$bindingMatch;executableFingerprint=$metadata.fingerprint;synthetic=$synthetic})
        }
    }
    return [pscustomobject]@{sessionId=$sessionId;runtimes=@($results.ToArray());status=if($results.Count){'Observed'}else{'RUNTIME_PROCESS_NOT_OBSERVED'}}
}

Export-ModuleMember -Function Invoke-MmtlJavaRuntimeObserver,Get-MmtlJavaReleaseMetadata
