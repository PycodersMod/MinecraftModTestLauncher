Set-StrictMode -Version Latest

function Write-MmtlAtomicTextFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $full=[IO.Path]::GetFullPath($Path);$directory=Split-Path -Parent $full
    if(-not(Test-Path -LiteralPath $directory -PathType Container)){throw 'ATOMIC_FILE_PARENT_MISSING'}
    $temporary=Join-Path $directory ('.'+[IO.Path]::GetFileName($full)+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
    $stream=$null
    try{
        $stream=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Content)
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Dispose();$stream=$null
        [IO.File]::Move($temporary,$full,$true)
    }finally{
        if($stream){$stream.Dispose()}
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    }
}

Export-ModuleMember -Function Write-MmtlAtomicTextFile
