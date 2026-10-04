Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'Platform/Platform.psm1') -Force

function Get-MmtlProcessStartIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    try{$target=Get-Process -Id $ProcessId -ErrorAction Stop;return $target.StartTime.ToUniversalTime().ToString('o')}catch{return $null}
}

function Assert-MmtlSessionLockPath {
    param([string]$LockPath,[string]$AllowedRoot)
    if(-not(Test-Path -LiteralPath $AllowedRoot -PathType Container)){throw 'SESSION_LOCK_ROOT_UNAVAILABLE'}
    $root=[IO.Path]::GetFullPath($AllowedRoot);$target=[IO.Path]::GetFullPath($LockPath)
    if(-not(Test-MmtlPlatformPathInsideRoot -Root $root -Target $target)){throw 'SESSION_LOCK_PATH_OUTSIDE_ROOT'}
    $volume=[IO.Path]::GetPathRoot($root);$current=$volume
    foreach($part in ($root.Substring($volume.Length) -split '[\\/]'|Where-Object{$_})){$current=Join-Path $current $part;if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw 'SESSION_LOCK_PATH_REPARSE_POINT'}}}
    $current=$root
    $relative=[IO.Path]::GetRelativePath($root,$target)
    foreach($part in ($relative -split '[\\/]'|Where-Object{$_ -and $_ -ne '.'})){
        $current=Join-Path $current $part
        if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType){throw 'SESSION_LOCK_PATH_REPARSE_POINT'}}
    }
}

function New-MmtlSessionLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath,[Parameter(Mandatory)][string]$AllowedRoot,[ValidateRange(0,300)][int]$TimeoutSeconds=5)
    Assert-MmtlSessionLockPath -LockPath $LockPath -AllowedRoot $AllowedRoot
    $full=[IO.Path]::GetFullPath($LockPath);$deadline=[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while($true){
        $stream=$null
        try{$stream=[IO.FileStream]::new($full,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough);break}
        catch [IO.IOException]{if([DateTimeOffset]::UtcNow -ge $deadline){throw 'SESSION_LOCKED'};Start-Sleep -Milliseconds 50}
        catch [UnauthorizedAccessException]{throw 'SESSION_LOCK_UNAVAILABLE'}
    }
    $ownerPid=$PID;$startIdentity=Get-MmtlProcessStartIdentity -ProcessId $ownerPid
    if(-not $startIdentity){$stream.Dispose();throw 'SESSION_LOCK_OWNER_IDENTITY_UNAVAILABLE'}
    $record=[ordered]@{schemaVersion=1;ownerPid=$ownerPid;processStartIdentity=$startIdentity;createdUtc=[DateTimeOffset]::UtcNow.ToString('o');nonce=[guid]::NewGuid().ToString('N')}
    try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Compress));$stream.SetLength(0);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}catch{$stream.Dispose();throw 'SESSION_LOCK_WRITE_FAILED'}
    [pscustomobject][ordered]@{lockPath=$full;ownerPid=$ownerPid;processStartIdentity=$startIdentity;createdUtc=$record.createdUtc;nonce=$record.nonce;stream=$stream;released=$false}
}

function Remove-MmtlSessionLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lock,[int]$OwnerPid=-1,[string]$ProcessStartIdentity,[string]$Nonce)
    if($Lock.released){return}
    if(($OwnerPid -ge 0 -and $OwnerPid -ne [int]$Lock.ownerPid) -or ($ProcessStartIdentity -and $ProcessStartIdentity -cne [string]$Lock.processStartIdentity) -or ($Nonce -and $Nonce -cne [string]$Lock.nonce)){throw 'SESSION_LOCK_OWNER_MISMATCH'}
    $Lock.stream.Dispose();$Lock.released=$true
}

function Get-MmtlSessionLockStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LockPath,[Parameter(Mandatory)][string]$AllowedRoot)
    Assert-MmtlSessionLockPath -LockPath $LockPath -AllowedRoot $AllowedRoot
    $full=[IO.Path]::GetFullPath($LockPath)
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){return [pscustomobject]@{status='Missing';owner=$null}}
    $record=$null;try{$record=Get-Content -LiteralPath $full -Raw|ConvertFrom-Json -ErrorAction Stop}catch{}
    $probe=$null
    try{$probe=[IO.FileStream]::new($full,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$probe.Dispose()}
    catch [IO.IOException]{return [pscustomobject]@{status='Locked';owner=$record}}
    if(-not $record){return [pscustomobject]@{status='Corrupt';owner=$null}}
    $actual=Get-MmtlProcessStartIdentity -ProcessId ([int]$record.ownerPid)
    $same=($actual -and $actual -ceq [string]$record.processStartIdentity)
    [pscustomobject]@{status=$(if($same){'Stale'}else{'Stale'});owner=$record;processStillMatches=[bool]$same;reasonCode=$(if($same){'SESSION_LOCK_HANDLE_ABANDONED'}else{'SESSION_LOCK_OWNER_GONE_OR_PID_REUSED'})}
}

Export-ModuleMember -Function Get-MmtlProcessStartIdentity,New-MmtlSessionLock,Remove-MmtlSessionLock,Get-MmtlSessionLockStatus
