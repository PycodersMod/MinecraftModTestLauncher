Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\GradleRunner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationPlan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ValidationEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Platform\Platform.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\ProjectDetector.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Adapters\ContractV2.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Compatibility\EvidenceStore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TargetIdentity.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Adapters\ForgeSecureBuild.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Adapters\FabricSecureBuild.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Adapters\QuiltSecureBuild.psm1') -Force

function Get-MmtlValidationGradleCommand {
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)][string]$Task,[switch]$Clean)
    if($Task -eq 'build'){return GradleRunner\Get-MmtlGradleCommand -Project $Project -Task build -Clean:$Clean}
    return GradleRunner\Get-MmtlGradleCommand -Project $Project -Task $Task
}

function Get-MmtlValidationGradleTaskBatches {
    param([Parameter(Mandatory)][string]$Task,[switch]$Clean,$ForgePrepared)
    $buildTasks=[Collections.Generic.List[string]]::new()
    if($Task -eq 'build' -and $ForgePrepared -and $ForgePrepared.PSObject.Properties['preparationTasks']){
        foreach($preparationTask in @($ForgePrepared.preparationTasks)){$buildTasks.Add([string]$preparationTask)}
    }
    $buildTasks.Add($Task)
    if($Clean -and $Task -eq 'build'){
        return @(
            [pscustomobject]@{phase='clean';tasks=@('clean')},
            [pscustomobject]@{phase='build';tasks=$buildTasks.ToArray()}
        )
    }
    return ,@([pscustomobject]@{phase='build';tasks=$buildTasks.ToArray()})
}

function Get-MmtlValidationGradleHomePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeRoot,[Parameter(Mandatory)][string]$TargetId,[string]$GradleHomeRoot)
    $targetStorageKey=Get-MmtlValidationTargetStorageKey -TargetId $TargetId
    if([string]::IsNullOrWhiteSpace($GradleHomeRoot)){
        $base=Join-Path (Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'validation') 'gradle-home'
    }else{
        if(-not [IO.Path]::IsPathRooted($GradleHomeRoot)){throw 'GradleHomeRoot 必须是绝对路径。'}
        $base=[IO.Path]::GetFullPath($GradleHomeRoot)
    }
    [IO.Path]::GetFullPath((Join-Path $base $targetStorageKey))
}

function New-MmtlValidationBuildProcessStartInfo {
    param(
        [Parameter(Mandatory)]$Provider,
        [Parameter(Mandatory)]$Command,
        [Parameter(Mandatory)][string]$Wrapper,
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)][string]$GradleHome,
        [Parameter(Mandatory)][string[]]$Tasks,
        $PinnedGradle,
        $ForgePrepared,
        $FabricPrepared,
        [string]$BuildJavaHome
    )
    $info=[Diagnostics.ProcessStartInfo]::new()
    $commonArgs=@('--no-daemon')
    if($ForgePrepared){
        if($ForgePrepared.initScriptPath -match '[&|<>^%!]'){throw 'Forge Init Script 路径包含不安全的 Windows 命令处理器元字符。'}
        $commonArgs+=@('--init-script',('"'+[IO.Path]::GetFullPath($ForgePrepared.initScriptPath)+'"'))
    }
    if($ForgePrepared -and $ForgePrepared.requiresOffline){$commonArgs+=@('--offline')}
    $commonArgs+=@(Get-MmtlValidationAdditionalArguments -ForgePrepared $ForgePrepared -FabricPrepared $FabricPrepared)
    if($Provider.OS -eq 'Windows'){
        if(-not (Test-MmtlPlatformPathInsideRoot -Root $SessionRoot -Target $Wrapper)){throw 'Gradle Wrapper 路径越出了 MMTL 验证副本。'}
        if($Wrapper -match '[&|<>^%!]'){throw 'Wrapper 路径包含不安全的 Windows 命令处理器元字符。'}
        $buildCommand=if($PinnedGradle){[IO.Path]::GetFullPath($PinnedGradle.executablePath)}else{$Wrapper}
        if($buildCommand -match '[&|<>^%!]'){throw 'Gradle 执行路径包含不安全的 Windows 命令处理器元字符。'}
        $info.FileName=$env:ComSpec
        $info.Arguments='/d /c call "'+$buildCommand+'" '+(@($commonArgs)+@($Tasks) -join ' ')
    } else {
        $selectedFile=if($PinnedGradle){$PinnedGradle.executablePath}else{$Command.File}
        $info.FileName=if([IO.Path]::IsPathRooted([string]$selectedFile)){[IO.Path]::GetFullPath([string]$selectedFile)}elseif([string]$selectedFile -match '^(\.{1,2}/)'){[IO.Path]::GetFullPath((Join-Path $SessionRoot ([string]$selectedFile)))}else{[string]$selectedFile}
        if($ForgePrepared){$info.ArgumentList.Add('--init-script');$info.ArgumentList.Add([IO.Path]::GetFullPath($ForgePrepared.initScriptPath))}
        if($ForgePrepared -and $ForgePrepared.requiresOffline){$info.ArgumentList.Add('--offline')}
        foreach($additionalArgument in @(Get-MmtlValidationAdditionalArguments -ForgePrepared $ForgePrepared -FabricPrepared $FabricPrepared)){$info.ArgumentList.Add([string]$additionalArgument)}
        foreach($arg in $Command.Arguments){if([string]$arg -notin @('clean','build','runClient','runServer')){$info.ArgumentList.Add([string]$arg)}}
        foreach($gradleTask in $Tasks){$info.ArgumentList.Add([string]$gradleTask)}
    }
    $info.WorkingDirectory=$SessionRoot;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Environment['GRADLE_USER_HOME']=$GradleHome
    if($BuildJavaHome){
        $javaHome=[IO.Path]::GetFullPath($BuildJavaHome);$javaName=if($Provider.OS -eq 'Windows'){'java.exe'}else{'java'};$javacName=if($Provider.OS -eq 'Windows'){'javac.exe'}else{'javac'}
        if((Test-Path -LiteralPath (Join-Path $javaHome "bin/$javaName") -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $javaHome "bin/$javacName") -PathType Leaf)){$info.Environment['JAVA_HOME']=$javaHome;$bin=Join-Path $javaHome 'bin';$info.Environment['PATH']=$bin+[IO.Path]::PathSeparator+$env:PATH}
    }
    $info.Environment['GRADLE_OPTS']=if($env:GRADLE_OPTS){$env:GRADLE_OPTS}else{''}
    return $info
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

function Copy-MmtlValidationProject {
    param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$DestinationRoot)
    $source=[IO.Path]::GetFullPath($SourceRoot);$destination=[IO.Path]::GetFullPath($DestinationRoot)
    $relativeRuntime=[IO.Path]::GetRelativePath($source,$destination)
    if(-not [IO.Path]::IsPathRooted($relativeRuntime) -and $relativeRuntime -ne '..' -and -not $relativeRuntime.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)){
        throw 'VALIDATION_RUNTIME_MUST_BE_OUTSIDE_SOURCE'
    }
    [void][IO.Directory]::CreateDirectory($destination)
    $excluded=@('.git','.gradle','build')
    foreach($directory in Get-ChildItem -LiteralPath $source -Directory -Recurse -Force -ErrorAction Stop){
        if(($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $directory.LinkType){throw 'VALIDATION_SOURCE_REPARSE_PATH'}
        $relative=[IO.Path]::GetRelativePath($source,$directory.FullName)
        $parts=@($relative -split '[\\/]')
        if(@($parts|Where-Object{$_ -in $excluded}).Count){continue}
        [void][IO.Directory]::CreateDirectory((Join-Path $destination $relative))
    }
    foreach($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force -ErrorAction Stop){
        if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.LinkType){throw 'VALIDATION_SOURCE_REPARSE_PATH'}
        $relative=[IO.Path]::GetRelativePath($source,$file.FullName);$parts=@($relative -split '[\\/]')
        if(@($parts|Where-Object{$_ -in $excluded}).Count){continue}
        $target=Join-Path $destination $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $target));[IO.File]::Copy($file.FullName,$target,$false)
        if(-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
            [IO.File]::SetUnixFileMode($target,[IO.File]::GetUnixFileMode($file.FullName))
        }
    }
}

function Resolve-MmtlValidationProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Target)
    $project=Get-MmtlProject -Path $Path
    if($project.DetectionStatus -ne 'Resolved'){throw "项目探测未能解析出唯一的 Loader 组合：$($project.DetectionStatus)。"}
    $stack=Resolve-MmtlProjectStack -Evidence @($project.Evidence)
    if($stack.status -ne 'Resolved' -or -not $project.Toolchain.id -or -not $project.BuildSystem.id -or -not $project.Wrapper){throw '项目探测结果缺少明确的 Loader、工具链、构建系统或 Gradle Wrapper。'}
    $targetLoaderVersion=[string]$Target.loaderVersion
    $detectedLoaderVersion=[string]$project.LoaderVersion
    if([string]$project.Loader -ceq 'Forge' -and $targetLoaderVersion.StartsWith([string]$Target.minecraftId+'-',[StringComparison]::Ordinal) -and $detectedLoaderVersion -ceq $targetLoaderVersion.Substring(([string]$Target.minecraftId).Length+1)){
        $exactForgeCoordinate='net.minecraftforge:forge:'+$targetLoaderVersion
        $buildFile=Join-Path ([string]$project.Root) ([string]$project.BuildFile)
        if(-not $buildFile -or -not(Test-Path -LiteralPath $buildFile -PathType Leaf) -or (Get-Content -LiteralPath $buildFile -Raw -ErrorAction Stop) -notmatch [regex]::Escape($exactForgeCoordinate)){throw 'FORGE_TARGET_VERSION_COORDINATE_NOT_VERIFIED'}
        $project.LoaderVersion=$targetLoaderVersion
    }
    if([string]$project.MinecraftVersion -cne [string]$Target.minecraftId -or [string]$project.Loader -cne [string]$Target.loaderStack.primary.id -or [string]$project.LoaderVersion -cne $targetLoaderVersion){throw '检测到的项目身份与请求的精确验证目标不匹配。'}
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

function Test-MmtlBuildJdkHome {
    param([string]$JavaHome)
    if([string]::IsNullOrWhiteSpace($JavaHome)){return $false}
    $provider=Get-MmtlPlatformProvider
    return (Test-Path -LiteralPath (Join-Path $JavaHome ('bin/'+$provider.JavaExecutable)) -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $JavaHome ('bin/'+$provider.JavacExecutable)) -PathType Leaf)
}

function Get-MmtlValidationBuildJavaRequirement {
    param($Target,$ForgeBuildPin,$FabricBuildPin,$QuiltBuildPin)
    if($ForgeBuildPin){return [pscustomobject]@{kind='Exact';major=[int]$ForgeBuildPin.policy.buildJavaMajor;source='PinnedForgeBuildPolicy'}}
    if($FabricBuildPin){return [pscustomobject]@{kind='Exact';major=[int]$FabricBuildPin.policy.buildJavaMajor;source='PinnedFabricBuildPolicy'}}
    if($QuiltBuildPin){return [pscustomobject]@{kind='Exact';major=[int]$QuiltBuildPin.policy.buildJavaMajor;source='PinnedQuiltBuildPolicy'}}
    if($Target.PSObject.Properties['java'] -and $Target.java){return $Target.java.buildRequirement}
    return $null
}

function Get-MmtlValidationForgeBuildRoute {
    param([Parameter(Mandatory)][string]$TargetId,$ForgeBuildPin)
    if($ForgeBuildPin){
        if([string]$ForgeBuildPin.targetId -cne $TargetId){throw 'FORGE_BUILD_ROUTE_PIN_TARGET_MISMATCH'}
        if([string]$ForgeBuildPin.forgeGradleSpec -ceq '[6.0,6.2)'){return 'ForgeGradle6'}
    }
    if($TargetId -ceq 'Forge@1.16.5' -and (-not $ForgeBuildPin -or -not $ForgeBuildPin.PSObject.Properties['forgeGradleSpec'] -or -not [string]$ForgeBuildPin.forgeGradleSpec)){return 'ForgeGradle6'}
    if($TargetId -in @('Forge@1.12.2','Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4')){return 'ForgeGradle3'}
    if($TargetId -in @('Forge@1.8.8','Forge@1.8.9','Forge@1.9','Forge@1.10','Forge@1.10.2','Forge@1.11','Forge@1.11.2','Forge@1.12','Forge@1.12.1')){return 'ForgeGradleClassic'}
    return 'ForgeGradlePinned'
}

function Test-MmtlValidationForgeGradle3SecurityEvidenceTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetId)
    return $TargetId -in @('Forge@1.12.2','Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4')
}

function Get-MmtlValidationForgeGradle3RuntimeCatalogPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$TargetId,[Parameter(Mandatory)][string]$MinecraftVersion)
    if($TargetId -cne ('Forge@'+$MinecraftVersion)){throw 'FORGE_GRADLE3_TARGET_IDENTITY_MISMATCH'}
    if($TargetId -notin @('Forge@1.13.2','Forge@1.14.2','Forge@1.14.3','Forge@1.14.4','Forge@1.15','Forge@1.15.1','Forge@1.15.2','Forge@1.16.1','Forge@1.16.2','Forge@1.16.3','Forge@1.16.4')){return $null}
    return Join-Path $RepositoryRoot ('compatibility/forge-gradle3-runtime-artifacts/Forge-'+$MinecraftVersion+'.json')
}

function Get-MmtlValidationForgeGradle6SecurityEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ForgeBuildPin,
        [Parameter(Mandatory)]$ForgePrepared,
        [Parameter(Mandatory)]$PinnedGradle,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ForgeMojangArtifacts,
        [AllowNull()][object]$IntegrityFailure=$null
    )
    $policy=$ForgeBuildPin.policy
    [pscustomobject][ordered]@{
        pinId=[string]$policy.targetId
        pinHash=[string]$ForgeBuildPin.pinHash
        forgeGradleSpec=[string]$policy.forgeGradleSpec
        forgeGradleResolvedVersion=[string]$policy.forgeGradleResolvedVersion
        forgeGradleJarSha256=[string]$policy.forgeGradleJarSha256
        forgeGradlePomSha256=[string]$policy.forgeGradlePomSha256
        sourceBuildGradleSha256=[string]$policy.buildGradleSha256
        gradleDistributionUrl=[string]$policy.gradleDistributionUrl
        gradleDistributionSha256=[string]$PinnedGradle.archiveSha256
        gradleVersion=[string]$PinnedGradle.version
        buildClasspathArtifactCatalogHash=[string]$ForgePrepared.buildClasspathCatalogHash
        buildClasspathArtifactCount=[int]$ForgePrepared.buildClasspathArtifactCount
        targetInputCatalogHash=[string]$ForgePrepared.targetInputCatalogHash
        targetInputArtifactCount=[int]$ForgePrepared.targetInputArtifactCount
        runtimeArtifactCatalogHash=[string]$ForgePrepared.runtimeArtifactCatalogHash
        runtimeArtifactCount=[int]$ForgePrepared.runtimeArtifactCount
        mojangVersionHash=[string]$ForgePrepared.mojangVersionHash
        mojangArtifacts=@($ForgeMojangArtifacts)
        integrityFailure=$IntegrityFailure
    }
}

function Get-MmtlValidationForgeGradle6CatalogPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$TargetId)
    $match=[regex]::Match($TargetId,'^Forge@(?<minecraftId>[0-9]+(?:\.[0-9]+){1,2})$')
    if(-not $match.Success){throw 'FORGE_GRADLE6_TARGET_IDENTITY_INVALID'}
    $minecraftId=$match.Groups['minecraftId'].Value
    $provider=Get-MmtlPlatformProvider
    $platformName=if([string]$provider.OS -ceq 'MacOS'){'macOS'}else{[string]$provider.OS}
    $platformKey=$platformName+'-'+([string]$provider.Arch).ToLowerInvariant()
    $compatibilityRoot=Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) 'compatibility'
    return [pscustomobject]@{
        buildClasspath=Join-Path (Join-Path $compatibilityRoot 'forge-gradle6-build-classpath-artifacts') ('Forge-'+$minecraftId+'.json')
        targetInputs=Join-Path (Join-Path $compatibilityRoot 'forge-gradle6-target-inputs') ('Forge-'+$minecraftId+'.json')
        runtimeArtifacts=Join-Path (Join-Path $compatibilityRoot 'forge-gradle6-runtime-artifacts') ('Forge-'+$minecraftId+'-'+$platformKey+'.json')
    }
}

function Get-MmtlValidationToolchainEvidence {
    [CmdletBinding()]
    param($Target,$Project,$ForgeBuildPin,$FabricBuildPin,$QuiltBuildPin)
    $forgeGradleSpec=if($ForgeBuildPin -and $ForgeBuildPin.policy.PSObject.Properties['forgeGradleSpec']){[string]$ForgeBuildPin.policy.forgeGradleSpec}else{''}
    $isLegacyUnspecifiedFg6=$ForgeBuildPin -and [string]$ForgeBuildPin.policy.targetId -ceq 'Forge@1.16.5' -and -not $forgeGradleSpec
    if($ForgeBuildPin -and ($forgeGradleSpec -ceq '[6.0,6.2)' -or $isLegacyUnspecifiedFg6)){
        return [pscustomobject]@{id='ForgeGradle6';version=[string]$ForgeBuildPin.policy.forgeGradleResolvedVersion}
    }
    if($FabricBuildPin){return [pscustomobject]@{id='FabricLoom';version=[string]$FabricBuildPin.policy.loomVersion}}
    if($QuiltBuildPin){return [pscustomobject]@{id='QuiltLoom';version=[string]$QuiltBuildPin.policy.quiltLoomVersion}}
    $toolchain=if($Target.PSObject.Properties['toolchain'] -and $Target.toolchain){$Target.toolchain}elseif($Project.PSObject.Properties['Toolchain']){$Project.Toolchain}else{$null}
    $id=if($toolchain -is [string]){[string]$toolchain}elseif($toolchain -and $toolchain.PSObject.Properties['id']){[string]$toolchain.id}else{'Unknown'}
    $version=if($Target.PSObject.Properties['toolchainVersion'] -and $Target.toolchainVersion){$Target.toolchainVersion}elseif($Project.PSObject.Properties['ToolchainVersion'] -and $Project.ToolchainVersion){$Project.ToolchainVersion}elseif($toolchain -and $toolchain.PSObject.Properties['version']){$toolchain.version}else{$null}
    return [pscustomobject]@{id=$id;version=$version}
}

function Get-MmtlValidationAdditionalArguments {
    param($ForgePrepared,$FabricPrepared)
    $arguments=[Collections.Generic.List[string]]::new()
    foreach($prepared in @($ForgePrepared,$FabricPrepared)){
        if($prepared -and $prepared.PSObject.Properties['additionalArguments']){
            foreach($argument in @($prepared.additionalArguments)){$arguments.Add([string]$argument)}
        }
    }
    return $arguments.ToArray()
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
        [string]$GradleHomeRoot,
        [AllowEmptyCollection()][string[]]$AllowedOwners=@(),
        [string]$BuildJavaHome,
        [object]$CacheIdentity,
        [ValidateRange(1,7200)][int]$TimeoutSeconds=1800,
        [switch]$Clean
    )
    $started=[DateTimeOffset]::UtcNow;$targetId=[string]$Target.targetId
    if(-not(Test-MmtlExactTargetId -TargetId $targetId)){throw '验证目标 ID 不安全。'}
    $fixture=$Target.sourceFixture
    if(-not $fixture){throw '验证目标缺少来源 Fixture 溯源信息。'}
    Test-MmtlValidationFixture -Fixture $fixture -AllowedOwners $AllowedOwners | Out-Null
    if(-not $Project -and $ProjectPath){$resolved=Resolve-MmtlValidationProject -Path $ProjectPath -Target $Target;$Project=$resolved.project}
    if(-not $Project -or -not $Project.Root -or -not (Test-Path -LiteralPath $Project.Root -PathType Container)){throw '已解析的项目根目录不可用。'}
    if([string]::IsNullOrWhiteSpace([string]$Project.MinecraftVersion)){throw '已解析的项目缺少准确的 Minecraft 正式版本 ID。'}
    $forgeBuildPin=$null;$fabricBuildPin=$null;$quiltBuildPin=$null;$repositoryRoot=$null
    if([string]$Project.Loader -ceq 'Forge'){
        $repositoryRoot=if($env:MMTL_REPO_ROOT){[IO.Path]::GetFullPath($env:MMTL_REPO_ROOT)}else{[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))}
        $pinPath=Join-Path $repositoryRoot 'compatibility/forge-build-pins.json'
        if(Test-Path -LiteralPath $pinPath -PathType Leaf){$forgeBuildPin=Get-MmtlForgeBuildPin -ManifestPath $pinPath -Target $Target -Project $Project -Fixture $fixture}
        if(-not $forgeBuildPin -and [string]$Target.targetId -ceq 'Forge@1.8'){
            $pluginPinPath=Join-Path $repositoryRoot 'compatibility/forge-plugin-build-pins.json'
            $expectedSource='https://maven.minecraftforge.net/net/minecraftforge/forge/1.8-11.14.4.1577/forge-1.8-11.14.4.1577-mdk.zip'
            if((Test-Path -LiteralPath $pluginPinPath -PathType Leaf) -and [string]$fixture.type -ceq 'OfficialArtifactFixture' -and [string]$fixture.trust -ceq 'TrustedOfficial' -and [string]$fixture.source -ceq $expectedSource){
                $forgeBuildPin=Get-MmtlForgePluginBuildPin -ManifestPath $pluginPinPath -PluginCatalogPath (Join-Path $repositoryRoot 'compatibility/forge-plugin-artifacts.json') -BuildArtifactCatalogPath (Join-Path $repositoryRoot 'compatibility/forge-build-artifacts.json') -MojangSnapshotsPath (Join-Path $repositoryRoot 'compatibility/snapshots/MojangVersions') -Target $Target -Project $Project -Fixture $fixture
            }
        }
        if(-not $forgeBuildPin){throw 'FORGE_BUILD_PIN_REQUIRED'}
    }
    if([string]$Project.Loader -ceq 'Fabric'){
        $repositoryRoot=if($env:MMTL_REPO_ROOT){[IO.Path]::GetFullPath($env:MMTL_REPO_ROOT)}else{[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))}
        $pinPath=Join-Path $repositoryRoot 'compatibility/fabric-build-pins.json'
        if(Test-Path -LiteralPath $pinPath -PathType Leaf){
            $pinManifest=Get-Content -LiteralPath $pinPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $targetPins=@($pinManifest.targets | Where-Object { [string]$_.targetId -ceq $targetId })
            if($targetPins.Count -gt 1){throw 'FABRIC_PIN_TARGET_MISSING_OR_DUPLICATE'}
            if($targetPins.Count -eq 1){
                $fabricBuildPin=Get-MmtlFabricBuildPin -ManifestPath $pinPath -Target $Target -Project $Project -Fixture $fixture
                if(-not $fabricBuildPin){throw 'FABRIC_BUILD_PIN_REQUIRED'}
            }
        }
    }
    if([string]$Project.Loader -ceq 'Quilt'){
        $repositoryRoot=if($env:MMTL_REPO_ROOT){[IO.Path]::GetFullPath($env:MMTL_REPO_ROOT)}else{[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))}
        $pinPath=Join-Path $repositoryRoot 'compatibility/quilt-build-pins.json'
        if(Test-Path -LiteralPath $pinPath -PathType Leaf){$quiltBuildPin=Get-MmtlQuiltBuildPin -ManifestPath $pinPath -Target $Target -Project $Project -Fixture $fixture}
        if([string]$Target.targetId -ceq 'Quilt@1.20.6' -and -not $quiltBuildPin){throw 'QUILT_BUILD_PIN_REQUIRED'}
    }
    if($CacheIdentity -and -not $forgeBuildPin -and -not $fabricBuildPin -and -not $quiltBuildPin){
        if([string]$CacheIdentity.targetId -cne $targetId){throw 'CACHE_IDENTITY_TARGET_MISMATCH'}
        $cached=Get-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $RuntimeRoot -Identity $CacheIdentity
        if($cached.status -eq 'HIT'){
            return [pscustomobject]@{targetId=$targetId;runId=[string]$cached.evidence.runId;result='PASSED';validationLevel=[string]$cached.evidence.validationLevel;failureCode='NONE';exitCode=0;durationSeconds=[double]$cached.evidence.durationSeconds;artifact=$cached.evidence.artifact;evidencePath=$cached.evidencePath;cached=$true;cacheKey=$cached.cacheKey}
        }
    }
    $task=if($Target.PSObject.Properties['task'] -and $Target.task){[string]$Target.task}else{'build'}
    if($task -notin @($fixture.allowedTasks)){throw '请求的 Gradle 任务未被 Fixture 明确列入许可清单。'}
    if($task -ne 'build'){throw '构建运行器仅接受 build 任务；启动操作必须使用专用启动验证器。'}
    $sourceFingerprintBefore=Get-MmtlValidationSourceFingerprint -ProjectRoot $Project.Root
    $artifactBefore=$null
    $command=Get-MmtlValidationGradleCommand -Project $Project -Task $task -Clean:$Clean
    $runId=$started.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $validationRoot=Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) 'validation'
    $targetStorageKey=Get-MmtlValidationTargetStorageKey -TargetId $targetId
    $runDirectory=Join-Path (Join-Path $validationRoot $targetStorageKey) $runId
    [void][IO.Directory]::CreateDirectory($runDirectory)
    $gradleHome=Get-MmtlValidationGradleHomePath -RuntimeRoot $RuntimeRoot -TargetId $targetId -GradleHomeRoot $GradleHomeRoot
    [void][IO.Directory]::CreateDirectory($gradleHome)
    $sessionRoot=Join-Path $runDirectory 'session'
    Copy-MmtlValidationProject -SourceRoot $Project.Root -DestinationRoot $sessionRoot
    $pinnedArtifacts=$null;$pinnedGradle=$null;$forgePrepared=$null;$fabricPrepared=$null;$pluginArtifactMirror=$null;$buildArtifactMirror=$null;$buildClasspathArtifactMirror=$null
    if($forgeBuildPin){
        $pinnedGradle=Get-MmtlForgePinnedGradle -Pin $forgeBuildPin.policy -CacheRoot (Join-Path $validationRoot 'forge-gradle-distributions') -TimeoutSeconds 300
        if([string]$forgeBuildPin.buildMode -ceq 'PluginsDsl'){
            $pluginCatalogPath=Join-Path $repositoryRoot 'compatibility/forge-plugin-artifacts.json';$buildCatalogPath=Join-Path $repositoryRoot 'compatibility/forge-build-artifacts.json'
            $pluginArtifactMirror=Get-MmtlForgePluginArtifactMirror -CatalogPath $pluginCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-plugin-cache') -TimeoutSeconds 180
            $buildArtifactMirror=Get-MmtlForgeBuildArtifactMirror -CatalogPath $buildCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-build-artifact-cache') -TimeoutSeconds 180
            $mcpVersions=Get-MmtlForgePluginMcpVersions -CatalogPath $pluginCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-mcp-cache') -TimeoutSeconds 120
            $fernflower=Get-MmtlForgePinnedFernflower -Pin $forgeBuildPin.policy -CacheRoot (Join-Path $validationRoot 'forge-fernflower-cache') -TimeoutSeconds 120
            $forgePrepared=Initialize-MmtlForgePluginDslProject -SessionRoot $sessionRoot -Pin $forgeBuildPin.policy -ArtifactCatalogPath $pluginCatalogPath -MirrorRoot $pluginArtifactMirror.mirrorRoot -BuildArtifactCatalogPath $buildCatalogPath -BuildMirrorRoot $buildArtifactMirror.mirrorRoot -GradleHome $gradleHome -McpVersionsPath $mcpVersions.path -FernflowerJarPath $fernflower.jarPath
            $fernflowerGradleCache=Join-Path $gradleHome 'caches/minecraft/fernflower-fixed.jar'
            if(-not(Test-Path -LiteralPath $fernflowerGradleCache -PathType Leaf) -or (Get-FileHash -LiteralPath $fernflowerGradleCache -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$forgeBuildPin.policy.fernflowerJar.sha256){throw 'FORGE_FERNFLOWER_GRADLE_CACHE_SEED_MISMATCH'}
        }else{
            $forgeRoute=Get-MmtlValidationForgeBuildRoute -TargetId $targetId -ForgeBuildPin $forgeBuildPin.policy
            if($forgeRoute -ceq 'ForgeGradle6'){
                $minecraftVersion=[string]$target.minecraftId
                if($targetId -cne ('Forge@'+$minecraftVersion)){throw 'FORGE_GRADLE6_TARGET_IDENTITY_MISMATCH'}
                $catalogPaths=Get-MmtlValidationForgeGradle6CatalogPaths -RepositoryRoot $repositoryRoot -TargetId $targetId
                $classpathCatalogPath=$catalogPaths.buildClasspath
                $targetInputCatalogPath=$catalogPaths.targetInputs
                $runtimeCatalogPath=$catalogPaths.runtimeArtifacts
                $buildClasspathArtifactMirror=Get-MmtlForgeGradle6BuildClasspathArtifactMirror -CatalogPath $classpathCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-gradle6-classpath-cache') -TimeoutSeconds 180
                $targetInputMirror=Get-MmtlForgeGradle6TargetInputMirror -CatalogPath $targetInputCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-gradle6-target-cache') -TimeoutSeconds 180
                $runtimeArtifactMirror=Get-MmtlForgeGradle6RuntimeArtifactMirror -CatalogPath $runtimeCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-gradle6-runtime-cache') -TimeoutSeconds 180
                $pinnedMojangArtifacts=Get-MmtlForgeGradle6PinnedMojangArtifacts -Pin $forgeBuildPin.policy -CacheRoot (Join-Path $validationRoot 'forge-gradle6-target-cache') -TimeoutSeconds 180
                $initializerParameters=@{SessionRoot=$sessionRoot;Pin=$forgeBuildPin.policy;BuildClasspathCatalogPath=$classpathCatalogPath;BuildClasspathMirrorRoot=$buildClasspathArtifactMirror.mirrorRoot;TargetInputCatalogPath=$targetInputCatalogPath;TargetInputMirrorRoot=$targetInputMirror.mirrorRoot;MojangVersionJsonPath=$targetInputMirror.mojangVersionPath;RuntimeCatalogPath=$runtimeCatalogPath;RuntimeMirrorRoot=$runtimeArtifactMirror.mirrorRoot;PinnedMojangArtifacts=$pinnedMojangArtifacts;GradleHome=$gradleHome}
                $forgePrepared=Initialize-MmtlForgeGradle6PinnedProject @initializerParameters
            }elseif($forgeRoute -ceq 'ForgeGradle3'){
                $pinnedArtifacts=Get-MmtlForgePinnedArtifacts -Pin $forgeBuildPin.policy -CacheRoot (Join-Path $validationRoot 'forge-plugin-cache') -TimeoutSeconds 180
                $minecraftVersion=[string]$target.minecraftId
                if($targetId -cne ('Forge@'+$minecraftVersion)){throw 'FORGE_GRADLE3_TARGET_IDENTITY_MISMATCH'}
                $classpathCatalogPath=Join-Path $repositoryRoot ('compatibility/forge-gradle-classpath-artifacts/Forge-'+$minecraftVersion+'-buildscript.json')
                $targetInputCatalogPath=Join-Path $repositoryRoot ('compatibility/forge-gradle3-target-inputs/Forge-'+$minecraftVersion+'.json')
                $runtimeCatalogPath=Get-MmtlValidationForgeGradle3RuntimeCatalogPath -RepositoryRoot $repositoryRoot -TargetId $targetId -MinecraftVersion $minecraftVersion
                $buildClasspathArtifactMirror=Get-MmtlForgeGradle3BuildClasspathArtifactMirror -CatalogPath $classpathCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-gradle3-classpath-cache') -TimeoutSeconds 180
                $runtimeArtifactMirror=$null
                $targetInputParameters=@{CatalogPath=$targetInputCatalogPath;CacheRoot=(Join-Path $validationRoot 'forge-gradle3-target-cache');TimeoutSeconds=180}
                if($runtimeCatalogPath){$targetInputParameters.RuntimeArtifactCatalogPath=$runtimeCatalogPath}
                $targetInputMirror=Get-MmtlForgeGradle3TargetInputMirror @targetInputParameters
                if($runtimeCatalogPath){$runtimeArtifactMirror=Get-MmtlForgeGradle3RuntimeArtifactMirror -CatalogPath $runtimeCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-gradle3-runtime-cache') -TimeoutSeconds 180}
                $pinnedMojangArtifacts=Get-MmtlForgeGradle3PinnedMojangArtifacts -Pin $forgeBuildPin.policy -CacheRoot (Join-Path $validationRoot 'forge-gradle3-target-cache') -TimeoutSeconds 180
                $initializerParameters=@{SessionRoot=$sessionRoot;Pin=$forgeBuildPin.policy;ForgeGradleJarPath=$pinnedArtifacts.jarPath;ForgeGradlePomPath=$pinnedArtifacts.pomPath;ClasspathMirrorRoot=$buildClasspathArtifactMirror.mirrorRoot;TargetMirrorRoot=$targetInputMirror.repositoryRoot;MojangVersionUrl=$targetInputMirror.mojangVersionUrl;MojangVersionJsonPath=$targetInputMirror.mojangVersionPath;PinnedMojangArtifacts=$pinnedMojangArtifacts;GradleHome=$gradleHome}
                if($runtimeArtifactMirror){$initializerParameters.RuntimeLibraryMirrorRoot=$runtimeArtifactMirror.mirrorRoot;$initializerParameters.RuntimeVersionResolutions=$runtimeArtifactMirror.dynamicVersionResolutions}
                $forgePrepared=Initialize-MmtlForgeGradle3PinnedProject @initializerParameters
                $forgePrepared|Add-Member -NotePropertyName classpathCatalogHash -NotePropertyValue $buildClasspathArtifactMirror.catalogHash -Force
                $forgePrepared|Add-Member -NotePropertyName classpathArtifactCount -NotePropertyValue $buildClasspathArtifactMirror.artifactCount -Force
                $forgePrepared|Add-Member -NotePropertyName targetInputCatalogHash -NotePropertyValue $targetInputMirror.catalogHash -Force
                $forgePrepared|Add-Member -NotePropertyName targetInputArtifactCount -NotePropertyValue $targetInputMirror.artifactCount -Force
                $forgePrepared|Add-Member -NotePropertyName mcpMappingSha256 -NotePropertyValue $targetInputMirror.mcpMappingSha256 -Force
                if($runtimeArtifactMirror){$forgePrepared|Add-Member -NotePropertyName runtimeArtifactCatalogHash -NotePropertyValue $runtimeArtifactMirror.catalogHash -Force;$forgePrepared|Add-Member -NotePropertyName runtimeArtifactCount -NotePropertyValue $runtimeArtifactMirror.artifactCount -Force}
            }elseif($forgeRoute -ceq 'ForgeGradleClassic'){
                $pinnedArtifacts=Get-MmtlForgePinnedArtifacts -Pin $forgeBuildPin.policy -CacheRoot (Join-Path $validationRoot 'forge-plugin-cache') -TimeoutSeconds 180
                $classpathCatalogPath=switch($targetId){'Forge@1.8.9'{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts.json'}'Forge@1.9'{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts/Forge-1.9.json'}'Forge@1.10'{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts/Forge-1.10.json'}'Forge@1.10.2'{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts/Forge-1.10.2.json'}'Forge@1.11'{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts/Forge-1.11.json'}'Forge@1.11.2'{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts/Forge-1.11.2.json'}'Forge@1.12'{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts/Forge-1.12.json'}'Forge@1.12.1'{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts/Forge-1.12.1.json'}default{Join-Path $repositoryRoot 'compatibility/forge-gradle-classpath-artifacts/Forge-1.8.8.json'}}
                $buildClasspathArtifactMirror=Get-MmtlForgeBuildClasspathArtifactMirror -CatalogPath $classpathCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-gradle-classpath-cache') -TimeoutSeconds 180
                $forgeUserdevFiles=Get-MmtlForgeBuildUserdevArtifacts -CatalogPath $classpathCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-gradle-classpath-cache') -TimeoutSeconds 180
                $forgeMcpArtifacts=Get-MmtlForgeBuildMcpArtifacts -CatalogPath $classpathCatalogPath -CacheRoot (Join-Path $validationRoot 'forge-gradle-classpath-cache') -TimeoutSeconds 180
                $forgePrepared=Initialize-MmtlForgePinnedProject -SessionRoot $sessionRoot -Pin $forgeBuildPin.policy -ForgeGradleJarPath $pinnedArtifacts.jarPath -ForgeGradlePomPath $pinnedArtifacts.pomPath -ClasspathArtifactCatalogPath $classpathCatalogPath -ClasspathMirrorRoot $buildClasspathArtifactMirror.mirrorRoot -ClasspathMcpVersionsPath $buildClasspathArtifactMirror.mcpVersionsPath -ClasspathMojangVersionPath $buildClasspathArtifactMirror.mojangVersionPath -ClasspathForgeUserdevFiles $forgeUserdevFiles -ClasspathMcpArtifacts $forgeMcpArtifacts -GradleHome $gradleHome -Fixture $fixture -FixtureOverlayRoot ([string]$Project.Root)
            }else{
                $pinnedArtifacts=Get-MmtlForgePinnedArtifacts -Pin $forgeBuildPin.policy -CacheRoot (Join-Path $validationRoot 'forge-plugin-cache') -TimeoutSeconds 180
                $forgePrepared=Initialize-MmtlForgePinnedProject -SessionRoot $sessionRoot -Pin $forgeBuildPin.policy -ForgeGradleJarPath $pinnedArtifacts.jarPath -ForgeGradlePomPath $pinnedArtifacts.pomPath -Fixture $fixture -FixtureOverlayRoot ([string]$Project.Root)
            }
        }
    }
    if($fabricBuildPin){$fabricPrepared=[pscustomobject]@{additionalArguments=@([string]$fabricBuildPin.additionalArguments)}}
    $sourceWrapper=[IO.Path]::GetFullPath($command.WrapperPath)
    if(-not (Test-MmtlPlatformPathInsideRoot -Root ([IO.Path]::GetFullPath($Project.Root)) -Target $sourceWrapper)){throw 'Gradle Wrapper 路径越出了项目根目录。'}
    $wrapperRelative=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Project.Root),$sourceWrapper)
    $command.WrapperPath=Join-Path $sessionRoot $wrapperRelative
    $stdoutPath=Join-Path $runDirectory 'stdout.log';$stderrPath=Join-Path $runDirectory 'stderr.log'
    $provider=Get-MmtlPlatformProvider
    $wrapper=[IO.Path]::GetFullPath($command.WrapperPath)
    $taskBatches=@(Get-MmtlValidationGradleTaskBatches -Task $task -Clean:$Clean -ForgePrepared $forgePrepared)
    $failure='NONE';$result='FAILED';$level='RESOLVED';$exitCode=$null
    $stdoutText='';$stderrText=''
    $buildJdkValid=if($BuildJavaHome){Test-MmtlBuildJdkHome -JavaHome $BuildJavaHome}elseif($forgeBuildPin -or $fabricBuildPin -or $quiltBuildPin){$false}else{$true}
    $observedBuildJava=if($buildJdkValid){Get-MmtlObservedBuildJava -JavaHome $BuildJavaHome}else{$null}
    $buildRequirement=Get-MmtlValidationBuildJavaRequirement -Target $Target -ForgeBuildPin $forgeBuildPin -FabricBuildPin $fabricBuildPin -QuiltBuildPin $quiltBuildPin
    if(-not $observedBuildJava){$failure='BUILD_JAVA_UNAVAILABLE';$result='BLOCKED';$stderrText='调用 Gradle Wrapper 前未能检测到可运行的 BuildJava。'}
    elseif(-not (Test-MmtlBuildJavaRequirement -Requirement $buildRequirement -Observed $observedBuildJava)){$failure='BUILD_JAVA_UNAVAILABLE';$result='BLOCKED';$stderrText=('检测到的 BuildJava 主版本 {0} 不符合目标要求。' -f $observedBuildJava.major)}
    $executionStarted=[DateTimeOffset]::UtcNow
    try{
        if($failure -eq 'NONE'){
            foreach($batch in $taskBatches){
                $remainingMilliseconds=[int][Math]::Floor(($TimeoutSeconds-([DateTimeOffset]::UtcNow-$executionStarted).TotalSeconds)*1000)
                if($remainingMilliseconds -le 0){$failure='BUILD_TIMEOUT';$result='BLOCKED';$exitCode=$null;break}
                $info=New-MmtlValidationBuildProcessStartInfo -Provider $provider -Command $command -Wrapper $wrapper -SessionRoot $sessionRoot -GradleHome $gradleHome -Tasks @($batch.tasks) -PinnedGradle $pinnedGradle -ForgePrepared $forgePrepared -FabricPrepared $fabricPrepared -BuildJavaHome $BuildJavaHome
                $process=[Diagnostics.Process]::new();$process.StartInfo=$info
                $stdoutTask=$null;$stderrTask=$null;$phaseExitCode=$null
                try{
                    if(-not $process.Start()){throw '无法启动 Gradle Wrapper。'}
                    $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()
                    if(-not $process.WaitForExit($remainingMilliseconds)){$failure='BUILD_TIMEOUT';$result='BLOCKED';$exitCode=$null;try{$process.Kill($true)}catch{};[void]$process.WaitForExit(10000)}
                    else{$process.WaitForExit();$phaseExitCode=$process.ExitCode;$exitCode=$phaseExitCode}
                    if($stdoutTask){$stdoutText+=('=== Gradle phase: {0} ===' -f [string]$batch.phase)+[Environment]::NewLine+$stdoutTask.GetAwaiter().GetResult()}
                    if($stderrTask){$stderrText+=('=== Gradle phase: {0} ===' -f [string]$batch.phase)+[Environment]::NewLine+$stderrTask.GetAwaiter().GetResult()}
                } finally {$process.Dispose()}
                if($failure -ne 'NONE' -or ($null -ne $phaseExitCode -and $phaseExitCode -ne 0)){break}
            }
        }
    } catch {if($failure -eq 'NONE'){$failure='BUILD_FAILED_MMTL'};$stderrText+=$_.Exception.Message}
    finally{
        $stdoutText=ConvertTo-MmtlRedactedValidationText -Text $stdoutText;$stderrText=ConvertTo-MmtlRedactedValidationText -Text $stderrText
        [IO.File]::WriteAllText($stdoutPath,$stdoutText,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderrPath,$stderrText,[Text.UTF8Encoding]::new($false))
    }
    $forgeMojangArtifacts=@();$forgeIntegrityFailure=$null
    if($forgePrepared -and $exitCode -eq 0 -and $result -ne 'BLOCKED'){
        try{$forgeMojangArtifacts=@(Test-MmtlForgeMojangArtifacts -PreparedProject $forgePrepared -GradleHome $gradleHome)}catch{$forgeIntegrityFailure=$_.Exception.Message}
    }
    $artifact=Get-MmtlValidationArtifact -ProjectRoot $sessionRoot
    $sourceFingerprintAfter=Get-MmtlValidationSourceFingerprint -ProjectRoot $Project.Root
    $sourceUnchanged=($sourceFingerprintBefore -ceq $sourceFingerprintAfter)
    $artifactFresh=[bool]$artifact
    if($forgeIntegrityFailure){$failure='BUILD_FAILED_TOOLCHAIN';$result='FAILED'}
    elseif($result -ne 'BLOCKED' -and $exitCode -eq 0){
        if(-not $sourceUnchanged){$failure='BUILD_SOURCE_CHANGED_DURING_RUN';$result='FAILED'}
        elseif(-not $artifact){$failure='ARTIFACT_MISSING';$result='FAILED'}
        elseif(-not $artifactFresh){$failure='ARTIFACT_STALE';$result='FAILED'}
        else{$result='PASSED';$level='BUILD_VERIFIED'}
    } elseif($failure -eq 'NONE'){$failure=Get-MmtlBuildFailureCode -Output ($stdoutText+"`n"+$stderrText)}
    $platform=Get-MmtlPlatformProvider
    $logs=@(foreach($path in @($stdoutPath,$stderrPath)){[pscustomobject]@{path=[IO.Path]::GetRelativePath($runDirectory,$path);sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}})
    $ended=[DateTimeOffset]::UtcNow
    $sourceFixtureEvidence=[ordered]@{type=[string]$fixture.type;source=[string]$fixture.source;commit=[string]$fixture.commit;license=[string]$fixture.license;trust=[string]$fixture.trust}
    foreach($optionalField in @('archiveUrl','archiveSha256','officialChecksum','officialChecksumAlgorithm','fixtureId','overlaySha256','overlayFiles')){if($fixture.PSObject.Properties[$optionalField] -and $fixture.$optionalField){$sourceFixtureEvidence[$optionalField]=$fixture.$optionalField}}
    $targetJava=if($Target.PSObject.Properties['java']){$Target.java}else{$null}
    $compilerTarget=$null
    if($targetJava -and $targetJava.PSObject.Properties['compilerTarget'] -and $targetJava.compilerTarget){$compilerTarget=[int]$targetJava.compilerTarget}
    elseif($Target.PSObject.Properties['compilerTarget'] -and $Target.compilerTarget){$compilerTarget=[int]$Target.compilerTarget}
    $runtimeRequirement=if($targetJava -and $targetJava.PSObject.Properties['runtimeRequirement']){$targetJava.runtimeRequirement}else{$null}
    $evidence=[pscustomobject][ordered]@{
        schemaVersion=1;targetId=$targetId;runId=$runId;startedAt=$started.ToString('o');endedAt=$ended.ToString('o');durationSeconds=[Math]::Round(($ended-$started).TotalSeconds,3)
        validationLevel=$level;result=$result;failureCode=$failure
        platform=[pscustomobject]@{os=$platform.OS;arch=$platform.Arch;isWSL=$platform.IsWSL}
        java=[pscustomobject]@{buildRequirement=$buildRequirement;observedBuildJava=$observedBuildJava;compilerTarget=$compilerTarget;runtimeRequirement=$runtimeRequirement;observedRuntimeJava=$null}
        minecraftId=[string]$Project.MinecraftVersion
        loaderId=[string]$Project.Loader;loaderVersion=[string]$Project.LoaderVersion
        toolchain=Get-MmtlValidationToolchainEvidence -Target $Target -Project $Project -ForgeBuildPin $forgeBuildPin -FabricBuildPin $fabricBuildPin -QuiltBuildPin $quiltBuildPin
        buildSystem=[pscustomobject]@{id=if($Target.PSObject.Properties['buildSystem']){[string]$Target.buildSystem}elseif($Project.PSObject.Properties['BuildSystem']){[string]$Project.BuildSystem.id}else{'Gradle'};version=if($Project.Root -and (Test-Path (Join-Path $Project.Root 'gradle/wrapper/gradle-wrapper.properties'))){$g=Get-Content (Join-Path $Project.Root 'gradle/wrapper/gradle-wrapper.properties')|Where-Object {$_ -match '^distributionUrl='}|Select-Object -First 1;if($g -match 'gradle-([^-/]+)-(?:bin|all)\.zip'){$Matches[1]}else{$null}}else{$null}}
        source=[pscustomobject]@{fingerprint=$sourceFingerprintBefore;unchangedDuringBuild=$sourceUnchanged;artifactFresh=$artifactFresh}
        sourceFixture=[pscustomobject]$sourceFixtureEvidence
        logs=$logs;artifact=$artifact;process=$null;marker=$null;stopMethod='NotApplicable';scenario=$null;notes=@("Gradle task: $task",("Exit code: {0}" -f $exitCode))
    }
    if($forgePrepared){
        if([string]$forgeBuildPin.buildMode -ceq 'PluginsDsl'){
            $forgeSecurity=[pscustomobject]@{
                pinId=[string]$forgeBuildPin.policy.targetId;pinHash=[string]$forgeBuildPin.pinHash;sourceBuildGradleSha256=[string]$forgeBuildPin.policy.buildGradleSha256
                gradleDistributionUrl=[string]$forgeBuildPin.policy.gradleDistributionUrl;gradleDistributionSha256=[string]$pinnedGradle.archiveSha256;gradleVersion=[string]$pinnedGradle.version
                pluginId=[string]$forgeBuildPin.policy.pluginId;pluginVersion=[string]$forgeBuildPin.policy.pluginVersion
                pluginArtifactCatalogHash=[string]$pluginArtifactMirror.catalogHash;pluginArtifactCount=[int]$pluginArtifactMirror.artifactCount
                buildArtifactCatalogHash=[string]$buildArtifactMirror.catalogHash;buildArtifactCount=[int]$buildArtifactMirror.artifactCount
                fernflowerArchiveSha256=[string]$forgePrepared.fernflowerArchiveSha256;fernflowerJarSha256=[string]$forgePrepared.fernflowerJarSha256
                mcpMapping=[string]$forgePrepared.mcpMapping;mojangArtifacts=@($forgeMojangArtifacts);integrityFailure=$forgeIntegrityFailure
            }
        }elseif((Get-MmtlValidationForgeBuildRoute -TargetId ([string]$forgeBuildPin.policy.targetId) -ForgeBuildPin $forgeBuildPin.policy) -ceq 'ForgeGradle6'){
            $forgeSecurity=Get-MmtlValidationForgeGradle6SecurityEvidence -ForgeBuildPin $forgeBuildPin -ForgePrepared $forgePrepared -PinnedGradle $pinnedGradle -ForgeMojangArtifacts @($forgeMojangArtifacts) -IntegrityFailure $forgeIntegrityFailure
        }elseif([string]$forgeBuildPin.policy.targetId -ceq 'Forge@1.16.5'){
            $forgeSecurity=[pscustomobject]@{
                pinId=[string]$forgeBuildPin.policy.targetId;pinHash=[string]$forgeBuildPin.pinHash;forgeGradleSpec=[string]$forgeBuildPin.policy.forgeGradleSpec;forgeGradleResolvedVersion=[string]$forgeBuildPin.policy.forgeGradleResolvedVersion
                forgeGradleJarSha256=[string]$forgeBuildPin.policy.forgeGradleJarSha256;forgeGradlePomSha256=[string]$forgeBuildPin.policy.forgeGradlePomSha256;sourceBuildGradleSha256=[string]$forgeBuildPin.policy.buildGradleSha256
                gradleDistributionUrl=[string]$forgeBuildPin.policy.gradleDistributionUrl;gradleDistributionSha256=[string]$pinnedGradle.archiveSha256;gradleVersion=[string]$pinnedGradle.version
                buildClasspathArtifactCatalogHash=[string]$forgePrepared.buildClasspathCatalogHash;buildClasspathArtifactCount=[int]$forgePrepared.buildClasspathArtifactCount
                targetInputCatalogHash=[string]$forgePrepared.targetInputCatalogHash;targetInputArtifactCount=[int]$forgePrepared.targetInputArtifactCount
                runtimeArtifactCatalogHash=[string]$forgePrepared.runtimeArtifactCatalogHash;runtimeArtifactCount=[int]$forgePrepared.runtimeArtifactCount
                mojangVersionHash=[string]$forgePrepared.mojangVersionHash;mojangArtifacts=@($forgeMojangArtifacts);integrityFailure=$forgeIntegrityFailure
            }
        }elseif(Test-MmtlValidationForgeGradle3SecurityEvidenceTarget -TargetId ([string]$forgeBuildPin.policy.targetId)){
            $forgeSecurity=[pscustomobject]@{
                pinId=[string]$forgeBuildPin.policy.targetId;pinHash=[string]$forgeBuildPin.pinHash;forgeGradleSpec=[string]$forgeBuildPin.policy.forgeGradleSpec;forgeGradleResolvedVersion=[string]$forgeBuildPin.policy.forgeGradleResolvedVersion
                forgeGradleJarSha256=[string]$pinnedArtifacts.jarSha256;forgeGradlePomSha256=[string]$pinnedArtifacts.pomSha256;sourceBuildGradleSha256=[string]$forgeBuildPin.policy.buildGradleSha256
                gradleDistributionUrl=[string]$forgeBuildPin.policy.gradleDistributionUrl;gradleDistributionSha256=[string]$pinnedGradle.archiveSha256;gradleVersion=[string]$pinnedGradle.version
                buildClasspathArtifactCatalogHash=[string]$forgePrepared.classpathCatalogHash;buildClasspathArtifactCount=[int]$forgePrepared.classpathArtifactCount
                targetInputCatalogHash=[string]$forgePrepared.targetInputCatalogHash;targetInputArtifactCount=[int]$forgePrepared.targetInputArtifactCount;mcpMappingSha256=[string]$forgePrepared.mcpMappingSha256
                mojangArtifacts=@($forgeMojangArtifacts);integrityFailure=$forgeIntegrityFailure
            }
            if($forgePrepared.PSObject.Properties['runtimeArtifactCatalogHash']){$forgeSecurity|Add-Member -NotePropertyName runtimeArtifactCatalogHash -NotePropertyValue ([string]$forgePrepared.runtimeArtifactCatalogHash);$forgeSecurity|Add-Member -NotePropertyName runtimeArtifactCount -NotePropertyValue ([int]$forgePrepared.runtimeArtifactCount)}
        }else{
            $forgeSecurity=[pscustomobject]@{
                pinId=[string]$forgeBuildPin.policy.targetId;pinHash=[string]$forgeBuildPin.pinHash;forgeGradleSpec=[string]$forgeBuildPin.policy.forgeGradleSpec;forgeGradleTimestamp=[string]$forgeBuildPin.policy.forgeGradleTimestamp
                forgeGradleJarSha256=[string]$pinnedArtifacts.jarSha256;forgeGradlePomSha256=[string]$pinnedArtifacts.pomSha256;sourceBuildGradleSha256=[string]$forgeBuildPin.policy.buildGradleSha256
                gradleDistributionUrl=[string]$forgeBuildPin.policy.gradleDistributionUrl;gradleDistributionSha256=[string]$pinnedGradle.archiveSha256;gradleVersion=[string]$pinnedGradle.version
                mojangArtifacts=@($forgeMojangArtifacts);integrityFailure=$forgeIntegrityFailure
            }
            if($forgePrepared.PSObject.Properties['classpathCatalogHash'] -and $forgePrepared.classpathCatalogHash){
                $forgeSecurity|Add-Member -NotePropertyName buildClasspathArtifactCatalogHash -NotePropertyValue ([string]$forgePrepared.classpathCatalogHash)
                $forgeSecurity|Add-Member -NotePropertyName buildClasspathArtifactCount -NotePropertyValue ([int]$forgePrepared.classpathArtifactCount)
                $forgeSecurity|Add-Member -NotePropertyName buildClasspathMcpVersionsSha256 -NotePropertyValue ([string]$forgePrepared.classpathMcpVersionsSha256)
                $forgeSecurity|Add-Member -NotePropertyName buildClasspathMcpMapping -NotePropertyValue ([string]$forgePrepared.classpathMcpMapping)
                $forgeSecurity|Add-Member -NotePropertyName buildClasspathMojangVersionSha256 -NotePropertyValue ([string]$forgePrepared.classpathMojangVersionSha256)
            }
        }
        $evidence|Add-Member -NotePropertyName forgeSecurity -NotePropertyValue $forgeSecurity
    }
    if($fabricBuildPin){
        $fabricSecurity=[pscustomobject]@{
            pinId=[string]$fabricBuildPin.policy.targetId;pinHash=[string]$fabricBuildPin.pinHash;sourceArchiveSha256=[string]$fabricBuildPin.policy.sourceArchiveSha256
            sourceBuildGradleSha256=[string]$fabricBuildPin.policy.sourceBuildGradleSha256;sourceSettingsGradleSha256=[string]$fabricBuildPin.policy.sourceSettingsGradleSha256
            sourceWrapperJarSha256=[string]$fabricBuildPin.policy.sourceWrapperJarSha256;gradleDistributionUrl=[string]$fabricBuildPin.policy.gradleDistributionUrl
            gradleDistributionSha256=[string]$fabricBuildPin.policy.gradleDistributionSha256;gradleVersion=[string]$fabricBuildPin.policy.gradleVersion
            loomPluginId=[string]$fabricBuildPin.policy.loomPluginId;loomVersion=[string]$fabricBuildPin.policy.loomVersion;loaderVersion=[string]$fabricBuildPin.policy.loaderVersion
            fabricApiVersion=[string]$fabricBuildPin.policy.fabricApiVersion;verificationMetadataSha256=[string]$fabricBuildPin.verificationMetadataSha256
            verificationComponentCount=[int]$fabricBuildPin.policy.verificationComponentCount;verificationArtifactCount=[int]$fabricBuildPin.policy.verificationArtifactCount
            trustedArtifactCount=[int]$fabricBuildPin.policy.trustedArtifactCount;overlaySha256=[string]$fabricBuildPin.overlaySha256
            buildJavaMajor=[int]$fabricBuildPin.policy.buildJavaMajor;runtimeJavaMajor=[int]$fabricBuildPin.policy.runtimeJavaMajor;verificationMode='strict'
        }
        $evidence|Add-Member -NotePropertyName fabricSecurity -NotePropertyValue $fabricSecurity
    }
    if($quiltBuildPin){
        $quiltSecurity=[pscustomobject]@{
            pinId=[string]$quiltBuildPin.policy.targetId;pinHash=[string]$quiltBuildPin.pinHash;sourceArchiveSha256=[string]$quiltBuildPin.policy.sourceArchiveSha256
            sourceBuildGradleSha256=[string]$quiltBuildPin.policy.sourceBuildGradleSha256;sourceSettingsGradleSha256=[string]$quiltBuildPin.policy.sourceSettingsGradleSha256
            sourceWrapperJarSha256=[string]$quiltBuildPin.policy.sourceWrapperJarSha256;sourceVersionsTomlSha256=[string]$quiltBuildPin.policy.sourceVersionsTomlSha256
            gradleDistributionUrl=[string]$quiltBuildPin.policy.gradleDistributionUrl;gradleDistributionSha256=[string]$quiltBuildPin.policy.gradleDistributionSha256;gradleVersion=[string]$quiltBuildPin.policy.gradleVersion
            quiltLoomVersion=[string]$quiltBuildPin.policy.quiltLoomVersion;loaderVersion=[string]$quiltBuildPin.policy.loaderVersion
            mappingsVersion=[string]$quiltBuildPin.policy.quiltMappingsVersion;quiltedFabricApiVersion=[string]$quiltBuildPin.policy.quiltedFabricApiVersion
            overlaySha256=[string]$quiltBuildPin.overlaySha256;buildJavaMajor=[int]$quiltBuildPin.policy.buildJavaMajor;runtimeJavaMajor=[int]$quiltBuildPin.policy.runtimeJavaMajor
        }
        $evidence|Add-Member -NotePropertyName quiltSecurity -NotePropertyValue $quiltSecurity
    }
    if($CacheIdentity){$evidence|Add-Member -NotePropertyName compatibilityIdentity -NotePropertyValue (ConvertTo-MmtlCompatibilityCacheIdentity -Identity $CacheIdentity)}
    $evidencePath=Write-MmtlValidationRunEvidence -RuntimeRoot $RuntimeRoot -Evidence $evidence
    $cacheResult=$null
    if($CacheIdentity -and -not $forgeBuildPin -and -not $fabricBuildPin -and -not $quiltBuildPin -and $result -eq 'PASSED' -and [string]$sourceFixtureEvidence.trust -in @('TrustedOfficial','VerifiedHistorical')){$cacheResult=Add-MmtlCompatibilityEvidenceCacheEntry -RuntimeRoot $RuntimeRoot -Identity $CacheIdentity -EvidencePath $evidencePath}
    [pscustomobject]@{targetId=$targetId;runId=$runId;result=$result;validationLevel=$level;failureCode=$failure;exitCode=$exitCode;durationSeconds=$evidence.durationSeconds;artifact=$artifact;logPath=$stdoutPath;evidencePath=$evidencePath;cached=$false;cacheKey=if($cacheResult){$cacheResult.cacheKey}else{$null}}
}

Export-ModuleMember -Function Invoke-MmtlValidationBuild,Resolve-MmtlValidationProject
