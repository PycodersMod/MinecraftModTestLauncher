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
    javaRequirementKinds = @('Minimum', 'Preferred', 'Exact', 'Unknown')
    loaders = @(
        [pscustomobject]@{ id = 'Forge'; displayName = 'Forge'; category = 'Mainstream'; historical = $false; providerId = 'Forge' }
        [pscustomobject]@{ id = 'Fabric'; displayName = 'Fabric'; category = 'Mainstream'; historical = $false; providerId = 'Fabric' }
        [pscustomobject]@{ id = 'NeoForge'; displayName = 'NeoForge'; category = 'Mainstream'; historical = $false; providerId = 'NeoForge' }
        [pscustomobject]@{ id = 'Quilt'; displayName = 'Quilt'; category = 'Mainstream'; historical = $false; providerId = 'Quilt' }
        [pscustomobject]@{ id = 'LegacyFabric'; displayName = 'Legacy Fabric'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'OrnitheLoader'; displayName = 'Ornithe Loader'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'LiteLoader'; displayName = 'LiteLoader'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'Rift'; displayName = 'Rift'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'ModLoader'; displayName = 'Risugami ModLoader'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'ModLoaderMP'; displayName = 'ModLoaderMP'; category = 'Historical'; historical = $true; providerId = $null }
        [pscustomobject]@{ id = 'JarMod'; displayName = '旧式 Jar Mod'; category = 'Compatibility'; historical = $true; providerId = $null }
    )
    toolchains = @(
        [pscustomobject]@{ id = 'ForgeGradle'; displayName = 'ForgeGradle' }
        [pscustomobject]@{ id = 'FabricLoom'; displayName = 'Fabric Loom' }
        [pscustomobject]@{ id = 'NeoGradle'; displayName = 'NeoGradle' }
        [pscustomobject]@{ id = 'ModDevGradle'; displayName = 'ModDevGradle' }
        [pscustomobject]@{ id = 'QuiltLoom'; displayName = 'Quilt Loom' }
        [pscustomobject]@{ id = 'Ploceus'; displayName = 'Ploceus' }
        [pscustomobject]@{ id = 'LegacyLooming'; displayName = 'Legacy Looming' }
        [pscustomobject]@{ id = 'Unknown'; displayName = 'Unknown' }
        [pscustomobject]@{ id = 'Custom'; displayName = 'Custom' }
    )
    buildSystems = @(
        [pscustomobject]@{ id = 'GradleWrapper'; displayName = 'Gradle Wrapper' }
        [pscustomobject]@{ id = 'Custom'; displayName = 'Custom' }
        [pscustomobject]@{ id = 'Legacy'; displayName = 'Legacy' }
    )
}

Import-Module (Join-Path $PSScriptRoot '../Platform/Platform.psm1') -Force

function Get-MmtlArchitectureContract {
    [CmdletBinding()]
    param()
    return $script:MmtlArchitectureContract
}

function Test-MmtlArchitectureValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('OS', 'Architecture', 'Capability', 'ValidationLevel', 'ValidationResult', 'ArtifactTrustClass', 'ArtifactPermission', 'ProvenanceType', 'ArchiveStatus', 'Confidence', 'JavaRequirementKind', 'Loader', 'Toolchain', 'BuildSystem', 'HistoricalSourceClass', 'HistoricalTransport', 'HistoricalIntegrityAlgorithm', 'HistoricalIntegrityStrength', 'HistoricalMaintenanceState')][string]$Kind,
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
        'JavaRequirementKind' { $script:MmtlArchitectureContract.javaRequirementKinds }
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
    $provider=Get-MmtlPlatformProvider
    if (-not $Capabilities.Count) { $Capabilities=@{Build='Native';WindowManagement=$provider.WindowManagement;ProcessManagement=$provider.ProcessManagement;FabricRuntimeLink=$provider.FabricRuntimeLink} }
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    return New-MmtlPlatformContext -OS $provider.OS -Arch $provider.Arch -IsWSL:([bool]$provider.IsWSL) -Shell $shell -Capabilities $Capabilities
}

function New-MmtlJavaRequirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('BuildJava', 'RuntimeJava')][string]$Purpose,
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$Major,
        [ValidateSet('Minimum', 'Preferred', 'Exact', 'Unknown')][string]$RequirementKind = 'Unknown',
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
        requirementKind = $RequirementKind
        minimumMajor = if($RequirementKind -eq 'Minimum'){$Major}else{$null}
        preferredMajor = if($RequirementKind -eq 'Preferred'){$Major}else{$null}
        exactMajor = if($RequirementKind -eq 'Exact'){$Major}else{$null}
        exactVersion = $ExactVersion
        home = $Home
        source = $Source
        confidence = $Confidence
        vendor = $Vendor
        arch = $Arch
    }
}

function New-MmtlBuildEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$MinecraftId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LoaderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LoaderVersion,
        [Parameter(Mandatory)]$Toolchain,
        [Parameter(Mandatory)]$Platform,
        [Parameter(Mandatory)]$BuildJavaRequirement,
        [Parameter(Mandatory)]$ObservedBuildJava,
        [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$CompilerTargetMajor,
        [string]$CompilerTargetSource='ProjectCompilerConfiguration',
        [Parameter(Mandatory)][ValidateSet('PASSED','FAILED','UNVERIFIED','STALE')][string]$Result,
        [string]$ArtifactSha256,
        [Parameter(Mandatory)][DateTimeOffset]$VerifiedAt,
        [Parameter(Mandatory)]$FixtureProvenance
    )
    if(-not (Test-MmtlArchitectureValue -Kind Loader -Value $LoaderId)){throw "未知的构建证据 Loader：$LoaderId"}
    if(-not $Toolchain.PSObject.Properties['id'] -or -not (Test-MmtlArchitectureValue -Kind Toolchain -Value ([string]$Toolchain.id))){throw '构建证据需要已注册的工具链身份。'}
    if(-not $Platform.PSObject.Properties['os'] -or -not $Platform.PSObject.Properties['arch'] -or -not (Test-MmtlArchitectureValue -Kind OS -Value ([string]$Platform.os)) -or -not (Test-MmtlArchitectureValue -Kind Architecture -Value ([string]$Platform.arch))){throw '构建证据需要有效的操作系统与 CPU 架构。'}
    if(-not $BuildJavaRequirement.PSObject.Properties['major'] -or [int]$BuildJavaRequirement.major -lt 1 -or -not $BuildJavaRequirement.PSObject.Properties['source'] -or [string]::IsNullOrWhiteSpace([string]$BuildJavaRequirement.source)){throw '构建证据需要明确的 BuildJava 要求。'}
    if(-not $ObservedBuildJava.PSObject.Properties['major'] -or [int]$ObservedBuildJava.major -lt 1 -or -not $ObservedBuildJava.PSObject.Properties['exactVersion'] -or [string]::IsNullOrWhiteSpace([string]$ObservedBuildJava.exactVersion) -or -not $ObservedBuildJava.PSObject.Properties['vendor'] -or [string]::IsNullOrWhiteSpace([string]$ObservedBuildJava.vendor) -or -not $ObservedBuildJava.PSObject.Properties['os'] -or -not $ObservedBuildJava.PSObject.Properties['arch'] -or -not (Test-MmtlArchitectureValue -Kind OS -Value ([string]$ObservedBuildJava.os)) -or -not (Test-MmtlArchitectureValue -Kind Architecture -Value ([string]$ObservedBuildJava.arch))){throw 'ObservedBuildJava 的主版本、完整版本、供应商、操作系统和架构必须有效。'}
    if([string]$ObservedBuildJava.os -ne [string]$Platform.os -or [string]$ObservedBuildJava.arch -ne [string]$Platform.arch){throw 'Java 的操作系统和架构必须与构建平台一致。'}
    if(-not $FixtureProvenance.PSObject.Properties['sourceUrl'] -or -not $FixtureProvenance.PSObject.Properties['commit'] -or -not $FixtureProvenance.PSObject.Properties['license']){throw '构建证据需要来源 fixture、commit 和许可证信息。'}
    if($ArtifactSha256 -and $ArtifactSha256 -notmatch '^(?i:[0-9a-f]{64})$'){throw 'Artifact SHA-256 必须恰好包含 64 个十六进制字符。'}
    if($Result -eq 'PASSED' -and -not $ArtifactSha256){throw '通过的构建证据必须包含产物 SHA-256。'}
    if($Result -eq 'PASSED' -and $BuildJavaRequirement.requirementKind -eq 'Minimum' -and [int]$ObservedBuildJava.major -lt [int]$BuildJavaRequirement.minimumMajor){throw '实测构建 JVM 低于要求的最低版本。'}
    if($Result -eq 'PASSED' -and $BuildJavaRequirement.PSObject.Properties['maximumMajor'] -and $BuildJavaRequirement.maximumMajor -and [int]$ObservedBuildJava.major -gt [int]$BuildJavaRequirement.maximumMajor){throw '实测构建 JVM 高于要求的最高版本。'}
    [pscustomobject][ordered]@{
        minecraftId=$MinecraftId
        loaderId=$LoaderId
        loaderVersion=$LoaderVersion
        toolchain=$Toolchain
        platform=[pscustomobject][ordered]@{os=[string]$Platform.os;arch=[string]$Platform.arch;isWSL=[bool]$Platform.isWSL}
        buildJavaRequirement=$BuildJavaRequirement
        observedBuildJava=$ObservedBuildJava
        compilerTarget=[pscustomobject][ordered]@{major=$CompilerTargetMajor;source=$CompilerTargetSource}
        result=$Result
        artifactSha256=if($ArtifactSha256){$ArtifactSha256.ToLowerInvariant()}else{$null}
        verifiedAt=$VerifiedAt.ToUniversalTime().ToString('o')
        fixtureProvenance=$FixtureProvenance
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
        [Parameter(Mandatory)][ValidateSet('ForgeGradle', 'FabricLoom', 'NeoGradle', 'ModDevGradle', 'QuiltLoom', 'Ploceus', 'LegacyLooming', 'Unknown', 'Custom')][string]$Id,
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

Export-ModuleMember -Function Get-MmtlArchitectureContract,Test-MmtlArchitectureValue,New-MmtlPlatformContext,Get-MmtlPlatformContext,New-MmtlJavaRequirement,New-MmtlBuildEvidence,New-MmtlProvenance,Resolve-MmtlArtifactTrust,New-MmtlLoaderStack,New-MmtlToolchainContext,New-MmtlBuildSystemContext
