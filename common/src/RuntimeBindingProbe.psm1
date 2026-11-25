Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Adapters/RuntimeBinding.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RunTaskJvmBinding.psm1') -Force

function Get-MmtlProbeProperty {
    param([AllowNull()]$InputObject,[Parameter(Mandatory)][string]$Name,$Default=$null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) { if ([string]$key -ieq $Name) { return $InputObject[$key] } }
        return $Default
    }
    $property=$InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Test-MmtlProbePathInsideRoot {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Target)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $targetFull=[IO.Path]::GetFullPath($Target).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if ($targetFull.Equals($rootFull,[StringComparison]::OrdinalIgnoreCase)) { return $true }
    $relative=[IO.Path]::GetRelativePath($rootFull,$targetFull)
    return -not ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $relative.StartsWith('..'+[IO.Path]::AltDirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))
}

function Test-MmtlProbePathHasReparsePoint {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Target)
    $relative=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root),[IO.Path]::GetFullPath($Target))
    $current=[IO.Path]::GetFullPath($Root)
    if ((Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
    foreach($part in ($relative -split '[\\/]' | Where-Object { $_ -and $_ -ne '.' })) {
        if($part -eq '..'){return $true}
        $current=Join-Path $current $part
        if(Test-Path -LiteralPath $current){if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){return $true}}
    }
    return $false
}

function Get-MmtlProbeDirectoryIdentity {
    param([Parameter(Mandatory)][string]$Path,[string[]]$TrustedRoots=@())
    $root=[IO.Path]::GetFullPath($Path)
    if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'RUNTIME_BINDING_MIRROR_UNAVAILABLE'}
    $trusted=$false
    foreach($trustedRootValue in $TrustedRoots){
        if([string]::IsNullOrWhiteSpace($trustedRootValue)){continue}
        $trustedRoot=[IO.Path]::GetFullPath($trustedRootValue)
        if((Test-MmtlProbePathInsideRoot -Root $trustedRoot -Target $root) -and -not(Test-MmtlProbePathHasReparsePoint -Root $trustedRoot -Target $root)){$trusted=$true;break}
    }
    if(-not $trusted){throw 'RUNTIME_BINDING_MIRROR_NOT_TRUSTED'}
    $entries=@(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)
    if(@($entries|Where-Object{($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0}).Count){throw 'RUNTIME_BINDING_MIRROR_REPARSE_POINT'}
    $files=@($entries|Where-Object{!$_.PSIsContainer}|Sort-Object -Property FullName)
    if(-not $files.Count){throw 'RUNTIME_BINDING_MIRROR_EMPTY'}
    $inventory=[Collections.Generic.List[string]]::new()
    foreach($file in $files){
        $relative=[IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
        $sha=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $inventory.Add($relative+"`0"+[string]$file.Length+"`0"+$sha)
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes(($inventory -join "`n"))
    $sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    [pscustomobject]@{root=$root;sha256=$sha256;fileCount=$files.Count}
}

function ConvertTo-MmtlProbeDynamicVersionPins {
    param([AllowNull()][object[]]$Pins=@())
    $normalized=[Collections.Generic.List[object]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pinCandidates=@($Pins|Where-Object{$null -ne $_})
    if(-not $pinCandidates.Count){return}
    foreach($pin in $pinCandidates){
        $group=[string](Get-MmtlProbeProperty $pin 'group' '')
        $artifact=[string](Get-MmtlProbeProperty $pin 'artifact' '')
        $selector=[string](Get-MmtlProbeProperty $pin 'selector' '')
        $version=[string](Get-MmtlProbeProperty $pin 'version' '')
        if($group -notmatch '^[A-Za-z0-9_.-]+$' -or $artifact -notmatch '^[A-Za-z0-9_.-]+$' -or $selector -notmatch '^[0-9]+(?:\.[0-9]+)*\.\+$' -or $version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$' -or $version.Contains('+')){throw 'RUNTIME_BINDING_DYNAMIC_VERSION_PIN_INVALID'}
        $key=$group+':'+$artifact+':'+$selector
        if(-not $seen.Add($key)){throw 'RUNTIME_BINDING_DYNAMIC_VERSION_PIN_DUPLICATE'}
        $normalized.Add([pscustomobject][ordered]@{group=$group;artifact=$artifact;selector=$selector;version=$version})
    }
    return @($normalized.ToArray()|Sort-Object group,artifact,selector)
}

function Get-MmtlProbeGitState {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $shaText=& git -C $ProjectRoot rev-parse --verify HEAD 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($shaText -join ''))){return [pscustomobject]@{isGitRepository=$false;sha=$null;dirty=$true}}
    $status=& git -C $ProjectRoot status --porcelain=v1 --untracked-files=all 2>$null
    if($LASTEXITCODE -ne 0){throw 'RUNTIME_BINDING_GIT_STATUS_FAILED: 无法读取项目工作树状态。'}
    [pscustomobject]@{isGitRepository=$true;sha=([string]($shaText -join '')).Trim();dirty=(@($status).Count -gt 0)}
}

function Get-MmtlProbeCacheIdentity {
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$GitState,[AllowNull()]$LocalMavenMirrorIdentity=$null,[object[]]$PinnedDynamicVersionResolutions=@())
    $buildResolution=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'buildJava') 'resolution'
    $runtimeRequirement=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtimeJava') 'requirement'
    $runtimeResolution=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtimeJava') 'resolution'
    $sourceFingerprint=Get-MmtlRunTaskJvmBindingSourceFingerprint
    $buildJavaHome=[string](Get-MmtlProbeProperty $buildResolution 'javaHome' '')
    if(-not $buildJavaHome){$buildJavaHome=[string](Get-MmtlProbeProperty $buildResolution 'home' '')}
    $toolchain=Get-MmtlProbeProperty $Project 'Toolchain';$buildSystem=Get-MmtlProbeProperty $Project 'BuildSystem';$platform=Get-MmtlProbeProperty $Plan 'platform'
    $projectRoot=[IO.Path]::GetFullPath([string](Get-MmtlProbeProperty $Project 'Root' ''))
    $roles=@(Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtime') 'roles' @())
    $requiredTasks=@($roles|ForEach-Object{if([string](Get-MmtlProbeProperty $_ 'role' '') -eq 'Server'){'runServer'}else{'runClient'}}|Select-Object -Unique|Sort-Object)
    if(-not $requiredTasks.Count){$requiredTasks=@('runClient')}
    [ordered]@{
        schemaVersion=1;projectRoot=$projectRoot;projectSha=[string]$GitState.sha
        toolchainId=[string](Get-MmtlProbeProperty $toolchain 'id' 'Unknown');toolchainVersion=[string](Get-MmtlProbeProperty $toolchain 'version' '')
        buildSystemId=[string](Get-MmtlProbeProperty $buildSystem 'id' 'Unknown');buildSystemVersion=[string](Get-MmtlProbeProperty $buildSystem 'version' '');loader=[string](Get-MmtlProbeProperty $Project 'Loader' 'Unknown')
        loaderVersion=[string](Get-MmtlProbeProperty $Project 'LoaderVersion' '');minecraft=[string](Get-MmtlProbeProperty $Project 'MinecraftVersion' '')
        platformOs=[string](Get-MmtlProbeProperty $platform 'os' 'Unknown');platformArch=[string](Get-MmtlProbeProperty $platform 'arch' 'Unknown')
        buildJavaHome=$buildJavaHome;buildJavaMajor=[string](Get-MmtlProbeProperty $buildResolution 'actualMajor' '')
        runtimeJavaMajor=[string](Get-MmtlProbeProperty $runtimeRequirement 'major' '')
        runtimeJavaResolvedMajor=[string](Get-MmtlProbeProperty $runtimeResolution 'actualMajor' '')
        runtimeJavaPath=[string](Get-MmtlProbeProperty $runtimeResolution 'javaPath' '')
        runtimeJavaKind=[string](Get-MmtlProbeProperty $runtimeRequirement 'requirementKind' '')
        runtimeJavaSource=[string](Get-MmtlProbeProperty $runtimeRequirement 'source' '');runTaskJvmBindingSourceSha256=$sourceFingerprint.sha256;requiredTasks=@($requiredTasks);localMavenMirrorPath=[string](Get-MmtlProbeProperty $LocalMavenMirrorIdentity 'root' '');localMavenMirrorSha256=[string](Get-MmtlProbeProperty $LocalMavenMirrorIdentity 'sha256' '');pinnedDynamicVersionResolutions=@($PinnedDynamicVersionResolutions);adapterVersion='9'
    }
}

function Get-MmtlCachedRuntimeBindingEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$RuntimeRoot,[string]$LocalMavenMirrorPath,[string[]]$TrustedProjectRoots=@(),[object[]]$PinnedDynamicVersionResolutions=@())
    $projectRoot=[IO.Path]::GetFullPath([string](Get-MmtlProbeProperty $Project 'Root' ''))
    $state=Get-MmtlProbeGitState -ProjectRoot $projectRoot
    if(-not $state.isGitRepository -or $state.dirty){return $null}
    $mirrorIdentity=$null
    if($LocalMavenMirrorPath){$mirrorIdentity=Get-MmtlProbeDirectoryIdentity -Path $LocalMavenMirrorPath -TrustedRoots $TrustedProjectRoots}
    $versionPins=ConvertTo-MmtlProbeDynamicVersionPins -Pins $PinnedDynamicVersionResolutions
    $identity=Get-MmtlProbeCacheIdentity -Project $Project -Plan $Plan -GitState $state -LocalMavenMirrorIdentity $mirrorIdentity -PinnedDynamicVersionResolutions $versionPins
    $cacheBytes=[Text.Encoding]::UTF8.GetBytes(($identity|ConvertTo-Json -Compress -Depth 8))
    $expectedKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cacheBytes)).ToLowerInvariant()
    $cachePath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "diagnostics/runtime-binding/$expectedKey.json"
    if(-not(Test-Path -LiteralPath $cachePath -PathType Leaf)){return $null}
    if((Get-Item -LiteralPath $cachePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){return $null}
    try{$item=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{return $null}
    if([string]$item.cacheKey -cne $expectedKey -or [string]$item.projectRoot -cne $projectRoot -or [string]$item.projectSha -cne [string]$state.sha -or $item.dirty -ne $false -or [string]$item.status -eq 'ProbeFailed' -or -not $item.runtimeJavaBinding){return $null}
    $item.cacheHit=$true
    return $item
}

function New-MmtlRuntimeBindingAdapterEvidenceFromFreshProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$ProbeResult)

    if([string](Get-MmtlProbeProperty $ProbeResult 'status' '') -cne 'Observed'){throw 'RUNTIME_BINDING_FRESH_PROBE_NOT_OBSERVED'}
    if((Get-MmtlProbeProperty $ProbeResult 'cacheHit' $false) -ne $false){throw 'RUNTIME_BINDING_FRESH_PROBE_CACHE_HIT'}
    $timestampText=[string](Get-MmtlProbeProperty $ProbeResult 'timestamp' '')
    $timestamp=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse($timestampText,[ref]$timestamp)){throw 'RUNTIME_BINDING_FRESH_PROBE_TIMESTAMP_INVALID'}
    $age=[DateTimeOffset]::UtcNow-$timestamp.ToUniversalTime()
    if($age.TotalMinutes -gt 15 -or $age.TotalMinutes -lt -2){throw 'RUNTIME_BINDING_FRESH_PROBE_STALE'}

    $expectedRoot=[IO.Path]::GetFullPath([string](Get-MmtlProbeProperty $Project 'Root' ''))
    $observedRoot=[IO.Path]::GetFullPath([string](Get-MmtlProbeProperty $ProbeResult 'projectRoot' ''))
    $expectedMinecraft=[string](Get-MmtlProbeProperty $Project 'MinecraftVersion' '')
    $expectedLoader=[string](Get-MmtlProbeProperty $Project 'Loader' '')
    $expectedLoaderVersion=[string](Get-MmtlProbeProperty $Project 'LoaderVersion' '')
    if(-not $expectedRoot -or -not $observedRoot -or -not $observedRoot.Equals($expectedRoot,[StringComparison]::OrdinalIgnoreCase) -or
       [string](Get-MmtlProbeProperty $ProbeResult 'minecraft' '') -cne $expectedMinecraft -or
       [string](Get-MmtlProbeProperty $ProbeResult 'loader' '') -cne $expectedLoader -or
       [string](Get-MmtlProbeProperty $ProbeResult 'loaderVersion' '') -cne $expectedLoaderVersion){throw 'RUNTIME_BINDING_FRESH_PROBE_IDENTITY_MISMATCH'}

    $binding=Get-MmtlProbeProperty $ProbeResult 'runtimeJavaBinding'
    if(-not $binding -or [string](Get-MmtlProbeProperty $binding 'confidence' '') -cne 'High' -or
       [string](Get-MmtlProbeProperty $binding 'evidenceSource' '') -cne 'GradleInitScriptJavaExecInspection'){
        throw 'RUNTIME_BINDING_FRESH_PROBE_CONFIDENCE_INSUFFICIENT'
    }
    $buildResolution=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'buildJava') 'resolution'
    $runtimeRequirement=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtimeJava') 'requirement'
    $runtimeResolution=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtimeJava') 'resolution'
    $expectedBuildMajor=[string](Get-MmtlProbeProperty $buildResolution 'actualMajor' '')
    $observedBuildMajor=[string](Get-MmtlProbeProperty $ProbeResult 'buildJavaMajor' '')
    $expectedRuntimeMajor=[string](Get-MmtlProbeProperty $runtimeRequirement 'major' '')
    $observedRuntimeMajor=[string](Get-MmtlProbeProperty (Get-MmtlProbeProperty $ProbeResult 'runtimeJavaRequirement') 'major' '')
    if(-not $expectedBuildMajor -or $observedBuildMajor -cne $expectedBuildMajor -or
       -not $expectedRuntimeMajor -or $observedRuntimeMajor -cne $expectedRuntimeMajor){throw 'RUNTIME_BINDING_FRESH_PROBE_JAVA_IDENTITY_MISMATCH'}

    $roles=@(Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtime') 'roles' @())
    if(-not $roles.Count){$requiredTasks=@('runClient')}else{$requiredTasks=@($roles|ForEach-Object{if([string](Get-MmtlProbeProperty $_ 'role' '') -eq 'Server'){'runServer'}else{'runClient'}}|Select-Object -Unique)}
    $details=@(Get-MmtlProbeProperty $binding 'evidenceDetails' @())
    foreach($taskName in $requiredTasks){
        $taskEvidence=@($details|Where-Object{[string](Get-MmtlProbeProperty $_ 'task' '') -ceq $taskName -and [string](Get-MmtlProbeProperty $_ 'taskType' '') -ceq 'JavaExec' -and -not [string]::IsNullOrWhiteSpace([string](Get-MmtlProbeProperty $_ 'executable' '')) -and -not [string]::IsNullOrWhiteSpace([string](Get-MmtlProbeProperty $_ 'launcherSource' ''))})
        if(-not $taskEvidence.Count){throw 'RUNTIME_BINDING_FRESH_PROBE_ROLE_TASK_MISSING'}
    }

    $mode=[string](Get-MmtlProbeProperty $binding 'mode' '')
    if($mode -ceq 'Direct'){
        if((Get-MmtlProbeProperty $binding 'runtimeJavaControllable' $false) -ne $true){throw 'RUNTIME_BINDING_FRESH_PROBE_DIRECT_CONTROL_UNPROVEN'}
        $expectedExecutable=[string](Get-MmtlProbeProperty $runtimeResolution 'javaPath' '')
        if(-not $expectedExecutable){throw 'RUNTIME_BINDING_FRESH_PROBE_RUNTIME_PATH_UNAVAILABLE'}
        $expectedExecutable=[IO.Path]::GetFullPath($expectedExecutable)
        foreach($taskName in $requiredTasks){
            $taskEvidence=@($details|Where-Object{[string](Get-MmtlProbeProperty $_ 'task' '') -ceq $taskName})|Select-Object -First 1
            $observedExecutable=[IO.Path]::GetFullPath([string](Get-MmtlProbeProperty $taskEvidence 'executable' ''))
            if(-not $observedExecutable.Equals($expectedExecutable,[StringComparison]::OrdinalIgnoreCase)){throw 'RUNTIME_BINDING_FRESH_PROBE_RUNTIME_PATH_MISMATCH'}
        }
    } elseif($mode -ceq 'SameAsBuildJvm'){
        if((Get-MmtlProbeProperty $binding 'requiresBuildJvmMatch' $false) -ne $true -or $expectedBuildMajor -cne $expectedRuntimeMajor){throw 'RUNTIME_BINDING_FRESH_PROBE_BUILD_RUNTIME_MISMATCH'}
    } else {throw 'RUNTIME_BINDING_FRESH_PROBE_MODE_UNSUPPORTED'}

    [pscustomobject][ordered]@{runtimeJavaBindingMode=$mode;runtimeJavaBindingEvidence=$binding}
}

function New-MmtlRuntimeBindingGradleInitScript {
    param([Parameter(Mandatory)][int]$RuntimeJavaMajor,[string]$LocalMavenMirrorPath,[object[]]$PinnedDynamicVersionResolutions=@())
    $bindingScript=New-MmtlRunTaskJvmBindingInitScript -RuntimeJavaMajor $RuntimeJavaMajor
    $effectivePins=@($PinnedDynamicVersionResolutions|Where-Object{$null -ne $_})
    $observer=@'
def mmtlObservedRuntimeTasks = []
gradle.projectsEvaluated {
    gradle.rootProject.allprojects.each { project ->
        project.tasks.configureEach { task ->
            def taskName = task.name
            if (taskName in ['runClient', 'runServer']) {
                def isJavaExec = task instanceof org.gradle.api.tasks.JavaExec
                def record = [task: taskName, taskPath: task.path, taskType: task.class.name, isJavaExec: isJavaExec]
                if (isJavaExec) {
                    try {
                        def launcher = task.javaLauncher.orNull
                        if (launcher != null) {
                            record.launcherSource = 'javaLauncher'
                            record.executable = launcher.executablePath.asFile.absolutePath
                        }
                    } catch (Throwable ignored) { }
                    if (!record.executable && task.executable) {
                        record.launcherSource = 'executable'
                        record.executable = task.executable.toString()
                    }
                    if (record.executable) {
                        def expected = new File(System.getenv('MMTL_RUNTIME_JAVA_EXECUTABLE')).canonicalFile
                        def observed = new File(record.executable).canonicalFile
                        if (observed != expected) {
                            throw new GradleException('MMTL_RUNTIME_LAUNCHER_MISMATCH:' + observed)
                        }
                    }
                }
                mmtlObservedRuntimeTasks << record
                println('MMTL_RUNTIME_BINDING_JSON:' + groovy.json.JsonOutput.toJson([tasks: mmtlObservedRuntimeTasks, buildJavaHome: System.getProperty('java.home'), buildJavaVersion: System.getProperty('java.version')]))
            }
        }
    }
}
'@
    $mirrorSetup=@'
def mmtlPinnedMirrorPath = System.getenv('MMTL_RUNTIME_BINDING_MAVEN_MIRROR')
if (mmtlPinnedMirrorPath) {
    gradle.beforeProject { project ->
        project.repositories.maven { repository ->
            repository.name = 'mmtlPinnedMavenMirror'
            repository.url = project.uri(new File(mmtlPinnedMirrorPath))
            repository.metadataSources {
                mavenPom()
                artifact()
            }
        }
    }
}
'@
    $versionPinSetup=''
    if($effectivePins.Count){
        $json=ConvertTo-Json -InputObject $effectivePins -Depth 8 -Compress
        $versionPinSetup=@"
def mmtlPinnedDynamicVersionResolutions = new groovy.json.JsonSlurper().parseText('$json')
gradle.beforeProject { project ->
    project.configurations.all {
        resolutionStrategy.eachDependency { details ->
            def pin = mmtlPinnedDynamicVersionResolutions.find { candidate -> candidate.group == details.requested.group && candidate.artifact == details.requested.name && candidate.selector == details.requested.version }
            if (pin != null) {
                details.useVersion(pin.version)
                details.because('MMTL exact target catalog pin for dynamic selector ' + pin.selector)
            }
        }
    }
}
"@
    }
    return $bindingScript + [Environment]::NewLine + $(if($LocalMavenMirrorPath){$mirrorSetup+[Environment]::NewLine}else{''}) + $versionPinSetup + [Environment]::NewLine + $observer
}

function Invoke-MmtlRuntimeBindingGradle {
    param([Parameter(Mandatory)]$Request)
    $wrapper=[string]$Request.wrapperPath
    $javaHome=[string]$Request.javaHome
    if(-not $javaHome -or -not (Test-Path -LiteralPath (Join-Path $javaHome ('bin/'+$(if($IsWindows -or $env:OS -eq 'Windows_NT'){'java.exe'}else{'java'}))) -PathType Leaf)){
        return [pscustomobject]@{exitCode=1;output=@('RUNTIME_BINDING_BUILD_JAVA_UNAVAILABLE: Plan 中解析的 Build Java 不可用。')}
    }
    $childScript='$ErrorActionPreference="Stop"; $a=[string[]]($env:MMTL_BINDING_PROBE_ARGS | ConvertFrom-Json); Push-Location -LiteralPath $env:MMTL_BINDING_PROBE_PROJECT; try { if($IsWindows -or $env:OS -eq "Windows_NT"){ & $env:MMTL_BINDING_PROBE_WRAPPER @a } else { $i=Get-Item -LiteralPath $env:MMTL_BINDING_PROBE_WRAPPER -Force; if(($i.UnixFileMode -band [IO.UnixFileMode]::UserExecute) -eq 0 -and ($i.UnixFileMode -band [IO.UnixFileMode]::GroupExecute) -eq 0 -and ($i.UnixFileMode -band [IO.UnixFileMode]::OtherExecute) -eq 0){ & sh $env:MMTL_BINDING_PROBE_WRAPPER @a } else { & (Join-Path "." ([IO.Path]::GetFileName($env:MMTL_BINDING_PROBE_WRAPPER))) @a } }; exit $LASTEXITCODE } finally { Pop-Location }'
    $pwsh=(Get-Process -Id $PID).Path
    $info=[Diagnostics.ProcessStartInfo]::new($pwsh)
    $info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.CreateNoWindow=$true
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-Command',$childScript)){$info.ArgumentList.Add([string]$argument)}
    $info.WorkingDirectory=[string]$Request.projectRoot
    $info.Environment['MMTL_BINDING_PROBE_WRAPPER']=$wrapper
    $info.Environment['MMTL_BINDING_PROBE_PROJECT']=[string]$Request.projectRoot
    $info.Environment['MMTL_BINDING_PROBE_ARGS']=ConvertTo-Json -InputObject ([string[]]$Request.arguments) -Compress
    $runtimeJavaHome=[string]$Request.runtimeJavaHome
    $runtimeJavaExecutable=[string]$Request.runtimeJavaExecutable
    $runtimeJavaMajor=[string]$Request.runtimeJavaMajor
    if(-not $runtimeJavaHome -or -not $runtimeJavaExecutable -or -not $runtimeJavaMajor){throw 'RUNTIME_BINDING_RUNTIME_JAVA_UNAVAILABLE'}
    $info.Environment['JAVA_HOME']=$javaHome
    $pathSeparator=[IO.Path]::PathSeparator
    $info.Environment['PATH']=(Join-Path $javaHome 'bin')+$pathSeparator+$env:PATH
    $info.Environment['MMTL_RUNTIME_JAVA_HOME']=$runtimeJavaHome
    $info.Environment['MMTL_RUNTIME_JAVA_EXECUTABLE']=$runtimeJavaExecutable
    $info.Environment['MMTL_RUNTIME_JAVA_MAJOR']=$runtimeJavaMajor
    $info.Environment['MMTL_RUNTIME_BINDING_MAVEN_MIRROR']=[string](Get-MmtlProbeProperty $Request 'localMavenMirrorPath' '')
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    if(-not $process.Start()){return [pscustomobject]@{exitCode=1;output=@('RUNTIME_BINDING_GRADLE_START_FAILED: 无法启动受信任项目的 Gradle Wrapper。')}}
    $timeoutSeconds=[int](Get-MmtlProbeProperty $Request 'timeoutSeconds' 300)
    if($timeoutSeconds -lt 1 -or $timeoutSeconds -gt 7200){$timeoutSeconds=300}
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $timedOut=-not $process.WaitForExit($timeoutSeconds*1000)
    $terminationError=$null
    if($timedOut){
        try{$process.Kill($true)}catch{$terminationError=$_.Exception.Message}
        $null=$process.WaitForExit(5000)
    }
    $readTasks=[Threading.Tasks.Task[]]@($stdout,$stderr)
    $streamsCompleted=$false
    try{$streamsCompleted=[Threading.Tasks.Task]::WaitAll($readTasks,5000)}catch{}
    $combined=@()
    if($streamsCompleted){$combined=@(($stdout.Result -split "`r?`n")+($stderr.Result -split "`r?`n")|Where-Object{$_})}
    else{$combined+='RUNTIME_BINDING_GRADLE_OUTPUT_DRAIN_TIMEOUT: redirected streams did not close after process exit.'}
    if($timedOut){
        $combined+=('RUNTIME_BINDING_GRADLE_TIMEOUT: exceeded {0} seconds.' -f $timeoutSeconds)
        if($terminationError){$combined+=('RUNTIME_BINDING_GRADLE_TREE_STOP_FAILED: '+$terminationError)}
    }
    $exitCode=if($timedOut){124}else{[int]$process.ExitCode}
    [pscustomobject]@{exitCode=$exitCode;timedOut=$timedOut;timeoutSeconds=$timeoutSeconds;output=$combined}
}

function Resolve-MmtlProbeJavaHome {
    param([AllowNull()][string]$Executable)
    if([string]::IsNullOrWhiteSpace($Executable)){return $null}
    $path=$Executable.Trim()
    if($path -match '^(?i)<JAVA_HOME>') { return '<JAVA_HOME>' }
    if(-not [IO.Path]::IsPathRooted($path)){return $null}
    try {
        $full=[IO.Path]::GetFullPath($path)
        $bin=Split-Path -Parent $full
        if((Split-Path -Leaf $bin) -ieq 'bin'){return (Split-Path -Parent $bin)}
        return $bin
    } catch { return $null }
}

function Test-MmtlProbeSameJavaHome {
    param([AllowNull()][string]$RuntimeExecutable,[AllowNull()][string]$BuildJavaHome)
    $runtimeHome=Resolve-MmtlProbeJavaHome -Executable $RuntimeExecutable
    if(-not $runtimeHome -or -not $BuildJavaHome){return $false}
    if($runtimeHome -eq '<JAVA_HOME>' -and $BuildJavaHome -eq '<JAVA_HOME>'){return $true}
    try {
        $runtimePath=[IO.Path]::GetFullPath($runtimeHome).TrimEnd('\','/')
        $buildPath=[IO.Path]::GetFullPath($BuildJavaHome).TrimEnd('\','/')
        if([IO.Path]::GetFileName($buildPath).Equals('jre',[StringComparison]::OrdinalIgnoreCase)){$buildPath=[IO.Path]::GetDirectoryName($buildPath).TrimEnd('\','/')}
        return $runtimePath.Equals($buildPath,[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Test-MmtlProbeBuildJavaMatchesPlan {
    param([AllowNull()][string]$ObservedBuildJavaHome,[AllowNull()][string]$ObservedBuildJavaVersion,[AllowNull()]$BuildResolution)
    $expectedHome=[string](Get-MmtlProbeProperty $BuildResolution 'javaHome' '')
    if(-not $expectedHome){$expectedHome=[string](Get-MmtlProbeProperty $BuildResolution 'home' '')}
    if(-not $expectedHome){$javaPath=[string](Get-MmtlProbeProperty $BuildResolution 'javaPath' '');if($javaPath){$expectedHome=Resolve-MmtlProbeJavaHome -Executable $javaPath}}
    if(-not $expectedHome -or -not $ObservedBuildJavaHome -or -not $ObservedBuildJavaVersion){return $false}
    $expectedMajor=[int](Get-MmtlProbeProperty $BuildResolution 'actualMajor' 0);$versionText=$ObservedBuildJavaVersion.Trim();$versionMajor=0
    if($versionText -match '^1\.(?<legacy>\d+)'){$versionMajor=[int]$Matches.legacy}elseif($versionText -match '^(?<major>\d+)'){$versionMajor=[int]$Matches.major}else{return $false}
    if($expectedMajor -le 0 -or $versionMajor -ne $expectedMajor){return $false}
    if($expectedHome.StartsWith('<') -or $ObservedBuildJavaHome.StartsWith('<')){return $expectedHome -ceq $ObservedBuildJavaHome}
    try{
        $expectedPath=[IO.Path]::GetFullPath($expectedHome).TrimEnd('\','/')
        $observedPath=[IO.Path]::GetFullPath($ObservedBuildJavaHome).TrimEnd('\','/')
        if($expectedPath.Equals($observedPath,[StringComparison]::OrdinalIgnoreCase)){return $true}
        if([IO.Path]::GetFileName($observedPath).Equals('jre',[StringComparison]::OrdinalIgnoreCase)){
            $jreParent=[IO.Path]::GetDirectoryName($observedPath).TrimEnd('\','/')
            return $expectedPath.Equals($jreParent,[StringComparison]::OrdinalIgnoreCase)
        }
        return $false
    }catch{return $false}
}

function Invoke-MmtlRuntimeBindingProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [string[]]$TrustedProjectRoots=@(),
        [string]$LocalMavenMirrorPath,
        [switch]$Offline,
        [scriptblock]$GradleInvoker,
        [ValidateRange(1,7200)][int]$GradleTimeoutSeconds=300,
        [object[]]$PinnedDynamicVersionResolutions=@()
    )

    $projectRoot=[IO.Path]::GetFullPath([string](Get-MmtlProbeProperty $Project 'Root' ''))
    $trusted=$false
    foreach($trustedRootValue in $TrustedProjectRoots){
        if([string]::IsNullOrWhiteSpace($trustedRootValue)){continue}
        $trustedRoot=[IO.Path]::GetFullPath($trustedRootValue)
        if((Test-MmtlProbePathInsideRoot -Root $trustedRoot -Target $projectRoot) -and -not (Test-MmtlProbePathHasReparsePoint -Root $trustedRoot -Target $projectRoot)){$trusted=$true;break}
    }
    if(-not $trusted){throw 'RUNTIME_BINDING_PROJECT_NOT_TRUSTED: Gradle probe 只允许当前 portfolio 或受信任 fixture。'}

    $mirrorIdentity=$null
    if($LocalMavenMirrorPath){$mirrorIdentity=Get-MmtlProbeDirectoryIdentity -Path $LocalMavenMirrorPath -TrustedRoots $TrustedProjectRoots}
    $versionPins=ConvertTo-MmtlProbeDynamicVersionPins -Pins $PinnedDynamicVersionResolutions

    $wrapper=[string](Get-MmtlProbeProperty $Project 'WrapperPath' '')
    if(-not $wrapper){$wrapper=Join-Path $projectRoot $(if($IsWindows -or $env:OS -eq 'Windows_NT'){'gradlew.bat'}else{'gradlew'})}
    $wrapper=[IO.Path]::GetFullPath($wrapper)
    if(-not (Test-MmtlProbePathInsideRoot -Root $projectRoot -Target $wrapper) -or -not (Test-Path -LiteralPath $wrapper -PathType Leaf)){
        $binding=New-MmtlRuntimeBindingEvidence -AdapterId ([string](Get-MmtlProbeProperty (Get-MmtlProbeProperty $Project 'Toolchain') 'id' 'Unknown')) -Mode Unknown -ProbeStrategy 'GradleJavaExecTaskInspection' -ReasonCode 'RUNTIME_BINDING_GRADLE_WRAPPER_UNAVAILABLE'
        return [pscustomobject][ordered]@{status='WrapperUnavailable';runtimeJavaBinding=$binding;evidenceDetails=@();cacheKey=$null;cacheHit=$false;dirty=$true;errorCode='RUNTIME_BINDING_GRADLE_WRAPPER_UNAVAILABLE';observedTasks=@()}
    }

    $gitState=Get-MmtlProbeGitState -ProjectRoot $projectRoot
    $toolchain=Get-MmtlProbeProperty $Project 'Toolchain'
    $buildSystem=Get-MmtlProbeProperty $Project 'BuildSystem'
    $loader=[string](Get-MmtlProbeProperty $Project 'Loader' 'Unknown')
    $minecraft=[string](Get-MmtlProbeProperty $Project 'MinecraftVersion' '')
    $platform=Get-MmtlProbeProperty $Plan 'platform'
    $buildResolution=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'buildJava') 'resolution'
    $buildJavaHome=[string](Get-MmtlProbeProperty $buildResolution 'javaHome' '')
    if(-not $buildJavaHome){$buildJavaHome=[string](Get-MmtlProbeProperty $buildResolution 'home' '')}
    $buildJavaMajor=[string](Get-MmtlProbeProperty $buildResolution 'actualMajor' '')
    $runtimeRequirement=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtimeJava') 'requirement'
    $runtimeResolution=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtimeJava') 'resolution'
    $runtimeJavaExecutable=[string](Get-MmtlProbeProperty $runtimeResolution 'javaPath' '')
    $runtimeJavaMajor=[int](Get-MmtlProbeProperty $runtimeResolution 'actualMajor' (Get-MmtlProbeProperty $runtimeRequirement 'major' 0))
    if(-not $runtimeJavaExecutable -and $runtimeJavaMajor -gt 0 -and $runtimeJavaMajor -eq [int]$buildJavaMajor){
        $runtimeJavaExecutable=Join-Path $buildJavaHome ('bin/'+$(if($IsWindows -or $env:OS -eq 'Windows_NT'){'java.exe'}else{'java'}))
    }
    if(-not $runtimeJavaExecutable -or $runtimeJavaMajor -lt 1){
        $binding=New-MmtlRuntimeBindingEvidence -AdapterId ([string](Get-MmtlProbeProperty $toolchain 'id' 'Unknown')) -Mode Unknown -ProbeStrategy 'GradleJavaExecTaskInspection' -ReasonCode 'RUNTIME_BINDING_RUNTIME_JAVA_UNAVAILABLE'
        return [pscustomobject][ordered]@{status='Unresolved';runtimeJavaBinding=$binding;evidenceDetails=@();cacheKey=$null;cacheHit=$false;dirty=[bool]$gitState.dirty;errorCode='RUNTIME_BINDING_RUNTIME_JAVA_UNAVAILABLE';observedTasks=@()}
    }
    $runtimeJavaHome=Split-Path (Split-Path $runtimeJavaExecutable -Parent) -Parent
    $cacheIdentity=Get-MmtlProbeCacheIdentity -Project $Project -Plan $Plan -GitState $gitState -LocalMavenMirrorIdentity $mirrorIdentity -PinnedDynamicVersionResolutions $versionPins
    $cacheBytes=[Text.Encoding]::UTF8.GetBytes(($cacheIdentity|ConvertTo-Json -Compress -Depth 8))
    $cacheKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cacheBytes)).ToLowerInvariant()
    $cacheDirectory=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'diagnostics/runtime-binding'
    $cachePath=Join-Path $cacheDirectory ($cacheKey+'.json')
    if(-not $gitState.dirty -and (Test-Path -LiteralPath $cachePath -PathType Leaf)){
        try {
            $cached=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json -ErrorAction Stop
            if($cached.cacheKey -eq $cacheKey -and $cached.dirty -eq $false -and [string]$cached.status -ne 'ProbeFailed'){$cached.cacheHit=$true;return $cached}
        } catch { }
    }

    New-Item -ItemType Directory -Path $cacheDirectory -Force|Out-Null
    $initScript=Join-Path $cacheDirectory ('probe-'+[guid]::NewGuid().ToString('N')+'.gradle')
    $initContents=New-MmtlRuntimeBindingGradleInitScript -RuntimeJavaMajor $runtimeJavaMajor -LocalMavenMirrorPath $LocalMavenMirrorPath -PinnedDynamicVersionResolutions $versionPins
    [IO.File]::WriteAllText($initScript,$initContents,[Text.UTF8Encoding]::new($false))
    $roleNames=@(Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtime') 'roles' @()|ForEach-Object{[string](Get-MmtlProbeProperty $_ 'role' '')})
    if(-not $roleNames.Count){$roleNames=@('Client')}
    $requiredTasks=@($roleNames|ForEach-Object{if($_ -eq 'Server'){'runServer'}else{'runClient'}}|Select-Object -Unique)
    try {
        # Init-script callbacks may be skipped when Gradle reuses a configuration-cache entry.
        # Gradle introduced configuration caching in 6.6; older wrappers reject its CLI flag.
        $arguments=@('--no-daemon')
        $gradleVersion=[string](Get-MmtlProbeProperty $buildSystem 'version' '')
        $versionMatch=[regex]::Match($gradleVersion,'(?<!\d)(?<major>\d+)\.(?<minor>\d+)(?:\.\d+)?')
        if(-not $versionMatch.Success){
            $wrapperProperties=Join-Path $projectRoot 'gradle/wrapper/gradle-wrapper.properties'
            if(Test-Path -LiteralPath $wrapperProperties -PathType Leaf){
                $distributionLine=Get-Content -LiteralPath $wrapperProperties | Where-Object { $_ -match '^\s*distributionUrl\s*=' } | Select-Object -Last 1
                if($distributionLine -and $distributionLine -match 'gradle-(?<version>\d+(?:\.\d+){1,2})-(?:bin|all)\.zip(?:\\|$|\?)'){
                    $gradleVersion=$Matches.version
                    $versionMatch=[regex]::Match($gradleVersion,'(?<!\d)(?<major>\d+)\.(?<minor>\d+)(?:\.\d+)?')
                }
            }
        }
        if($versionMatch.Success){
            $gradleFeatureVersion=[version]::new([int]$versionMatch.Groups['major'].Value,[int]$versionMatch.Groups['minor'].Value)
            if($gradleFeatureVersion -ge [version]'6.6'){$arguments+='--no-configuration-cache'}
        }
        $arguments+=@('--init-script',$initScript)
        $arguments=@("-Dorg.gradle.java.installations.paths=$runtimeJavaHome")+$arguments
        if($Offline){$arguments+='--offline'}
        # A Gradle dry-run realizes only the selected launch tasks and their
        # graph, allowing lazy JavaExec properties to be inspected without
        # executing Minecraft or unrelated task providers.
        $arguments+=@('--dry-run')+$requiredTasks
        $request=[pscustomobject]@{projectRoot=$projectRoot;wrapperPath=$wrapper;arguments=$arguments;offline=[bool]$Offline;javaHome=$buildJavaHome;runtimeJavaHome=$runtimeJavaHome;runtimeJavaExecutable=$runtimeJavaExecutable;runtimeJavaMajor=$runtimeJavaMajor;localMavenMirrorPath=[string](Get-MmtlProbeProperty $mirrorIdentity 'root' '');localMavenMirrorSha256=[string](Get-MmtlProbeProperty $mirrorIdentity 'sha256' '');pinnedDynamicVersionResolutions=@($versionPins);timeoutSeconds=$GradleTimeoutSeconds}
        if($GradleInvoker){$invocation=& $GradleInvoker $request}
        else{$invocation=Invoke-MmtlRuntimeBindingGradle -Request $request}
    } finally {
        if(Test-Path -LiteralPath $initScript -PathType Leaf){Remove-Item -LiteralPath $initScript -Force}
    }

    $output=@(Get-MmtlProbeProperty $invocation 'output' @()|ForEach-Object{[string]$_})
    $exitCode=[int](Get-MmtlProbeProperty $invocation 'exitCode' 1)
    $timedOut=[bool](Get-MmtlProbeProperty $invocation 'timedOut' $false)
    $marker=@($output|Where-Object{$_ -like 'MMTL_RUNTIME_BINDING_JSON:*'}|Select-Object -Last 1)
    $observed=$null
    if($marker.Count){try{$observed=$marker[0].Substring('MMTL_RUNTIME_BINDING_JSON:'.Length)|ConvertFrom-Json -ErrorAction Stop}catch{}}
    $observedTasks=if($observed){@($observed.tasks)}else{@()}
    $selected=@($observedTasks|Where-Object{[string]$_.task -in @('runClient','runServer')})
    $missingTasks=@($requiredTasks|Where-Object{$_ -notin @($selected|ForEach-Object{[string]$_.task})})
    $runtimeEvidence=@()
    $binding=$null
    $status='Observed'
    $reason='RUNTIME_BINDING_TASK_ABSENT'
    if($timedOut){$status='ProbeFailed';$reason='RUNTIME_BINDING_GRADLE_TIMEOUT'}
    elseif($exitCode -ne 0 -or -not $observed){$status='ProbeFailed';$reason='RUNTIME_BINDING_GRADLE_PROBE_FAILED'}
    elseif($selected.Count -eq 0){$status='TaskNotFound'}
    elseif($missingTasks.Count){$status='Unresolved';$reason='RUNTIME_BINDING_ROLE_TASK_UNAVAILABLE'}
    elseif(-not (Test-MmtlProbeBuildJavaMatchesPlan -ObservedBuildJavaHome ([string]$observed.buildJavaHome) -ObservedBuildJavaVersion ([string]$observed.buildJavaVersion) -BuildResolution $buildResolution)){$status='Unresolved';$reason='RUNTIME_BINDING_BUILD_JVM_MISMATCH'}
    else {
        foreach($task in @($selected|Where-Object{[string]$_.task -in $requiredTasks})){
            if($task.isJavaExec -ne $true -or [string]::IsNullOrWhiteSpace([string]$task.executable)){$status='Unresolved';$reason='RUNTIME_BINDING_FINAL_LAUNCHER_UNOBSERVED';continue}
            $mode=if(Test-MmtlProbeSameJavaHome -RuntimeExecutable ([string]$task.executable) -BuildJavaHome ([string]$observed.buildJavaHome)){'SameAsBuildJvm'}else{'Direct'}
            $runtimeEvidence+=New-MmtlRuntimeBindingEvidence -AdapterId ([string](Get-MmtlProbeProperty $toolchain 'id' 'Unknown')) -Mode $mode -EvidenceSource 'GradleInitScriptJavaExecInspection' -Confidence High -RuntimeJavaControllable:($mode -eq 'Direct') -RequiresBuildJvmMatch:($mode -eq 'SameAsBuildJvm') -ProbeStrategy 'GradleJavaExecTaskInspection' -ReasonCode '' -EvidenceDetails @([pscustomobject][ordered]@{task=[string]$task.task;taskType='JavaExec';executable=[string]$task.executable;launcherSource=[string]$task.launcherSource;buildJavaHome=[string]$observed.buildJavaHome;buildJavaVersion=[string]$observed.buildJavaVersion})
        }
        if($runtimeEvidence.Count -and @($runtimeEvidence|ForEach-Object mode|Select-Object -Unique).Count -gt 1){
            $binding=Resolve-MmtlRuntimeBinding -Evidence $runtimeEvidence
            $status='ConflictingTasks';$reason='RUNTIME_BINDING_EVIDENCE_CONFLICT'
        } elseif($runtimeEvidence.Count){$binding=Resolve-MmtlRuntimeBinding -Evidence $runtimeEvidence;$reason=[string]$binding.reasonCode}
    }
    if(-not $binding){$binding=New-MmtlRuntimeBindingEvidence -AdapterId ([string](Get-MmtlProbeProperty $toolchain 'id' 'Unknown')) -Mode Unknown -EvidenceSource $(if($observed){'GradleInitScriptJavaExecInspection'}else{''}) -Confidence Unknown -ProbeStrategy 'GradleJavaExecTaskInspection' -ReasonCode $reason -EvidenceDetails @($selected)}

    $diagnosticSummary=$null
    if($status -eq 'ProbeFailed'){
        $diagnosticLines=@($output|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}|Select-Object -Last 12)
        $diagnosticSummary=($diagnosticLines -join ' | ')
        foreach($privatePath in @($projectRoot,$buildJavaHome,[IO.Path]::GetFullPath($RuntimeRoot))|Where-Object{$_}){$diagnosticSummary=$diagnosticSummary.Replace([string]$privatePath,'<LOCAL_PATH>')}
        $diagnosticSummary=[regex]::Replace($diagnosticSummary,'(?i)(password|token|authorization|secret)(\s*[=:]\s*)\S+','$1$2<REDACTED>')
        if($diagnosticSummary.Length -gt 1600){$diagnosticSummary=$diagnosticSummary.Substring(0,1600)}
    }
    $taskNames=@($observedTasks|ForEach-Object{[string]$_.task})
    $observedBuildJavaHome=[string](Get-MmtlProbeProperty $observed 'buildJavaHome' '')
    $observedBuildJavaVersion=[string](Get-MmtlProbeProperty $observed 'buildJavaVersion' '')
    $result=[pscustomobject][ordered]@{schemaVersion=1;status=$status;projectRoot=$projectRoot;runtimeJavaBinding=$binding;evidenceDetails=@($binding.evidenceDetails);cacheKey=$cacheKey;cacheHit=$false;dirty=[bool]$gitState.dirty;projectSha=$gitState.sha;buildJavaHome=$buildJavaHome;buildJavaMajor=$buildJavaMajor;observedBuildJavaHome=$observedBuildJavaHome;observedBuildJavaVersion=$observedBuildJavaVersion;runtimeJavaRequirement=$runtimeRequirement;toolchain=$cacheIdentity.toolchainId;toolchainVersion=$cacheIdentity.toolchainVersion;buildSystem=$cacheIdentity.buildSystemId;buildSystemVersion=$cacheIdentity.buildSystemVersion;adapterVersion=$cacheIdentity.adapterVersion;localMavenMirror=$mirrorIdentity;pinnedDynamicVersionResolutions=@($versionPins);loader=$loader;loaderVersion=$cacheIdentity.loaderVersion;minecraft=$minecraft;platform=[pscustomobject]@{os=$cacheIdentity.platformOs;arch=$cacheIdentity.platformArch};method='Gradle dry-run task graph + JavaExec inspection';observedTasks=$observedTasks;taskNames=$taskNames;diagnosticSummary=$diagnosticSummary;timestamp=[DateTimeOffset]::UtcNow.ToString('o');errorCode=$(if($status -eq 'Observed'){$null}else{$reason});evidencePath=$null}
    $evidenceDirectory=Join-Path $cacheDirectory 'evidence'
    New-Item -ItemType Directory -Path $evidenceDirectory -Force|Out-Null
    $evidencePath=Join-Path $evidenceDirectory ($cacheKey+'-'+[guid]::NewGuid().ToString('N')+'.json')
    $result.evidencePath=$evidencePath
    $evidenceTemporary=$evidencePath+'.tmp'
    [IO.File]::WriteAllText($evidenceTemporary,($result|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $evidenceTemporary -Destination $evidencePath -Force
    if(-not $gitState.dirty -and $gitState.isGitRepository -and $status -ne 'ProbeFailed'){
        $temporary=$cachePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try {[IO.File]::WriteAllText($temporary,($result|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $cachePath -Force} finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    }
    return $result
}

Export-ModuleMember -Function Invoke-MmtlRuntimeBindingProbe,Get-MmtlCachedRuntimeBindingEvidence,New-MmtlRuntimeBindingAdapterEvidenceFromFreshProbe
