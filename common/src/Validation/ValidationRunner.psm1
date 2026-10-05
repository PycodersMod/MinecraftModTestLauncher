Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\GradleRunner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationPlan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Platform\Platform.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\ProjectDetector.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Adapters\ContractV2.psm1') -Force

function Get-MmtlValidationGradleCommand {
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)][string]$Task,[switch]$Clean)
    if($Task -eq 'build'){return GradleRunner\Get-MmtlGradleCommand -Project $Project -Task build -Clean:$Clean}
    return GradleRunner\Get-MmtlGradleCommand -Project $Project -Task $Task
}

function Get-MmtlValidationArtifact {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $directory=Join-Path $ProjectRoot 'build/libs'
    if(-not(Test-Path -LiteralPath $directory -PathType Container)){return $null}
    $artifacts=@(Get-ChildItem -LiteralPath $directory -Filter '*.jar' -File | Where-Object {$_.Name -notmatch '(?i)(sources|javadoc|dev)(?:[-.]|\.jar$)'})
    if($artifacts.Count -ne 1){return $null}
    $item=$artifacts[0]
    [pscustomobject]@{path='build/libs/'+$item.Name;filename=$item.Name;sizeBytes=[long]$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
}

function Get-MmtlValidationSourceFingerprint {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $root=[IO.Path]::GetFullPath($ProjectRoot);$excluded=@('.git','.gradle','build');$records=[Collections.Generic.List[string]]::new()
    foreach($file in Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction Stop){
        $relative=[IO.Path]::GetRelativePath($root,$file.FullName).Replace([string][IO.Path]::DirectorySeparatorChar,'/')
        if(@($relative.Split('/')|Where-Object{$_ -in $excluded}).Count){continue}
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.LinkType){throw 'SOURCE_FINGERPRINT_REPARSE_PATH'}
        $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $records.Add($relative+'|'+$hash)
    }
    $orderedRecords=$records.ToArray();[Array]::Sort($orderedRecords,[StringComparer]::Ordinal)
    $payload=[Text.Encoding]::UTF8.GetBytes(($orderedRecords -join "`n"))
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($payload)).ToLowerInvariant()
    return 'sha256:'+$digest
}

function Resolve-MmtlValidationProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Target)
    $project=Get-MmtlProject -Path $Path
    if($project.DetectionStatus -ne 'Resolved'){throw "项目探测未能解析出唯一的 Loader 组合：$($project.DetectionStatus)。"}
    $stack=Resolve-MmtlProjectStack -Evidence @($project.Evidence)
    if($stack.status -ne 'Resolved' -or -not $project.Toolchain.id -or -not $project.BuildSystem.id -or -not $project.Wrapper){throw '项目探测结果缺少明确的 Loader、工具链、构建系统或 Gradle Wrapper。'}
    if([string]$project.MinecraftVersion -cne [string]$Target.minecraftId -or [string]$project.Loader -cne [string]$Target.loaderStack.primary.id -or [string]$project.LoaderVersion -cne [string]$Target.loaderVersion){throw '检测到的项目身份与请求的精确验证目标不匹配。'}
    $plan=New-MmtlAdapterBuildPlan -Project $project
    if(-not $plan -or -not $plan.task -or -not $plan.wrapperPath){throw '适配器未能生成可用的 Gradle 构建计划。'}
    [pscustomobject]@{resolved=$true;project=$project;loaderStack=$stack.loaderStack;buildPlan=$plan}
}

function Get-MmtlObservedBuildJava {
    param([string]$JavaHome)
    $provider=Get-MmtlPlatformProvider
    $javaPath=$null
    if($JavaHome){$javaPath=Join-Path (Join-Path $JavaHome 'bin') $provider.JavaExecutable}
    elseif($env:JAVA_HOME){$candidate=Join-Path (Join-Path $env:JAVA_HOME 'bin') $provider.JavaExecutable;if(Test-Path -LiteralPath $candidate -PathType Leaf){$javaPath=$candidate}}
    if(-not $javaPath -and -not $JavaHome){
        $javaCommand=Get-Command java -CommandType Application -ErrorAction SilentlyContinue
        $javaPath=if($javaCommand -and $javaCommand.PSObject.Properties['Path'] -and $javaCommand.Path){$javaCommand.Path}elseif($javaCommand -and $javaCommand.PSObject.Properties['Source']){$javaCommand.Source}else{$null}
    }
    if(-not $javaPath -or -not(Test-Path -LiteralPath $javaPath -PathType Leaf)){return $null}
    $lines=@(& $javaPath -version 2>&1 | ForEach-Object {[string]$_})
    $raw=$lines -join ' '
    $match=[regex]::Match($raw,'(?:version\s+"|openjdk\s+)(\d+(?:\.\d+){0,3}(?:_[0-9]+)?(?:[-+][A-Za-z0-9._-]+)?)')
    if(-not $match.Success){return $null}
    $version=$match.Groups[1].Value
    $major=if($version.StartsWith('1.')){[int]($version -split '\.')[1]}else{[int]($version -split '[._+-]')[0]}
    [pscustomobject]@{major=$major;exactVersion=$version;vendor=($lines -join ' ');os=$provider.OS;arch=$provider.Arch}
}

function Test-MmtlBuildJavaRequirement {
    param($Requirement,$Observed)
    if(-not $Observed){return $false}
    if(-not $Requirement -or -not $Requirement.PSObject.Properties['kind'] -or $Requirement.kind -eq 'Unknown' -or -not $Requirement.major){return $true}
    switch([string]$Requirement.kind){'Minimum'{return [int]$Observed.major -ge [int]$Requirement.major}'Exact'{return [int]$Observed.major -eq [int]$Requirement.major}'Preferred'{return $true}default{return $true}}
}

function Get-MmtlBuildFailureCode {
    param([string]$Output)
    if($Output -match '(?i)(UnknownHostException|ConnectException|Connection timed out|Connect timed out|Read timed out|Could not GET\s+["'']?https?://|Temporary failure in name resolution|unable to access .* network|PKIX path building failed)'){return 'BUILD_FAILED_NETWORK'}
    if($Output -match '(?im)(?:^|\s)(?:error:|cannot find symbol|compilation failed|compileJava FAILED|compileKotlin FAILED|Execution failed for task .*(?:compile|checkstyle))'){return 'BUILD_FAILED_PROJECT_SOURCE'}
    return 'BUILD_FAILED_TOOLCHAIN'
}

function Invoke-MmtlValidationBuild {
    [CmdletBinding()]
    param(
        $Project,
        [string]$ProjectPath,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [AllowEmptyCollection()][string[]]$AllowedOwners=@(),
        [string]$BuildJavaHome,
        [ValidateRange(1,7200)][int]$TimeoutSeconds=1800,
        [switch]$Clean
    )
    $started=[DateTimeOffset]::UtcNow;$targetId=[string]$Target.targetId
    if($targetId -notmatch '^[a-z0-9][a-z0-9._-]{2,127}$'){throw '验证目标 ID 不安全。'}
    $fixture=$Target.sourceFixture
    if(-not $fixture){throw '验证目标缺少来源 Fixture 溯源信息。'}
    Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners $AllowedOwners | Out-Null
    if(-not $Project -and $ProjectPath){$resolved=Resolve-MmtlValidationProject -Path $ProjectPath -Target $Target;$Project=$resolved.project}
    if(-not $Project -or -not $Project.Root -or -not (Test-Path -LiteralPath $Project.Root -PathType Container)){throw '已解析的项目根目录不可用。'}
    if([string]::IsNullOrWhiteSpace([string]$Project.MinecraftVersion)){throw '已解析的项目缺少准确的 Minecraft 正式版本 ID。'}
    $task=if($Target.PSObject.Properties['task'] -and $Target.task){[string]$Target.task}else{'build'}
    if($task -notin @($fixture.allowedTasks)){throw '请求的 Gradle 任务未被 Fixture 明确列入许可清单。'}
    if($task -ne 'build'){throw '构建运行器仅接受 build 任务；启动操作必须使用专用启动验证器。'}
    $sourceFingerprintBefore=Get-MmtlValidationSourceFingerprint -ProjectRoot $Project.Root
    $artifactBefore=Get-MmtlValidationArtifact -ProjectRoot $Project.Root
    $artifactBeforeTime=$null
    if($artifactBefore){$artifactBeforeTime=(Get-Item -LiteralPath (Join-Path (Join-Path $Project.Root 'build/libs') $artifactBefore.filename)).LastWriteTimeUtc}
    $command=Get-MmtlValidationGradleCommand -Project $Project -Task $task -Clean:$Clean
    $runId=$started.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $validationRoot=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'validation'
    $runDirectory=Join-Path (Join-Path $validationRoot $targetId) $runId
    [void][IO.Directory]::CreateDirectory($runDirectory)
    $stdoutPath=Join-Path $runDirectory 'stdout.log';$stderrPath=Join-Path $runDirectory 'stderr.log'
    $info=[Diagnostics.ProcessStartInfo]::new();$provider=Get-MmtlPlatformProvider
    if($provider.OS -eq 'Windows'){
        $wrapper=[IO.Path]::GetFullPath($command.WrapperPath)
        if(-not (Test-MmtlPlatformPathInsideRoot -Root ([IO.Path]::GetFullPath($Project.Root)) -Target $wrapper)){throw 'Gradle Wrapper 路径越出了项目根目录。'}
        if($wrapper -match '[&|<>^%!]'){throw 'Wrapper 路径包含不安全的 Windows 命令处理器元字符。'}
        $taskArgs=@('--no-daemon')+$(if($task -eq 'build' -and $Clean){@('clean','build')}else{@($task)})
        $info.FileName=$env:ComSpec
        $info.Arguments='/d /c call "'+$wrapper+'" '+($taskArgs -join ' ')
    } else {
        $info.FileName=if([IO.Path]::IsPathRooted([string]$command.File)){[IO.Path]::GetFullPath([string]$command.File)}elseif([string]$command.File -match '^(\.{1,2}/)'){[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($Project.Root)) ([string]$command.File)))}else{[string]$command.File}
        foreach($arg in $command.Arguments){$info.ArgumentList.Add([string]$arg)}
    }
    $info.WorkingDirectory=[IO.Path]::GetFullPath($Project.Root);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    if($BuildJavaHome){
        $javaHome=[IO.Path]::GetFullPath($BuildJavaHome);$javaName=if($provider.OS -eq 'Windows'){'java.exe'}else{'java'};$javacName=if($provider.OS -eq 'Windows'){'javac.exe'}else{'javac'}
        if((Test-Path -LiteralPath (Join-Path $javaHome "bin/$javaName") -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $javaHome "bin/$javacName") -PathType Leaf)){$info.Environment['JAVA_HOME']=$javaHome;$bin=Join-Path $javaHome 'bin';$info.Environment['PATH']=$bin+[IO.Path]::PathSeparator+$env:PATH}
    }
    $info.Environment['GRADLE_OPTS']=if($env:GRADLE_OPTS){$env:GRADLE_OPTS}else{''}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    $failure='NONE';$result='FAILED';$level='RESOLVED';$exitCode=$null
    $stdoutText='';$stderrText='';$observedBuildJava=Get-MmtlObservedBuildJava -JavaHome $BuildJavaHome
    $buildRequirement=if($Target.PSObject.Properties['java'] -and $Target.java){$Target.java.buildRequirement}else{$null}
    if(-not $observedBuildJava){$failure='BUILD_JAVA_UNAVAILABLE';$result='BLOCKED';$stderrText='调用 Gradle Wrapper 前未能检测到可运行的 BuildJava。'}
    elseif(-not (Test-MmtlBuildJavaRequirement -Requirement $buildRequirement -Observed $observedBuildJava)){$failure='BUILD_JAVA_UNAVAILABLE';$result='BLOCKED';$stderrText=('检测到的 BuildJava 主版本 {0} 不符合目标要求。' -f $observedBuildJava.major)}
    $stdoutTask=$null;$stderrTask=$null
    try{
        if($failure -eq 'NONE'){
            if(-not $process.Start()){throw '无法启动 Gradle Wrapper。'}
            $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit($TimeoutSeconds*1000)){$failure='BUILD_TIMEOUT';$result='BLOCKED';try{$process.Kill($true)}catch{};[void]$process.WaitForExit(10000)}
            else{$process.WaitForExit();$exitCode=$process.ExitCode}
            if($stdoutTask){$stdoutText=$stdoutTask.GetAwaiter().GetResult()};if($stderrTask){$stderrText=$stderrTask.GetAwaiter().GetResult()}
        }
    } catch {if($failure -eq 'NONE'){$failure='BUILD_FAILED_MMTL'};$stderrText+=$_.Exception.Message}
    finally{
        $stdoutText=ConvertTo-MmtlRedactedValidationText -Text $stdoutText;$stderrText=ConvertTo-MmtlRedactedValidationText -Text $stderrText
        [IO.File]::WriteAllText($stdoutPath,$stdoutText,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderrPath,$stderrText,[Text.UTF8Encoding]::new($false))
        $process.Dispose()
    }
    $artifact=Get-MmtlValidationArtifact -ProjectRoot $Project.Root
    $sourceFingerprintAfter=Get-MmtlValidationSourceFingerprint -ProjectRoot $Project.Root
    $sourceUnchanged=($sourceFingerprintBefore -ceq $sourceFingerprintAfter)
    $artifactFresh=$false
    if($artifact){
        if(-not $artifactBefore){$artifactFresh=$true}
        else{
            $artifactAfterTime=(Get-Item -LiteralPath (Join-Path (Join-Path $Project.Root 'build/libs') $artifact.filename)).LastWriteTimeUtc
            $artifactFresh=($artifact.sha256 -cne $artifactBefore.sha256 -or $artifactAfterTime -gt $artifactBeforeTime)
        }
    }
    if($result -ne 'BLOCKED' -and $exitCode -eq 0){
        if(-not $sourceUnchanged){$failure='BUILD_SOURCE_CHANGED_DURING_RUN';$result='FAILED'}
        elseif(-not $artifact){$failure='ARTIFACT_MISSING';$result='FAILED'}
        elseif(-not $artifactFresh){$failure='ARTIFACT_STALE';$result='FAILED'}
        else{$result='PASSED';$level='BUILD_VERIFIED'}
    } elseif($failure -eq 'NONE'){$failure=Get-MmtlBuildFailureCode -Output ($stdoutText+"`n"+$stderrText)}
    $platform=Get-MmtlPlatformProvider
    $logs=@(foreach($path in @($stdoutPath,$stderrPath)){[pscustomobject]@{path=[IO.Path]::GetRelativePath($runDirectory,$path);sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}})
    $ended=[DateTimeOffset]::UtcNow
    $sourceFixtureEvidence=[ordered]@{type=[string]$fixture.type;source=[string]$fixture.source;commit=[string]$fixture.commit;license=[string]$fixture.license;trust=[string]$fixture.trust}
    foreach($optionalField in @('archiveSha256','officialChecksum','officialChecksumAlgorithm')){if($fixture.PSObject.Properties[$optionalField] -and $fixture.$optionalField){$sourceFixtureEvidence[$optionalField]=$fixture.$optionalField}}
    $evidence=[pscustomobject][ordered]@{
        schemaVersion=1;targetId=$targetId;runId=$runId;startedAt=$started.ToString('o');endedAt=$ended.ToString('o');durationSeconds=[Math]::Round(($ended-$started).TotalSeconds,3)
        validationLevel=$level;result=$result;failureCode=$failure
        platform=[pscustomobject]@{os=$platform.OS;arch=$platform.Arch;isWSL=$platform.IsWSL}
        java=[pscustomobject]@{buildRequirement=$buildRequirement;observedBuildJava=$observedBuildJava;compilerTarget=if($Target.PSObject.Properties['java'] -and $Target.java -and $Target.java.compilerTarget){[int]$Target.java.compilerTarget}elseif($Target.PSObject.Properties['compilerTarget'] -and $Target.compilerTarget){[int]$Target.compilerTarget}else{$null};runtimeRequirement=if($Target.PSObject.Properties['java'] -and $Target.java){$Target.java.runtimeRequirement}else{$null};observedRuntimeJava=$null}
        minecraftId=[string]$Project.MinecraftVersion
        loaderId=[string]$Project.Loader;loaderVersion=[string]$Project.LoaderVersion
        toolchain=[pscustomobject]@{id=if($Target.PSObject.Properties['toolchain']){[string]$Target.toolchain}elseif($Project.PSObject.Properties['Toolchain']){[string]$Project.Toolchain}else{'Unknown'};version=if($Target.PSObject.Properties['toolchainVersion']){$Target.toolchainVersion}elseif($Project.PSObject.Properties['ToolchainVersion']){$Project.ToolchainVersion}else{$null}}
        buildSystem=[pscustomobject]@{id=if($Target.PSObject.Properties['buildSystem']){[string]$Target.buildSystem}elseif($Project.PSObject.Properties['BuildSystem']){[string]$Project.BuildSystem.id}else{'Gradle'};version=if($Project.Root -and (Test-Path (Join-Path $Project.Root 'gradle/wrapper/gradle-wrapper.properties'))){$g=Get-Content (Join-Path $Project.Root 'gradle/wrapper/gradle-wrapper.properties')|Where-Object {$_ -match '^distributionUrl='}|Select-Object -First 1;if($g -match 'gradle-([^-/]+)-(?:bin|all)\.zip'){$Matches[1]}else{$null}}else{$null}}
        source=[pscustomobject]@{fingerprint=$sourceFingerprintBefore;unchangedDuringBuild=$sourceUnchanged;artifactFresh=$artifactFresh}
        sourceFixture=[pscustomobject]$sourceFixtureEvidence
        logs=$logs;artifact=$artifact;process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@("Gradle task: $task",("Exit code: {0}" -f $exitCode))
    }
    $evidencePath=Write-MmtlValidationRunEvidence -RuntimeRoot $RuntimeRoot -Evidence $evidence
    [pscustomobject]@{targetId=$targetId;runId=$runId;result=$result;validationLevel=$level;failureCode=$failure;exitCode=$exitCode;durationSeconds=$evidence.durationSeconds;artifact=$artifact;logPath=$stdoutPath;evidencePath=$evidencePath}
}

Export-ModuleMember -Function Invoke-MmtlValidationBuild,Resolve-MmtlValidationProject
