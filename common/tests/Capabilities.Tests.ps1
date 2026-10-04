BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/Platform/Platform.psm1') -Force
}

Describe '平台 Capabilities' {
    It '输出稳定且完整的平台 capability 字段' {
        $provider=[pscustomobject]@{OS='MacOS';Arch='ARM64';IsWSL=$false;WindowManagement='Unsupported';ProcessManagement='Unsupported';FabricRuntimeLink='Unsupported';JavaExecutable='java';JavacExecutable='javac';GradleWrapper='gradlew';PathComparison=[StringComparison]::Ordinal;DefaultRuntimeRoot=$TestDrive;GetPhysicalMemoryMb={8192}}

        $capabilities=Get-MmtlPlatformCapabilities -Platform $provider

        $capabilities.os | Should -BeExactly 'MacOS'
        $capabilities.arch | Should -BeExactly 'ARM64'
        $capabilities.Build | Should -BeExactly 'Native'
        $capabilities.Launch | Should -BeExactly 'BuildOnly'
        $capabilities.WindowManagement | Should -BeExactly 'Unsupported'
        $capabilities.ProcessManagement | Should -BeExactly 'Unsupported'
        $capabilities.PSObject.Properties.Name | Should -Contain 'RuntimeBinding'
    }
}
