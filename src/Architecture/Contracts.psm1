$script:MmtlArchitectureContract = [ordered]@{
    operatingSystems = @('Windows', 'Linux', 'MacOS')
    architectures = @('x64', 'ARM64')
    capabilities = @('Native', 'Compatibility', 'BuildOnly', 'Unsupported')
    validationLevels = @('CATALOGUED', 'RESOLVED', 'BUILD_VERIFIED', 'SERVER_VERIFIED', 'CLIENT_LAUNCH_VERIFIED', 'INTEGRATION_VERIFIED')
    validationResults = @('UNVERIFIED', 'PASSED', 'FAILED', 'STALE')
    artifactTrustClasses = @('TrustedOfficial', 'VerifiedHistorical', 'UnverifiedHistorical')
    historicalSourceClasses = @('ActiveOfficial', 'HistoricalOfficial', 'VerifiedCommunityArchive', 'VerifiedCommunitySource', 'ManualArtifact', 'UnknownHistorical')
    historicalTransportSecurity = @('HTTPS', 'HTTPOnly', 'LocalManual', 'ArchivedSnapshot', 'Unknown')
    historicalIntegrityAlgorithms = @('SHA256', 'SHA1', 'MD5', 'None', 'Unknown')
    historicalIntegrityStrengths = @('StrongIntegrity', 'LegacyIntegrity', 'CorruptionDetectionOnly', 'NoIntegrity', 'Unknown')
    historicalMaintenanceStates = @('Active', 'Limited', 'Archived', 'Dead', 'Unknown')
    artifactPermissionStates = @('Granted', 'RequiresConfirmation', 'Denied')
    provenanceTypes = @('official', 'archivedOfficial', 'trustedArchive', 'communityMirror', 'unknown')
    archiveStatuses = @('active', 'archived', 'unverified', 'unknown')
    confidences = @('High', 'Medium', 'Low', 'Unknown')
    loaders = @(
        [pscustomobject]@{ id = 'Forge'; displayName = 'Forge'; category = 'Mainstream'; historical = $false; providerId = 'Forge' }
        [pscustomobject]@{ id = 'Fabric'; displayName = 'Fabric'; category = 'Mainstream'; historical = $false; providerId = 'Fabric' }
        [pscustomobject]@{ id = 'NeoForge'; displayName = 'NeoForge'; category = 'Mainstream'; historical = $false; providerId = 'NeoForge' }
        [pscustomobject]@{ id = 'Quilt'; displayName = 'Quilt'; category = 'Mainstream'; historical = $false; providerId = 'Quilt' }
        [pscustomobject]@{ id = 'LegacyFabric'; displayName = 'Legacy Fabric'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'LiteLoader'; displayName = 'LiteLoader'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'Rift'; displayName = 'Rift'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'ModLoader'; displayName = 'Risugami ModLoader'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'ModLoaderMP'; displayName = 'ModLoaderMP'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'JarMod'; displayName = 'Legacy Jar Mod'; category = 'Compatibility'; historical = $true; providerId = $null }
    )
    toolchains = @(
        [pscustomobject]@{ id = 'ForgeGradle'; displayName = 'ForgeGradle' }
        [pscustomobject]@{ id = 'FabricLoom'; displayName = 'Fabric Loom' }
        [pscustomobject]@{ id = 'NeoGradle'; displayName = 'NeoGradle' }
        [pscustomobject]@{ id = 'ModDevGradle'; displayName = 'ModDevGradle' }
        [pscustomobject]@{ id = 'QuiltLoom'; displayName = 'Quilt Loom' }
        [pscustomobject]@{ id = 'Ploceus'; displayName = 'Ploceus' }
        [pscustomobject]@{ id = 'Unknown'; displayName = 'Unknown' }
        [pscustomobject]@{ id = 'Custom'; displayName = 'Custom' }
    )
    buildSystems = @(
        [pscustomobject]@{ id = 'GradleWrapper'; displayName = 'Gradle Wrapper' }
        [pscustomobject]@{ id = 'Custom'; displayName = 'Custom' }
        [pscustomobject]@{ id = 'Legacy'; displayName = 'Legacy' }
    )
}

function Get-MmtlArchitectureContract {
    [CmdletBinding()]
    param()
    return $script:MmtlArchitectureContract
}

function Test-MmtlArchitectureValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('OS', 'Architecture', 'Capability', 'ValidationLevel', 'ValidationResult', 'ArtifactTrustClass', 'ArtifactPermission', 'ProvenanceType', 'ArchiveStatus', 'Confidence', 'Loader', 'Toolchain', 'BuildSystem', 'HistoricalSourceClass', 'HistoricalTransport', 'HistoricalIntegrityAlgorithm', 'HistoricalIntegrityStrength', 'HistoricalMaintenanceState')][string]$Kind,
        [Parameter(Mandatory)][string]$Value
    )
    $values = switch ($Kind) {
        'OS' { $script:MmtlArchitectureContract.operatingSystems }
        'Architecture' { $script:MmtlArchitectureContract.architectures }
        'Capability' { $script:MmtlArchitectureContract.capabilities }
        'ValidationLevel' { $script:MmtlArchitectureContract.validationLevels }
        'ValidationResult' { $script:MmtlArchitectureContract.validationResults }
        'ArtifactTrustClass' { $script:MmtlArchitectureContract.artifactTrustClasses }
        'ArtifactPermission' { $script:MmtlArchitectureContract.artifactPermissionStates }
        'ProvenanceType' { $script:MmtlArchitectureContract.provenanceTypes }
        'ArchiveStatus' { $script:MmtlArchitectureContract.archiveStatuses }
        'Confidence' { $script:MmtlArchitectureContract.confidences }
        'Loader' { @($script:MmtlArchitectureContract.loaders | ForEach-Object id) }
        'Toolchain' { @($script:MmtlArchitectureContract.toolchains | ForEach-Object id) }
        'BuildSystem' { @($script:MmtlArchitectureContract.buildSystems | ForEach-Object id) }
        'HistoricalSourceClass' { $script:MmtlArchitectureContract.historicalSourceClasses }
        'HistoricalTransport' { $script:MmtlArchitectureContract.historicalTransportSecurity }
        'HistoricalIntegrityAlgorithm' { $script:MmtlArchitectureContract.historicalIntegrityAlgorithms }
        'HistoricalIntegrityStrength' { $script:MmtlArchitectureContract.historicalIntegrityStrengths }
        'HistoricalMaintenanceState' { $script:MmtlArchitectureContract.historicalMaintenanceStates }
    }
    return $Value -cin $values
}

function New-MmtlPlatformContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Windows', 'Linux', 'MacOS')][string]$OS,
        [Parameter(Mandatory)][ValidateSet('x64', 'ARM64')][string]$Arch,
        [switch]$IsWSL,
        [string]$Shell,
        [System.Collections.IDictionary]$Capabilities = @{}
    )
    if ($IsWSL -and $OS -ne 'Linux') { throw 'isWSL 只能用于 Linux PlatformContext。' }
    foreach ($name in $Capabilities.Keys) {
        if (-not (Test-MmtlArchitectureValue -Kind Capability -Value ([string]$Capabilities[$name]))) {
            throw "Platform capability '$name' 的值无效：$($Capabilities[$name])"
        }
    }
    return [pscustomobject][ordered]@{
        os = $OS
        arch = $Arch
        isWSL = [bool]$IsWSL
        shell = $Shell
        capabilities = [pscustomobject]$Capabilities
    }
}

function Get-MmtlPlatformContext {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Capabilities = @{})
    $runtime = [System.Runtime.InteropServices.RuntimeInformation]
    $os = if ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { 'Windows' }
        elseif ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) { 'Linux' }
        elseif ($runtime::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { 'MacOS' }
        else { throw '当前操作系统不在 PlatformContext contract 中。' }
    $arch = switch ($runtime::OSArchitecture.ToString()) {
        'X64' { 'x64' }
        'Arm64' { 'ARM64' }
        default { throw "当前 CPU 架构不在 PlatformContext contract 中：$($runtime::OSArchitecture)" }
    }
    $isWsl = $false
    if ($os -eq 'Linux') {
        $isWsl = [bool]($env:WSL_INTEROP -or $env:WSL_DISTRO_NAME)
        if (-not $isWsl -and (Test-Path -LiteralPath '/proc/sys/kernel/osrelease')) {
            $isWsl = (Get-Content -LiteralPath '/proc/sys/kernel/osrelease' -Raw) -match '(?i)microsoft|wsl'
        }
    }
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    return New-MmtlPlatformContext -OS $os -Arch $arch -IsWSL:$isWsl -Shell $shell -Capabilities $Capabilities
}

function New-MmtlJavaRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('BuildJava', 'RuntimeJava')][string]$Purpose,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$Major,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Source,
        [Parameter(Mandatory)][ValidateSet('High', 'Medium', 'Low', 'Unknown')][string]$Confidence,
        [string]$ExactVersion,
        [string]$Home,
        [string]$Vendor,
        [ValidateSet('x64', 'ARM64')][string]$Arch
    )
    return [pscustomobject][ordered]@{
        purpose = $Purpose
        major = $Major
        exactVersion = $ExactVersion
        home = $Home
        source = $Source
        confidence = $Confidence
        vendor = $Vendor
        arch = $Arch
    }
}

function New-MmtlProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('official', 'archivedOfficial', 'trustedArchive', 'communityMirror', 'unknown')][string]$SourceType,
        [string]$Url,
        [Parameter(Mandatory)][DateTimeOffset]$FetchedAt,
        [string]$Hash,
        [ValidateSet('active', 'archived', 'unverified', 'unknown')][string]$ArchiveStatus = 'unknown',
        [string[]]$Notes = @()
    )
    if ($Url) {
        $parsedUri = $null
        if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -notin @('http', 'https')) {
            throw 'Provenance URL 必须是绝对 HTTP(S) URL。'
        }
    }
    if ($Hash -and $Hash -notmatch '^(?i:[0-9a-f]{64})$') { throw 'Provenance hash 必须是 64 位 SHA-256 十六进制值。' }
    return [pscustomobject][ordered]@{
        sourceType = $SourceType
        url = $Url
        fetchedAt = $FetchedAt.ToUniversalTime().ToString('o')
        hash = $Hash
        archiveStatus = $ArchiveStatus
        notes = @($Notes)
    }
}

function Resolve-MmtlArtifactTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('TrustedOfficial', 'VerifiedHistorical', 'UnverifiedHistorical')][string]$TrustClass,
        [switch]$AllowAutomaticOfficial,
        [switch]$DownloadConfirmed,
        [switch]$ExecuteConfirmed
    )
    $download = 'RequiresConfirmation'
    $execute = 'RequiresConfirmation'
    if ($TrustClass -eq 'TrustedOfficial' -and $AllowAutomaticOfficial) {
        $download = 'Granted'
        $execute = 'Granted'
    } else {
        if ($DownloadConfirmed) { $download = 'Granted' }
        if ($ExecuteConfirmed) { $execute = 'Granted' }
    }
    return [pscustomobject][ordered]@{
        trustClass = $TrustClass
        downloadPermission = $download
        executePermission = $execute
    }
}

function Get-MmtlValue {
    param([Parameter(Mandatory)]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-MmtlLoaderStackMember {
    param([Parameter(Mandatory)]$Loader, [Parameter(Mandatory)][ValidateSet('Primary', 'Overlay')][string]$Role)
    $id = [string](Get-MmtlValue -InputObject $Loader -Name 'id')
    $version = [string](Get-MmtlValue -InputObject $Loader -Name 'version')
    $provenance = @(Get-MmtlValue -InputObject $Loader -Name 'provenance')
    if (-not (Test-MmtlArchitectureValue -Kind Loader -Value $id)) { throw "未知 Loader identity：$id" }
    if ([string]::IsNullOrWhiteSpace($version)) { throw "$Role Loader 必须提供 version。" }
    if ($provenance.Count -eq 0) { throw "$Role Loader 必须包含 provenance。" }
    foreach ($source in $provenance) {
        if (-not $source.sourceType -or -not (Test-MmtlArchitectureValue -Kind ProvenanceType -Value ([string]$source.sourceType))) { throw "$Role Loader provenance 无效。" }
    }
    return [pscustomobject][ordered]@{ id = $id; version = $version; role = $Role; provenance = $provenance }
}

function New-MmtlLoaderStack {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$PrimaryLoader, [object[]]$OverlayLoaders = @())
    $primary = ConvertTo-MmtlLoaderStackMember -Loader $PrimaryLoader -Role Primary
    $overlays = @($OverlayLoaders | ForEach-Object { ConvertTo-MmtlLoaderStackMember -Loader $_ -Role Overlay })
    return [pscustomobject][ordered]@{ primaryLoader = $primary; overlayLoaders = $overlays }
}

function New-MmtlToolchainContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('ForgeGradle', 'FabricLoom', 'NeoGradle', 'ModDevGradle', 'QuiltLoom', 'Ploceus', 'Unknown', 'Custom')][string]$Id,
        [string]$Version,
        [string]$Ecosystem
    )
    return [pscustomobject][ordered]@{ id = $Id; version = $Version; ecosystem = $Ecosystem }
}

function New-MmtlBuildSystemContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GradleWrapper', 'Custom', 'Legacy')][string]$Id,
        [string]$Version
    )
    return [pscustomobject][ordered]@{ id = $Id; version = $Version }
}

Export-ModuleMember -Function Get-MmtlArchitectureContract,Test-MmtlArchitectureValue,New-MmtlPlatformContext,Get-MmtlPlatformContext,New-MmtlJavaRequirement,New-MmtlProvenance,Resolve-MmtlArtifactTrust,New-MmtlLoaderStack,New-MmtlToolchainContext,New-MmtlBuildSystemContext
