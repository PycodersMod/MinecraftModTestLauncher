Set-StrictMode -Version Latest

function Test-MmtlAgentPathInsideRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Target)
    $rootPath=[IO.Path]::GetFullPath($Root);$targetPath=[IO.Path]::GetFullPath($Target)
    $comparison=if([IO.Path]::DirectorySeparatorChar -eq '\'){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if($targetPath.Equals($rootPath,$comparison)){return $true}
    $relative=[IO.Path]::GetRelativePath($rootPath,$targetPath)
    return -not ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,$comparison) -or $relative.StartsWith('..'+[IO.Path]::AltDirectorySeparatorChar,$comparison))
}

function Assert-MmtlAgentNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetPathRoot($full);$current=$root
    foreach($part in ($full.Substring($root.Length) -split '[\\/]'|Where-Object{$_})){$current=Join-Path $current $part;if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'AGENT_PATH_REPARSE_POINT'}}}
}

function Get-MmtlAgentProviderStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AgentRoot,[Parameter(Mandatory)][string]$LoaderId,[Parameter(Mandatory)][string]$MinecraftVersion)
    $root=[IO.Path]::GetFullPath($AgentRoot)
    if(-not(Test-Path -LiteralPath $root -PathType Container)){return [pscustomobject]@{status='Unsupported';reason='AGENT_PROVIDER_NOT_FOUND';loaderId=$LoaderId;minecraftVersion=$MinecraftVersion}}
    Assert-MmtlAgentNoReparsePath -Path $root
    $manifests=@(Get-ChildItem -LiteralPath $root -Filter 'agent-manifest.json' -File -Recurse -ErrorAction SilentlyContinue)
    foreach($file in $manifests){
        try{$manifest=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json -ErrorAction Stop}catch{continue}
        if([string]$manifest.loaderId -cne $LoaderId){continue}
        if(@($manifest.minecraftVersions) -notcontains $MinecraftVersion){continue}
        $providerRoot=[IO.Path]::GetDirectoryName($file.FullName)
        if([int]$manifest.schemaVersion -ne 1 -or -not $manifest.providerId -or -not $manifest.agentVersion -or -not $manifest.artifact -or [string]$manifest.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or [int]$manifest.minJavaMajor -lt 1 -or -not @($manifest.roles).Count){return [pscustomobject]@{status='Unsupported';reason='AGENT_MANIFEST_INVALID';loaderId=$LoaderId;minecraftVersion=$MinecraftVersion}}
        $relative=[string]$manifest.artifact
        if([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)'){return [pscustomobject]@{status='Unsupported';reason='AGENT_MANIFEST_INVALID';loaderId=$LoaderId;minecraftVersion=$MinecraftVersion}}
        $artifact=Join-Path $root $relative
        if(-not(Test-MmtlAgentPathInsideRoot -Root $root -Target $artifact)){return [pscustomobject]@{status='Unsupported';reason='AGENT_MANIFEST_INVALID';loaderId=$LoaderId;minecraftVersion=$MinecraftVersion}}
        if(-not(Test-Path -LiteralPath $artifact -PathType Leaf)){return [pscustomobject]@{status='Unsupported';reason='AGENT_ARTIFACT_MISSING';loaderId=$LoaderId;minecraftVersion=$MinecraftVersion;providerId=[string]$manifest.providerId}}
        try{Assert-MmtlAgentNoReparsePath -Path $artifact}catch{return [pscustomobject]@{status='Unsupported';reason='AGENT_MANIFEST_INVALID';loaderId=$LoaderId;minecraftVersion=$MinecraftVersion}}
        $actual=(Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -cne ([string]$manifest.sha256).ToLowerInvariant()){return [pscustomobject]@{status='Unsupported';reason='AGENT_ARTIFACT_HASH_MISMATCH';loaderId=$LoaderId;minecraftVersion=$MinecraftVersion;providerId=[string]$manifest.providerId}}
        return [pscustomobject][ordered]@{status='Supported';reason=$null;loaderId=$LoaderId;minecraftVersion=$MinecraftVersion;providerId=[string]$manifest.providerId;agentVersion=[string]$manifest.agentVersion;minJavaMajor=[int]$manifest.minJavaMajor;artifactPath=$artifact;agentRoot=$root;sha256=$actual;roles=@($manifest.roles|ForEach-Object{[string]$_});capabilities=@($manifest.capabilities|ForEach-Object{[string]$_})}
    }
    $loaderManifest=@($manifests|ForEach-Object{try{Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json -ErrorAction Stop}catch{$null}}|Where-Object{[string]$_.loaderId -ceq $LoaderId})
    $reason=if($loaderManifest.Count){'AGENT_VERSION_UNSUPPORTED'}else{'AGENT_PROVIDER_NOT_FOUND'}
    return [pscustomobject]@{status='Unsupported';reason=$reason;loaderId=$LoaderId;minecraftVersion=$MinecraftVersion}
}

function New-MmtlAgentLaunchBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Provider,[Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$SessionId,[Parameter(Mandatory)][ValidateSet('Client','Host','Guest','Server')][string]$Role,[Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{32,128}$')][string]$SessionToken,[ValidateRange(0,65535)][int]$IntegratedLanPort=0,[ValidateRange(0,65535)][int]$ExpectedLoopbackPort=0)
    if($Provider.status -cne 'Supported'){throw 'AGENT_PROVIDER_UNSUPPORTED'}
    if(@($Provider.roles) -notcontains $Role){throw 'AGENT_ROLE_UNSUPPORTED'}
    if($IntegratedLanPort -gt 0 -and $Role -cne 'Host'){throw 'AGENT_LAN_PUBLISH_HOST_ONLY'}
    if($ExpectedLoopbackPort -gt 0 -and $Role -cne 'Guest'){throw 'AGENT_LOOPBACK_EXPECTATION_GUEST_ONLY'}
    if($Role -ceq 'Guest' -and $ExpectedLoopbackPort -eq 0){throw 'AGENT_GUEST_LOOPBACK_PORT_REQUIRED'}
    $session=[IO.Path]::GetFullPath($SessionPath)
    if(-not(Test-Path -LiteralPath $session -PathType Container)){throw 'AGENT_SESSION_PATH_INVALID'}
    Assert-MmtlAgentNoReparsePath -Path $session
    $sessionRecordPath=Join-Path $session 'session.json'
    if(-not(Test-Path -LiteralPath $sessionRecordPath -PathType Leaf)){throw 'AGENT_SESSION_METADATA_MISSING'}
    Assert-MmtlAgentNoReparsePath -Path $sessionRecordPath
    try{$sessionRecord=Get-Content -LiteralPath $sessionRecordPath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{throw 'AGENT_SESSION_METADATA_INVALID'}
    if([string]$sessionRecord.sessionId -cne $SessionId){throw 'AGENT_SESSION_ID_MISMATCH'}
    $artifactSource=[IO.Path]::GetFullPath([string]$Provider.artifactPath)
    if(-not(Test-MmtlAgentPathInsideRoot -Root ([string]$Provider.agentRoot) -Target $artifactSource)){throw 'AGENT_ARTIFACT_OUTSIDE_PROVIDER_ROOT'}
    Assert-MmtlAgentNoReparsePath -Path $artifactSource
    if((Get-FileHash -LiteralPath $artifactSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Provider.sha256){throw 'AGENT_ARTIFACT_HASH_MISMATCH'}
    $artifactDirectory=Join-Path $session 'agent'
    $eventDirectory=Join-Path $session 'agent-events'
    New-Item -ItemType Directory -Path $artifactDirectory,$eventDirectory -Force|Out-Null
    Assert-MmtlAgentNoReparsePath -Path $artifactDirectory;Assert-MmtlAgentNoReparsePath -Path $eventDirectory
    $artifactPath=Join-Path $artifactDirectory ([IO.Path]::GetFileName($artifactSource))
    if(Test-Path -LiteralPath $artifactPath){if((Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Provider.sha256){throw 'AGENT_SESSION_ARTIFACT_CONFLICT'}}else{[IO.File]::Copy($artifactSource,$artifactPath,$false)}
    Assert-MmtlAgentNoReparsePath -Path $artifactPath
    if((Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Provider.sha256){throw 'AGENT_SESSION_ARTIFACT_HASH_MISMATCH'}
    $item=Get-Item -LiteralPath $artifactPath -Force;$item.Attributes=$item.Attributes -bor [IO.FileAttributes]::ReadOnly
    $eventSink=Join-Path $eventDirectory ($Role.ToLowerInvariant()+'.jsonl')
    if(-not(Test-Path -LiteralPath $eventSink -PathType Leaf)){[IO.File]::WriteAllText($eventSink,'',[Text.UTF8Encoding]::new($false))}
    Assert-MmtlAgentNoReparsePath -Path $eventSink
    $tokenFile=Join-Path $artifactDirectory 'session-token.txt'
    if(Test-Path -LiteralPath $tokenFile){
        Assert-MmtlAgentNoReparsePath -Path $tokenFile
        if([IO.File]::ReadAllText($tokenFile) -cne $SessionToken){throw 'AGENT_SESSION_TOKEN_CONFLICT'}
    }else{[IO.File]::WriteAllText($tokenFile,$SessionToken,[Text.UTF8Encoding]::new($false))}
    $nonceHash=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SessionToken)))).ToLowerInvariant()
    $allowedRoles=(@($Provider.roles|ForEach-Object{[string]$_}) -join ',')
    $args=@("-Dmmtl.agent.sessionId=$SessionId","-Dmmtl.agent.role=$Role","-Dmmtl.agent.allowedRoles=$allowedRoles","-Dmmtl.agent.sessionTokenFile=$tokenFile","-Dmmtl.agent.sessionNonceHash=$nonceHash","-Dmmtl.agent.sessionRoot=$session","-Dmmtl.agent.eventSink=$eventSink")
    if($IntegratedLanPort -gt 0){$args+="-Dmmtl.agent.integratedLanPort=$IntegratedLanPort"}
    if($ExpectedLoopbackPort -gt 0){$args+="-Dmmtl.agent.expectedLoopbackPort=$ExpectedLoopbackPort"}
    return [pscustomobject][ordered]@{providerId=[string]$Provider.providerId;artifactPath=$artifactPath;artifactSha256=[string]$Provider.sha256;eventSink=$eventSink;sessionId=$SessionId;role=$Role;sessionNonceHash=$nonceHash;integratedLanPort=$IntegratedLanPort;expectedLoopbackPort=$ExpectedLoopbackPort;jvmArgs=$args;capabilities=@($Provider.capabilities)}
}

Export-ModuleMember -Function Test-MmtlAgentPathInsideRoot,Get-MmtlAgentProviderStatus,New-MmtlAgentLaunchBinding
