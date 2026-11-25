BeforeAll {
    $script:repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:hygieneScript = Join-Path $script:repositoryRoot '.github/scripts/Test-PublicRepositoryHygiene.ps1'
    $script:pwshPath = (Get-Command pwsh -ErrorAction Stop).Source

    function Invoke-HygieneScanInChildProcess {
        param([Parameter(Mandatory)][string]$Root)

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:pwshPath
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:hygieneScript, '-RepositoryRoot', $Root)) {
            $startInfo.ArgumentList.Add($argument)
        }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = [Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.Result + $stderr.Result
        }
    }

    function Initialize-HygieneFixtureRepository {
        param([Parameter(Mandatory)][string]$Root)

        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        & git init --quiet $Root
        if ($LASTEXITCODE -ne 0) { throw 'TEST_GIT_INIT_FAILED' }
    }
}

Describe 'Test-PublicRepositoryHygiene upstream path fixtures' {
    It 'allows only the exact verified Forge changelogs containing upstream scp home paths' {
        $root = Join-Path $TestDrive 'upstream-forge-fixtures'
        Initialize-HygieneFixtureRepository -Root $root

        $fixturePaths = @(
            'common/fixtures/forge/1.7.10-marker/forge-1.7.10-10.13.4.1614-1.7.10-changelog.txt',
            'common/fixtures/forge/1.8.8-marker/forge-1.8.8-11.15.0.1655-changelog.txt'
        )
        foreach ($relativePath in $fixturePaths) {
            $source = Join-Path $script:repositoryRoot $relativePath
            $destination = Join-Path $root $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination
        }

        $result = Invoke-HygieneScanInChildProcess -Root $root
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'Public repository hygiene: PASS'
    }

    It 'still rejects a synthetic Linux user home path' {
        $root = Join-Path $TestDrive 'synthetic-linux-home'
        Initialize-HygieneFixtureRepository -Root $root
        $syntheticPath = '/' + 'home/alice/.gradle'
        Set-Content -LiteralPath (Join-Path $root 'PRIVATE_PATH.md') -Value ("Cache: $syntheticPath") -Encoding utf8

        $result = Invoke-HygieneScanInChildProcess -Root $root
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'PRIVATE_PATH.md'
    }
}
