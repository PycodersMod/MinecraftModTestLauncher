BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    $script:platformRoot=Split-Path -Parent $script:repoRoot
    Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
    if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        Import-Module (Join-Path $script:platformRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
        Register-MmtlWindowsPlatform -RepositoryRoot $script:platformRoot
    }elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)){
        Import-Module (Join-Path $script:platformRoot 'linux/src/LinuxPlatformProvider.psm1') -Force
        Register-MmtlLinuxPlatform -RepositoryRoot $script:platformRoot
    }else{
        Import-Module (Join-Path $script:platformRoot 'macos/src/MacOSPlatformProvider.psm1') -Force
        Register-MmtlMacOSPlatform -RepositoryRoot $script:platformRoot
    }
    Import-Module (Join-Path $script:repoRoot 'src/RunManager.psm1') -Force
}

Describe 'Runtime Mod JAR 隔离与完整性' {
    BeforeEach {
        $script:caseRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:session=Join-Path $script:caseRoot 'runtime/sessions/session_artifacts'
        $script:runtime=Join-Path $script:session 'Client-Dev'
        $script:sourceRoot=Join-Path $script:caseRoot 'sources'
        New-Item -ItemType Directory -Path $script:runtime,$script:sourceRoot -Force|Out-Null
        $script:jar=Join-Path $script:sourceRoot 'fixture-mod.jar'
        [IO.File]::WriteAllBytes($script:jar,[byte[]](0x50,0x4b,0x03,0x04,0x01,0x02,0x03))
    }

    It '复制到当前 Runtime mods 并记录匹配的 SHA-256，不泄露来源绝对路径' {
        $records=@(Copy-MmtlRuntimeMods -SessionPath $script:session -RuntimeDirectory $script:runtime -ModJars @($script:jar) -Role Client -Username Dev)
        $target=Join-Path $script:runtime 'mods/fixture-mod.jar'
        Test-Path -LiteralPath $target | Should -BeTrue
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $records[0].sha256
        $records[0].sha256 | Should -Match '^[a-f0-9]{64}$'
        $manifest=Join-Path $script:session 'artifacts/mods-Client-Dev.json'
        $text=Get-Content -LiteralPath $manifest -Raw
        $text | Should -Not -Match ([regex]::Escape($script:sourceRoot))
        ($text|ConvertFrom-Json).artifacts[0].sha256 | Should -Be $records[0].sha256
    }

    It '拒绝重复文件名或重复内容，并回滚本次部分复制' {
        $sameName=Join-Path $script:caseRoot 'other/fixture-mod.jar'
        New-Item -ItemType Directory -Path (Split-Path $sameName) -Force|Out-Null
        [IO.File]::WriteAllBytes($sameName,[byte[]](0x11,0x12,0x13))
        { Copy-MmtlRuntimeMods -SessionPath $script:session -RuntimeDirectory $script:runtime -ModJars @($script:jar,$sameName) -Role Client -Username Dev } | Should -Throw '*MOD_JAR_DUPLICATE*'
        @(Get-ChildItem (Join-Path $script:runtime 'mods') -File -ErrorAction SilentlyContinue).Count | Should -Be 0

        $renamed=Join-Path $script:sourceRoot 'renamed-copy.jar';Copy-Item -LiteralPath $script:jar -Destination $renamed
        { Copy-MmtlRuntimeMods -SessionPath $script:session -RuntimeDirectory $script:runtime -ModJars @($script:jar,$renamed) -Role Client -Username Dev } | Should -Throw '*MOD_JAR_DUPLICATE*'
    }

    It '拒绝 Runtime 越出当前 Session 的目标路径' {
        $outside=Join-Path $script:caseRoot 'outside-runtime';New-Item -ItemType Directory -Path $outside -Force|Out-Null
        { Copy-MmtlRuntimeMods -SessionPath $script:session -RuntimeDirectory $outside -ModJars @($script:jar) -Role Client -Username Dev } | Should -Throw '*MOD_JAR_RUNTIME_OUTSIDE_SESSION*'
        Test-Path -LiteralPath (Join-Path $outside 'mods/fixture-mod.jar') | Should -BeFalse
    }

    It 'linked build evidence 的预期哈希与当前 JAR 不符时拒绝注入' {
        $expected=@{$script:jar=('0'*64)}
        { Copy-MmtlRuntimeMods -SessionPath $script:session -RuntimeDirectory $script:runtime -ModJars @($script:jar) -Role Client -Username Dev -ExpectedHashes $expected } | Should -Throw '*MOD_JAR_EXPECTED_HASH_MISMATCH*'
        Test-Path -LiteralPath (Join-Path $script:runtime 'mods/fixture-mod.jar') | Should -BeFalse
    }
}
