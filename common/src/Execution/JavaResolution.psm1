Set-StrictMode -Version Latest

function Get-MmtlJavaReleaseProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JavaHome)

    $releasePath = Join-Path $JavaHome 'release'
    if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) { return $null }
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($releasePath)) {
        if ($line -match '^([A-Z0-9_]+)="?(.*?)"?$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function ConvertTo-MmtlJavaArchitecture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        '^(amd64|x86_64|x64)$' { return 'x64' }
        '^(aarch64|arm64)$' { return 'ARM64' }
        default { return $null }
    }
}

function Test-MmtlJavaReleaseOperatingSystem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReleaseName, [Parameter(Mandatory)][string]$OperatingSystem)
    if ([string]::IsNullOrWhiteSpace($ReleaseName)) { return $true }
    switch ($OperatingSystem) {
        'Windows' { return $ReleaseName -match '(?i)windows' }
        'Linux' { return $ReleaseName -match '(?i)linux' }
        'MacOS' { return $ReleaseName -match '(?i)(mac|darwin)' }
        default { return $false }
    }
}

function Get-MmtlJavaRequirementProperty {
    param([Parameter(Mandatory)]$Requirement, [Parameter(Mandatory)][string]$Name)
    $property = $Requirement.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Resolve-MmtlJavaCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Requirement,
        [Parameter(Mandatory)][System.Collections.IDictionary]$JavaHomes,
        [Parameter(Mandatory)]$Platform
    )

    $purpose = [string](Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'purpose')
    if ($purpose -notin @('BuildJava', 'RuntimeJava')) { throw 'JAVA_PURPOSE_INVALID: purpose 必须是 BuildJava 或 RuntimeJava。' }
    $reasonCode = if ($purpose -eq 'BuildJava') { 'BUILD_JAVA_NOT_RESOLVED' } else { 'RUNTIME_JAVA_NOT_RESOLVED' }
    $source = Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'source'
    $base = [ordered]@{ status='Unresolved'; javaPath=$null; home=$null; actualMajor=$null; exactVersion=$null; vendor=$null; os=[string]$Platform.os; arch=$null; reasonCode=$reasonCode; source=[string]$source }

    $minimum = 0
    $target = 0
    $preferred = 0
    if ($purpose -eq 'BuildJava') {
        $minimumValue = Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'minimumMajor'
        $preferredValue = Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'preferredMajor'
        $exactValue = Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'exactMajor'
        $kind = [string](Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'requirementKind')
        $majorValue = Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'major'
        if ($minimumValue) { $minimum = [int]$minimumValue }
        elseif ($kind -eq 'Minimum' -and $majorValue) { $minimum = [int]$majorValue }
        if ($preferredValue) { $preferred = [int]$preferredValue }
        if ($exactValue) { $target = [int]$exactValue }
        elseif ($preferred -gt 0) { $target = $preferred }
        elseif ($minimum -gt 0) { $target = $minimum }
        elseif ($majorValue) { $target = [int]$majorValue }
    }
    else {
        $majorValue = Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'major'
        $exactValue = Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'exactMajor'
        $kind = [string](Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'requirementKind')
        if ($majorValue) { $target = [int]$majorValue }
        elseif ($exactValue) { $target = [int]$exactValue }
        if ($kind -eq 'Minimum' -and $target -gt 0) { $minimum = $target }
    }
    if ($target -le 0 -and $minimum -le 0) { return [pscustomobject]$base }

    $candidateMajors = @($JavaHomes.Keys | ForEach-Object { $number = 0; if ([int]::TryParse([string]$_, [ref]$number) -and $number -gt 0) { $number } } | Sort-Object -Unique)
    $kind = [string](Get-MmtlJavaRequirementProperty -Requirement $Requirement -Name 'requirementKind')
    if ($purpose -eq 'RuntimeJava' -and $target -gt 0 -and $kind -ne 'Minimum') {
        $candidateMajors = @($candidateMajors | Where-Object { $_ -eq $target })
    }
    elseif ($target -gt 0) {
        $candidateMajors = @($candidateMajors | Sort-Object @{ Expression = { if ($_ -eq $target) { 0 } elseif ($minimum -gt 0 -and $_ -ge $minimum) { 1 } else { 2 } } }, @{ Expression = { $_ } })
    }
    if ($minimum -gt 0) { $candidateMajors = @($candidateMajors | Where-Object { $_ -ge $minimum }) }

    $sawArchitectureMismatch = $false
    $sawMetadataProblem = $false
    foreach ($major in $candidateMajors) {
        $home = [IO.Path]::GetFullPath([string]$JavaHomes[[string]$major])
        $exeName = if ($Platform.PSObject.Properties['javaExecutable'] -and $Platform.javaExecutable) { [string]$Platform.javaExecutable } elseif ($Platform.os -eq 'Windows') { 'java.exe' } else { 'java' }
        $javaPath = Join-Path (Join-Path $home 'bin') $exeName
        if (-not (Test-Path -LiteralPath $javaPath -PathType Leaf)) { continue }
        $release = Get-MmtlJavaReleaseProperties -JavaHome $home
        if ($null -eq $release -or -not $release.ContainsKey('JAVA_VERSION') -or -not $release.ContainsKey('OS_ARCH')) { $sawMetadataProblem = $true; continue }
        $versionMatch = [regex]::Match([string]$release['JAVA_VERSION'], '^(?:1\.)?(\d+)')
        if (-not $versionMatch.Success) { $sawMetadataProblem = $true; continue }
        $actualMajor = [int]$versionMatch.Groups[1].Value
        $actualArch = ConvertTo-MmtlJavaArchitecture -Value ([string]$release['OS_ARCH'])
        if ($actualArch -ne [string]$Platform.arch) { $sawArchitectureMismatch = $true; continue }
        if ($release.ContainsKey('OS_NAME') -and -not (Test-MmtlJavaReleaseOperatingSystem -ReleaseName ([string]$release['OS_NAME']) -OperatingSystem ([string]$Platform.os))) { continue }
        if ($purpose -eq 'RuntimeJava' -and $kind -ne 'Minimum' -and $actualMajor -ne $target) { continue }
        if ($minimum -gt 0 -and $actualMajor -lt $minimum) { continue }
        if ($purpose -eq 'RuntimeJava' -and $kind -eq 'Minimum' -and $actualMajor -lt $minimum) { continue }

        $base.status = 'Resolved'
        $base.javaPath = [IO.Path]::GetFullPath($javaPath)
        $base.home = $home
        $base.actualMajor = $actualMajor
        $base.exactVersion = [string]$release['JAVA_VERSION']
        $base.vendor = if ($release.ContainsKey('IMPLEMENTOR')) { [string]$release['IMPLEMENTOR'] } elseif ($release.ContainsKey('IMPLEMENTOR_VERSION')) { [string]$release['IMPLEMENTOR_VERSION'] } else { 'Unknown' }
        $base.arch = $actualArch
        $base.reasonCode = $null
        return [pscustomobject]$base
    }

    if ($sawArchitectureMismatch) { $base.reasonCode = if ($purpose -eq 'BuildJava') { 'BUILD_JAVA_ARCH_MISMATCH' } else { 'RUNTIME_JAVA_ARCH_MISMATCH' } }
    elseif ($sawMetadataProblem) { $base.reasonCode = if ($purpose -eq 'BuildJava') { 'BUILD_JAVA_METADATA_UNAVAILABLE' } else { 'RUNTIME_JAVA_METADATA_UNAVAILABLE' } }
    return [pscustomobject]$base
}

Export-ModuleMember -Function Get-MmtlJavaReleaseProperties,ConvertTo-MmtlJavaArchitecture,Test-MmtlJavaReleaseOperatingSystem,Resolve-MmtlJavaCandidate
