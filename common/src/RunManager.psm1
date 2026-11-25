Import-Module (Join-Path $PSScriptRoot 'RuntimeManager.psm1')
Import-Module (Join-Path $PSScriptRoot 'LogManager.psm1')
Import-Module (Join-Path $PSScriptRoot 'ProcessManager.psm1')
Import-Module (Join-Path $PSScriptRoot 'AtomicFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'RunTaskJvmBinding.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Compatibility/LiteLoaderRuntimeDependencies.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Compatibility/LiteLoaderRunInitScript.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ProjectArtifactResolver.psm1') -Force

function Get-MmtlGradleUserHomeForSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    if(-not [string]::IsNullOrWhiteSpace($env:MMTL_GRADLE_USER_HOME)){
        if(-not [IO.Path]::IsPathRooted($env:MMTL_GRADLE_USER_HOME)){throw 'MMTL_GRADLE_USER_HOME_MUST_BE_ABSOLUTE'}
        return [IO.Path]::GetFullPath($env:MMTL_GRADLE_USER_HOME)
    }
    $session=[IO.Path]::GetFullPath($SessionPath)
    $sessions=[IO.Path]::GetFullPath((Split-Path $session -Parent))
    if([IO.Path]::GetFileName($sessions) -cne 'sessions'){throw 'SESSION_PATH_INVALID_FOR_GRADLE_HOME'}
    $runtime=[IO.Path]::GetFullPath((Split-Path $sessions -Parent))
    return Join-Path $runtime 'gradle-home'
}

function Initialize-MmtlLiteLoaderSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$GradleUserHome,[Parameter(Mandatory)][ValidateSet('runClient','runServer')][string]$TaskName,[Parameter(Mandatory)]$LoaderLaunchPlan)
    if([string]$Project.Loader -cne 'LiteLoader' -or [string]$LoaderLaunchPlan.targetId -cne ("LiteLoader@"+[string]$Project.MinecraftVersion) -or [string]$LoaderLaunchPlan.loaderVersion -cne [string]$Project.LoaderVersion -or [string]$LoaderLaunchPlan.minecraftId -cne [string]$Project.MinecraftVersion){throw 'LITELOADER_RUN_TARGET_MISMATCH'}
    $session=[IO.Path]::GetFullPath($SessionPath);$gradleHome=[IO.Path]::GetFullPath($GradleUserHome)
    Assert-MmtlNoReparsePath -Path $session|Out-Null;Assert-MmtlNoReparsePath -Path $gradleHome|Out-Null
    $stagedArtifacts=@(Save-MmtlLiteLoaderRuntimeArtifacts -SessionPath $session -LoaderLaunchPlan $LoaderLaunchPlan)
    if($TaskName -eq 'runClient'){$null=Save-MmtlLiteLoaderClientArtifact -SessionPath $session -LoaderLaunchPlan $LoaderLaunchPlan}
    $assetCacheEvidence=Save-MmtlMojangAssets -GradleUserHome $gradleHome -LoaderLaunchPlan $LoaderLaunchPlan
    if([int]$assetCacheEvidence.assetCount -le 0 -or [string]$assetCacheEvidence.indexSha1 -cne [string]$LoaderLaunchPlan.assetIndex.sha1){throw 'LITELOADER_ASSET_CACHE_EVIDENCE_INVALID'}
    $evidenceDirectory=Join-Path $session 'evidence';New-Item -ItemType Directory -Path $evidenceDirectory -Force|Out-Null;Assert-MmtlNoReparsePath -Path $evidenceDirectory|Out-Null
    $assetCacheEvidencePath=Join-Path $evidenceDirectory 'mojang-assets-cache.json';Assert-MmtlNoReparsePath -Path $assetCacheEvidencePath|Out-Null
    $evidence=[ordered]@{schemaVersion=1;targetId=[string]$LoaderLaunchPlan.targetId;verifiedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');gradleUserHome=$gradleHome;assetCount=[int]$assetCacheEvidence.assetCount;cachedAssetCount=[int]$assetCacheEvidence.cachedAssetCount;downloadedAssetCount=[int]$assetCacheEvidence.downloadedAssetCount;assetBytes=[long]$assetCacheEvidence.assetBytes;assetIndexSha1=[string]$assetCacheEvidence.indexSha1;status='VerifiedByPinnedSha1AndSize'}|ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($assetCacheEvidencePath,$evidence,[Text.UTF8Encoding]::new($false))
    $initDirectory=Join-Path $session 'gradle-loader';New-Item -ItemType Directory -Path $initDirectory -Force|Out-Null;Assert-MmtlNoReparsePath -Path $initDirectory|Out-Null
    $initScript=New-MmtlLiteLoaderRunInitScript -SessionPath $session -TaskName $TaskName -LoaderLaunchPlan $LoaderLaunchPlan -Artifacts $stagedArtifacts
    $initScriptPath=Join-Path $initDirectory ('liteloader-'+[guid]::NewGuid().ToString('N')+'.gradle');Assert-MmtlNoReparsePath -Path $initScriptPath|Out-Null
    [IO.File]::WriteAllText($initScriptPath,$initScript,[Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{InitScriptPath=$initScriptPath;AssetCacheEvidencePath=$assetCacheEvidencePath;AssetCache=$assetCacheEvidence}
}

function Invoke-MmtlGradleBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)][string]$JavaPath,[Parameter(Mandatory)][string]$SessionPath,[switch]$Clean,[AllowNull()]$LoaderLaunchPlan=$null)
    if(-not(Test-Path -LiteralPath $JavaPath -PathType Leaf)){throw "Java 不存在：$JavaPath"}
    $name=[IO.Path]::GetFileName($Project.Root)-replace '[^A-Za-z0-9_-]','_'
    $log=New-MmtlLogPath -RuntimeRoot (Split-Path (Split-Path $SessionPath -Parent) -Parent) -SessionPath $SessionPath -Name "build-$name"
    $cmd=Get-MmtlGradleCommand -Project $Project -Task build -Clean:$Clean
    $liteLoaderBootstrap=$null
    if([string]$Project.Loader -ceq 'LiteLoader'){
        if(-not $LoaderLaunchPlan){throw 'LITELOADER_BUILD_LAUNCH_PLAN_REQUIRED'}
        $gradleHome=Get-MmtlGradleUserHomeForSession -SessionPath $SessionPath
        New-Item -ItemType Directory -Path $gradleHome -Force|Out-Null;Assert-MmtlNoReparsePath -Path $gradleHome|Out-Null
        $liteLoaderBootstrap=Initialize-MmtlLiteLoaderSession -Project $Project -SessionPath $SessionPath -GradleUserHome $gradleHome -TaskName runClient -LoaderLaunchPlan $LoaderLaunchPlan
    }elseif($LoaderLaunchPlan){throw 'LITELOADER_BUILD_PROJECT_MISMATCH'}
    $oldHome=$env:JAVA_HOME;$oldPath=$env:Path;$oldGradleHome=$env:GRADLE_USER_HOME;$javaHome=Split-Path (Split-Path $JavaPath -Parent) -Parent
    $gradleHome=Get-MmtlGradleUserHomeForSession -SessionPath $SessionPath
    New-Item -ItemType Directory -Path $gradleHome -Force|Out-Null;Assert-MmtlNoReparsePath -Path $gradleHome|Out-Null
    $pathSeparator=[string]$global:MmtlPlatformProvider.PathListSeparator
    $started=[DateTimeOffset]::UtcNow
    try{
        $env:JAVA_HOME=$javaHome;$env:Path=(Join-Path $javaHome 'bin')+$pathSeparator+$oldPath;$env:GRADLE_USER_HOME=$gradleHome
        Push-Location -LiteralPath $cmd.WorkingDirectory
        try{$args=if($liteLoaderBootstrap){@('--init-script',$liteLoaderBootstrap.InitScriptPath)+@($cmd.Arguments)}else{@($cmd.Arguments)};$cmdOutputPreference=$PSNativeCommandUseErrorActionPreference;$PSNativeCommandUseErrorActionPreference=$false;& $cmd.File @args *> $log;$exitCode=$LASTEXITCODE;$PSNativeCommandUseErrorActionPreference=$cmdOutputPreference}
        finally{Pop-Location}
    }finally{$env:JAVA_HOME=$oldHome;$env:Path=$oldPath;$env:GRADLE_USER_HOME=$oldGradleHome}
    if($exitCode -ne 0){throw "Gradle 构建失败（退出码 $exitCode），日志：$log"}
    $artifact=Get-MmtlProjectOutputArtifact -Project $Project
    $artifactPath=[IO.Path]::GetFullPath([string]$artifact.path)
    $gitSha=(& git -C $Project.Root rev-parse HEAD 2>$null);if($LASTEXITCODE -ne 0){$gitSha=$null}
    [pscustomobject]@{Project=$Project.Root;JavaPath=$JavaPath;BuildStartedUtc=$started.ToString('o');BuildFinishedUtc=[DateTimeOffset]::UtcNow.ToString('o');ExitCode=$exitCode;ArtifactPath=$artifactPath;ArtifactExtension=[string]$artifact.extension;JarPath=$(if([string]$artifact.extension -ceq '.jar'){$artifactPath}else{$null});JarSha256=(Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash;GitSha=([string]$gitSha).Trim();LogPath=$log;AssetCacheEvidencePath=$(if($liteLoaderBootstrap){$liteLoaderBootstrap.AssetCacheEvidencePath}else{$null})}
}

function Invoke-MmtlProjectBuildPipeline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Primary,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LinkedProjects,
        [Parameter(Mandatory)][string]$JavaPath,
        [Parameter(Mandatory)][string]$SessionPath,
        [switch]$AutoBuild,
        [switch]$Clean,
        [AllowNull()]$LoaderLaunchPlan=$null,
        [scriptblock]$BuildAction,
        [scriptblock]$ArtifactResolver
    )
    $builds=[Collections.Generic.List[object]]::new();$artifacts=[Collections.Generic.List[object]]::new()
    $allProjects=@($Primary)+@($LinkedProjects)
    if($AutoBuild){
        foreach($candidate in $allProjects){
            $candidateLoaderPlan=if([IO.Path]::GetFullPath([string]$candidate.Root) -ceq [IO.Path]::GetFullPath([string]$Primary.Root)){$LoaderLaunchPlan}else{$null}
            if($BuildAction){if($candidateLoaderPlan){$build=& $BuildAction -Project $candidate -JavaPath $JavaPath -SessionPath $SessionPath -Clean:$Clean -LoaderLaunchPlan $candidateLoaderPlan}else{$build=& $BuildAction -Project $candidate -JavaPath $JavaPath -SessionPath $SessionPath -Clean:$Clean}}
            else{$build=Invoke-MmtlGradleBuild -Project $candidate -JavaPath $JavaPath -SessionPath $SessionPath -Clean:$Clean -LoaderLaunchPlan $candidateLoaderPlan}
            if(-not $build -or [int]$build.ExitCode -ne 0){throw "PROJECT_BUILD_FAILED: $($candidate.Root)"}
            $artifactPath=[IO.Path]::GetFullPath([string]$(if($build.PSObject.Properties['ArtifactPath'] -and $build.ArtifactPath){$build.ArtifactPath}else{$build.JarPath}))
            $isPrimary=[IO.Path]::GetFullPath([string]$candidate.Root) -ceq [IO.Path]::GetFullPath([string]$Primary.Root)
            $allowedExtensions=if($isPrimary -and [string]$candidate.Loader -ceq 'LiteLoader'){@('.jar','.litemod')}else{@('.jar')}
            if([IO.Path]::GetExtension($artifactPath) -cnotin $allowedExtensions -or -not(Test-Path -LiteralPath $artifactPath -PathType Leaf)){throw "PROJECT_BUILD_ARTIFACT_MISSING: $($candidate.Root)"}
            $relative=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath([string]$candidate.Root),$artifactPath)
            if([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)){throw "PROJECT_BUILD_ARTIFACT_OUTSIDE_ROOT: $($candidate.Root)"}
            $actualHash=(Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
            if(-not $build.JarSha256 -or [string]$build.JarSha256 -cne $actualHash){throw "LINKED_ARTIFACT_HASH_MISMATCH: $($candidate.Root)"}
            $builds.Add($build)
            if(-not $isPrimary){$artifacts.Add([pscustomobject]@{project=[string]$candidate.Root;path=$artifactPath;sha256=$actualHash;source='BuildEvidence'})}
        }
    }else{
        foreach($candidate in $LinkedProjects){
            $jarPath=if($ArtifactResolver){[string](& $ArtifactResolver -Project $candidate)}else{throw 'LINKED_ARTIFACT_RESOLVER_REQUIRED'}
            $jarPath=[IO.Path]::GetFullPath($jarPath)
            if([IO.Path]::GetExtension($jarPath) -cne '.jar' -or -not(Test-Path -LiteralPath $jarPath -PathType Leaf)){throw "PROJECT_BUILD_ARTIFACT_MISSING: $($candidate.Root)"}
            $relative=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath([string]$candidate.Root),$jarPath)
            if([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)){throw "PROJECT_BUILD_ARTIFACT_OUTSIDE_ROOT: $($candidate.Root)"}
            $artifacts.Add([pscustomobject]@{project=[string]$candidate.Root;path=$jarPath;sha256=(Get-FileHash -LiteralPath $jarPath -Algorithm SHA256).Hash;source='ExistingArtifact'})
        }
    }
    foreach($artifact in $artifacts){
        if(-not(Test-Path -LiteralPath $artifact.path -PathType Leaf) -or (Get-FileHash -LiteralPath $artifact.path -Algorithm SHA256).Hash -cne $artifact.sha256){throw "LINKED_ARTIFACT_CHANGED_BEFORE_INJECTION: $($artifact.project)"}
    }
    $expectedHashes=@{};foreach($artifact in $artifacts){$expectedHashes[[IO.Path]::GetFullPath([string]$artifact.path)]=[string]$artifact.sha256}
    return [pscustomobject]@{builds=@($builds.ToArray());linkedArtifacts=@($artifacts.ToArray());linkedJars=@($artifacts|ForEach-Object path);expectedModHashes=$expectedHashes}
}

function Get-MmtlMemoryBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile,[ValidateSet('Single','IntegratedLAN','Dedicated')][string]$Mode='Single',[long]$PhysicalMemoryMb=0)
    $players=if($Profile.players){[int]$Profile.players}else{1}
    $fallback=if($Profile.memoryMb){[int]$Profile.memoryMb}else{0}
    $hostMemory=if($Profile.hostMemoryMb){[int]$Profile.hostMemoryMb}else{$fallback}
    $clientMemory=if($Profile.clientMemoryMb){[int]$Profile.clientMemoryMb}else{$fallback}
    $serverMemory=if($Profile.serverMemoryMb){[int]$Profile.serverMemoryMb}else{$fallback}
    $requested=switch($Mode){'Single'{$hostMemory};'IntegratedLAN'{$hostMemory+[Math]::Max(0,$players-1)*$clientMemory};'Dedicated'{$serverMemory+$players*$clientMemory}}
    if($requested -le 0){return [pscustomobject]@{RequestedMb=0;LimitMb=0;ExceedsLimit=$false;PhysicalMemoryMb=$PhysicalMemoryMb;Mode=$Mode}}
    if($PhysicalMemoryMb -le 0){$PhysicalMemoryMb=if($global:MmtlPlatformProvider.GetPhysicalMemoryMb){[long](& $global:MmtlPlatformProvider.GetPhysicalMemoryMb)}else{0};if(-not $PhysicalMemoryMb){throw '无法确定本机物理内存；拒绝估算多实例内存预算。'}}
    $requested=[long]$requested;$limit=[long][Math]::Floor($PhysicalMemoryMb*0.8)
    return [pscustomobject]@{RequestedMb=$requested;LimitMb=$limit;ExceedsLimit=($requested -gt $limit);PhysicalMemoryMb=$PhysicalMemoryMb;Mode=$Mode}
}
function Assert-MmtlMemoryBudget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile,[ValidateSet('Single','IntegratedLAN','Dedicated')][string]$Mode='Single',[long]$PhysicalMemoryMb=0)
    $budget=Get-MmtlMemoryBudget -Profile $Profile -Mode $Mode -PhysicalMemoryMb $PhysicalMemoryMb
    if($budget.ExceedsLimit){throw "实例内存预算超限：请求 $($budget.RequestedMb) MB，上限为物理内存的 80%（$($budget.LimitMb) MB；$Mode 模式按各角色内存预算汇总）。请降低实例内存或玩家数量。"}
    return $true
}
function New-MmtlFabricRuntimeLink {
    param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$TargetPath,[Parameter(Mandatory)][string]$Name)
    if($global:MmtlPlatformProvider.FabricRuntimeLink -ne 'Native'){throw '当前平台不支持 Fabric Runtime 链接；普通构建无需此功能。'}
    $root=[IO.Path]::GetFullPath($ProjectRoot);$session=[IO.Path]::GetFullPath($SessionPath);$target=[IO.Path]::GetFullPath($TargetPath)
    $sessionId=Split-Path $session -Leaf;$safe=($Name -replace '[^A-Za-z0-9_-]','_')
    $linkRoot=Join-Path $root '.gradle'
    if(-not(Test-Path -LiteralPath $linkRoot)){New-Item -ItemType Directory -Path $linkRoot|Out-Null}
    Assert-MmtlNoReparsePath -Path $linkRoot|Out-Null
    $link=Join-Path $linkRoot "mmtl-runtime-$sessionId-$safe"
    if(-not(Test-MmtlInsideRoot -Root $root -Target $link)){throw 'Fabric Runtime junction 越出项目目录。'}
    Assert-MmtlNoReparsePath -Path $root|Out-Null
    if(Test-Path -LiteralPath $link){throw "Fabric Runtime junction 路径已存在：$link"}
    New-Item -ItemType Junction -Path $link -Target $target|Out-Null
    return $link
}
function Remove-MmtlFabricRuntimeLink {
    param([Parameter(Mandatory)][string]$ProjectRoot,[Parameter(Mandatory)][string]$LinkPath,[Parameter(Mandatory)][string]$TargetPath)
    if($global:MmtlPlatformProvider.FabricRuntimeLink -ne 'Native'){throw '当前平台不支持清理 Fabric Runtime 链接。'}
    $root=[IO.Path]::GetFullPath($ProjectRoot);$link=[IO.Path]::GetFullPath($LinkPath);$target=[IO.Path]::GetFullPath($TargetPath)
    if(-not(Test-MmtlInsideRoot -Root $root -Target $link)){throw 'Fabric Runtime junction 越出项目目录，拒绝清理。'}
    if(-not(Test-Path -LiteralPath $link)){return $false}
    $item=Get-Item -LiteralPath $link -Force
    if(-not($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -ne 'Junction'){throw '目标不是预期的 Fabric Runtime junction，拒绝清理。'}
    $linkTarget=[IO.Path]::GetFullPath([string]@($item.Target)[0])
    if($linkTarget -ne $target){throw 'Fabric Runtime junction 目标与登记信息不符，拒绝清理。'}
    Remove-Item -LiteralPath $link -Force
    return $true
}
function Set-MmtlClientGuiScale {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$RuntimeDirectory,[Parameter(Mandatory)][object]$GuiScale)
    $scale=0
    if([string]$GuiScale -ine 'Auto' -and (-not[int]::TryParse([string]$GuiScale,[ref]$scale) -or $scale -lt 0 -or $scale -gt 4)){throw 'guiScale 必须为 Auto 或 0 至 4。'}
    $session=[IO.Path]::GetFullPath($SessionPath);$runtime=[IO.Path]::GetFullPath($RuntimeDirectory)
    if(-not(Test-MmtlInsideRoot -Root $session -Target $runtime) -or $runtime -eq $session){throw '客户端 Runtime 必须位于当前 Session 内。'}
    Assert-MmtlNoReparsePath -Path $session|Out-Null;Assert-MmtlNoReparsePath -Path $runtime|Out-Null
    $options=Join-Path $runtime 'options.txt'
    if(Test-Path -LiteralPath $options){$item=Get-Item -LiteralPath $options -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'options.txt 不得是 junction 或 symlink。'};$lines=@([IO.File]::ReadAllLines($options))}else{$lines=@()}
    $updated=$false
    for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match '^guiScale:'){$lines[$i]="guiScale:$scale";$updated=$true}}
    if(-not $updated){$lines+= "guiScale:$scale"}
    [IO.File]::WriteAllLines($options,[string[]]$lines,[Text.UTF8Encoding]::new($false))
    return $true
}

function Copy-MmtlRuntimeMods {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][string]$RuntimeDirectory,[string[]]$ModJars=@(),[Parameter(Mandatory)][ValidateSet('Client','Host','Guest','Server')][string]$Role,[string]$Username='',[hashtable]$ExpectedHashes=@{},[string[]]$AllowedExtensions=@('.jar'))
    $session=[IO.Path]::GetFullPath($SessionPath);$runtime=[IO.Path]::GetFullPath($RuntimeDirectory)
    if(-not(Test-MmtlInsideRoot -Root $session -Target $runtime)){throw 'MOD_JAR_RUNTIME_OUTSIDE_SESSION'}
    Assert-MmtlNoReparsePath -Path $session|Out-Null;Assert-MmtlNoReparsePath -Path $runtime|Out-Null
    if(-not(Test-Path -LiteralPath $runtime -PathType Container)){throw 'MOD_JAR_RUNTIME_MISSING'}
    $mods=Join-Path $runtime 'mods';New-Item -ItemType Directory -Path $mods -Force|Out-Null
    if(-not(Test-MmtlInsideRoot -Root $runtime -Target $mods)){throw 'MOD_JAR_DESTINATION_OUTSIDE_RUNTIME'}
    Assert-MmtlNoReparsePath -Path $mods|Out-Null
    $nameComparer=[StringComparer]::Ordinal
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){$nameComparer=[StringComparer]::OrdinalIgnoreCase}
    $names=[Collections.Generic.HashSet[string]]::new($nameComparer);$hashes=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sources=[Collections.Generic.List[object]]::new()
    foreach($sourceValue in $ModJars){
        if(-not $sourceValue){continue}
        $source=[IO.Path]::GetFullPath([string]$sourceValue)
        if(-not(Test-Path -LiteralPath $source -PathType Leaf) -or [IO.Path]::GetExtension($source).ToLowerInvariant() -notin @($AllowedExtensions|ForEach-Object{$_.ToLowerInvariant()})){throw 'MOD_JAR_SOURCE_INVALID'}
        Assert-MmtlNoReparsePath -Path $source|Out-Null
        $name=[IO.Path]::GetFileName($source);$destination=[IO.Path]::GetFullPath((Join-Path $mods $name))
        if(-not(Test-MmtlInsideRoot -Root $mods -Target $destination)){throw 'MOD_JAR_DESTINATION_OUTSIDE_RUNTIME'}
        $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if($ExpectedHashes.ContainsKey($source) -and $hash -cne ([string]$ExpectedHashes[$source]).ToLowerInvariant()){throw "MOD_JAR_EXPECTED_HASH_MISMATCH: $name"}
        $newName=$names.Add($name);$newHash=$hashes.Add($hash)
        if(-not $newName -or -not $newHash){throw "MOD_JAR_DUPLICATE: 拒绝重复名称或重复内容的 Mod JAR：$name"}
        if(Test-Path -LiteralPath $destination){throw "MOD_JAR_DUPLICATE: 当前 Runtime 已存在同名 Mod JAR：$name"}
        $sources.Add([pscustomobject]@{source=$source;name=$name;destination=$destination;sha256=$hash;sizeBytes=[long]([IO.FileInfo]::new($source).Length)})
    }
    $created=[Collections.Generic.List[string]]::new();$temporaries=[Collections.Generic.List[string]]::new()
    $safeRole=($Role+'-'+$Username)-replace '[^A-Za-z0-9_-]','_'
    $artifacts=Join-Path $session 'artifacts';New-Item -ItemType Directory -Path $artifacts -Force|Out-Null
    if(-not(Test-MmtlInsideRoot -Root $session -Target $artifacts)){throw 'MOD_JAR_MANIFEST_OUTSIDE_SESSION'}
    Assert-MmtlNoReparsePath -Path $artifacts|Out-Null
    $manifestPath=Join-Path $artifacts "mods-$safeRole.json"
    if(Test-Path -LiteralPath $manifestPath){throw 'MOD_JAR_MANIFEST_ALREADY_EXISTS'}
    try{
        $records=[Collections.Generic.List[object]]::new()
        foreach($item in $sources){
            $temporary=Join-Path $mods ('.'+$item.name+'.'+[guid]::NewGuid().ToString('N')+'.tmp');$temporaries.Add($temporary)
            [IO.File]::Copy($item.source,$temporary)
            $copiedHash=(Get-FileHash -LiteralPath $temporary -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            if($copiedHash -cne $item.sha256 -or [long]([IO.FileInfo]::new($temporary).Length) -ne $item.sizeBytes){throw "MOD_JAR_COPY_INTEGRITY_MISMATCH: $($item.name)"}
            [IO.File]::Move($temporary,$item.destination);$null=$temporaries.Remove($temporary);$created.Add($item.destination)
            $records.Add([pscustomobject][ordered]@{filename=$item.name;extension=[IO.Path]::GetExtension($item.name).ToLowerInvariant();sizeBytes=$item.sizeBytes;sha256=$copiedHash;role=$Role;username=$Username})
        }
        $manifest=[ordered]@{schemaVersion=1;artifacts=@($records.ToArray())}
        Write-MmtlAtomicTextFile -Path $manifestPath -Content (($manifest|ConvertTo-Json -Depth 8)+"`n")
        return @($records.ToArray())
    }catch{
        foreach($path in $temporaries){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
        foreach($path in $created){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}}
        throw
    }
}
function Start-MmtlGradleInstance {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][string]$BuildJavaPath,[Parameter(Mandatory)][string]$RuntimeJavaPath,[Parameter(Mandatory)][ValidateRange(1,100)][int]$RuntimeJavaMajor,[Parameter(Mandatory)][string]$SessionPath,[string[]]$ModJars=@(),[hashtable]$ExpectedModHashes=@{},[AllowNull()]$LoaderLaunchPlan=$null)
    if(-not(Test-Path -LiteralPath $BuildJavaPath -PathType Leaf)){throw 'BUILD_JAVA_CANDIDATE_UNAVAILABLE'}
    if(-not(Test-Path -LiteralPath $RuntimeJavaPath -PathType Leaf)){throw 'RUNTIME_JAVA_CANDIDATE_UNAVAILABLE'}
    $session=[IO.Path]::GetFullPath($SessionPath);$runtime=[IO.Path]::GetFullPath([string]$Plan.RuntimeDirectory)
    if(-not(Test-MmtlInsideRoot -Root $session -Target $runtime)){throw '实例 Runtime 必须位于当前 Session。'}
    $gradleHome=Get-MmtlGradleUserHomeForSession -SessionPath $session
    New-Item -ItemType Directory -Path $gradleHome -Force|Out-Null;Assert-MmtlNoReparsePath -Path $gradleHome|Out-Null
    Assert-MmtlNoReparsePath -Path $session|Out-Null
    New-Item -ItemType Directory -Path $runtime -Force|Out-Null
    Assert-MmtlNoReparsePath -Path $runtime|Out-Null
    $sessionMarkerPath=Join-Path $runtime 'mmtl-session.id';$sessionId=[IO.Path]::GetFileName($session)
    if(Test-Path -LiteralPath $sessionMarkerPath -PathType Leaf){$markerItem=Get-Item -LiteralPath $sessionMarkerPath -Force;if($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Session marker 不得是链接。'};if((Get-Content -LiteralPath $sessionMarkerPath -Raw).Trim() -cne $sessionId){throw '当前 RuntimeDirectory 已绑定其他 Session。'}}else{[IO.File]::WriteAllText($sessionMarkerPath,$sessionId,[Text.UTF8Encoding]::new($false))}
    $mods=Join-Path $runtime 'mods';New-Item -ItemType Directory -Path $mods -Force|Out-Null
    Assert-MmtlNoReparsePath -Path $mods|Out-Null
    if($Plan.Role -ne 'Server' -and $null -ne $Plan.GuiScale -and [string]$Plan.GuiScale -ne ''){Set-MmtlClientGuiScale -SessionPath $session -RuntimeDirectory $runtime -GuiScale $Plan.GuiScale|Out-Null}
    $allowedModExtensions=if([string]$Project.Loader -ceq 'LiteLoader'){@('.jar','.litemod')}else{@('.jar')}
    $null=Copy-MmtlRuntimeMods -SessionPath $session -RuntimeDirectory $runtime -ModJars $ModJars -Role ([string]$Plan.Role) -Username ([string]$Plan.Username) -ExpectedHashes $ExpectedModHashes -AllowedExtensions $allowedModExtensions
    $logName=if($Plan.Role -eq 'Server'){'server'}else{"$($Plan.Role)-$($Plan.Username)"}
    $helper=[string]$global:MmtlPlatformProvider.GradleTaskEntrypoint
    if(-not(Test-Path -LiteralPath $helper -PathType Leaf)){throw '缺少 Gradle Session Runner。'}
    $bindingDirectory=Join-Path $session 'gradle-runtime-binding'
    New-Item -ItemType Directory -Path $bindingDirectory -Force|Out-Null
    Assert-MmtlNoReparsePath -Path $bindingDirectory|Out-Null
    $bindingInitScript=Join-Path $bindingDirectory ('runtime-'+[guid]::NewGuid().ToString('N')+'.gradle')
    $bindingScript=New-MmtlRunTaskJvmBindingInitScript -RuntimeJavaMajor $RuntimeJavaMajor
    [IO.File]::WriteAllText($bindingInitScript,$bindingScript,[Text.UTF8Encoding]::new($false))
    $powerShellHost=Get-Command pwsh -ErrorAction SilentlyContinue
    if(-not $powerShellHost){$powerShellHost=Get-Command powershell.exe -ErrorAction Stop}
    $runtimeLink=$null;$arguments=@();$liteLoaderScriptPath=$null;$assetCacheEvidencePath=$null
    if($Project.Loader -ceq 'LiteLoader'){
        if(-not $LoaderLaunchPlan){throw 'LITELOADER_RUN_LAUNCH_PLAN_REQUIRED'}
        $liteLoaderBootstrap=Initialize-MmtlLiteLoaderSession -Project $Project -SessionPath $session -GradleUserHome $gradleHome -TaskName ([string]$Plan.Task) -LoaderLaunchPlan $LoaderLaunchPlan
        $liteLoaderScriptPath=[string]$liteLoaderBootstrap.InitScriptPath;$assetCacheEvidencePath=[string]$liteLoaderBootstrap.AssetCacheEvidencePath
    }elseif($LoaderLaunchPlan){throw 'LITELOADER_RUN_PROJECT_MISMATCH'}
    $arguments+=@($Plan.Arguments)
    if($Project.Loader -eq 'Fabric'){
        $runtimeLink=New-MmtlFabricRuntimeLink -ProjectRoot $Project.Root -SessionPath $session -TargetPath $runtime -Name $logName
        $runtimeArgumentIndex=-1
        for($i=0;$i -lt $arguments.Count;$i++){if([string]$arguments[$i] -like '-PpycodersRuntimeDir=*'){$runtimeArgumentIndex=$i;break}}
        if($runtimeArgumentIndex -lt 0){Remove-MmtlFabricRuntimeLink -ProjectRoot $Project.Root -LinkPath $runtimeLink -TargetPath $runtime|Out-Null;throw 'Gradle 计划缺少 Runtime 参数。'}
        $arguments[$runtimeArgumentIndex]="-PpycodersRuntimeDir=$runtimeLink"
    }
    $payload=[ordered]@{projectRoot=$Project.Root;sessionPath=$session;arguments=$arguments;runtimeBindingInitScriptPath=$bindingInitScript;liteLoaderInitScriptPath=$liteLoaderScriptPath;runtimeLinkPath=$runtimeLink;runtimeTargetPath=$(if($runtimeLink){$runtime}else{$null})}|ConvertTo-Json -Depth 8 -Compress
    $payloadB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $log=New-MmtlLogPath -RuntimeRoot (Split-Path (Split-Path $session -Parent) -Parent) -SessionPath $session -Name $logName
    $oldHome=$env:JAVA_HOME;$oldPath=$env:Path;$oldGradleHome=$env:GRADLE_USER_HOME;$oldRuntimeHome=$env:MMTL_RUNTIME_JAVA_HOME;$oldRuntimeExecutable=$env:MMTL_RUNTIME_JAVA_EXECUTABLE;$oldRuntimeMajor=$env:MMTL_RUNTIME_JAVA_MAJOR
    $buildJavaHome=Split-Path (Split-Path $BuildJavaPath -Parent) -Parent
    $runtimeJavaHome=Split-Path (Split-Path $RuntimeJavaPath -Parent) -Parent
    $pathSeparator=[string]$global:MmtlPlatformProvider.PathListSeparator
    try{
        $env:JAVA_HOME=$buildJavaHome;$env:Path=(Join-Path $buildJavaHome 'bin')+$pathSeparator+$oldPath;$env:GRADLE_USER_HOME=$gradleHome
        $env:MMTL_RUNTIME_JAVA_HOME=$runtimeJavaHome;$env:MMTL_RUNTIME_JAVA_EXECUTABLE=[IO.Path]::GetFullPath($RuntimeJavaPath);$env:MMTL_RUNTIME_JAVA_MAJOR=[string]$RuntimeJavaMajor
        $args=@('-NoProfile','-NonInteractive','-File',('"'+$helper+'"'),'-LaunchPlanB64',$payloadB64)
        $processId=Start-MmtlTrackedProcess -SessionPath $session -FilePath $powerShellHost.Source -ArgumentList $args -WorkingDirectory $Project.Root -LogPath $log -Role $Plan.Role -Username $Plan.Username -RuntimeDirectory $runtime -RuntimeLinkPath $runtimeLink -RuntimeTargetPath $(if($runtimeLink){$runtime}else{''})
    }catch{if($runtimeLink){Remove-MmtlFabricRuntimeLink -ProjectRoot $Project.Root -LinkPath $runtimeLink -TargetPath $runtime|Out-Null};throw
    }finally{$env:JAVA_HOME=$oldHome;$env:Path=$oldPath;$env:GRADLE_USER_HOME=$oldGradleHome;$env:MMTL_RUNTIME_JAVA_HOME=$oldRuntimeHome;$env:MMTL_RUNTIME_JAVA_EXECUTABLE=$oldRuntimeExecutable;$env:MMTL_RUNTIME_JAVA_MAJOR=$oldRuntimeMajor}
    [pscustomobject]@{ProcessId=[int]$processId;Role=$Plan.Role;Username=$Plan.Username;Project=$Project.Root;Task=$Plan.Task;RuntimeDirectory=$runtime;LogPath=$log;ErrorLogPath=($log+'.err');AssetCacheEvidencePath=$assetCacheEvidencePath}
}
function Initialize-MmtlDedicatedServerRuntime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,[Parameter(Mandatory)]$Profile)
    if($Profile.acceptEula -ne $true){throw 'Dedicated Server 需要用户在配置中明确设置 acceptEula=true。'}
    $world=if($Profile.worldName){[string]$Profile.worldName}else{'MMTL-Test'}
    if($world -notmatch '^[A-Za-z0-9._ -]{1,64}$'){throw 'Dedicated 测试世界名包含不支持的字符。'}
    $players=if($Profile.players){[int]$Profile.players}else{1}
    if($players -lt 1 -or $players -gt 64){throw 'Dedicated 玩家数量必须在 1 到 64 之间。'}
    $mode=if($Profile.gameMode){[string]$Profile.gameMode}else{'survival'}
    if($mode -notin @('survival','creative','adventure','spectator')){throw 'Dedicated 游戏模式无效。'}
    $difficulty=if($Profile.difficulty){[string]$Profile.difficulty}else{'normal'}
    if($difficulty -notin @('peaceful','easy','normal','hard')){throw 'Dedicated 难度无效。'}
    $session=[IO.Path]::GetFullPath($SessionPath);Assert-MmtlNoReparsePath -Path $session|Out-Null
    $server=Join-Path $session 'Server';if(-not(Test-MmtlInsideRoot -Root $session -Target $server)){throw 'Dedicated Runtime 越出 Session。'}
    if(Test-Path -LiteralPath $server){Assert-MmtlNoReparsePath -Path $server|Out-Null}
    New-Item -ItemType Directory -Path $server -Force|Out-Null
    $eula=Join-Path $server 'eula.txt';$properties=Join-Path $server 'server.properties'
    if((Test-Path -LiteralPath $eula) -or (Test-Path -LiteralPath $properties)){throw '拒绝覆盖已有 Dedicated Runtime 配置。'}
    $lines=@("server-ip=127.0.0.1","server-port=$Port","online-mode=false","level-name=$world","max-players=$players","gamemode=$mode","difficulty=$difficulty","motd=MMTL 本地隔离开发会话","enable-command-block=false")
    if($Profile.seed){$seedText=[string]$Profile.seed;if($seedText -notmatch '^-?\d{1,20}$'){throw 'Dedicated 世界种子必须是整数。'};$lines+="level-seed=$seedText"}
    $permission=if($null -ne $Profile.clientPermissionLevel){[int]$Profile.clientPermissionLevel}else{0}
    if($permission -lt 0 -or $permission -gt 4){throw 'Dedicated 客户端权限等级必须为 0 至 4。'}
    $ops=@()
    if($permission -gt 0){
        $host=if($Profile.hostUsername){[string]$Profile.hostUsername}else{'Dev'};$prefix=if($Profile.clientPrefix){[string]$Profile.clientPrefix}else{'Dev_'}
        if($host -notmatch '^[A-Za-z0-9_]{1,16}$' -or $prefix -notmatch '^[A-Za-z0-9_]{1,15}$'){throw 'Dedicated 测试玩家用户名或前缀无效。'}
        $names=@($host);for($i=1;$i -lt $players;$i++){$names+=($prefix+$i)}
        foreach($name in $names){$md5=[Security.Cryptography.MD5]::Create();try{$bytes=$md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("OfflinePlayer:$name"))}finally{$md5.Dispose()};$bytes[6]=($bytes[6] -band 0x0f) -bor 0x30;$bytes[8]=($bytes[8] -band 0x3f) -bor 0x80;$hex=([BitConverter]::ToString($bytes).Replace('-','')).ToLowerInvariant();$uuid=$hex.Substring(0,8)+'-'+$hex.Substring(8,4)+'-'+$hex.Substring(12,4)+'-'+$hex.Substring(16,4)+'-'+$hex.Substring(20,12);$ops+=@{uuid=$uuid;name=$name;level=$permission;bypassesPlayerLimit=$false}}
    }
    [IO.File]::WriteAllText($eula,"# 用户已通过本机 Profile 明确接受 Minecraft EULA`neula=true`n",[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($properties,$lines,[Text.UTF8Encoding]::new($false))
    if($ops.Count){[IO.File]::WriteAllText((Join-Path $server 'ops.json'),($ops|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))}
    [pscustomobject]@{ServerDirectory=$server;EulaPath=$eula;PropertiesPath=$properties;Port=$Port;WorldName=$world;Players=$players;Ops=$ops}
}
function Set-MmtlDedicatedServerPort {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port)
    $session=[IO.Path]::GetFullPath($SessionPath)
    if(-not(Test-Path -LiteralPath $session -PathType Container)){throw 'DEDICATED_SESSION_MISSING'}
    Assert-MmtlNoReparsePath -Path $session|Out-Null
    $properties=Join-Path $session 'Server/server.properties'
    if(-not(Test-MmtlInsideRoot -Root $session -Target $properties)){throw 'DEDICATED_PROPERTIES_OUTSIDE_SESSION'}
    Assert-MmtlNoReparsePath -Path $properties|Out-Null
    if(-not(Test-Path -LiteralPath $properties -PathType Leaf)){throw 'DEDICATED_PROPERTIES_MISSING'}
    $lines=[Collections.Generic.List[string]]::new([string[]][IO.File]::ReadAllLines($properties))
    $indices=@(for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match '^server-port='){$i}})
    if($indices.Count -ne 1){throw 'DEDICATED_SERVER_PORT_PROPERTY_INVALID: server-port 必须恰好出现一次。'}
    $lines[$indices[0]]="server-port=$Port"
    $content=($lines.ToArray() -join [Environment]::NewLine)+[Environment]::NewLine
    Write-MmtlAtomicTextFile -Path $properties -Content $content
    return $true
}
Export-ModuleMember -Function Get-MmtlGradleUserHomeForSession,Invoke-MmtlGradleBuild,Invoke-MmtlProjectBuildPipeline,Get-MmtlMemoryBudget,Assert-MmtlMemoryBudget,Start-MmtlGradleInstance,Initialize-MmtlDedicatedServerRuntime,Set-MmtlDedicatedServerPort,New-MmtlFabricRuntimeLink,Remove-MmtlFabricRuntimeLink,Set-MmtlClientGuiScale,Copy-MmtlRuntimeMods
