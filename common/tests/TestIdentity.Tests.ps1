BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src/TestIdentity.psm1') -Force
    Import-Module (Join-Path $root 'src/Config.psm1') -Force
    Import-Module (Join-Path $root 'src/SessionManager.psm1') -Force
}

Describe '离线 Test Identity 与角色隔离目录' {
    BeforeEach {
        $script:sessionPath = Join-Path $TestDrive ('sessions/session-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:sessionPath -Force | Out-Null
        $script:roles = @(
            [pscustomobject]@{role='Host';username='OfflineHost';runtimeJavaMajor=21;runtimeJavaPath='C:/Java/21/bin/java.exe';networkRole='IntegratedServerHost'},
            [pscustomobject]@{role='Guest';username='OfflineGuest1';runtimeJavaMajor=21;runtimeJavaPath='C:/Java/21/bin/java.exe';networkRole='LoopbackClient'},
            [pscustomobject]@{role='Guest';username='OfflineGuest2';runtimeJavaMajor=21;runtimeJavaPath='C:/Java/21/bin/java.exe';networkRole='LoopbackClient'}
        )
    }

    It '按离线 UUID v3 算法生成稳定且区分大小写的身份 ID' {
        $one = Get-MmtlOfflinePlayerUuid -Username 'OfflineHost'
        $two = Get-MmtlOfflinePlayerUuid -Username 'OfflineHost'
        $other = Get-MmtlOfflinePlayerUuid -Username 'offlinehost'

        $one | Should -BeExactly $two
        $one | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-3[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        $one | Should -Not -BeExactly $other
    }

    It '为 IntegratedLAN 生成确定、合法且互不冲突的 Host/Guest 用户名' {
        $profile = [pscustomobject]@{mode='IntegratedLAN';players=4;hostUsername='Dev_1';clientPrefix='Dev_'}
        $first = New-MmtlTestIdentityRolePlan -Profile $profile
        $second = New-MmtlTestIdentityRolePlan -Profile $profile

        @($first.username | Select-Object -Unique).Count | Should -Be 4
        @($first.username | Where-Object { $_ -notmatch '^[A-Za-z0-9_]{1,16}$' }).Count | Should -Be 0
        ($first | ConvertTo-Json -Compress) | Should -BeExactly ($second | ConvertTo-Json -Compress)
        $first[0].role | Should -BeExactly 'Host'
        @($first | Where-Object role -eq 'Guest').Count | Should -Be 3
    }

    It '为 Host/Guest 创建唯一隔离 gameDir 与日志和存档目录' {
        $identities = Initialize-MmtlTestIdentityDirectories -SessionId 'session-a' -SessionPath $script:sessionPath -Roles $script:roles

        $identities.Count | Should -Be 3
        @($identities.username | Select-Object -Unique).Count | Should -Be 3
        @($identities.offlineUuid | Select-Object -Unique).Count | Should -Be 3
        @($identities | ForEach-Object gameDir | Select-Object -Unique).Count | Should -Be 3
        foreach ($identity in $identities) {
            Test-Path -LiteralPath $identity.logDirectory | Should -BeTrue
            Test-Path -LiteralPath $identity.configDirectory | Should -BeTrue
            Test-Path -LiteralPath $identity.screenshotsDirectory | Should -BeTrue
            Test-Path -LiteralPath $identity.crashReportsDirectory | Should -BeTrue
        }
        $schema = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/test-identity-v1.schema.json'
        foreach ($identity in $identities) { Test-Json -Json ($identity | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $schema | Should -BeTrue }
        Test-Path -LiteralPath (Join-Path $identities[0].gameDir 'saves') | Should -BeTrue
        $identities[1].savesDirectory | Should -BeNullOrEmpty
        $identities[0].offline | Should -BeTrue
        $identities[0].runtimeJavaMajor | Should -Be 21
        $identities[0].networkRole | Should -BeExactly 'IntegratedServerHost'
        ($identities | ConvertTo-Json -Depth 10) | Should -Not -Match '(?i)token|password|access.?key|credential'

        'preserve-existing-options' | Set-Content -LiteralPath $identities[0].optionsFile
        Initialize-MmtlTestIdentityDirectories -SessionId 'session-a' -SessionPath $script:sessionPath -Roles $script:roles | Out-Null
        Get-Content -LiteralPath $identities[0].optionsFile -Raw | Should -Match 'preserve-existing-options'
    }

    It '兼容读取 v1/v2 Profile 并且不写回用户配置' {
        foreach ($version in @(1,2)) {
            $configPath = Join-Path $TestDrive "config-v$version.json"
            $config = [ordered]@{
                configVersion = $version
                defaultProfile = 'offline'
                javaHomes = @{ '21' = 'C:/Java/21' }
                profiles = @{ offline = @{ project = 'anonymous-project'; mode = 'Single'; players = 1; primaryModId = 'example' } }
            }
            $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath
            $before = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash

            $loaded = Read-MmtlConfig -Path $configPath

            $loaded.profiles.offline.primaryModId | Should -BeExactly 'example'
            (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash | Should -BeExactly $before
        }
    }

    It '正式 Session 创建时登记 offline identities 并使用隔离目录' {
        $runtime = Join-Path $TestDrive 'identity-session-runtime'
        $metadata = [pscustomobject]@{mode='IntegratedLAN';players=3;hostUsername='HostDev';clientPrefix='Guest_';runtimeJavaMajor=21;runtimeJavaPath='C:/Java/21/bin/java.exe'}

        $session = New-MmtlSession -RuntimeRoot $runtime -Name 'identity_integration' -Metadata $metadata
        $record = Get-Content -LiteralPath (Join-Path $session 'session.json') -Raw | ConvertFrom-Json

        @($record.testIdentities).Count | Should -Be 3
        @($record.testIdentities | Where-Object role -eq 'Host').Count | Should -Be 1
        @($record.testIdentities | Where-Object role -eq 'Guest').Count | Should -Be 2
        @($record.testIdentities | ForEach-Object gameDir | Select-Object -Unique).Count | Should -Be 3
        @($record.players).Count | Should -Be 3
        $record.testIdentities[0].runtimeJavaMajor | Should -Be 21
        $record.testIdentities[0].runtimeJavaPath | Should -BeExactly 'C:/Java/21/bin/java.exe'
    }

    It '拒绝重复、非法和过长的 Minecraft 用户名且不创建角色目录' {
        $duplicate = @($script:roles[0],$script:roles[0])
        { Initialize-MmtlTestIdentityDirectories -SessionId 'session-a' -SessionPath $script:sessionPath -Roles $duplicate } | Should -Throw '*IDENTITY_USERNAME*'
        $invalid = @([pscustomobject]@{role='Client';username='../escape'})
        { Initialize-MmtlTestIdentityDirectories -SessionId 'session-a' -SessionPath $script:sessionPath -Roles $invalid } | Should -Throw '*IDENTITY_USERNAME*'
        Test-Path -LiteralPath (Join-Path $script:sessionPath '..\escape') | Should -BeFalse
    }

    It '将共享测试工件复制到每个角色的独立 mods 目录并校验 SHA-256' {
        $identities = Initialize-MmtlTestIdentityDirectories -SessionId 'session-a' -SessionPath $script:sessionPath -Roles $script:roles
        $artifact = Join-Path $TestDrive 'test-mod.jar'
        [IO.File]::WriteAllBytes($artifact,[byte[]](1,2,3,4,5))
        $before = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash

        $copies = @($identities | ForEach-Object { Copy-MmtlArtifactToTestIdentity -SourcePath $artifact -Identity $_ })

        $copies.Count | Should -Be 3
        @($copies.destination | Select-Object -Unique).Count | Should -Be 3
        foreach ($copy in $copies) {
            $copy.sha256 | Should -BeExactly $before
            $copy.readOnly | Should -BeTrue
            ((Get-Item -LiteralPath $copy.destination).Attributes -band [IO.FileAttributes]::ReadOnly) | Should -Not -Be 0
            $copiedItem = Get-Item -LiteralPath $copy.destination -Force
            $copiedItem.Attributes = $copiedItem.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        }
        (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash | Should -BeExactly $before
    }

    It '拒绝 Session 路径外的身份根和 Session 内重解析点' {
        $outside = Join-Path $TestDrive 'outside-identities'
        { Initialize-MmtlTestIdentityDirectories -SessionId 'session-a' -SessionPath $outside -Roles @($script:roles[0]) -AllowedRoot $script:sessionPath } | Should -Throw '*IDENTITY_PATH*'
        $linked = Join-Path $TestDrive 'linked-session'
        $linkType=if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){'Junction'}else{'SymbolicLink'}
        try { New-Item -ItemType $linkType -Path $linked -Target $script:sessionPath -ErrorAction Stop | Out-Null } catch { Set-ItResult -Skipped -Because '当前运行环境不允许创建目录链接'; return }
        { Initialize-MmtlTestIdentityDirectories -SessionId 'session-a' -SessionPath $linked -Roles @($script:roles[0]) } | Should -Throw '*IDENTITY_PATH_REPARSE_POINT*'
    }
}
