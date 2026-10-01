function Get-MmtlPlatformProvider {
    [CmdletBinding()]
    param([string]$Path)
    $runtime=[Runtime.InteropServices.RuntimeInformation]
    $os=if($runtime::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){'Windows'}elseif($runtime::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){'Linux'}elseif($runtime::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){'MacOS'}else{throw 'Unsupported operating system.'}
    $arch=switch($runtime::OSArchitecture.ToString()){'X64'{'x64'}'Arm64'{'ARM64'}default{throw "Unsupported architecture: $($runtime::OSArchitecture)"}}
    $home=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $root=switch($os){
        'Windows' { if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'MinecraftModTestLauncher'}else{Join-Path $home 'AppData/Local/MinecraftModTestLauncher'} }
        'Linux' { $data=if($env:XDG_DATA_HOME){$env:XDG_DATA_HOME}else{Join-Path $home '.local/share'};Join-Path $data 'MinecraftModTestLauncher' }
        'MacOS' { Join-Path $home 'Library/Application Support/MinecraftModTestLauncher' }
    }
    $isWSL=$false
    if($os -eq 'Linux'){$isWSL=(Test-Path '/proc/sys/fs/binfmt_misc/WSLInterop') -or ((Test-Path '/proc/version') -and (Select-String -Path '/proc/version' -Pattern 'microsoft|wsl' -Quiet -ErrorAction SilentlyContinue))}
    $comparison=if($os -eq 'Windows'){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if($os -eq 'MacOS'){
        # APFS volumes may use either policy; probe on the target path's nearest existing volume.
        $probeBase=if($Path -and (Test-Path -LiteralPath $Path)){if((Get-Item -LiteralPath $Path).PSIsContainer){[IO.Path]::GetFullPath($Path)}else{Split-Path -Parent ([IO.Path]::GetFullPath($Path))}}else{[IO.Path]::GetTempPath()}
        while($probeBase -and -not(Test-Path -LiteralPath $probeBase)){$probeBase=Split-Path -Parent $probeBase}
        if(-not $probeBase){$probeBase=[IO.Path]::GetTempPath()}
        $probe=Join-Path $probeBase ('.mmtl-case-'+[guid]::NewGuid().ToString('N')+'A')
        try{[IO.File]::WriteAllText($probe,'x');$variant=$probe.Substring(0,$probe.Length-1)+'a';$comparison=if(Test-Path -LiteralPath $variant){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}}
        catch{$comparison=[StringComparison]::Ordinal}finally{if(Test-Path -LiteralPath $probe){Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue}}
    }
    return [pscustomobject]@{
        OS=$os;Arch=$arch;IsWSL=$isWSL;PathSeparator=[IO.Path]::DirectorySeparatorChar;PathListSeparator=[IO.Path]::PathSeparator
        PathComparison=$comparison;ExecutableSuffix=$(if($os -eq 'Windows'){'.exe'}else{''});JavaExecutable=$(if($os -eq 'Windows'){'java.exe'}else{'java'});JavacExecutable=$(if($os -eq 'Windows'){'javac.exe'}else{'javac'})
        GradleWrapper=$(if($os -eq 'Windows'){'gradlew.bat'}else{'gradlew'});DefaultRuntimeRoot=[IO.Path]::GetFullPath($root);TempRoot=[IO.Path]::GetTempPath()
        WindowManagement=$(if($os -eq 'Windows'){'Native'}else{'Unsupported'});ProcessManagement=$(if($os -in @('Windows','Linux')){'Native'}else{'Unsupported'});FabricRuntimeLink=$(if($os -eq 'Windows'){'Native'}else{'Unsupported'})
    }
}

function Get-MmtlCanonicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-MmtlPathLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path)){return $false}
    $item=Get-Item -LiteralPath $Path -Force
    return [bool](($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType)
}

function Test-MmtlPlatformPathInsideRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Target)
    $r=Get-MmtlCanonicalPath -Path $Root;$t=Get-MmtlCanonicalPath -Path $Target;$provider=Get-MmtlPlatformProvider -Path $r
    if($t.Equals($r,$provider.PathComparison)){return $true}
    $relative=[IO.Path]::GetRelativePath($r,$t)
    if(-not ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,$provider.PathComparison) -or $relative.StartsWith('..'+[IO.Path]::AltDirectorySeparatorChar,$provider.PathComparison))){return $true}
    if($provider.PathComparison -eq [StringComparison]::OrdinalIgnoreCase){$trimmed=$r.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar);$prefix=if($trimmed){$trimmed+[IO.Path]::DirectorySeparatorChar}else{[string][IO.Path]::DirectorySeparatorChar};return $t.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)}
    return $false
}

function Get-MmtlPlatformContext {
    [CmdletBinding()]
    param()
    $provider=Get-MmtlPlatformProvider
    return [pscustomobject]@{os=$provider.OS;arch=$provider.Arch;isWSL=$provider.IsWSL;shell=$PSVersionTable.PSEdition;capabilities=[pscustomobject]@{Build='Native';WindowManagement=$provider.WindowManagement;ProcessManagement=$provider.ProcessManagement;FabricRuntimeLink=$provider.FabricRuntimeLink}}
}

function Get-MmtlPhysicalMemoryMb {
    [CmdletBinding()]
    param()
    $provider=Get-MmtlPlatformProvider
    if($provider.OS -eq 'Linux' -and (Test-Path '/proc/meminfo')){$match=Select-String -Path '/proc/meminfo' -Pattern '^MemTotal:\s+(\d+)\s+kB$';if($match){return [long][Math]::Floor(([double]$match.Matches[0].Groups[1].Value/1024))}}
    if($provider.OS -eq 'Windows'){return [long][Math]::Floor((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory/1MB)}
    if($provider.OS -eq 'MacOS'){$bytes=& sysctl -n hw.memsize 2>$null;if($LASTEXITCODE -eq 0 -and [long]$bytes -gt 0){return [long][Math]::Floor([long]$bytes/1MB)}}
    return $null
}

Export-ModuleMember -Function Get-MmtlPlatformProvider,Get-MmtlPlatformContext,Get-MmtlCanonicalPath,Test-MmtlPathLink,Test-MmtlPlatformPathInsideRoot,Get-MmtlPhysicalMemoryMb
