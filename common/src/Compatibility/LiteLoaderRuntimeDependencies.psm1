Set-StrictMode -Version Latest

function Get-MmtlLiteLoaderRuntimeDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)]$Universe,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$LoaderArtifactCatalog
    )

    if ([string]$Catalog.universeHash -cne [string]$Universe.catalogHash) { throw 'LITELOADER_RUNTIME_UNIVERSE_MISMATCH' }
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $schemaPath = Join-Path $root 'compatibility/liteloader-runtime-dependencies.schema.json'
    if (-not (Test-Json -Json ($Catalog | ConvertTo-Json -Depth 20 -Compress) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) { throw 'LITELOADER_RUNTIME_CATALOG_SCHEMA_INVALID' }
    if ([string]$Catalog.sourceUrl -cne 'https://dl.liteloader.com/versions/versions.json') { throw 'LITELOADER_RUNTIME_SOURCE_INVALID' }

    $matches = @($Catalog.targets | Where-Object { [string]$_.targetId -ceq $TargetId })
    if ($matches.Count -ne 1) { throw 'LITELOADER_RUNTIME_TARGET_UNSUPPORTED' }
    $target = $matches[0]
    $universeTargets = @($Universe.targets | Where-Object { [string]$_.targetId -ceq $TargetId -and [string]$_.availability -ceq 'Available' -and [string]$_.loaderId -ceq 'LiteLoader' })
    if ($universeTargets.Count -ne 1 -or [string]$target.minecraftId -cne [string]$universeTargets[0].minecraftId -or [string]$Catalog.sourceSha256 -cne [string]$universeTargets[0].sourceHash -or [string]$target.loaderVersion -cnotin @($universeTargets[0].loaderVersionCandidates | ForEach-Object { [string]$_ })) {
        throw 'LITELOADER_RUNTIME_TARGET_BINDING_MISMATCH'
    }

    $artifactModule = Join-Path $PSScriptRoot 'LiteLoaderArtifactCatalog.psm1'
    Import-Module $artifactModule -Force
    $loaderPin = Get-MmtlLiteLoaderArtifactPin -TargetId $TargetId -Universe $Universe -Catalog $LoaderArtifactCatalog
    if ([string]$target.loaderVersion -cne [string]$loaderPin.loaderVersion -or [string]$target.loaderArtifactSha256 -cne [string]$loaderPin.sha256) { throw 'LITELOADER_RUNTIME_LOADER_PIN_MISMATCH' }

    $resolvedLibraries = [System.Collections.Generic.List[object]]::new()
    foreach ($coordinate in @($target.libraries)) {
        $libraryMatches = @($Catalog.libraries | Where-Object { [string]$_.name -ceq [string]$coordinate })
        if ($libraryMatches.Count -ne 1) { throw 'LITELOADER_RUNTIME_LIBRARY_PIN_MISSING_OR_DUPLICATE' }
        $library = $libraryMatches[0]
        if ([string]$library.name -ceq 'com.google.guava:guava:16.0' -and ([string]$library.dependencySourceUrl -cne 'https://www.liteloader.com/explore/docs/user:install:manual:1.7.10?do=export_raw' -or [string]$library.dependencySourceSha256 -cne '4bd57f6775688e83f41cb66d670a735eff365954517deb9c837e8bfc58a899ec')) { throw 'LITELOADER_RUNTIME_DEPENDENCY_SOURCE_MISMATCH' }
        $uri = $null
        if (-not [Uri]::TryCreate([string]$library.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'libraries.minecraft.net' -or $uri.Port -ne 443 -or $uri.UserInfo.Length -gt 0 -or $uri.Query -or $uri.Fragment) { throw 'LITELOADER_RUNTIME_LIBRARY_URL_UNTRUSTED' }
        if ([long]$library.bytes -le 0 -or [string]$library.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [string]$library.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [string]$library.hashEvidence -cnotin @('MOJANG_SHA1_SIZE_PLUS_HTTPS_SHA256','HTTPS_DOWNLOAD_OBSERVATION')) { throw 'LITELOADER_RUNTIME_LIBRARY_PIN_INVALID' }
        $resolvedLibraries.Add($library)
    }

    return [pscustomobject]@{
        targetId = $TargetId
        minecraftId = [string]$target.minecraftId
        loaderVersion = [string]$target.loaderVersion
        loaderArtifactSha256 = [string]$loaderPin.sha256
        loaderArtifactUrl = [string]$loaderPin.artifactUrl
        loaderArtifactBytes = [long]$loaderPin.bytes
        loaderArtifactOfficialMd5 = [string]$loaderPin.officialMd5
        mainClass = [string]$Catalog.mainClass
        tweakClass = [string]$Catalog.tweakClass
        libraries = @($resolvedLibraries.ToArray())
    }
}

function Assert-MmtlLiteLoaderNoReparsePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetPathRoot($full);$cursor=$root
    foreach($segment in @($full.Substring($root.Length) -split '[\\/]+'|Where-Object{$_})){
        $cursor=Join-Path $cursor $segment
        if(Test-Path -LiteralPath $cursor){$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw 'LITELOADER_RUNTIME_PATH_REPARSE'}}
    }
    return $full
}

function Invoke-MmtlLiteLoaderHttpsDownload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Uri]$Uri,[Parameter(Mandatory)][string]$DestinationPath,[Parameter(Mandatory)][long]$ExpectedBytes,[ValidateRange(1,600)][int]$TimeoutSeconds=120)

    $current=$Uri
    for($redirect=0;$redirect -le 5;$redirect++){
        if($current.Scheme -cne 'https' -or $current.Host -cnotin @('libraries.minecraft.net','dl.liteloader.com','repo.mumfrey.com','launchermeta.mojang.com','resources.download.minecraft.net','launcher.mojang.com','piston-data.mojang.com') -or $current.Port -ne 443 -or $current.UserInfo -or $current.Query -or $current.Fragment){throw 'LITELOADER_RUNTIME_REDIRECT_REJECTED'}
        $request=[Net.HttpWebRequest]::Create($current);$request.Method='GET';$request.AllowAutoRedirect=$false;$request.Timeout=$TimeoutSeconds*1000;$request.ReadWriteTimeout=$TimeoutSeconds*1000
        $response=$null
        try {
            $response = $request.GetResponse()
        }
        catch [Net.WebException] {
            $response = $_.Exception.Response
            if (-not $response) { throw }
        }
        if([int]$response.StatusCode -in @(301,302,303,307,308)){$location=[string]$response.Headers['Location'];$response.Close();if(-not $location -or $redirect -eq 5){throw 'LITELOADER_RUNTIME_REDIRECT_LIMIT'};$current=[Uri]::new($current,$location);continue}
        if([int]$response.StatusCode -ne 200){$status=[int]$response.StatusCode;$response.Close();throw "LITELOADER_RUNTIME_HTTP_STATUS:$status"}
        if($response.ContentLength -gt $ExpectedBytes){$response.Close();throw 'LITELOADER_RUNTIME_ARTIFACT_SIZE_LIMIT'}
        try{$inputStream=$response.GetResponseStream();$output=[IO.FileStream]::new($DestinationPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$buffer=[byte[]]::new(65536);$total=0L;while(($read=$inputStream.Read($buffer,0,$buffer.Length))-gt 0){$total+=$read;if($total -gt $ExpectedBytes){throw 'LITELOADER_RUNTIME_ARTIFACT_SIZE_LIMIT'};$output.Write($buffer,0,$read)}}finally{$output.Dispose();$inputStream.Dispose()}}finally{$response.Close()}
        return
    }
    throw 'LITELOADER_RUNTIME_REDIRECT_LIMIT'
}

function Save-MmtlLiteLoaderClientArtifact {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$LoaderLaunchPlan,[scriptblock]$Download,[ValidateRange(1,600)][int]$TimeoutSeconds=120)

    $minecraftId=[string]$LoaderLaunchPlan.minecraftId
    $pin=$LoaderLaunchPlan.clientArtifact
    $uri=$null
    if($minecraftId -notmatch '^[A-Za-z0-9._-]{1,64}$' -or -not $pin -or -not [Uri]::TryCreate([string]$pin.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cnotin @('launcher.mojang.com','piston-data.mojang.com') -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or [string]$pin.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [long]$pin.bytes -le 0 -or $uri.AbsolutePath -cnotmatch ('^/v1/objects/'+[regex]::Escape([string]$pin.sha1)+'/client\.jar$')){throw 'LITELOADER_CLIENT_ARTIFACT_PIN_INVALID'}
    $session=Assert-MmtlLiteLoaderNoReparsePath -Path $SessionPath
    if(-not(Test-Path -LiteralPath $session -PathType Container)){throw 'LITELOADER_CLIENT_SESSION_MISSING'}
    $artifactRoot=Join-Path $session 'gradle-loader/minecraft-artifacts'
    $null=Assert-MmtlLiteLoaderNoReparsePath -Path $artifactRoot;New-Item -ItemType Directory -Path $artifactRoot -Force|Out-Null;$null=Assert-MmtlLiteLoaderNoReparsePath -Path $artifactRoot
    $destination=Join-Path $artifactRoot ('client-'+$minecraftId+'.jar')
    if(Test-Path -LiteralPath $destination){
        $item=Get-Item -LiteralPath $destination -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw 'LITELOADER_CLIENT_ARTIFACT_REPARSE'}
        if([long]$item.Length -ne [long]$pin.bytes -or (Get-FileHash -LiteralPath $destination -Algorithm SHA1).Hash -ine [string]$pin.sha1){throw 'LITELOADER_CLIENT_ARTIFACT_CACHE_INVALID'}
        return [pscustomobject]@{path=[IO.Path]::GetFullPath($destination);bytes=[long]$pin.bytes;sha1=([string]$pin.sha1).ToLowerInvariant();cached=$true}
    }
    $temporary=Join-Path $artifactRoot ('.client-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        if($Download){& $Download $uri $temporary}else{Invoke-MmtlLiteLoaderHttpsDownload -Uri $uri -DestinationPath $temporary -ExpectedBytes ([long]$pin.bytes) -TimeoutSeconds $TimeoutSeconds}
        if(-not(Test-Path -LiteralPath $temporary -PathType Leaf)){throw 'LITELOADER_CLIENT_ARTIFACT_DOWNLOAD_MISSING'}
        $downloaded=Get-Item -LiteralPath $temporary -Force
        if(($downloaded.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$downloaded.Length -ne [long]$pin.bytes){throw 'LITELOADER_CLIENT_ARTIFACT_SIZE_MISMATCH'}
        if((Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash -ine [string]$pin.sha1){throw 'LITELOADER_CLIENT_ARTIFACT_SHA1_MISMATCH'}
        [IO.File]::Move($temporary,$destination)
        return [pscustomobject]@{path=[IO.Path]::GetFullPath($destination);bytes=[long]$pin.bytes;sha1=([string]$pin.sha1).ToLowerInvariant();cached=$false}
    }finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}
}

function Save-MmtlLiteLoaderRuntimeArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$LoaderLaunchPlan,[scriptblock]$Download,[ValidateRange(1,600)][int]$TimeoutSeconds=120)

    if([string]$LoaderLaunchPlan.targetId -notmatch '^LiteLoader@[^/\\]+$' -or [string]$LoaderLaunchPlan.loaderVersion -notmatch '^[A-Za-z0-9_.+-]+$'){throw 'LITELOADER_RUNTIME_TARGET_INVALID'}
    $session=Assert-MmtlLiteLoaderNoReparsePath -Path $SessionPath
    if(-not(Test-Path -LiteralPath $session -PathType Container)){New-Item -ItemType Directory -Path $session -Force|Out-Null;$session=Assert-MmtlLiteLoaderNoReparsePath -Path $session}
    $artifactRoot=Join-Path $session 'libraries/liteloader';$null=Assert-MmtlLiteLoaderNoReparsePath -Path $artifactRoot;New-Item -ItemType Directory -Path $artifactRoot -Force|Out-Null;$null=Assert-MmtlLiteLoaderNoReparsePath -Path $artifactRoot
    $artifacts=[Collections.Generic.List[object]]::new()
    $artifacts.Add([pscustomobject]@{name="com.mumfrey:liteloader:$($LoaderLaunchPlan.loaderVersion)";url=[string]$LoaderLaunchPlan.loaderArtifactUrl;bytes=[long]$LoaderLaunchPlan.loaderArtifactBytes;sha256=[string]$LoaderLaunchPlan.loaderArtifactSha256;officialMd5=[string]$LoaderLaunchPlan.loaderArtifactOfficialMd5;sha1=$null;kind='Loader'})
    foreach($library in @($LoaderLaunchPlan.libraries)){$artifacts.Add([pscustomobject]@{name=[string]$library.name;url=[string]$library.url;bytes=[long]$library.bytes;sha1=[string]$library.sha1;sha256=[string]$library.sha256;officialMd5=$null;kind='Library'})}
    $results=[Collections.Generic.List[object]]::new()
    foreach($artifact in $artifacts){
        $parts=@(([string]$artifact.name).Split(':'))
        if($parts.Count -ne 3 -or $parts[0] -notmatch '^[A-Za-z0-9_.-]+$' -or $parts[1] -notmatch '^[A-Za-z0-9_.-]+$' -or $parts[2] -notmatch '^[A-Za-z0-9_.+-]+$'){throw 'LITELOADER_RUNTIME_COORDINATE_INVALID'}
        $uri=$null
        if (-not [Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cnotin @('libraries.minecraft.net','dl.liteloader.com','repo.mumfrey.com') -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'LITELOADER_RUNTIME_URL_UNTRUSTED' }
        if([long]$artifact.bytes -le 0 -or [string]$artifact.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or ($artifact.kind -eq 'Loader' -and [string]$artifact.officialMd5 -notmatch '^(?i:[a-f0-9]{32})$') -or ($artifact.kind -eq 'Library' -and [string]$artifact.sha1 -notmatch '^(?i:[a-f0-9]{40})$')){throw 'LITELOADER_RUNTIME_ARTIFACT_PIN_INVALID'}
        $relative=$parts[0].Replace('.',[IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar+$parts[1]+[IO.Path]::DirectorySeparatorChar+$parts[2]+[IO.Path]::DirectorySeparatorChar+$parts[1]+'-'+$parts[2]+'.jar'
        $destination=[IO.Path]::GetFullPath((Join-Path $artifactRoot $relative));$prefix=[IO.Path]::GetFullPath($artifactRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
        if(-not $destination.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'LITELOADER_RUNTIME_PATH_ESCAPE'}
        $parent=Split-Path -Parent $destination;$null=Assert-MmtlLiteLoaderNoReparsePath -Path $parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null;$null=Assert-MmtlLiteLoaderNoReparsePath -Path $parent
        if(Test-Path -LiteralPath $destination){
            $item=Get-Item -LiteralPath $destination -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw 'LITELOADER_RUNTIME_ARTIFACT_REPARSE'}
            if([long]$item.Length -ne [long]$artifact.bytes){throw 'LITELOADER_RUNTIME_ARTIFACT_LENGTH_MISMATCH'}
            if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine [string]$artifact.sha256){throw 'LITELOADER_RUNTIME_ARTIFACT_SHA256_MISMATCH'}
            if($artifact.kind -eq 'Loader' -and (Get-FileHash -LiteralPath $destination -Algorithm MD5).Hash -ine [string]$artifact.officialMd5){throw 'LITELOADER_RUNTIME_ARTIFACT_MD5_MISMATCH'}
            if($artifact.kind -eq 'Library' -and (Get-FileHash -LiteralPath $destination -Algorithm SHA1).Hash -ine [string]$artifact.sha1){throw 'LITELOADER_RUNTIME_ARTIFACT_SHA1_MISMATCH'}
            $results.Add([pscustomobject]@{name=$artifact.name;path=$destination;sha256=[string]$artifact.sha256;cached=$true});continue
        }
        $temporary=Join-Path $parent ('.mmtl-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try{
            if($Download){& $Download $uri $temporary}else{Invoke-MmtlLiteLoaderHttpsDownload -Uri $uri -DestinationPath $temporary -ExpectedBytes ([long]$artifact.bytes) -TimeoutSeconds $TimeoutSeconds}
            if(-not(Test-Path -LiteralPath $temporary -PathType Leaf)){throw 'LITELOADER_RUNTIME_ARTIFACT_DOWNLOAD_MISSING'}
            $downloaded=Get-Item -LiteralPath $temporary -Force
            if(($downloaded.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$downloaded.Length -ne [long]$artifact.bytes){throw 'LITELOADER_RUNTIME_ARTIFACT_LENGTH_MISMATCH'}
            if((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine [string]$artifact.sha256){throw 'LITELOADER_RUNTIME_ARTIFACT_SHA256_MISMATCH'}
            if($artifact.kind -eq 'Loader' -and (Get-FileHash -LiteralPath $temporary -Algorithm MD5).Hash -ine [string]$artifact.officialMd5){throw 'LITELOADER_RUNTIME_ARTIFACT_MD5_MISMATCH'}
            if($artifact.kind -eq 'Library' -and (Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash -ine [string]$artifact.sha1){throw 'LITELOADER_RUNTIME_ARTIFACT_SHA1_MISMATCH'}
            [IO.File]::Move($temporary,$destination);$results.Add([pscustomobject]@{name=$artifact.name;path=$destination;sha256=[string]$artifact.sha256;cached=$false})
        }finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}
    }
    return @($results.ToArray())
}

function Save-MmtlMojangAssets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GradleUserHome,[Parameter(Mandatory)]$LoaderLaunchPlan,[scriptblock]$Download,[ValidateRange(1,600)][int]$TimeoutSeconds=120)

    $minecraftId=[string]$LoaderLaunchPlan.minecraftId
    if($minecraftId -notmatch '^[A-Za-z0-9._-]{1,64}$'){throw 'LITELOADER_ASSET_MINECRAFT_ID_INVALID'}
    $pin=$LoaderLaunchPlan.assetIndex
    $indexUri=$null
    if(-not $pin -or -not [Uri]::TryCreate([string]$pin.url,[UriKind]::Absolute,[ref]$indexUri) -or $indexUri.Scheme -cne 'https' -or $indexUri.Host -cne 'launchermeta.mojang.com' -or $indexUri.Port -ne 443 -or $indexUri.UserInfo -or $indexUri.Query -or $indexUri.Fragment -or $indexUri.AbsolutePath -notmatch ('^/v1/packages/'+[regex]::Escape([string]$pin.sha1)+'/'+[regex]::Escape($minecraftId)+'\.json$') -or [string]$pin.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [long]$pin.bytes -le 0 -or [long]$pin.bytes -gt 16777216){throw 'LITELOADER_ASSET_INDEX_PIN_INVALID'}

    $home=Assert-MmtlLiteLoaderNoReparsePath -Path $GradleUserHome
    if(-not(Test-Path -LiteralPath $home -PathType Container)){New-Item -ItemType Directory -Path $home -Force|Out-Null;$home=Assert-MmtlLiteLoaderNoReparsePath -Path $home}
    $assetsRoot=Join-Path $home 'caches/minecraft/assets'
    $indexRoot=Join-Path $assetsRoot 'indexes'
    $objectsRoot=Join-Path $assetsRoot 'objects'
    foreach($directory in @($assetsRoot,$indexRoot,$objectsRoot)){$null=Assert-MmtlLiteLoaderNoReparsePath -Path $directory;New-Item -ItemType Directory -Path $directory -Force|Out-Null;$null=Assert-MmtlLiteLoaderNoReparsePath -Path $directory}

    $downloadPinnedFile={
        param([Uri]$Uri,[string]$DestinationPath,[long]$ExpectedBytes,[string]$ExpectedSha1,[string]$ErrorPrefix)
        $destination=[IO.Path]::GetFullPath($DestinationPath);$parent=Split-Path -Parent $destination
        $null=Assert-MmtlLiteLoaderNoReparsePath -Path $parent;New-Item -ItemType Directory -Path $parent -Force|Out-Null;$null=Assert-MmtlLiteLoaderNoReparsePath -Path $parent
        if(Test-Path -LiteralPath $destination){$existing=Get-Item -LiteralPath $destination -Force;if(($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $existing.LinkType){throw ($ErrorPrefix+'_CACHE_REPARSE')};if([long]$existing.Length -eq $ExpectedBytes -and (Get-FileHash -LiteralPath $destination -Algorithm SHA1).Hash -ieq $ExpectedSha1){return $true}}
        $temporary=Join-Path $parent ('.mmtl-'+[guid]::NewGuid().ToString('N')+'.tmp')
        try{
            if($Download){& $Download $Uri $temporary}else{Invoke-MmtlLiteLoaderHttpsDownload -Uri $Uri -DestinationPath $temporary -ExpectedBytes $ExpectedBytes -TimeoutSeconds $TimeoutSeconds}
            if(-not(Test-Path -LiteralPath $temporary -PathType Leaf)){throw ($ErrorPrefix+'_DOWNLOAD_MISSING')}
            $downloaded=Get-Item -LiteralPath $temporary -Force
            if(($downloaded.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [long]$downloaded.Length -ne $ExpectedBytes){throw ($ErrorPrefix+'_SIZE_MISMATCH')}
            if((Get-FileHash -LiteralPath $temporary -Algorithm SHA1).Hash -ine $ExpectedSha1){throw ($ErrorPrefix+'_SHA1_MISMATCH')}
            try{if(Test-Path -LiteralPath $destination){[IO.File]::Replace($temporary,$destination,$null)}else{[IO.File]::Move($temporary,$destination)};return $false}
            catch [IO.IOException]{
                if(Test-Path -LiteralPath $destination){$published=Get-Item -LiteralPath $destination -Force;if(-not($published.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [long]$published.Length -eq $ExpectedBytes -and (Get-FileHash -LiteralPath $destination -Algorithm SHA1).Hash -ieq $ExpectedSha1){return $true}}
                throw
            }
        }finally{if(Test-Path -LiteralPath $temporary -PathType Leaf){[IO.File]::Delete($temporary)}}
    }

    $indexPath=Join-Path $indexRoot ($minecraftId+'.json')
    $indexCached=& $downloadPinnedFile $indexUri $indexPath ([long]$pin.bytes) ([string]$pin.sha1).ToLowerInvariant() 'LITELOADER_ASSET_INDEX'
    try{$indexDocument=Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{throw 'LITELOADER_ASSET_INDEX_JSON_INVALID'}
    if(-not $indexDocument.objects -or $indexDocument.objects -isnot [pscustomobject]){throw 'LITELOADER_ASSET_INDEX_OBJECTS_INVALID'}
    $records=@($indexDocument.objects.PSObject.Properties)
    if($records.Count -gt 100000){throw 'LITELOADER_ASSET_OBJECT_COUNT_LIMIT'}

    $cachedAssets=0;$downloadedAssets=0;$totalBytes=0L
    foreach($record in $records){
        $hash=[string]$record.Value.hash;$size=[long]$record.Value.size
        if($hash -notmatch '^(?i:[a-f0-9]{40})$' -or $size -lt 0 -or $size -gt 536870912){throw 'LITELOADER_ASSET_OBJECT_PIN_INVALID'}
        $totalBytes+=$size;if($totalBytes -gt 4294967296){throw 'LITELOADER_ASSET_TOTAL_SIZE_LIMIT'}
        $hash=$hash.ToLowerInvariant();$objectPath=Join-Path (Join-Path $objectsRoot $hash.Substring(0,2)) $hash
        $objectUri=[Uri]::new("https://resources.download.minecraft.net/$($hash.Substring(0,2))/$hash")
        $wasCached=& $downloadPinnedFile $objectUri $objectPath $size $hash 'LITELOADER_ASSET_OBJECT'
        if($wasCached){$cachedAssets++}else{$downloadedAssets++}
    }

    return [pscustomobject]@{minecraftId=$minecraftId;assetCount=$records.Count;cachedAssetCount=$cachedAssets;downloadedAssetCount=$downloadedAssets;assetBytes=$totalBytes;indexCached=[bool]$indexCached;indexSha1=([string]$pin.sha1).ToLowerInvariant()}
}

Export-ModuleMember -Function Get-MmtlLiteLoaderRuntimeDependencies,Save-MmtlLiteLoaderRuntimeArtifacts,Save-MmtlLiteLoaderClientArtifact,Save-MmtlMojangAssets
