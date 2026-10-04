Set-StrictMode -Version Latest

function Get-MmtlJavaReleaseValue {
    param([string[]]$Lines,[string]$Name)
    $match=@($Lines|Where-Object{$_ -match ('^'+[regex]::Escape($Name)+'=(.*)$')}|Select-Object -First 1)
    if(-not $match.Count){return $null}
    $value=$match[0] -replace ('^'+[regex]::Escape($Name)+'=') ,''
    return $value.Trim('"')
}

function Get-MmtlJavaHomeFromExecutable {
    param([string]$Executable)
    if(-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)){return $null}
    $resolved=(Get-Item -LiteralPath $Executable -Force).FullName
    if((Split-Path -Leaf (Split-Path -Parent $resolved)) -ieq 'bin'){return Split-Path -Parent (Split-Path -Parent $resolved)}
    return Split-Path -Parent $resolved
}

function Get-MmtlJavaDiscovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Platform,[string[]]$AdditionalRoots=@())
    $javaName=[string]$Platform.JavaExecutable;$javacName=[string]$Platform.JavacExecutable
    $roots=[Collections.Generic.List[object]]::new()
    if($env:JAVA_HOME){$roots.Add([pscustomobject]@{home=$env:JAVA_HOME;source='JAVA_HOME';rank=0})}
    foreach($pathEntry in ($env:PATH -split [regex]::Escape([string][IO.Path]::PathSeparator))){
        if(-not $pathEntry){continue}
        $pathJava=Join-Path $pathEntry $javaName
        $jdkHome=Get-MmtlJavaHomeFromExecutable $pathJava
        if($jdkHome){$roots.Add([pscustomobject]@{home=$jdkHome;source='PATH';rank=1})}
    }
    foreach($root in $AdditionalRoots){$roots.Add([pscustomobject]@{home=$root;source='StandardLocation';rank=2})}
    $standardRoots=switch([string]$Platform.OS){
        'Windows' {@('D:\java','C:\Program Files\Java','C:\Program Files\Eclipse Adoptium','C:\Program Files\Microsoft')}
        'Linux' {@('/usr/lib/jvm','/usr/java','/opt/java',(Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.sdkman/candidates/java'))}
        'MacOS' {@('/Library/Java/JavaVirtualMachines')}
    }
    foreach($parent in $standardRoots){
        if(-not (Test-Path -LiteralPath $parent -PathType Container)){continue}
        foreach($child in Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue){
            $jdkHome=if([string]$Platform.OS -eq 'MacOS'){Join-Path $child.FullName 'Contents/Home'}else{$child.FullName}
            $roots.Add([pscustomobject]@{home=$jdkHome;source='StandardLocation';rank=2})
        }
    }
    if([string]$Platform.OS -eq 'Windows'){
        foreach($key in @('HKLM:\SOFTWARE\JavaSoft\JDK','HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK')){
            if(-not (Test-Path $key)){continue}
            foreach($subkey in Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue){try{$jdkHome=(Get-ItemProperty -LiteralPath $subkey.PSPath -Name JavaHome -ErrorAction Stop).JavaHome;if($jdkHome){$roots.Add([pscustomobject]@{home=$jdkHome;source='WindowsRegistry';rank=3})}}catch{}}
        }
    }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $candidates=[Collections.Generic.List[object]]::new()
    foreach($candidateRoot in $roots){
        try{$jdkHome=[IO.Path]::GetFullPath([string]$candidateRoot.home)}catch{continue}
        if(-not $seen.Add($jdkHome)){continue}
        $java=Join-Path $jdkHome ('bin/'+$javaName);$javac=Join-Path $jdkHome ('bin/'+$javacName)
        if(-not (Test-Path -LiteralPath $java -PathType Leaf)){continue}
        $release=Join-Path $jdkHome 'release';$lines=if(Test-Path -LiteralPath $release -PathType Leaf){Get-Content -LiteralPath $release}else{@()}
        $version=Get-MmtlJavaReleaseValue -Lines $lines -Name 'JAVA_VERSION';$vendor=Get-MmtlJavaReleaseValue -Lines $lines -Name 'IMPLEMENTOR';if(-not $vendor){$vendor=Get-MmtlJavaReleaseValue -Lines $lines -Name 'JAVA_VENDOR'}
        $arch=Get-MmtlJavaReleaseValue -Lines $lines -Name 'OS_ARCH'
        $major=$null
        if($version){if($version -match '^1\.(\d+)'){$major=[int]$Matches[1]}elseif($version -match '^(\d+)'){$major=[int]$Matches[1]}}
        if($arch){$arch=switch -Regex ($arch.ToLowerInvariant()){'^(amd64|x86_64|x64)$'{'x64'}'^(aarch64|arm64)$'{'ARM64'}default{$arch}}}
        $candidates.Add([pscustomobject][ordered]@{vendor=$(if($vendor){$vendor}else{'Unknown'});version=$version;major=$major;architecture=$(if($arch){$arch}else{'Unknown'});home=$jdkHome;javaPath=$java;javacPath=$(if(Test-Path -LiteralPath $javac -PathType Leaf){$javac}else{$null});hasJavac=(Test-Path -LiteralPath $javac -PathType Leaf);source=[string]$candidateRoot.source;rank=[int]$candidateRoot.rank})
    }
    $sorted=@($candidates.ToArray()|Sort-Object @{Expression={if($_.major){[int]$_.major}else{0}};Descending=$true},@{Expression='rank';Descending=$false},@{Expression='home';Descending=$false})
    [pscustomobject][ordered]@{platform=[string]$Platform.OS;candidates=$sorted;count=$sorted.Count;configModified=$false}
}

Export-ModuleMember -Function Get-MmtlJavaDiscovery
