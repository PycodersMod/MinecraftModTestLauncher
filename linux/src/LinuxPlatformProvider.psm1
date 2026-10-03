Import-Module (Join-Path $PSScriptRoot '../../common/src/Platform/Platform.psm1') -Force
$script:LinuxProcessModule=Import-Module (Join-Path $PSScriptRoot 'Linux.Process.psm1') -Force -PassThru

function New-MmtlLinuxPlatformProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $home=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $data=if($env:XDG_DATA_HOME){$env:XDG_DATA_HOME}else{Join-Path $home '.local/share'}
    $arch=switch([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()){'X64'{'x64'}'Arm64'{'ARM64'}default{throw '不支持当前 CPU 架构。'}}
    $isWsl=[bool]($env:WSL_INTEROP -or $env:WSL_DISTRO_NAME)
    if(-not $isWsl -and (Test-Path -LiteralPath '/proc/sys/kernel/osrelease')){$isWsl=(Get-Content -LiteralPath '/proc/sys/kernel/osrelease' -Raw) -match '(?i)microsoft|wsl'}
    $processModule=$script:LinuxProcessModule
    [pscustomobject]@{OS='Linux';Arch=$arch;IsWSL=$isWsl;PathSeparator=[IO.Path]::DirectorySeparatorChar;PathListSeparator=[IO.Path]::PathSeparator;PathComparison=[StringComparison]::Ordinal;ExecutableSuffix='';JavaExecutable='java';JavacExecutable='javac';GradleWrapper='gradlew';GradleTaskEntrypoint=(Join-Path $PSScriptRoot 'Invoke-GradleTask.ps1');DefaultRuntimeRoot=[IO.Path]::GetFullPath((Join-Path $data 'MinecraftModTestLauncher'));TempRoot=[IO.Path]::GetTempPath();WindowManagement='Unsupported';ProcessManagement='Native';FabricRuntimeLink='Unsupported';GetPhysicalMemoryMb={if(Test-Path -LiteralPath '/proc/meminfo'){$match=Select-String -Path '/proc/meminfo' -Pattern '^MemTotal:\s+(\d+)\s+kB$';if($match){return [long][Math]::Floor(([double]$match.Matches[0].Groups[1].Value/1024))}};return 0}.GetNewClosure();ProcessApi=[pscustomobject]@{GetRecord={param($id) & $processModule {param($x) Get-MmtlLinuxProcessRecord -ProcessId $x} $id}.GetNewClosure();GetSnapshot={param($id) & $processModule {param($x) Get-MmtlLinuxProcessSnapshot -RootProcessId $x} $id}.GetNewClosure();TestIdentity={param($process,$record) & $processModule {param($p,$r) Test-MmtlLinuxProcessIdentity -Process $p -Record $r} $process $record}.GetNewClosure()}}
}

function Register-MmtlLinuxPlatform {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    Set-MmtlPlatformProvider (New-MmtlLinuxPlatformProvider -RepositoryRoot $RepositoryRoot)
}
Export-ModuleMember -Function New-MmtlLinuxPlatformProvider,Register-MmtlLinuxPlatform
