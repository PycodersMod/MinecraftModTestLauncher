BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Compatibility/LiteLoaderRunInitScript.psm1') -Force
}

Describe 'LiteLoader Gradle run task integration' {
    It 'generates an exact-target script with Session-only classpath and LaunchWrapper Tweaker' {
        $session = Join-Path $TestDrive 'session'
        $loader = Join-Path $session 'libraries/com/mumfrey/liteloader/1.7.10_04/liteloader.jar'
        $library = Join-Path $session 'libraries/net/minecraft/launchwrapper/1.11/launchwrapper.jar'
        New-Item -ItemType Directory -Path (Split-Path $loader) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $library) -Force | Out-Null
        [IO.File]::WriteAllBytes($loader,[byte[]]@(1,2,3))
        [IO.File]::WriteAllBytes($library,[byte[]]@(4,5,6))
        $plan = [pscustomobject]@{
            targetId='LiteLoader@1.7.10'; minecraftId='1.7.10'; mainClass='net.minecraft.launchwrapper.Launch';
            tweakClass='com.mumfrey.liteloader.launch.LiteLoaderTweaker'; libraries=@([pscustomobject]@{name='net.minecraft:launchwrapper:1.11'});
            clientArtifact=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/e80d9b3bf5085002218d4be59e668bac718abbc6/client.jar';sha1='e80d9b3bf5085002218d4be59e668bac718abbc6';bytes=5256245};
            serverArtifact=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/952438ac4e01b4d115c5fc38f891710c4941df29/server.jar';sha1='952438ac4e01b4d115c5fc38f891710c4941df29';bytes=9605030};
            versionMetadata=[pscustomobject]@{url='https://piston-meta.mojang.com/v1/packages/ed5d8789ed29872ea2ef1c348302b0c55e3f3468/1.7.10.json';sha1='ed5d8789ed29872ea2ef1c348302b0c55e3f3468';bytes=999;sha256=('d'*64)};
            assetIndex=[pscustomobject]@{url='https://launchermeta.mojang.com/v1/packages/1863782e33ce7b584fc45b037325a1964e095d3e/1.7.10.json';sha1='1863782e33ce7b584fc45b037325a1964e095d3e';bytes=72996;id='1.7.10'}
        }
        $artifacts = @([pscustomobject]@{path=$loader},[pscustomobject]@{path=$library})

        $scriptText = New-MmtlLiteLoaderRunInitScript -SessionPath $session -TaskName runClient -LoaderLaunchPlan $plan -Artifacts $artifacts
        $match = [regex]::Match($scriptText,"Base64\.decoder\.decode\('(?<value>[A-Za-z0-9+/=]+)'\)")
        $match.Success | Should -BeTrue
        $config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups['value'].Value)) | ConvertFrom-Json
        $config.taskName | Should -BeExactly 'runClient'
        $config.minecraftId | Should -BeExactly '1.7.10'
        $config.mainClass | Should -BeExactly 'net.minecraft.launchwrapper.Launch'
        $config.tweakClass | Should -BeExactly 'com.mumfrey.liteloader.launch.LiteLoaderTweaker'
        @($config.classpath).Count | Should -Be 2
        $scriptText | Should -Match 'def mmtlRuntimeClasspath = mmtlProject\.files\(mmtlPatchedStartDirectory\) \+ mmtlProject\.files\(mmtlLiteLoaderConfig\.classpath\)'
        $scriptText | Should -Match 'mmtlRuntimeClasspath \+= mmtlProject\.files\(mmtlSessionClientArtifact\)'
        $scriptText | Should -Match "mmtlLiteLoaderConfig\.taskName == 'runClient'"
        $scriptText | Should -Match 'mmtlTask\.classpath = mmtlRuntimeClasspath \+ mmtlTask\.classpath'
        $scriptText | Should -Match 'mmtlTask\.setArgs\(mmtlArgs\)'
        $scriptText | Should -Not -Match 'mmtlTask\.mainClass\.set|mmtlTask\.main\s*='
        $scriptText | Should -Match 'mmtlLiteLoaderTweakerPresent'
        $scriptText | Should -Match "mmtlArgs\.add\('--tweakClass'\)"
        $scriptText | Should -Not -Match 'MMTL_LITELOADER_TWEAK_CLASS_CONFLICT'
        $scriptText | Should -Match 'mmtlSessionClientArtifact'
        $scriptText | Should -Match 'MMTL_LITELOADER_PINNED_DOWNLOAD_STAGE_FAILED:'
        $scriptText | Should -Match "\!\(\['CLIENT','SERVER'\]\.contains\(mmtlArtifactName\.toUpperCase\(\)\)\)"
        $scriptText | Should -Match 'mmtlProject\.files\(mmtlSessionClientArtifact\)'
        $scriptText | Should -Match 'mmtlUrlSetter\.invoke\(mmtlDownloadTask, mmtlDelayedUrl\)'
        $scriptText | Should -Match "'_SHA1_MISMATCH:' \+ mmtlDownloadTask\.path"
        $scriptText | Should -Match 'mmtlDownloadTask\.outputs\.upToDateWhen'
        $scriptText | Should -Match "mmtlConfigurePinnedDownload\('download' \+ mmtlArtifactName\.capitalize\(\)"
        $scriptText | Should -Match "mmtlConfigurePinnedDownload\('getVersionJson'"
        $scriptText | Should -Match "mmtlConfigurePinnedDownload\('getAssetsIndex'"
        $scriptText | Should -Match 'mmtlAllowTrailingLineFeed && mmtlArtifactBytes\.length == mmtlPin\.bytes \+ 1'
        $scriptText | Should -Match "gradle.rootProject.tasks.findByName\('makeStart'\)"
        $scriptText | Should -Match 'com\.mumfrey\.liteloader\.debug\.Start'
        $scriptText | Should -Match 'net\.minecraft\.launchwrapper\.Launch'
        $scriptText | Should -Match 'MMTL_LITELOADER_BOUNCE_CLASS_UNSUPPORTED'
        $serverScriptText = New-MmtlLiteLoaderRunInitScript -SessionPath $session -TaskName runServer -LoaderLaunchPlan $plan -Artifacts $artifacts
        $serverScriptText | Should -Match 'GradleStartServer\.java'
        $serverScriptText | Should -Match 'net\.minecraft\.server\.MinecraftServer'
        $serverScriptText | Should -Match 'MMTL_LITELOADER_SERVER_BOUNCE_CLASS_UNSUPPORTED'
        $serverScriptText | Should -Match 'ToolProvider\.getSystemJavaCompiler\(\)'
        $serverScriptText | Should -Match 'mmtlPatchedStartDirectory'
        $serverScriptText | Should -Match 'MMTL_LITELOADER_START_COMPILATION_FAILED:'
        $serverScriptText | Should -Match "mmtlLiteLoaderConfig\.taskName == 'runClient'"
    }

    It 'rejects artifacts outside Session, unsupported tasks, and incomplete artifact sets' {
        $session = Join-Path $TestDrive 'session'
        New-Item -ItemType Directory -Path $session -Force | Out-Null
        $outside = Join-Path $TestDrive 'outside.jar'
        [IO.File]::WriteAllBytes($outside,[byte[]]@(1))
        $plan = [pscustomobject]@{mainClass='net.minecraft.launchwrapper.Launch';minecraftId='1.7.10';tweakClass='com.mumfrey.liteloader.launch.LiteLoaderTweaker';libraries=@();clientArtifact=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/e80d9b3bf5085002218d4be59e668bac718abbc6/client.jar';sha1='e80d9b3bf5085002218d4be59e668bac718abbc6';bytes=5256245};serverArtifact=[pscustomobject]@{url='https://launcher.mojang.com/v1/objects/952438ac4e01b4d115c5fc38f891710c4941df29/server.jar';sha1='952438ac4e01b4d115c5fc38f891710c4941df29';bytes=9605030};versionMetadata=[pscustomobject]@{url='https://piston-meta.mojang.com/v1/packages/ed5d8789ed29872ea2ef1c348302b0c55e3f3468/1.7.10.json';sha1='ed5d8789ed29872ea2ef1c348302b0c55e3f3468';bytes=999;sha256=('d'*64)};assetIndex=[pscustomobject]@{url='https://launchermeta.mojang.com/v1/packages/1863782e33ce7b584fc45b037325a1964e095d3e/1.7.10.json';sha1='1863782e33ce7b584fc45b037325a1964e095d3e';bytes=72996;id='1.7.10'}}
        { New-MmtlLiteLoaderRunInitScript -SessionPath $session -TaskName runClient -LoaderLaunchPlan $plan -Artifacts @([pscustomobject]@{path=$outside}) } | Should -Throw '*LITELOADER_RUN_ARTIFACT_OUTSIDE_SESSION*'
        { New-MmtlLiteLoaderRunInitScript -SessionPath $session -TaskName build -LoaderLaunchPlan $plan -Artifacts @() } | Should -Throw '*LITELOADER_RUN_TASK_INVALID*'
        { New-MmtlLiteLoaderRunInitScript -SessionPath $session -TaskName runServer -LoaderLaunchPlan $plan -Artifacts @() } | Should -Throw '*LITELOADER_RUN_ARTIFACT_SET_INCOMPLETE*'
    }

    It 'rejects a missing or unpinned Mojang client artifact before generating a script' {
        $session = Join-Path $TestDrive 'missing-client-session'
        New-Item -ItemType Directory -Path $session -Force | Out-Null
        $loader = Join-Path $session 'loader.jar'; $library = Join-Path $session 'library.jar'
        [IO.File]::WriteAllBytes($loader,[byte[]]@(1)); [IO.File]::WriteAllBytes($library,[byte[]]@(2))
        $plan=[pscustomobject]@{mainClass='net.minecraft.launchwrapper.Launch';tweakClass='com.mumfrey.liteloader.launch.LiteLoaderTweaker';libraries=@([pscustomobject]@{});clientArtifact=$null;serverArtifact=$null;versionMetadata=$null;assetIndex=$null}
        { New-MmtlLiteLoaderRunInitScript -SessionPath $session -TaskName runClient -LoaderLaunchPlan $plan -Artifacts @([pscustomobject]@{path=$loader},[pscustomobject]@{path=$library}) } | Should -Throw '*LITELOADER_CLIENT_ARTIFACT_PIN_INVALID*'
    }
}
