Describe 'Public repository hygiene scanner' {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $script:scannerModule = Join-Path $script:repoRoot '.github/scripts/PublicRepositoryHygiene.psm1'
        Import-Module $script:scannerModule -Force
    }

    It 'detects an arbitrary Windows drive path' {
        $sample = 'cache=' + ('E:' + '\' + 'private-cache\gradle.properties')
        $findings = @(Get-MmtlPublicHygieneContentFinding -Content $sample -RelativePath 'fixture.txt')
        $findings.Code | Should -Contain 'WINDOWS_ABSOLUTE_PATH'
    }

    It 'detects Linux and macOS user home paths' {
        $linux = '/' + 'home' + '/' + 'build-user' + '/.gradle/gradle.properties'
        $macos = '/' + 'Users' + '/' + 'build-user' + '/Library/Caches/runtime'
        $findings = @(
            Get-MmtlPublicHygieneContentFinding -Content $linux -RelativePath 'linux.txt'
            Get-MmtlPublicHygieneContentFinding -Content $macos -RelativePath 'macos.txt'
        )
        $findings.Code | Should -Contain 'LINUX_HOME_PATH'
        $findings.Code | Should -Contain 'MACOS_HOME_PATH'
    }

    It 'detects local proxy endpoints and local scratch cache names' {
        $proxy = 'http://' + '127.0.0.1' + ':7897'
        $scratch = '/' + 'tmp' + '/' + (@('mmtl','temp') -join '-') + '/run.log'
        $findings = @(
            Get-MmtlPublicHygieneContentFinding -Content $proxy -RelativePath 'proxy.txt'
            Get-MmtlPublicHygieneContentFinding -Content $scratch -RelativePath 'scratch.txt'
        )
        $findings.Code | Should -Contain 'LOCAL_PROXY_ENDPOINT'
        $findings.Code | Should -Contain 'LOCAL_CACHE_RUNTIME_PATH'
    }

    It 'detects credential-shaped bearer, password and URL values' {
        $sample = ('password' + '=') + 'synthetic-secret-value' + ' ' + ('Bearer ' + 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH') + ' ' + ('https://' + 'example:synthetic-secret' + '@github.com/org/repo')
        $findings = @(Get-MmtlPublicHygieneContentFinding -Content $sample -RelativePath 'credentials.txt')
        $findings.Code | Should -Contain 'PASSWORD_CREDENTIAL'
        $findings.Code | Should -Contain 'BEARER_CREDENTIAL'
        $findings.Code | Should -Contain 'URL_CREDENTIAL'
    }

    It 'detects embedded web-view token fields without flagging redacted placeholders' {
        $field = 'upload' + 'Token'
        $sample = ('"' + $field + '":"') + 'synthetic' + 'TokenValue1234567890' + '"'
        $redacted = ('"' + $field + '":"') + '<redacted>' + '"'
        $findings = @(Get-MmtlPublicHygieneContentFinding -Content $sample -RelativePath 'payload.json')
        $findings.Code | Should -Contain 'EMBEDDED_TOKEN_FIELD'
        @(Get-MmtlPublicHygieneContentFinding -Content $redacted -RelativePath 'redacted.json').Count | Should -Be 0
    }

    It 'detects configured sensitive identities without printing their value' {
        $sample = 'machine=' + 'SyntheticHostName'
        $findings = @(Get-MmtlPublicHygieneContentFinding -Content $sample -RelativePath 'identity.txt' -SensitiveIdentities @('SyntheticHostName'))
        $findings.Code | Should -Contain 'SENSITIVE_IDENTITY'
        ($findings | ConvertTo-Json -Compress) | Should -Not -Match 'SyntheticHostName'
    }

    It 'does not treat the generic GitHub Actions runner account as a private identity' {
        $runnerProfile = ('C:' + '\' + 'Users\runner')
        $automatic = @(Get-MmtlPublicHygieneIdentityCandidates -EnvironmentUserName 'runner' -MachineName 'fv-az123' -UserProfile $runnerProfile -GitHubActions)
        $automatic | Should -Not -Contain 'runner'
        $automatic | Should -Contain 'fv-az123'

        $explicit = @(Get-MmtlPublicHygieneIdentityCandidates -SensitiveIdentities @('runner') -EnvironmentUserName 'runner' -MachineName 'fv-az123' -UserProfile $runnerProfile -GitHubActions)
        $explicit | Should -Contain 'runner'
    }

    It 'allows a generic path placeholder and a single explicitly marked synthetic fixture' {
        $placeholder = 'JDK path: ' + ('C:' + '\' + '<JDK_HOME>' + '\bin\java.exe') + '; home: ' + ('/' + 'home' + '/' + '<user>' + '/.gradle')
        $fixture = 'test executable: ' + ('C:' + '\' + 'fake\java.exe') + ' # public-hygiene: allow-synthetic-path'
        @(Get-MmtlPublicHygieneContentFinding -Content $placeholder -RelativePath 'example.md').Count | Should -Be 0
        @(Get-MmtlPublicHygieneContentFinding -Content $fixture -RelativePath 'fixture.ps1').Count | Should -Be 0
    }

    It 'detects path strings in binary files and compressed archive entries' {
        $privatePath = 'D:' + '\' + 'private-cache\runtime.bin'
        $binary = [Text.Encoding]::Unicode.GetBytes($privatePath)
        $binaryFindings = @(Get-MmtlPublicHygieneFileFinding -RelativePath 'snapshot.bin' -Bytes $binary)
        $binaryFindings.Code | Should -Contain 'WINDOWS_ABSOLUTE_PATH'

        $memory = [IO.MemoryStream]::new()
        try {
            $archive = [IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Create,$true)
            try {
                $entry = $archive.CreateEntry('metadata.txt')
                $entryStream = $entry.Open()
                try {
                    $entryBytes = [Text.Encoding]::UTF8.GetBytes($privatePath)
                    $entryStream.Write($entryBytes,0,$entryBytes.Length)
                } finally { $entryStream.Dispose() }
            } finally { $archive.Dispose() }
            $zipFindings = @(Get-MmtlPublicHygieneFileFinding -RelativePath 'snapshot.zip' -Bytes $memory.ToArray())
            $zipFindings.Code | Should -Contain 'WINDOWS_ABSOLUTE_PATH'
            $zipFindings.Path | Should -Contain 'snapshot.zip!/metadata.txt'
        } finally { $memory.Dispose() }
    }
}
