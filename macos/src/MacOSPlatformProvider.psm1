Import-Module (Join-Path $PSScriptRoot '../../common/src/Platform/Platform.psm1') -Force
$script:MacOSProcessModule=Import-Module (Join-Path $PSScriptRoot 'MacOS.Process.psm1') -Force -PassThru

function New-MmtlMacOSPlatformProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $home=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $arch=switch([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()){'X64'{'x64'}'Arm64'{'ARM64'}default{throw '不支持当前 CPU 架构。'}}
    $provider=[pscustomobject]@{OS='MacOS';Arch=$arch;IsWSL=$false;PathSeparator=[IO.Path]::DirectorySeparatorChar;PathListSeparator=[IO.Path]::PathSeparator;PathComparison=[StringComparison]::Ordinal;ExecutableSuffix='';JavaExecutable='java';JavacExecutable='javac';GradleWrapper='gradlew';GradleTaskEntrypoint=(Join-Path $PSScriptRoot 'Invoke-GradleTask.ps1');DefaultRuntimeRoot=[IO.Path]::GetFullPath((Join-Path $home 'Library/Application Support/MinecraftModTestLauncher'));TempRoot=[IO.Path]::GetTempPath();WindowManagement='Unsupported';ProcessManagement='Unsupported';FabricRuntimeLink='Unsupported';GetPhysicalMemoryMb={ $bytes=& sysctl -n hw.memsize 2>$null;if($LASTEXITCODE -eq 0 -and [long]$bytes -gt 0){return [long][Math]::Floor([long]$bytes/1MB)};return 0 }.GetNewClosure();GetPathComparison={param($path) $base=if($path -and (Test-Path -LiteralPath $path)){if((Get-Item -LiteralPath $path).PSIsContainer){[IO.Path]::GetFullPath($path)}else{Split-Path -Parent ([IO.Path]::GetFullPath($path))}}else{[IO.Path]::GetTempPath()};while($base -and -not(Test-Path -LiteralPath $base)){$base=Split-Path -Parent $base};if(-not $base){$base=[IO.Path]::GetTempPath()};$probe=Join-Path $base ('.mmtl-case-'+[guid]::NewGuid().ToString('N')+'A');try{[IO.File]::WriteAllText($probe,'x');$variant=$probe.Substring(0,$probe.Length-1)+'a';if(Test-Path -LiteralPath $variant){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}}catch{[StringComparison]::Ordinal}finally{if(Test-Path -LiteralPath $probe){Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue}}}.GetNewClosure()}
    $processModule=$script:MacOSProcessModule
    $provider|Add-Member -NotePropertyName ProcessApi -NotePropertyValue ([pscustomobject]@{GetRecord={param($id)& $processModule {param($x)Get-MmtlMacOSProcessRecord -ProcessId $x} $id}.GetNewClosure();GetSnapshot={param($id)& $processModule {param($x)Get-MmtlMacOSProcessSnapshot -RootProcessId $x} $id}.GetNewClosure();TestIdentity={param($process,$record)& $processModule {param($p,$r)Test-MmtlMacOSProcessIdentity -Process $p -Record $r} $process $record}.GetNewClosure()})
    return $provider
}

function Register-MmtlMacOSPlatform {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    Set-MmtlPlatformProvider (New-MmtlMacOSPlatformProvider -RepositoryRoot $RepositoryRoot)
}
Export-ModuleMember -Function New-MmtlMacOSPlatformProvider,Register-MmtlMacOSPlatform
