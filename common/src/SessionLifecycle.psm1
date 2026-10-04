Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Execution/ExecutionPlan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AtomicFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SessionLock.psm1') -Force
$script:MmtlSessionV2Transitions=@{Created=@('Preparing','Building','Launching','Failed');Preparing=@('Building','Launching','Failed');Building=@('Launching','Completed','Failed');Launching=@('Running','Failed');Running=@('Completed','Failed','Stopped');Completed=@();Failed=@();Stopped=@()}

function Get-MmtlSessionV2StateTransitions { return $script:MmtlSessionV2Transitions }

function Assert-MmtlSessionV2PathNoReparse {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path);$drive=[IO.Path]::GetPathRoot($full);$current=$drive
    foreach($part in ($full.Substring($drive.Length) -split '[\\/]' | Where-Object {$_})){
        $current=Join-Path $current $part
        if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw "SESSION_PATH_REPARSE_POINT: $current"}}
    }
    return $true
}

function Get-MmtlSessionV2Paths {
    param([Parameter(Mandatory)][string]$SessionPath)
    $session=[IO.Path]::GetFullPath($SessionPath)
    return [pscustomobject]@{session=$session;manifest=(Join-Path $session 'session.v2.json');plan=(Join-Path $session 'execution-plan.json')}
}

function Get-MmtlSessionProperty {
    param([AllowNull()]$Object,[Parameter(Mandatory)][string]$Name)
    if($null -eq $Object){return $null}
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $null
}

function Initialize-MmtlSessionV2 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)]$ExecutionPlan)
    $paths=Get-MmtlSessionV2Paths $SessionPath
    if(-not(Test-Path -LiteralPath $paths.session -PathType Container)){throw 'SESSION_PATH_MISSING'}
    Assert-MmtlSessionV2PathNoReparse -Path $paths.session|Out-Null
    Assert-MmtlSessionV2PathNoReparse -Path $paths.plan|Out-Null
    Assert-MmtlSessionV2PathNoReparse -Path $paths.manifest|Out-Null
    $lock=New-MmtlSessionLock -LockPath (Join-Path $paths.session '.session.lock') -AllowedRoot $paths.session
    try{
        if(Test-Path -LiteralPath $paths.manifest -PathType Leaf){throw 'SESSION_MANIFEST_EXISTS'}
        $check=Test-MmtlExecutionPlan -Plan $ExecutionPlan
        if(-not $check.valid){throw "SESSION_PLAN_INVALID: $($check.errors -join ',')"}
        $json=ConvertTo-Json -InputObject $ExecutionPlan -Depth 100
        Write-MmtlAtomicTextFile -Path $paths.plan -Content ($json+"`n")
        $hash=(Get-FileHash -LiteralPath $paths.plan -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=[ordered]@{schemaVersion=2;sessionId=[IO.Path]::GetFileName($paths.session);state='Created';createdUtc=[DateTimeOffset]::UtcNow.ToString('o');updatedUtc=[DateTimeOffset]::UtcNow.ToString('o');planFile='execution-plan.json';planDigest=[string]$ExecutionPlan.semanticDigest;planSha256="sha256:$hash";artifacts=@([pscustomobject]@{path='execution-plan.json';sha256="sha256:$hash";kind='ExecutionPlan'})}
        Write-MmtlAtomicTextFile -Path $paths.manifest -Content ((ConvertTo-Json -InputObject $manifest -Depth 20)+"`n")
        return [pscustomobject]$manifest
    }finally{Remove-MmtlSessionLock -Lock $lock}
}

function Set-MmtlSessionV2State {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath,[Parameter(Mandatory)][ValidateSet('Preparing','Building','Launching','Running','Completed','Failed','Stopped')][string]$State)
    $paths=Get-MmtlSessionV2Paths $SessionPath
    if(Test-Path -LiteralPath $paths.session -PathType Container){Assert-MmtlSessionV2PathNoReparse -Path $paths.session|Out-Null}
    Assert-MmtlSessionV2PathNoReparse -Path $paths.manifest|Out-Null
    Assert-MmtlSessionV2PathNoReparse -Path $paths.plan|Out-Null
    if(-not(Test-Path -LiteralPath $paths.manifest -PathType Leaf)){throw 'SESSION_MANIFEST_MISSING'}
    $lock=New-MmtlSessionLock -LockPath (Join-Path $paths.session '.session.lock') -AllowedRoot $paths.session
    try{
        try{$manifest=Get-Content -LiteralPath $paths.manifest -Raw|ConvertFrom-Json -ErrorAction Stop}catch{throw 'SESSION_MANIFEST_CORRUPT'}
        if(-not $script:MmtlSessionV2Transitions.ContainsKey([string]$manifest.state)){throw 'SESSION_MANIFEST_CORRUPT'}
        if($State -notin $script:MmtlSessionV2Transitions[[string]$manifest.state]){throw "SESSION_STATE_TRANSITION_INVALID: $($manifest.state)->$State"}
        $manifest.state=$State;$manifest.updatedUtc=[DateTimeOffset]::UtcNow.ToString('o')
        Write-MmtlAtomicTextFile -Path $paths.manifest -Content (($manifest|ConvertTo-Json -Depth 30)+"`n")
        return $manifest
    }finally{Remove-MmtlSessionLock -Lock $lock}
}

function Test-MmtlSessionV2 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionPath)
    $paths=Get-MmtlSessionV2Paths $SessionPath
    try{Assert-MmtlSessionV2PathNoReparse -Path $paths.session|Out-Null;Assert-MmtlSessionV2PathNoReparse -Path $paths.manifest|Out-Null;Assert-MmtlSessionV2PathNoReparse -Path $paths.plan|Out-Null}catch{return [pscustomobject]@{valid=$false;status='UnsafePath';errors=@('SESSION_PATH_REPARSE_POINT');state=$null;sessionId=[IO.Path]::GetFileName($paths.session)}}
    if(-not(Test-Path -LiteralPath $paths.manifest -PathType Leaf)){return [pscustomobject]@{valid=$false;status='LegacyOrManifestMissing';errors=@('SESSION_MANIFEST_MISSING');state=$null;sessionId=[IO.Path]::GetFileName($paths.session)}}
    try{$manifest=Get-Content -LiteralPath $paths.manifest -Raw|ConvertFrom-Json -ErrorAction Stop}catch{return [pscustomobject]@{valid=$false;status='Corrupt';errors=@('SESSION_MANIFEST_CORRUPT');state=$null;sessionId=[IO.Path]::GetFileName($paths.session)}}
    $errors=[Collections.Generic.List[string]]::new()
    if($manifest.schemaVersion -ne 2){$errors.Add('SESSION_SCHEMA_UNSUPPORTED')}
    if([string]$manifest.sessionId -cne [IO.Path]::GetFileName($paths.session)){$errors.Add('SESSION_ID_MISMATCH')}
    $manifestJson=ConvertTo-Json -InputObject $manifest -Depth 50 -Compress
    $manifestSchema=Join-Path $PSScriptRoot '../schemas/session-v2.schema.json'
    if(-not(Test-Json -Json $manifestJson -SchemaFile $manifestSchema -ErrorAction SilentlyContinue)){$errors.Add('SESSION_MANIFEST_SCHEMA_INVALID')}
    if(-not(Test-Path -LiteralPath $paths.plan -PathType Leaf)){return [pscustomobject]@{valid=$false;status='ArtifactMissing';errors=@('SESSION_ARTIFACT_MISSING');state=[string]$manifest.state;sessionId=[string]$manifest.sessionId}}
    $hash=(Get-FileHash -LiteralPath $paths.plan -Algorithm SHA256).Hash.ToLowerInvariant()
    if("sha256:$hash" -cne [string]$manifest.planSha256){$errors.Add('SESSION_ARTIFACT_HASH_MISMATCH')}
    try{$plan=Get-Content -LiteralPath $paths.plan -Raw|ConvertFrom-Json -ErrorAction Stop;$planCheck=Test-MmtlExecutionPlan -Plan $plan;if(-not $planCheck.valid){$errors.AddRange([string[]]$planCheck.errors)};if([string]$plan.semanticDigest -cne [string]$manifest.planDigest){$errors.Add('SESSION_PLAN_DIGEST_MISMATCH')}}catch{$errors.Add('SESSION_ARTIFACT_CORRUPT')}
    $statePath=Join-Path $paths.session 'session.json'
    if(Test-Path -LiteralPath $statePath -PathType Leaf){
        try{$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -ErrorAction Stop}catch{$errors.Add('SESSION_STATE_CORRUPT');$state=$null}
        $buildResult=Get-MmtlSessionProperty $state 'buildResult'
        $artifactHash=Get-MmtlSessionProperty $state 'jarSha256';if(-not $artifactHash){$artifactHash=Get-MmtlSessionProperty $buildResult 'JarSha256'}
        $artifactPath=Get-MmtlSessionProperty $state 'jarPath';if(-not $artifactPath){$artifactPath=Get-MmtlSessionProperty $buildResult 'JarPath'}
        if($artifactHash -or $artifactPath){
            if([string]$artifactHash -notmatch '^(?:sha256:)?[0-9A-Fa-f]{64}$'){$errors.Add('SESSION_ARTIFACT_HASH_INVALID')}
            if(-not $artifactPath){$errors.Add('SESSION_ARTIFACT_PATH_INVALID')}
            else{
                try{
                    $artifactFull=[IO.Path]::GetFullPath([string]$artifactPath)
                    $projectRoot=[string](Get-MmtlSessionProperty (Get-MmtlSessionProperty $state 'metadata') 'project')
                    if(-not $projectRoot){$errors.Add('SESSION_ARTIFACT_PATH_INVALID')}
                    else{
                        $projectFull=[IO.Path]::GetFullPath($projectRoot);$relative=[IO.Path]::GetRelativePath($projectFull,$artifactFull)
                        if([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or $relative.StartsWith('..'+[IO.Path]::AltDirectorySeparatorChar,[StringComparison]::Ordinal)){$errors.Add('SESSION_ARTIFACT_PATH_INVALID')}
                        else{
                            $artifactSafe=$true
                            try{Assert-MmtlSessionV2PathNoReparse -Path $artifactFull|Out-Null}catch{$errors.Add('SESSION_PATH_REPARSE_POINT');$artifactSafe=$false}
                            if(-not(Test-Path -LiteralPath $artifactFull -PathType Leaf)){return [pscustomobject]@{valid=$false;status='ArtifactMissing';errors=@(@($errors.ToArray())+'SESSION_ARTIFACT_MISSING');state=[string]$manifest.state;sessionId=[string]$manifest.sessionId;planDigest=[string]$manifest.planDigest}}
                            if($artifactSafe -and $artifactHash -match '^(?:sha256:)?(?<hash>[0-9A-Fa-f]{64})$'){$actualArtifactHash=(Get-FileHash -LiteralPath $artifactFull -Algorithm SHA256).Hash;if($actualArtifactHash -cne $Matches.hash){$errors.Add('SESSION_ARTIFACT_HASH_MISMATCH')}}
                        }
                    }
                }catch{$errors.Add('SESSION_ARTIFACT_PATH_INVALID')}
            }
        }
    }
    return [pscustomobject]@{valid=($errors.Count -eq 0);status=$(if($errors.Count){'Corrupt'}else{'Valid'});errors=@($errors.ToArray());state=[string]$manifest.state;sessionId=[string]$manifest.sessionId;planDigest=[string]$manifest.planDigest}
}

Export-ModuleMember -Function Initialize-MmtlSessionV2,Set-MmtlSessionV2State,Test-MmtlSessionV2,Get-MmtlSessionV2StateTransitions
