BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    $repoRoot=Split-Path -Parent $root
    Import-Module (Join-Path $root 'src/Platform/Platform.psm1') -Force
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        Import-Module (Join-Path $repoRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
        Register-MmtlWindowsPlatform -RepositoryRoot $repoRoot
    }elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){
        Import-Module (Join-Path $repoRoot 'linux/src/LinuxPlatformProvider.psm1') -Force
        Register-MmtlLinuxPlatform -RepositoryRoot $repoRoot
    }else{
        Import-Module (Join-Path $repoRoot 'macos/src/MacOSPlatformProvider.psm1') -Force
        Register-MmtlMacOSPlatform -RepositoryRoot $repoRoot
    }
    Import-Module (Join-Path $root 'src/ProjectImport.psm1') -Force
}

Describe 'Project Registry 明确备份恢复' {
    BeforeEach {
        $script:runtime=Join-Path $TestDrive ('registry-recovery-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:runtime -Force|Out-Null
        $script:registry=Join-Path $script:runtime 'project-registry.json'
        [IO.File]::WriteAllText($script:registry,'{ broken original bytes',[Text.UTF8Encoding]::new($false))
        $script:originalHash=(Get-FileHash $script:registry -Algorithm SHA256).Hash
    }

    It '必须显式确认保留损坏文件备份后才执行恢复' {
        { Repair-MmtlProjectRegistry -RuntimeRoot $script:runtime } | Should -Throw '*PROJECT_REGISTRY_RECOVERY_CONFIRMATION_REQUIRED*'
        (Get-FileHash $script:registry -Algorithm SHA256).Hash | Should -BeExactly $script:originalHash
    }

    It '把原始 Registry 原字节备份后生成并验证空 Registry' {
        $result=Repair-MmtlProjectRegistry -RuntimeRoot $script:runtime -ConfirmBackup

        $result.status | Should -BeExactly 'Recovered'
        $result.projectCount | Should -Be 0
        (Get-FileHash $result.backupPath -Algorithm SHA256).Hash | Should -BeExactly $script:originalHash
        (Get-MmtlProjectRegistry -RuntimeRoot $script:runtime).projects | Should -BeNullOrEmpty
        (Get-Item $script:registry).Attributes -band [IO.FileAttributes]::ReparsePoint | Should -Be 0
    }

    It '有效 Registry 不允许被 recovery 覆盖' {
        [IO.File]::WriteAllText($script:registry,'{"schemaVersion":1,"projects":[]}',[Text.UTF8Encoding]::new($false))

        { Repair-MmtlProjectRegistry -RuntimeRoot $script:runtime -ConfirmBackup } | Should -Throw '*PROJECT_REGISTRY_NOT_CORRUPT*'
        (Get-MmtlProjectRegistry -RuntimeRoot $script:runtime).projects | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:runtime -Filter 'project-registry.corrupt-*.json').Count | Should -Be 0
    }
}
