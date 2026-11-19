Import-Module (Join-Path $PSScriptRoot '../../common/src/Platform/Platform.psm1') -Force
$script:WindowsProcessModule=Import-Module (Join-Path $PSScriptRoot 'Windows.Process.psm1') -Force -PassThru
Import-Module (Join-Path $PSScriptRoot 'WindowManager.psm1') -Force

function New-MmtlWindowsPlatformProvider {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $home=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $runtimeRoot=if($env:LOCALAPPDATA){Join-Path $env:LOCALAPPDATA 'MinecraftModTestLauncher'}else{Join-Path $home 'AppData/Local/MinecraftModTestLauncher'}
    $arch=switch([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()){'X64'{'x64'}'Arm64'{'ARM64'}default{throw '不支持当前 CPU 架构。'}}
    $processModule=$script:WindowsProcessModule
    [pscustomobject]@{OS='Windows';Arch=$arch;IsWSL=$false;PathSeparator=[IO.Path]::DirectorySeparatorChar;PathListSeparator=[IO.Path]::PathSeparator;PathComparison=[StringComparison]::OrdinalIgnoreCase;ExecutableSuffix='.exe';JavaExecutable='java.exe';JavacExecutable='javac.exe';GradleWrapper='gradlew.bat';GradleTaskEntrypoint=(Join-Path $PSScriptRoot 'Invoke-GradleTask.ps1');LauncherPath=(Join-Path $RepositoryRoot 'windows/launcher.ps1');DefaultRuntimeRoot=[IO.Path]::GetFullPath($runtimeRoot);TempRoot=[IO.Path]::GetTempPath();WindowManagement='Native';ProcessManagement='Native';FabricRuntimeLink='Native';GetPhysicalMemoryMb={ [long][Math]::Floor((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory/1MB) };ProcessApi=[pscustomobject]@{GetRecord={param($id) & $processModule {param($x) Get-MmtlWindowsProcessRecord -ProcessId $x} $id}.GetNewClosure();GetSnapshot={param($id) & $processModule {param($x) Get-MmtlWindowsProcessSnapshot -RootProcessId $x} $id}.GetNewClosure();TestIdentity={param($process,$record) & $processModule {param($p,$r) Test-MmtlWindowsProcessIdentity -Process $p -Record $r} $process $record}.GetNewClosure()};WindowApi=[pscustomobject]@{GetLayout={param($mode) Get-MmtlWindowLayout -Mode $mode}.GetNewClosure()}}
}

function Register-MmtlWindowsPlatform {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    Set-MmtlPlatformProvider (New-MmtlWindowsPlatformProvider -RepositoryRoot $RepositoryRoot)
}
Export-ModuleMember -Function New-MmtlWindowsPlatformProvider,Register-MmtlWindowsPlatform
