BeforeAll {
    $script:root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/Doctor.psm1') -Force
}

Describe 'Environment Doctor' {
    It '返回固定 checks 结构并离线只读诊断，不泄漏代理或凭据值' {
        $runtime=Join-Path $TestDrive 'runtime';$sessions=Join-Path $runtime 'sessions';New-Item -ItemType Directory -Path $sessions -Force|Out-Null
        $project=Join-Path $TestDrive 'project';New-Item -ItemType Directory -Path $project -Force|Out-Null;Set-Content (Join-Path $project 'gradlew.bat') '@echo off'
        $config=[pscustomobject]@{runtimeRoot=$runtime;profiles=[pscustomobject]@{default=[pscustomobject]@{project=$project;mode='Single';players=1}};defaultProfile='default';javaHomes=@{}}
        $plan=[pscustomobject]@{project=[pscustomobject]@{projectRoot=$project};capabilityGates=[pscustomobject]@{buildReady=$false;launchReady=$false};blockingReasons=@();runtime=[pscustomobject]@{runtimeDirectories=@()}}
        $env:HTTPS_PROXY='https://secret.invalid/token-value';$env:GITHUB_TOKEN='secret-value'

        $result=Invoke-MmtlDoctor -Config $config -Plan $plan -RuntimeRoot $runtime -Offline

        $result.checks.Count | Should -BeGreaterThan 10
        foreach($check in $result.checks){$check.id|Should -Not -BeNullOrEmpty;$check.status|Should -BeIn @('PASS','WARN','FAIL','SKIP');$check.severity|Should -BeIn @('INFO','WARNING','ERROR')}
        ($result|ConvertTo-Json -Depth 20) | Should -Not -Match 'secret-value|token-value|secret.invalid'
        ($result.checks|Where-Object id -eq 'NETWORK_METADATA').status | Should -BeExactly 'SKIP'
        Test-Path -LiteralPath $runtime | Should -BeTrue
        Remove-Item Env:HTTPS_PROXY;Remove-Item Env:GITHUB_TOKEN
    }
}
