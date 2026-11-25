BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:universe = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/compatibility-universe.json') -Raw | ConvertFrom-Json
    $script:loaderPins = Get-Content -LiteralPath (Join-Path $script:repoRoot 'compatibility/liteloader-artifact-pins.json') -Raw | ConvertFrom-Json
    $script:catalogPath = Join-Path $script:repoRoot 'compatibility/liteloader-runtime-dependencies.json'
    $script:modulePath = Join-Path $script:repoRoot 'common/src/Compatibility/LiteLoaderRuntimeDependencies.psm1'
    if (Test-Path -LiteralPath $script:modulePath) { Import-Module $script:modulePath -Force }
}

Describe 'LiteLoader exact runtime dependency catalog' {
    It 'resolves the frozen loader dependencies only for exact pinned targets' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $targets = @('LiteLoader@1.5.2','LiteLoader@1.6.2','LiteLoader@1.6.4','LiteLoader@1.7.2','LiteLoader@1.7.10','LiteLoader@1.8')
        foreach ($targetId in $targets) {
            $resolved = Get-MmtlLiteLoaderRuntimeDependencies -TargetId $targetId -Universe $script:universe -Catalog $catalog -LoaderArtifactCatalog $script:loaderPins
            $resolved.targetId | Should -BeExactly $targetId
            $resolved.mainClass | Should -BeExactly 'net.minecraft.launchwrapper.Launch'
            $resolved.tweakClass | Should -BeExactly 'com.mumfrey.liteloader.launch.LiteLoaderTweaker'
            @($resolved.libraries).Count | Should -BeGreaterThan 0
            foreach ($library in $resolved.libraries) {
                ([uri]$library.url).Scheme | Should -BeExactly 'https'
                ([uri]$library.url).Host | Should -BeExactly 'libraries.minecraft.net'
                $library.bytes | Should -BeGreaterThan 0
                $library.sha256 | Should -Match '^[a-f0-9]{64}$'
            }
        }
        @($catalog.targets).Count | Should -Be 6
    }

    It 'binds each resolved loader version to the separately verified artifact pin' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $resolved = Get-MmtlLiteLoaderRuntimeDependencies -TargetId 'LiteLoader@1.7.10' -Universe $script:universe -Catalog $catalog -LoaderArtifactCatalog $script:loaderPins
        $resolved.loaderVersion | Should -BeExactly '1.7.10_04'
        $resolved.loaderArtifactSha256 | Should -BeExactly 'a30e91e7abfcf482fd740893a207e2e00eb6a24d3909bfa2939a13b3c1703b7b'
        @($resolved.libraries | ForEach-Object name) | Should -Contain 'net.minecraft:launchwrapper:1.11'
        @($resolved.libraries | ForEach-Object name) | Should -Contain 'org.ow2.asm:asm-all:5.0.3'
        @($resolved.libraries | ForEach-Object name) | Should -Contain 'com.google.guava:guava:16.0'
        $guava=$resolved.libraries|Where-Object name -CEQ 'com.google.guava:guava:16.0'
        $guava.dependencySourceSha256 | Should -BeExactly '4bd57f6775688e83f41cb66d670a735eff365954517deb9c837e8bfc58a899ec'
    }

    It 'rejects targets without a verified exact loader artifact and dependency entries' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        { Get-MmtlLiteLoaderRuntimeDependencies -TargetId 'LiteLoader@1.10.2' -Universe $script:universe -Catalog $catalog -LoaderArtifactCatalog $script:loaderPins } | Should -Throw '*LITELOADER_RUNTIME_TARGET_UNSUPPORTED*'
    }

    It 'rejects untrusted or altered library pins' {
        $catalog = Get-Content -LiteralPath $script:catalogPath -Raw | ConvertFrom-Json
        $catalog.libraries[0].url = 'http://libraries.minecraft.net/untrusted.jar'
        { Get-MmtlLiteLoaderRuntimeDependencies -TargetId 'LiteLoader@1.5.2' -Universe $script:universe -Catalog $catalog -LoaderArtifactCatalog $script:loaderPins } | Should -Throw '*LITELOADER_RUNTIME_CATALOG_SCHEMA_INVALID*'
    }

    It 'rejects an altered upstream dependency documentation snapshot' {
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw|ConvertFrom-Json
        ($catalog.libraries|Where-Object name -CEQ 'com.google.guava:guava:16.0').dependencySourceSha256='0'*64
        { Get-MmtlLiteLoaderRuntimeDependencies -TargetId 'LiteLoader@1.7.10' -Universe $script:universe -Catalog $catalog -LoaderArtifactCatalog $script:loaderPins } | Should -Throw '*LITELOADER_RUNTIME_CATALOG_SCHEMA_INVALID*'
    }

    It 'stages the pinned loader and dependencies only inside the Session and reuses verified files' {
        $loaderBytes=[Text.Encoding]::UTF8.GetBytes('verified-loader-fixture')
        $libraryBytes=[Text.Encoding]::UTF8.GetBytes('verified-library-fixture')
        $launchPlan=[pscustomobject]@{
            targetId='LiteLoader@1.7.10';minecraftId='1.7.10';loaderVersion='1.7.10_04'
            loaderArtifactUrl='https://dl.liteloader.com/versions/liteloader-fixture.jar';loaderArtifactBytes=$loaderBytes.Length
            loaderArtifactSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($loaderBytes)).ToLowerInvariant()
            loaderArtifactOfficialMd5=[Convert]::ToHexString([Security.Cryptography.MD5]::HashData($loaderBytes)).ToLowerInvariant()
            libraries=@([pscustomobject]@{name='net.minecraft:launchwrapper:1.11';url='https://libraries.minecraft.net/net/minecraft/launchwrapper/1.11/launchwrapper-1.11.jar';bytes=$libraryBytes.Length;sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($libraryBytes)).ToLowerInvariant();sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($libraryBytes)).ToLowerInvariant();hashEvidence='HTTPS_DOWNLOAD_OBSERVATION'})
        }
        $download={param($Uri,$DestinationPath) $bytes=if($Uri -like '*liteloader-fixture.jar'){$loaderBytes}else{$libraryBytes};[IO.File]::WriteAllBytes($DestinationPath,$bytes)}.GetNewClosure()
        $session=Join-Path $TestDrive 'liteloader-session'

        $first=Save-MmtlLiteLoaderRuntimeArtifacts -SessionPath $session -LoaderLaunchPlan $launchPlan -Download $download
        $second=Save-MmtlLiteLoaderRuntimeArtifacts -SessionPath $session -LoaderLaunchPlan $launchPlan -Download {throw 'verified cache should be reused'}

        @($first).Count | Should -Be 2
        @($second).Count | Should -Be 2
        foreach($file in @($first)){Test-Path -LiteralPath $file.path -PathType Leaf|Should -BeTrue;([IO.Path]::GetFullPath($file.path).StartsWith([IO.Path]::GetFullPath($session)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))|Should -BeTrue}
    }

    It 'stages and verifies the pinned Mojang client JAR inside the Session' {
        $bytes=[Text.Encoding]::UTF8.GetBytes('pinned-client-fixture')
        $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($bytes)).ToLowerInvariant()
        $plan=[pscustomobject]@{minecraftId='1.7.10';clientArtifact=[pscustomobject]@{url="https://launcher.mojang.com/v1/objects/$sha1/client.jar";sha1=$sha1;bytes=$bytes.Length}}
        $download={param($Uri,$DestinationPath)[IO.File]::WriteAllBytes($DestinationPath,$bytes)}.GetNewClosure()
        $session=Join-Path $TestDrive 'pinned-client-session'
        New-Item -ItemType Directory -Path $session -Force | Out-Null

        $staged=Save-MmtlLiteLoaderClientArtifact -SessionPath $session -LoaderLaunchPlan $plan -Download $download
        $reused=Save-MmtlLiteLoaderClientArtifact -SessionPath $session -LoaderLaunchPlan $plan -Download {throw 'verified client should be reused'}

        $staged.path | Should -BeExactly (Join-Path $session 'gradle-loader/minecraft-artifacts/client-1.7.10.jar')
        $staged.sha1 | Should -BeExactly $sha1
        $reused.cached | Should -BeTrue
    }

    It 'rejects a client artifact hash mismatch without publishing a partial Session JAR' {
        $bytes=[Text.Encoding]::UTF8.GetBytes('wrong-client-data')
        $expected=[Text.Encoding]::UTF8.GetBytes('pinned-client-fixture')
        $sha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($expected)).ToLowerInvariant()
        $plan=[pscustomobject]@{minecraftId='1.7.10';clientArtifact=[pscustomobject]@{url="https://launcher.mojang.com/v1/objects/$sha1/client.jar";sha1=$sha1;bytes=$expected.Length}}
        $session=Join-Path $TestDrive 'bad-pinned-client-session'
        New-Item -ItemType Directory -Path $session -Force | Out-Null

        $download={param($Uri,$DestinationPath)[IO.File]::WriteAllBytes($DestinationPath,$bytes)}.GetNewClosure()
        { Save-MmtlLiteLoaderClientArtifact -SessionPath $session -LoaderLaunchPlan $plan -Download $download } | Should -Throw '*LITELOADER_CLIENT_ARTIFACT_SIZE_MISMATCH*'
        @(Get-ChildItem -LiteralPath $session -Recurse -File -ErrorAction SilentlyContinue | Where-Object Extension -CEQ '.jar').Count | Should -Be 0
    }

    It 'removes an unverified temporary file and rejects an artifact hash mismatch' {
        $good=[Text.Encoding]::UTF8.GetBytes('expected-bytes')
        $launchPlan=[pscustomobject]@{targetId='LiteLoader@1.7.10';loaderVersion='1.7.10_04';loaderArtifactUrl='https://dl.liteloader.com/versions/liteloader-fixture.jar';loaderArtifactBytes=$good.Length;loaderArtifactSha256=('a'*64);loaderArtifactOfficialMd5=('b'*32);libraries=@()}
        $session=Join-Path $TestDrive 'liteloader-bad-session'
        { Save-MmtlLiteLoaderRuntimeArtifacts -SessionPath $session -LoaderLaunchPlan $launchPlan -Download {param($Uri,$DestinationPath)[IO.File]::WriteAllBytes($DestinationPath,[byte[]]::new($good.Length))} } | Should -Throw '*LITELOADER_RUNTIME_ARTIFACT_SHA256_MISMATCH*'
        @(Get-ChildItem -LiteralPath $session -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'rejects HTTPS artifact URLs that use a nonstandard port' {
        $launchPlan=[pscustomobject]@{targetId='LiteLoader@1.7.10';loaderVersion='1.7.10_04';loaderArtifactUrl='https://dl.liteloader.com:444/versions/liteloader.jar';loaderArtifactBytes=1;loaderArtifactSha256=('a'*64);loaderArtifactOfficialMd5=('b'*32);libraries=@()}
        { Save-MmtlLiteLoaderRuntimeArtifacts -SessionPath (Join-Path $TestDrive 'liteloader-port-session') -LoaderLaunchPlan $launchPlan -Download {throw 'must not download'} } | Should -Throw '*LITELOADER_RUNTIME_URL_UNTRUSTED*'
    }

    It 'downloads and verifies the pinned Mojang asset index and content-addressed assets into Gradle User Home' {
        $assetBytes=[Text.Encoding]::UTF8.GetBytes('official-asset-fixture')
        $assetSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($assetBytes)).ToLowerInvariant()
        $indexJson=@{objects=@{'fixtures/asset.bin'=@{hash=$assetSha1;size=$assetBytes.Length}}}|ConvertTo-Json -Depth 5 -Compress
        $indexBytes=[Text.Encoding]::UTF8.GetBytes($indexJson)
        $indexSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($indexBytes)).ToLowerInvariant()
        $plan=[pscustomobject]@{minecraftId='1.7.10';assetIndex=[pscustomobject]@{url="https://launchermeta.mojang.com/v1/packages/$indexSha1/1.7.10.json";sha1=$indexSha1;bytes=$indexBytes.Length}}
        $download={param($Uri,$DestinationPath) if($Uri.Host -eq 'launchermeta.mojang.com'){[IO.File]::WriteAllBytes($DestinationPath,$indexBytes)}else{[IO.File]::WriteAllBytes($DestinationPath,$assetBytes)}}.GetNewClosure()
        $gradleHome=Join-Path $TestDrive 'mojang-assets-gradle-home'

        $first=Save-MmtlMojangAssets -GradleUserHome $gradleHome -LoaderLaunchPlan $plan -Download $download
        $second=Save-MmtlMojangAssets -GradleUserHome $gradleHome -LoaderLaunchPlan $plan -Download {throw 'verified asset cache should be reused'}

        $first.assetCount | Should -Be 1
        $second.cachedAssetCount | Should -Be 1
        $assetPath=Join-Path $gradleHome "caches/minecraft/assets/objects/$($assetSha1.Substring(0,2))/$assetSha1"
        (Get-FileHash -LiteralPath $assetPath -Algorithm SHA1).Hash.ToLowerInvariant() | Should -BeExactly $assetSha1
    }

    It 'rejects invalid Mojang asset hashes and does not leave a partial cache object' {
        $actual=[Text.Encoding]::UTF8.GetBytes('bad-data')
        $expected=[Text.Encoding]::UTF8.GetBytes('expected')
        $assetSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($expected)).ToLowerInvariant()
        $indexJson=@{objects=@{'fixtures/asset.bin'=@{hash=$assetSha1;size=$expected.Length}}}|ConvertTo-Json -Depth 5 -Compress
        $indexBytes=[Text.Encoding]::UTF8.GetBytes($indexJson)
        $indexSha1=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData($indexBytes)).ToLowerInvariant()
        $plan=[pscustomobject]@{minecraftId='1.7.10';assetIndex=[pscustomobject]@{url="https://launchermeta.mojang.com/v1/packages/$indexSha1/1.7.10.json";sha1=$indexSha1;bytes=$indexBytes.Length}}
        $download={param($Uri,$DestinationPath) $bytes=if($Uri.Host -eq 'launchermeta.mojang.com'){$indexBytes}else{$actual};[IO.File]::WriteAllBytes($DestinationPath,$bytes)}.GetNewClosure()
        $gradleHome=Join-Path $TestDrive 'mojang-assets-bad-gradle-home'

        { Save-MmtlMojangAssets -GradleUserHome $gradleHome -LoaderLaunchPlan $plan -Download $download } | Should -Throw '*LITELOADER_ASSET_OBJECT_SHA1_MISMATCH*'
        (Test-Path -LiteralPath (Join-Path $gradleHome "caches/minecraft/assets/objects/$($assetSha1.Substring(0,2))/$assetSha1")) | Should -BeFalse
        @(Get-ChildItem -LiteralPath $gradleHome -Recurse -Filter '.mmtl-*.tmp' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}
