Set-StrictMode -Version Latest

function Assert-MmtlIdentityNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($part in ($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            $linkTarget = $item.PSObject.Properties['LinkTarget']
            $isLink = [bool](($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -or ($linkTarget -and $linkTarget.Value))
            if (-not $isLink) { try { $isLink = $null -ne $item.ResolveLinkTarget($false) } catch {} }
            if ($isLink) { throw "IDENTITY_PATH_REPARSE_POINT:$current" }
        }
    }
    return $true
}

function Test-MmtlIdentityInsideRoot {
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Target)
    $rootPath = [IO.Path]::GetFullPath($Root)
    $targetPath = [IO.Path]::GetFullPath($Target)
    $comparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($targetPath.Equals($rootPath,$comparison)) { return $true }
    $relative = [IO.Path]::GetRelativePath($rootPath,$targetPath)
    return -not ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..' + [IO.Path]::DirectorySeparatorChar,$comparison) -or $relative.StartsWith('..' + [IO.Path]::AltDirectorySeparatorChar,$comparison))
}

function Get-MmtlOfflinePlayerUuid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_]{1,16}$')][string]$Username)
    $bytes = [Text.Encoding]::UTF8.GetBytes('OfflinePlayer:' + $Username)
    $digest = [Security.Cryptography.MD5]::HashData($bytes)
    $digest[6] = [byte](($digest[6] -band 0x0f) -bor 0x30)
    $digest[8] = [byte](($digest[8] -band 0x3f) -bor 0x80)
    $hex = [Convert]::ToHexString($digest).ToLowerInvariant()
    return '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0,8),$hex.Substring(8,4),$hex.Substring(12,4),$hex.Substring(16,4),$hex.Substring(20,12)
}

function New-MmtlTestIdentityRolePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile)
    $mode = [string]$Profile.mode
    $players = 0
    if ($mode -notin @('Single','IntegratedLAN','Dedicated') -or -not [int]::TryParse([string]$Profile.players,[ref]$players) -or $players -lt 1 -or $players -gt 8) { throw 'IDENTITY_PROFILE_INVALID' }
    $hostName = if ($Profile.PSObject.Properties['hostUsername'] -and $Profile.hostUsername) { [string]$Profile.hostUsername } else { 'Dev' }
    $prefix = if ($Profile.PSObject.Properties['clientPrefix'] -and $Profile.clientPrefix) { [string]$Profile.clientPrefix } else { 'Dev_' }
    if ($hostName -notmatch '^[A-Za-z0-9_]{1,16}$' -or $prefix -notmatch '^[A-Za-z0-9_]{1,15}$') { throw 'IDENTITY_USERNAME_INVALID' }
    $roles = [Collections.Generic.List[object]]::new()
    if ($mode -eq 'Single') { $roles.Add([pscustomobject]@{role='Client';username=$hostName;networkRole='SingleplayerClient'}) }
    else {
        if ($mode -eq 'IntegratedLAN') { $roles.Add([pscustomobject]@{role='Host';username=$hostName;networkRole='IntegratedServerHost'}) }
        else { $roles.Add([pscustomobject]@{role='Server';username='';networkRole='DedicatedServer'}) }
        $clientCount = if ($mode -eq 'IntegratedLAN') { $players - 1 } else { $players }
        $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if ($mode -eq 'IntegratedLAN') { $used.Add($hostName) | Out-Null }
        for ($index=1; $index -le $clientCount; $index++) {
            $suffix = [string]$index
            $maxPrefixLength = 16 - $suffix.Length
            $candidatePrefix = $prefix.Substring(0,[Math]::Min($prefix.Length,$maxPrefixLength))
            $candidate = $candidatePrefix + $suffix
            if ($used.Contains($candidate)) {
                $candidate = ('Guest' + $index)
                if ($candidate.Length -gt 16) { $candidate = $candidate.Substring(0,16) }
                if ($used.Contains($candidate)) { throw 'IDENTITY_USERNAME_COLLISION' }
            }
            $used.Add($candidate) | Out-Null
            $roles.Add([pscustomobject]@{role=$(if($mode -eq 'IntegratedLAN'){'Guest'}else{'Client'});username=$candidate;networkRole='LoopbackClient'})
        }
    }
    foreach ($role in $roles) {
        $role | Add-Member -NotePropertyName runtimeJavaMajor -NotePropertyValue $(if ($Profile.PSObject.Properties['runtimeJavaMajor']) { $Profile.runtimeJavaMajor } else { $null }) -Force
        $role | Add-Member -NotePropertyName runtimeJavaPath -NotePropertyValue $(if ($Profile.PSObject.Properties['runtimeJavaPath']) { $Profile.runtimeJavaPath } else { $null }) -Force
    }
    return $roles.ToArray()
}

function Initialize-MmtlTestIdentityDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,80}$')][string]$SessionId,
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][object[]]$Roles,
        [string]$AllowedRoot
    )
    if (-not $Roles.Count) { throw 'IDENTITY_ROLES_REQUIRED' }
    $session = [IO.Path]::GetFullPath($SessionPath)
    if ($AllowedRoot) {
        $allowed = [IO.Path]::GetFullPath($AllowedRoot)
        if (-not (Test-MmtlIdentityInsideRoot -Root $allowed -Target $session)) { throw 'IDENTITY_PATH_OUTSIDE_ALLOWED_ROOT' }
    }
    Assert-MmtlIdentityNoReparsePath -Path $session | Out-Null

    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prepared = [Collections.Generic.List[object]]::new()
    for ($index=0; $index -lt $Roles.Count; $index++) {
        $role = $Roles[$index]
        $roleName = [string]$role.role
        if ($roleName -notin @('Client','Host','Guest','Server')) { throw 'IDENTITY_ROLE_INVALID' }
        $isServer = $roleName -eq 'Server'
        $username = [string]$role.username
        if ($isServer) { $username = '' }
        elseif ($username -notmatch '^[A-Za-z0-9_]{1,16}$') { throw 'IDENTITY_USERNAME_INVALID' }
        if ($username -and -not $names.Add($username)) { throw 'IDENTITY_USERNAME_COLLISION' }
        $directoryName = if ($isServer) { 'Server' } else { $username }
        $gameDir = Join-Path $session $directoryName
        if (-not (Test-MmtlIdentityInsideRoot -Root $session -Target $gameDir)) { throw 'IDENTITY_PATH_ESCAPE' }
        $prepared.Add([pscustomobject]@{role=$roleName;username=$username;directoryName=$directoryName;gameDir=$gameDir;instanceId=('{0}-{1:d2}' -f $roleName,$index);source=$role;isServer=$isServer})
    }

    $identities = [Collections.Generic.List[object]]::new()
    foreach ($item in $prepared) {
        New-Item -ItemType Directory -Path $item.gameDir -Force | Out-Null
        Assert-MmtlIdentityNoReparsePath -Path $item.gameDir | Out-Null
        $directories = [ordered]@{
            logDirectory = Join-Path $item.gameDir 'logs'
            configDirectory = Join-Path $item.gameDir 'config'
            screenshotsDirectory = Join-Path $item.gameDir 'screenshots'
            crashReportsDirectory = Join-Path $item.gameDir 'crash-reports'
            savesDirectory = $null
        }
        if ($item.role -in @('Host','Server')) { $directories.savesDirectory = Join-Path $item.gameDir 'saves' }
        foreach ($directory in $directories.Values) { if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null } }
        Assert-MmtlIdentityNoReparsePath -Path $item.gameDir | Out-Null
        $options = Join-Path $item.gameDir 'options.txt'
        if (-not (Test-Path -LiteralPath $options -PathType Leaf)) {
            try { $stream=[IO.File]::Open($options,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read);$stream.Dispose() } catch [IO.IOException] { if (-not (Test-Path -LiteralPath $options -PathType Leaf)) { throw } }
        }
        $uuid = if ($item.isServer) { $null } else { Get-MmtlOfflinePlayerUuid -Username $item.username }
        $source = $item.source
        $identities.Add([pscustomobject][ordered]@{
            identityId = if ($uuid) { 'offline:' + $uuid } else { 'server:' + $SessionId }
            offlineUuid = $uuid
            username = if ($item.isServer) { $null } else { $item.username }
            role = $item.role
            sessionId = $SessionId
            instanceId = $item.instanceId
            gameDir = $item.gameDir
            logDirectory = $directories.logDirectory
            configDirectory = $directories.configDirectory
            optionsFile = $options
            screenshotsDirectory = $directories.screenshotsDirectory
            crashReportsDirectory = $directories.crashReportsDirectory
            savesDirectory = $directories.savesDirectory
            processIdentity = $null
            runtimeJavaMajor = if ($source.PSObject.Properties['runtimeJavaMajor']) { $source.runtimeJavaMajor } else { $null }
            runtimeJavaPath = if ($source.PSObject.Properties['runtimeJavaPath']) { $source.runtimeJavaPath } else { $null }
            networkRole = if ($source.PSObject.Properties['networkRole']) { [string]$source.networkRole } else { $item.role }
            offline = $true
        })
    }
    return ,@($identities.ToArray())
}

function Copy-MmtlArtifactToTestIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcePath,[Parameter(Mandatory)]$Identity)
    $source = [IO.Path]::GetFullPath($SourcePath)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'IDENTITY_ARTIFACT_SOURCE_MISSING' }
    Assert-MmtlIdentityNoReparsePath -Path $source | Out-Null
    $identityRoot = [IO.Path]::GetFullPath([string]$Identity.gameDir)
    Assert-MmtlIdentityNoReparsePath -Path $identityRoot | Out-Null
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $mods = Join-Path $identityRoot 'mods'
    New-Item -ItemType Directory -Path $mods -Force | Out-Null
    Assert-MmtlIdentityNoReparsePath -Path $mods | Out-Null
    $destination = Join-Path $mods ([IO.Path]::GetFileName($source))
    if ($source.Equals($destination,[StringComparison]::OrdinalIgnoreCase)) { throw 'IDENTITY_ARTIFACT_SOURCE_EQUALS_DESTINATION' }
    if (Test-Path -LiteralPath $destination) {
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $sourceHash) { throw 'IDENTITY_ARTIFACT_DESTINATION_CONFLICT' }
    } else {
        $temporary = Join-Path $mods ('.' + [guid]::NewGuid().ToString('N') + '.copying')
        try {
            [IO.File]::Copy($source,$temporary,$false)
            if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -cne $sourceHash) { throw 'IDENTITY_ARTIFACT_COPY_HASH_MISMATCH' }
            [IO.File]::Move($temporary,$destination)
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    }
    $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if ($destinationHash -cne $sourceHash) { throw 'IDENTITY_ARTIFACT_DESTINATION_HASH_MISMATCH' }
    $item = Get-Item -LiteralPath $destination -Force
    $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::ReadOnly
    return [pscustomobject][ordered]@{sourceName=[IO.Path]::GetFileName($source);destination=$destination;sha256=$destinationHash;role=[string]$Identity.role;username=$Identity.username;readOnly=$true}
}

Export-ModuleMember -Function Get-MmtlOfflinePlayerUuid,New-MmtlTestIdentityRolePlan,Initialize-MmtlTestIdentityDirectories,Copy-MmtlArtifactToTestIdentity
