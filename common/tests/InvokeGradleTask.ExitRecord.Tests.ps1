BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:worker = if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
        Join-Path $script:repoRoot 'windows/src/Invoke-GradleTask.ps1'
    }else{
        Join-Path $script:repoRoot 'linux/src/Invoke-GradleTask.ps1'
    }
    $script:pwsh = (Get-Command pwsh -ErrorAction Stop).Source
}

Describe 'Gradle task process exit record' {
    It 'writes StopRequested false when the Gradle wrapper exits normally' {
        $project = Join-Path $TestDrive 'project'
        $session = Join-Path $TestDrive 'session'
        New-Item -ItemType Directory -Path $project,$session -Force | Out-Null
        if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){
            "@echo off`r`nexit /b 0`r`n" | Set-Content -LiteralPath (Join-Path $project 'gradlew.bat') -Encoding ascii
        }else{
            $wrapper=Join-Path $project 'gradlew';Set-Content -LiteralPath $wrapper -Value "#!/bin/sh`nexit 0" -Encoding utf8;& chmod +x $wrapper
        }
        $plan = [pscustomobject]@{projectRoot=$project;sessionPath=$session;arguments=@()}
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($plan | ConvertTo-Json -Compress)))

        $output = & $script:pwsh -NoProfile -File $script:worker -LaunchPlanB64 $encoded 2>&1 | Out-String
        $workerExitCode = $LASTEXITCODE

        $workerExitCode | Should -Be 0 -Because $output
        $exitFiles = @(Get-ChildItem -LiteralPath $session -Filter 'process-*.exit.json' -File)
        $exitFiles.Count | Should -Be 1
        $exitRecord = Get-Content -LiteralPath $exitFiles[0].FullName -Raw | ConvertFrom-Json
        $exitRecord.PSObject.Properties.Name | Should -Contain 'StopRequested'
        $exitRecord.StopRequested | Should -BeFalse
    }
}
