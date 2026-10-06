BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:launcher = Join-Path $script:repoRoot 'windows/launcher.ps1'
    $script:pwsh = (Get-Command pwsh -ErrorAction Stop).Source
}

Describe '通用项目 Registry CLI' {
    BeforeEach {
        $script:fixture = Join-Path $TestDrive 'anonymous-project'
        $script:runtime = Join-Path $TestDrive 'runtime'
        $script:config = Join-Path $TestDrive 'registry-config.json'
        New-Item -ItemType Directory -Path (Join-Path $script:fixture 'src/main/resources') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:fixture 'build.gradle') -Value "plugins { id 'fabric-loom' version '1.7.4' }"
        Set-Content -LiteralPath (Join-Path $script:fixture 'gradle.properties') -Value "minecraft_version=1.21.6`nloader_version=0.16.14"
        Set-Content -LiteralPath (Join-Path $script:fixture 'src/main/resources/fabric.mod.json') -Value '{"schemaVersion":1,"id":"anonymous_mod","name":"Anonymous Mod"}'
        $configObject = [ordered]@{
            configVersion = 2
            defaultProfile = 'unused'
            runtimeRoot = $script:runtime
            javaHomes = @{ '21' = 'unused' }
            profiles = @{ unused = @{ project = 'does-not-exist'; mode = 'InvalidLegacyValue' } }
        }
        $configObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:config
        $script:buildHash = (Get-FileHash -LiteralPath (Join-Path $script:fixture 'build.gradle') -Algorithm SHA256).Hash
    }

    It '在无有效活动 Profile 时仍可导入并输出纯 JSON' {
        $output = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:config --import-project $script:fixture --json 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $result = $output | ConvertFrom-Json -ErrorAction Stop
        $result.status | Should -BeExactly 'Imported'
        $result.targets[0].modIds | Should -Contain 'anonymous_mod'
        $output | Should -Not -Match 'WARNING:|项目：|Build Java'
        (Get-FileHash -LiteralPath (Join-Path $script:fixture 'build.gradle') -Algorithm SHA256).Hash | Should -BeExactly $script:buildHash
    }

    It 'list/info/remove 仅操作本地 registry 且不删除项目源码' {
        $import = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:config --import-project $script:fixture --json 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $projectId = ($import | ConvertFrom-Json -ErrorAction Stop).projectId

        $list = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:config --list-projects --json 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        @(($list | ConvertFrom-Json -ErrorAction Stop).projects).Count | Should -Be 1

        $info = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:config --project-info $projectId --json 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        ($info | ConvertFrom-Json -ErrorAction Stop).projectId | Should -BeExactly $projectId

        $removed = & $script:pwsh -NoProfile -File $script:launcher --config-file $script:config --remove-project $projectId --json 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        ($removed | ConvertFrom-Json -ErrorAction Stop).removed | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:fixture 'build.gradle') | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $script:fixture 'build.gradle') -Algorithm SHA256).Hash | Should -BeExactly $script:buildHash
    }
}
