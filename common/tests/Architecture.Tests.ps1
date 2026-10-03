BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Architecture/Contracts.psm1') -Force
}

Describe 'MMTL v2 architecture contracts' {
    It '集中定义当前 OS、架构、能力、验证和信任等级' {
        $contract = Get-MmtlArchitectureContract
        $contract.operatingSystems | Should -Be @('Windows', 'Linux', 'MacOS')
        $contract.architectures | Should -Be @('x64', 'ARM64')
        $contract.capabilities | Should -Be @('Native', 'Compatibility', 'BuildOnly', 'Unsupported')
        $contract.validationLevels | Should -Be @('CATALOGUED', 'RESOLVED', 'BUILD_VERIFIED', 'SERVER_VERIFIED', 'CLIENT_LAUNCH_VERIFIED', 'INTEGRATION_VERIFIED')
        $contract.artifactTrustClasses | Should -Be @('TrustedOfficial', 'VerifiedHistorical', 'UnverifiedHistorical')
    }

    It '建立含 WSL 与 capability 的 PlatformContext 并拒绝未知身份' {
        $context = New-MmtlPlatformContext -OS Linux -Arch x64 -IsWSL -Shell pwsh -Capabilities @{ Build = 'Native'; WindowManagement = 'Unsupported' }
        $context.os | Should -Be 'Linux'
        $context.arch | Should -Be 'x64'
        $context.isWSL | Should -BeTrue
        $context.capabilities.Build | Should -Be 'Native'
        { New-MmtlPlatformContext -OS FreeBSD -Arch x64 } | Should -Throw
        { New-MmtlPlatformContext -OS Windows -Arch x86 } | Should -Throw
        { New-MmtlPlatformContext -OS Windows -Arch x64 -IsWSL } | Should -Throw
        $detected = Get-MmtlPlatformContext
        $detected.os | Should -BeIn @('Windows', 'Linux', 'MacOS')
        $detected.arch | Should -BeIn @('x64', 'ARM64')
    }

    It '区分能力和验证等级且拒绝未知值' {
        (Test-MmtlArchitectureValue -Kind Capability -Value BuildOnly) | Should -BeTrue
        (Test-MmtlArchitectureValue -Kind ValidationLevel -Value BUILD_VERIFIED) | Should -BeTrue
        (Test-MmtlArchitectureValue -Kind ValidationLevel -Value Unsupported) | Should -BeFalse
        (Test-MmtlArchitectureValue -Kind Capability -Value BUILD_VERIFIED) | Should -BeFalse
    }

    It '将 Artifact 的下载与执行信任动作独立授权' {
        $default = Resolve-MmtlArtifactTrust -TrustClass VerifiedHistorical
        $default.downloadPermission | Should -Be 'RequiresConfirmation'
        $default.executePermission | Should -Be 'RequiresConfirmation'
        $downloaded = Resolve-MmtlArtifactTrust -TrustClass UnverifiedHistorical -DownloadConfirmed
        $downloaded.downloadPermission | Should -Be 'Granted'
        $downloaded.executePermission | Should -Be 'RequiresConfirmation'
        $executed = Resolve-MmtlArtifactTrust -TrustClass VerifiedHistorical -ExecuteConfirmed
        $executed.downloadPermission | Should -Be 'RequiresConfirmation'
        $executed.executePermission | Should -Be 'Granted'
        $official = Resolve-MmtlArtifactTrust -TrustClass TrustedOfficial -AllowAutomaticOfficial
        $official.downloadPermission | Should -Be 'Granted'
        $official.executePermission | Should -Be 'Granted'
    }

    It '集中登记 loader identity 但不暗示验证状态' {
        $contract = Get-MmtlArchitectureContract
        $ids = @($contract.loaders | ForEach-Object id)
        $ids | Should -Contain 'Forge'
        $ids | Should -Contain 'Quilt'
        $ids | Should -Contain 'LegacyFabric'
        $ids | Should -Contain 'LiteLoader'
        $ids | Should -Contain 'Rift'
        $ids | Should -Contain 'ModLoader'
        $ids | Should -Contain 'ModLoaderMP'
        $ids | Should -Contain 'JarMod'
        @($contract.loaders | Where-Object validationLevel).Count | Should -Be 0
        @($contract.toolchains | ForEach-Object id) | Should -Contain 'Ploceus'
        @($contract.buildSystems | ForEach-Object id) | Should -Contain 'GradleWrapper'
        (New-MmtlBuildSystemContext -Id GradleWrapper -Version '8.10').id | Should -Be 'GradleWrapper'
        { New-MmtlBuildSystemContext -Id Maven } | Should -Throw
    }

    It '用 primary 与 overlay 表达 Forge 和 LiteLoader，并要求来源 provenance' {
        $provenance = New-MmtlProvenance -SourceType archivedOfficial -Url 'https://example.invalid/liteloader' -FetchedAt '2026-10-01T00:00:00Z' -Hash ('a' * 64) -ArchiveStatus archived
        $stack = New-MmtlLoaderStack -PrimaryLoader @{ id = 'Forge'; version = '14.23.5.2860'; provenance = $provenance } -OverlayLoaders @(@{ id = 'LiteLoader'; version = '1.12.2'; provenance = $provenance })
        $stack.primaryLoader.role | Should -Be 'Primary'
        $stack.overlayLoaders[0].role | Should -Be 'Overlay'
        $stack.overlayLoaders[0].id | Should -Be 'LiteLoader'
        { New-MmtlLoaderStack -PrimaryLoader @{ id = 'Forge'; version = 'x' } } | Should -Throw
        { New-MmtlLoaderStack -PrimaryLoader @{ id = 'UnknownLoader'; version = 'x'; provenance = $provenance } } | Should -Throw
    }

    It '将 Ornithe 记录为 ecosystem context 而非 Loader identity' {
        $toolchain = New-MmtlToolchainContext -Id Ploceus -Version '0.0.1' -Ecosystem Ornithe
        $toolchain.id | Should -Be 'Ploceus'
        $toolchain.ecosystem | Should -Be 'Ornithe'
        { New-MmtlToolchainContext -Id Ornithe } | Should -Throw
    }

    It '支持开放的 BuildJava 与 RuntimeJava major 和可选安装信息' {
        $buildJava = New-MmtlJavaRequirement -Purpose BuildJava -Major 6 -Source ProjectConfig -Confidence High -Home '/opt/jdk-6' -Vendor Oracle -Arch x64
        $runtimeJava = New-MmtlJavaRequirement -Purpose RuntimeJava -Major 26 -Source MinecraftMetadata -Confidence Medium -ExactVersion '26-ea' -Arch ARM64
        $buildJava.purpose | Should -Be 'BuildJava'
        $buildJava.major | Should -Be 6
        $buildJava.home | Should -Be '/opt/jdk-6'
        $runtimeJava.major | Should -Be 26
        $runtimeJava.vendor | Should -BeNullOrEmpty
        { New-MmtlJavaRequirement -Purpose BuildJava -Major 0 -Source ProjectConfig -Confidence High } | Should -Throw
    }

    It '记录 provenance 类型和可选归档状态' {
        $provenance = New-MmtlProvenance -SourceType communityMirror -Url 'https://example.invalid/archive' -FetchedAt '2026-10-01T00:00:00Z' -ArchiveStatus unverified -Notes 'community copy'
        $provenance.sourceType | Should -Be 'communityMirror'
        $provenance.archiveStatus | Should -Be 'unverified'
        $provenance.notes | Should -Contain 'community copy'
        { New-MmtlProvenance -SourceType invented -Url 'https://example.invalid' -FetchedAt '2026-10-01T00:00:00Z' } | Should -Throw
    }
}
