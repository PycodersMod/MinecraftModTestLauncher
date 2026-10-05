BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src/Platform/Platform.psm1') -Force
    Import-Module (Join-Path $root 'src/RunManager.psm1') -Force
}

Describe '多角色演练内存预算' {
    BeforeAll { $script:originalPlatformProvider=$global:MmtlPlatformProvider }
    BeforeEach {
        $global:MmtlPlatformProvider=[pscustomobject]@{OS='Windows';Arch='x64';PathComparison=[StringComparison]::OrdinalIgnoreCase;DefaultRuntimeRoot=$TestDrive;JavaExecutable='java.exe';JavacExecutable='javac.exe';GradleWrapper='gradlew.bat';WindowManagement='Native';ProcessManagement='Native';FabricRuntimeLink='Native';GetPhysicalMemoryMb={0}}
    }
    AfterEach { $global:MmtlPlatformProvider=$script:originalPlatformProvider }
    It '分别汇总 Single、IntegratedLAN、Dedicated 角色内存并应用 80% 上限' {
        $profile=[pscustomobject]@{players=2;memoryMb=1024;hostMemoryMb=1536;clientMemoryMb=512;serverMemoryMb=2048}
        $single=Get-MmtlMemoryBudget -Profile $profile -Mode Single -PhysicalMemoryMb 4096
        $lan=Get-MmtlMemoryBudget -Profile $profile -Mode IntegratedLAN -PhysicalMemoryMb 4096
        $dedicated=Get-MmtlMemoryBudget -Profile $profile -Mode Dedicated -PhysicalMemoryMb 4096
        $single.RequestedMb | Should -Be 1536
        $lan.RequestedMb | Should -Be 2048
        $dedicated.RequestedMb | Should -Be 3072
        $dedicated.LimitMb | Should -Be 3276
        $dedicated.ExceedsLimit | Should -BeFalse
        (Get-MmtlMemoryBudget -Profile $profile -Mode Dedicated -PhysicalMemoryMb 3000).ExceedsLimit | Should -BeTrue
    }

    It '自动模式无法确认物理内存时拒绝编造预算' {
        $profile=[pscustomobject]@{players=2;memoryMb=1024;hostMemoryMb=1536;clientMemoryMb=512;serverMemoryMb=2048}
        { Get-MmtlMemoryBudget -Profile $profile -Mode Dedicated -PhysicalMemoryMb 0 } | Should -Throw '*无法确定本机物理内存*'
    }
}
