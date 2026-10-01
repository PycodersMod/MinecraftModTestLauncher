Import-Module (Join-Path $PSScriptRoot '../src/Platform/Platform.psm1') -Force
if((Get-MmtlPlatformProvider).OS -in @('Linux','MacOS')) {
    BeforeAll {
        $script:repoRoot=Split-Path -Parent $PSScriptRoot
        $script:platform=Get-MmtlPlatformProvider
        $script:project=Join-Path $TestDrive 'project'
        $script:javaHome=Join-Path $TestDrive 'jdk'
        $script:runtime=Join-Path $TestDrive 'runtime'
        New-Item -ItemType Directory -Path (Join-Path $script:project 'src/main/resources'),(Join-Path $script:javaHome 'bin') -Force|Out-Null
        Set-Content (Join-Path $script:project 'build.gradle') '// fixture'
        Set-Content (Join-Path $script:project 'gradle.properties') "minecraft_version=1.20.1`nloader_version=0.16.0`njava_version=17`nmod_id=mmtl_fixture"
        Set-Content (Join-Path $script:project 'src/main/resources/fabric.mod.json') '{"schemaVersion":1,"id":"mmtl_fixture","version":"1.0.0","name":"Fixture","environment":"*","entrypoints":{}}'
        $script:java=Join-Path (Join-Path $script:javaHome 'bin') 'java'
        [IO.File]::WriteAllText($script:java,"#!/bin/sh`necho 'openjdk version `"17.0.1`"' >&2`nexit 0`n",[Text.UTF8Encoding]::new($false))
        $script:wrapper=Join-Path $script:project 'gradlew'
        [IO.File]::WriteAllText($script:wrapper,"#!/bin/sh`nmkdir -p build/libs`nprintf fixture > build/libs/fixture.jar`nexit 0`n",[Text.UTF8Encoding]::new($false))
        $exec=[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherRead -bor [IO.UnixFileMode]::OtherExecute
        [IO.File]::SetUnixFileMode($script:java,$exec);[IO.File]::SetUnixFileMode($script:wrapper,$exec)
        $script:configPath=Join-Path $TestDrive 'launcher.config.json'
        $platformHomes=@{};$platformHomes[$script:platform.OS]=@{'17'=$script:javaHome}
        $script:config=[ordered]@{configVersion=2;defaultProfile='fixture';javaHomes=@{'17'=$script:javaHome};javaHomesByPlatform=$platformHomes;runtimeRoot=$script:runtime;profiles=@{fixture=@{project=$script:project;linkedProjects=@();mode='Single';players=1;hostUsername='Dev';clientPrefix='Dev_';hostCheats=$false;clientPermissionLevel=0;gameMode='creative';difficulty='normal';worldName='Fixture';seed='';newWorld=$true;resetWorld=$false;port='Auto';autoBuild=$true;cleanBuild=$false;acceptEula=$false;extraMods=@();memoryMb=0;hostMemoryMb=0;clientMemoryMb=0;serverMemoryMb=0;resolution='Auto';guiScale='Auto';windowLayout='None';jvmArgs=@();gameArgs=@()}}}
        $script:config|ConvertTo-Json -Depth 20|Set-Content $script:configPath
        $script:pwsh=(Get-Command pwsh -ErrorAction Stop).Source
        $script:launcher=Join-Path $script:repoRoot 'launcher.ps1'
    }

    Describe 'Linux/macOS basic CLI and build path' {
        It 'runs launcher.sh help without project configuration' {
            $output=& sh (Join-Path $script:repoRoot 'launcher.sh') --help 2>&1|Out-String
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'Minecraft Mod Test Launcher'
        }

        It 'validates project, Linux Java and platform identity' {
            $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --profile fixture --validate 2>&1|Out-String
            $LASTEXITCODE | Should -Be 0
            $output=[regex]::Replace($output,'\x1B\[[0-?]*[ -/]*[@-~]','')
            $output | Should -Match "Platform\s+: $($script:platform.OS)"
            $output | Should -Match 'Architecture'
            $output | Should -Match 'WSL'
        }

        It 'previews the POSIX Gradle wrapper without executing it' {
            $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --profile fixture --dry-run 2>&1|Out-String
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match '(\./gradlew|sh .+gradlew)'
            Test-Path $script:runtime | Should -BeFalse
        }

        It 'runs build through the fixture wrapper and records platform metadata and artifact hash' {
            $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --profile fixture --build 2>&1|Out-String
            $LASTEXITCODE | Should -Be 0
            $sessions=Get-ChildItem (Join-Path $script:runtime 'sessions') -Directory
            $sessions.Count | Should -Be 1
            $state=Get-Content (Join-Path $sessions[0].FullName 'session.json') -Raw|ConvertFrom-Json
            $state.metadata.platform | Should -Be $script:platform.OS
            $state.metadata.arch | Should -Be $script:platform.Arch
            $state.metadata.isWSL | Should -Be $script:platform.IsWSL
            $state.jarSha256 | Should -Match '^[A-F0-9]{64}$'
        }
    }
}
