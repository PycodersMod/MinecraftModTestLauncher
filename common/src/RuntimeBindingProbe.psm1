Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Adapters/RuntimeBinding.psm1') -Force

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

function Get-MmtlProbeGitState {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $shaText=& git -C $ProjectRoot rev-parse --verify HEAD 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($shaText -join ''))){return [pscustomobject]@{isGitRepository=$false;sha=$null;dirty=$true}}
    $status=& git -C $ProjectRoot status --porcelain=v1 --untracked-files=all 2>$null
    if($LASTEXITCODE -ne 0){throw 'RUNTIME_BINDING_GIT_STATUS_FAILED: 无法读取项目工作树状态。'}
    [pscustomobject]@{isGitRepository=$true;sha=([string]($shaText -join '')).Trim();dirty=(@($status).Count -gt 0)}
}

function Get-MmtlProbeCacheIdentity {
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$GitState)
    $buildResolution=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'buildJava') 'resolution'
    $runtimeRequirement=Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtimeJava') 'requirement'
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
        buildSystemId=[string](Get-MmtlProbeProperty $buildSystem 'id' 'Unknown');loader=[string](Get-MmtlProbeProperty $Project 'Loader' 'Unknown')
        loaderVersion=[string](Get-MmtlProbeProperty $Project 'LoaderVersion' '');minecraft=[string](Get-MmtlProbeProperty $Project 'MinecraftVersion' '')
        platformOs=[string](Get-MmtlProbeProperty $platform 'os' 'Unknown');platformArch=[string](Get-MmtlProbeProperty $platform 'arch' 'Unknown')
        buildJavaHome=$buildJavaHome;buildJavaMajor=[string](Get-MmtlProbeProperty $buildResolution 'actualMajor' '')
        runtimeJavaMajor=[string](Get-MmtlProbeProperty $runtimeRequirement 'major' '')
        runtimeJavaKind=[string](Get-MmtlProbeProperty $runtimeRequirement 'requirementKind' '')
        runtimeJavaSource=[string](Get-MmtlProbeProperty $runtimeRequirement 'source' '');requiredTasks=@($requiredTasks);adapterVersion='8'
    }
}

function Get-MmtlCachedRuntimeBindingEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$RuntimeRoot)
    $projectRoot=[IO.Path]::GetFullPath([string](Get-MmtlProbeProperty $Project 'Root' ''))
    $state=Get-MmtlProbeGitState -ProjectRoot $projectRoot
    if(-not $state.isGitRepository -or $state.dirty){return $null}
    $identity=Get-MmtlProbeCacheIdentity -Project $Project -Plan $Plan -GitState $state
    $cacheBytes=[Text.Encoding]::UTF8.GetBytes(($identity|ConvertTo-Json -Compress -Depth 8))
    $expectedKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cacheBytes)).ToLowerInvariant()
    $cachePath=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) "diagnostics/runtime-binding/$expectedKey.json"
    if(-not(Test-Path -LiteralPath $cachePath -PathType Leaf)){return $null}
    if((Get-Item -LiteralPath $cachePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){return $null}
    try{$item=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{return $null}
    if([string]$item.cacheKey -cne $expectedKey -or [string]$item.projectRoot -cne $projectRoot -or [string]$item.projectSha -cne [string]$state.sha -or $item.dirty -ne $false -or -not $item.runtimeJavaBinding){return $null}
    $item.cacheHit=$true
    return $item
}

function New-MmtlRuntimeBindingGradleInitScript {
    @'
gradle.taskGraph.whenReady {
    def records = []
    gradle.rootProject.allprojects.each { project ->
        ['runClient', 'runServer'].each { taskName ->
            def task = project.tasks.findByName(taskName)
            if (task != null) {
                def isJavaExec = task instanceof org.gradle.api.tasks.JavaExec
                def record = [task: taskName, taskType: task.class.name, isJavaExec: isJavaExec]
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
                }
                records << record
            }
        }
    }
    println('MMTL_RUNTIME_BINDING_JSON:' + groovy.json.JsonOutput.toJson([tasks: records, buildJavaHome: System.getProperty('java.home'), buildJavaVersion: System.getProperty('java.version')]))
}
'@
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
    $info.Environment['JAVA_HOME']=$javaHome
    $pathSeparator=[IO.Path]::PathSeparator
    $info.Environment['PATH']=(Join-Path $javaHome 'bin')+$pathSeparator+$env:PATH
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    if(-not $process.Start()){return [pscustomobject]@{exitCode=1;output=@('RUNTIME_BINDING_GRADLE_START_FAILED: 无法启动受信任项目的 Gradle Wrapper。')}}
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
    $combined=@(($stdout.Result -split "`r?`n")+($stderr.Result -split "`r?`n")|Where-Object{$_})
    [pscustomobject]@{exitCode=[int]$process.ExitCode;output=$combined}
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
    try { return [IO.Path]::GetFullPath($runtimeHome).TrimEnd('\','/').Equals([IO.Path]::GetFullPath($BuildJavaHome).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase) } catch { return $false }
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
    try{return [IO.Path]::GetFullPath($expectedHome).TrimEnd('\','/').Equals([IO.Path]::GetFullPath($ObservedBuildJavaHome).TrimEnd('\','/'),[StringComparison]::OrdinalIgnoreCase)}catch{return $false}
}

function Invoke-MmtlRuntimeBindingProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [string[]]$TrustedProjectRoots=@(),
        [switch]$Offline,
        [scriptblock]$GradleInvoker
    )

    $projectRoot=[IO.Path]::GetFullPath([string](Get-MmtlProbeProperty $Project 'Root' ''))
    $trusted=$false
    foreach($trustedRootValue in $TrustedProjectRoots){
        if([string]::IsNullOrWhiteSpace($trustedRootValue)){continue}
        $trustedRoot=[IO.Path]::GetFullPath($trustedRootValue)
        if((Test-MmtlProbePathInsideRoot -Root $trustedRoot -Target $projectRoot) -and -not (Test-MmtlProbePathHasReparsePoint -Root $trustedRoot -Target $projectRoot)){$trusted=$true;break}
    }
    if(-not $trusted){throw 'RUNTIME_BINDING_PROJECT_NOT_TRUSTED: Gradle probe 只允许当前 portfolio 或受信任 fixture。'}

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
    $cacheIdentity=Get-MmtlProbeCacheIdentity -Project $Project -Plan $Plan -GitState $gitState
    $cacheBytes=[Text.Encoding]::UTF8.GetBytes(($cacheIdentity|ConvertTo-Json -Compress -Depth 8))
    $cacheKey=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cacheBytes)).ToLowerInvariant()
    $cacheDirectory=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'diagnostics/runtime-binding'
    $cachePath=Join-Path $cacheDirectory ($cacheKey+'.json')
    if(-not $gitState.dirty -and (Test-Path -LiteralPath $cachePath -PathType Leaf)){
        try {
            $cached=Get-Content -LiteralPath $cachePath -Raw|ConvertFrom-Json -ErrorAction Stop
            if($cached.cacheKey -eq $cacheKey -and $cached.dirty -eq $false){$cached.cacheHit=$true;return $cached}
        } catch { }
    }

    New-Item -ItemType Directory -Path $cacheDirectory -Force|Out-Null
    $initScript=Join-Path $cacheDirectory ('probe-'+[guid]::NewGuid().ToString('N')+'.gradle')
    $initContents=New-MmtlRuntimeBindingGradleInitScript
    [IO.File]::WriteAllText($initScript,$initContents,[Text.UTF8Encoding]::new($false))
    try {
        # Init-script callbacks may be skipped when Gradle reuses a configuration-cache entry.
        # Disable that cache for this observational probe so task model evidence is freshly emitted.
        $arguments=@('--no-daemon','--no-configuration-cache','--console=plain','--init-script',$initScript)
        if($Offline){$arguments+='--offline'}
        $arguments+=@('tasks','--all')
        $request=[pscustomobject]@{projectRoot=$projectRoot;wrapperPath=$wrapper;arguments=$arguments;offline=[bool]$Offline;javaHome=$buildJavaHome}
        if($GradleInvoker){$invocation=& $GradleInvoker $request}
        else{$invocation=Invoke-MmtlRuntimeBindingGradle -Request $request}
    } finally {
        if(Test-Path -LiteralPath $initScript -PathType Leaf){Remove-Item -LiteralPath $initScript -Force}
    }

    $output=@(Get-MmtlProbeProperty $invocation 'output' @()|ForEach-Object{[string]$_})
    $exitCode=[int](Get-MmtlProbeProperty $invocation 'exitCode' 1)
    $marker=@($output|Where-Object{$_ -like 'MMTL_RUNTIME_BINDING_JSON:*'}|Select-Object -Last 1)
    $observed=$null
    if($marker.Count){try{$observed=$marker[0].Substring('MMTL_RUNTIME_BINDING_JSON:'.Length)|ConvertFrom-Json -ErrorAction Stop}catch{}}
    $observedTasks=if($observed){@($observed.tasks)}else{@()}
    $selected=@($observedTasks|Where-Object{[string]$_.task -in @('runClient','runServer')})
    $roleNames=@(Get-MmtlProbeProperty (Get-MmtlProbeProperty $Plan 'runtime') 'roles' @()|ForEach-Object{[string](Get-MmtlProbeProperty $_ 'role' '')})
    if(-not $roleNames.Count){$roleNames=@('Client')}
    $requiredTasks=@($roleNames|ForEach-Object{if($_ -eq 'Server'){'runServer'}else{'runClient'}}|Select-Object -Unique)
    $missingTasks=@($requiredTasks|Where-Object{$_ -notin @($selected|ForEach-Object{[string]$_.task})})
    $runtimeEvidence=@()
    $binding=$null
    $status='Observed'
    $reason='RUNTIME_BINDING_TASK_ABSENT'
    if($exitCode -ne 0 -or -not $observed){$status='ProbeFailed';$reason='RUNTIME_BINDING_GRADLE_PROBE_FAILED'}
    elseif($selected.Count -eq 0){$status='TaskNotFound'}
    elseif($missingTasks.Count){$status='Unresolved';$reason='RUNTIME_BINDING_ROLE_TASK_UNAVAILABLE'}
    elseif(-not (Test-MmtlProbeBuildJavaMatchesPlan -ObservedBuildJavaHome ([string]$observed.buildJavaHome) -ObservedBuildJavaVersion ([string]$observed.buildJavaVersion) -BuildResolution $buildResolution)){$status='Unresolved';$reason='RUNTIME_BINDING_BUILD_JVM_MISMATCH'}
    else {
        foreach($task in @($selected|Where-Object{[string]$_.task -in $requiredTasks})){
            if($task.isJavaExec -ne $true -or [string]::IsNullOrWhiteSpace([string]$task.executable)){$status='Unresolved';$reason='RUNTIME_BINDING_FINAL_LAUNCHER_UNOBSERVED';continue}
            $mode=if(Test-MmtlProbeSameJavaHome -RuntimeExecutable ([string]$task.executable) -BuildJavaHome ([string]$observed.buildJavaHome)){'SameAsBuildJvm'}else{'ToolchainManaged'}
            $runtimeEvidence+=New-MmtlRuntimeBindingEvidence -AdapterId ([string](Get-MmtlProbeProperty $toolchain 'id' 'Unknown')) -Mode $mode -EvidenceSource 'GradleInitScriptJavaExecInspection' -Confidence High -RuntimeJavaControllable:$false -RequiresBuildJvmMatch:($mode -eq 'SameAsBuildJvm') -ProbeStrategy 'GradleJavaExecTaskInspection' -ReasonCode '' -EvidenceDetails @([pscustomobject][ordered]@{task=[string]$task.task;taskType=[string]$task.taskType;executable=[string]$task.executable;launcherSource=[string]$task.launcherSource;buildJavaHome=[string]$observed.buildJavaHome;buildJavaVersion=[string]$observed.buildJavaVersion})
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
    $result=[pscustomobject][ordered]@{schemaVersion=1;status=$status;projectRoot=$projectRoot;runtimeJavaBinding=$binding;evidenceDetails=@($binding.evidenceDetails);cacheKey=$cacheKey;cacheHit=$false;dirty=[bool]$gitState.dirty;projectSha=$gitState.sha;buildJavaHome=$buildJavaHome;buildJavaMajor=$buildJavaMajor;observedBuildJavaHome=$observedBuildJavaHome;observedBuildJavaVersion=$observedBuildJavaVersion;runtimeJavaRequirement=$runtimeRequirement;toolchain=$cacheIdentity.toolchainId;toolchainVersion=$cacheIdentity.toolchainVersion;buildSystem=$cacheIdentity.buildSystemId;adapterVersion=$cacheIdentity.adapterVersion;loader=$loader;loaderVersion=$cacheIdentity.loaderVersion;minecraft=$minecraft;platform=[pscustomobject]@{os=$cacheIdentity.platformOs;arch=$cacheIdentity.platformArch};method='Gradle task graph configuration + JavaExec inspection';observedTasks=$observedTasks;taskNames=$taskNames;diagnosticSummary=$diagnosticSummary;timestamp=[DateTimeOffset]::UtcNow.ToString('o');errorCode=$(if($status -eq 'Observed'){$null}else{$reason});evidencePath=$null}
    $evidenceDirectory=Join-Path $cacheDirectory 'evidence'
    New-Item -ItemType Directory -Path $evidenceDirectory -Force|Out-Null
    $evidencePath=Join-Path $evidenceDirectory ($cacheKey+'-'+[guid]::NewGuid().ToString('N')+'.json')
    $result.evidencePath=$evidencePath
    $evidenceTemporary=$evidencePath+'.tmp'
    [IO.File]::WriteAllText($evidenceTemporary,($result|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $evidenceTemporary -Destination $evidencePath -Force
    if(-not $gitState.dirty -and $gitState.isGitRepository){
        $temporary=$cachePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try {[IO.File]::WriteAllText($temporary,($result|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $cachePath -Force} finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
    }
    return $result
}

Export-ModuleMember -Function Invoke-MmtlRuntimeBindingProbe,Get-MmtlCachedRuntimeBindingEvidence
