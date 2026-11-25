BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/ProjectArtifactResolver.psm1') -Force
}

Describe 'Project build artifact selection' {
    It 'selects the LiteLoader litemod output and ignores the Forge jar variant' {
        $root=Join-Path $TestDrive 'liteloader-project';$output=Join-Path $root 'build/libs';New-Item -ItemType Directory -Path $output -Force|Out-Null
        $forge=Join-Path $output 'sample-1.0-forge.jar';$lite=Join-Path $output 'sample-1.0-liteloader.litemod'
        [IO.File]::WriteAllBytes($forge,[byte[]]@(1));[IO.File]::WriteAllBytes($lite,[byte[]]@(2))

        $artifact=Get-MmtlProjectOutputArtifact -Project ([pscustomobject]@{Root=$root;Loader='LiteLoader'})

        $artifact.path | Should -BeExactly ([IO.Path]::GetFullPath($lite))
        $artifact.extension | Should -BeExactly '.litemod'
    }

    It 'selects the newest Forge jar when an older build output remains in the directory' {
        $root=Join-Path $TestDrive 'forge-project';$output=Join-Path $root 'build/libs';New-Item -ItemType Directory -Path $output -Force|Out-Null
        $old=Join-Path $output 'sample-1.0.jar';$new=Join-Path $output 'sample-1.0-forge.jar'
        [IO.File]::WriteAllBytes($old,[byte[]]@(1));[IO.File]::WriteAllBytes($new,[byte[]]@(2))
        (Get-Item $old).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes(-2)
        (Get-Item $new).LastWriteTimeUtc=[DateTime]::UtcNow

        $artifact=Get-MmtlProjectOutputArtifact -Project ([pscustomobject]@{Root=$root;Loader='Forge'})

        $artifact.path | Should -BeExactly ([IO.Path]::GetFullPath($new))
        $artifact.extension | Should -BeExactly '.jar'
    }

    It 'rejects equally recent competing artifacts instead of guessing' {
        $root=Join-Path $TestDrive 'ambiguous-project';$output=Join-Path $root 'build/libs';New-Item -ItemType Directory -Path $output -Force|Out-Null
        $first=Join-Path $output 'sample-a.litemod';$second=Join-Path $output 'sample-b.litemod'
        [IO.File]::WriteAllBytes($first,[byte[]]@(1));[IO.File]::WriteAllBytes($second,[byte[]]@(2))
        $timestamp=[DateTime]::UtcNow.AddMinutes(-1);(Get-Item $first).LastWriteTimeUtc=$timestamp;(Get-Item $second).LastWriteTimeUtc=$timestamp

        { Get-MmtlProjectOutputArtifact -Project ([pscustomobject]@{Root=$root;Loader='LiteLoader'}) } | Should -Throw '*PROJECT_OUTPUT_ARTIFACT_AMBIGUOUS*'
    }
}
