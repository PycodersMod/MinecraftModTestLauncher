BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/MinecraftVersionCatalog.psm1') -Force
    $script:runtime=Join-Path $TestDrive 'runtime'
    $script:configPath=Join-Path $TestDrive 'launcher.config.json'
    $script:launcher=Join-Path $script:repoRoot 'launcher.ps1'
    $script:pwsh=(Get-Command pwsh -ErrorAction Stop).Source
    $metadataJson='{"id":"1.20.5","javaVersion":{"component":"java-runtime-delta","majorVersion":21}}'
    $metadataBytes=[Text.Encoding]::UTF8.GetBytes($metadataJson)
    $metadataHash=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]$metadataBytes)).ToLowerInvariant()
    $manifest=[pscustomobject]@{
        latest=[pscustomobject]@{release='1.20.5';snapshot='24w14a'}
        versions=@(
            [pscustomobject]@{id='1.20.5';type='release';url='https://piston-meta.mojang.com/v1/1.20.5.json';time='2024-04-23T19:54:12Z';releaseTime='2024-04-23T19:54:12Z';sha1=$metadataHash},
            [pscustomobject]@{id='24w14a';type='snapshot';url='https://piston-meta.mojang.com/v1/snapshot.json';time='2024-04-03T00:00:00Z';releaseTime='2024-04-03T00:00:00Z';sha1=('b'*40)},
            [pscustomobject]@{id='1.0';type='release';url='https://piston-meta.mojang.com/v1/1.0.json';time='2011-11-18T06:00:00Z';releaseTime='2011-11-18T06:00:00Z';sha1=('c'*40)}
        )
    }
    $manifestJson=$manifest|ConvertTo-Json -Depth 20 -Compress
    $script:manifestJson=$manifestJson
    Get-MmtlMinecraftVersionCatalog -RuntimeRoot $script:runtime -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($manifestJson)}}.GetNewClosure() | Out-Null
    $entry=[pscustomobject]@{id='1.20.5';metadataUrl='https://piston-meta.mojang.com/v1/1.20.5.json';metadataSha1=$metadataHash}
    Get-MmtlMinecraftVersionMetadata -CatalogEntry $entry -RuntimeRoot $script:runtime -HttpGet {param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=$metadataBytes;ResponseUri=$Uri}}.GetNewClosure() | Out-Null
    $script:config=@{configVersion=2;defaultProfile='fixture';runtimeRoot=$script:runtime;javaHomes=@{};profiles=@{fixture=@{project='';mode='Single';players=1}}}
    $script:config|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $script:configPath -Encoding utf8
}

Describe 'Minecraft Catalog CLI' {
    It 'lists cached release entries offline, marks CurrentStable and excludes snapshots' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --catalog-offline --list-minecraft-versions 2>&1|Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match '1.20.5'
        $output | Should -Match 'CurrentStable'
        $output | Should -Not -Match '24w14a'
    }

    It 'prints integrity and authoritative runtime Java for CurrentStable' {
        $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --catalog-offline --minecraft-info CurrentStable 2>&1|Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'ID'
        $output | Should -Match '1\.20\.5'
        $output | Should -Match 'ActualSHA1'
        $output | Should -Match 'RuntimeJavaMajor'
        $output | Should -Match '21'
        $output | Should -Match 'AuthoritativeMetadata'
    }

    It 'does not allow offline mode with forced refresh and reports an absent cache' {
        $conflict=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --catalog-offline --refresh-catalog 2>&1|Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $conflict | Should -Match 'CATALOG_OPTION_CONFLICT'
        $empty=$configPath.Replace('launcher.config.json','empty-config.json')
        $script:config.runtimeRoot=Join-Path $TestDrive 'empty-runtime'
        $script:config|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $empty -Encoding utf8
        $missing=& $script:pwsh -NoProfile -File $script:launcher --config-file $empty --catalog-offline --list-minecraft-versions 2>&1|Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $missing | Should -Match 'CACHE_UNAVAILABLE'
    }

    It 'uses the native catalog cache on Unix when shared config contains Windows LOCALAPPDATA' {
        Import-Module (Join-Path $script:repoRoot 'src/Platform/Platform.psm1') -Force
        $platform=Get-MmtlPlatformProvider
        if($platform.OS -ne 'Linux'){return}
        $previousXdg=$env:XDG_DATA_HOME
        try{
            $env:XDG_DATA_HOME=Join-Path $TestDrive 'isolated-xdg'
            $nativeRuntime=(Get-MmtlPlatformProvider).DefaultRuntimeRoot
            $json=$script:manifestJson
            $http={param($Uri,$Headers,$TimeoutSeconds)[pscustomobject]@{StatusCode=200;Headers=@{};Bytes=[Text.Encoding]::UTF8.GetBytes($json)}}.GetNewClosure()
            Get-MmtlMinecraftVersionCatalog -RuntimeRoot $nativeRuntime -HttpGet $http | Out-Null
            $script:config.runtimeRoot='%LOCALAPPDATA%/MinecraftModTestLauncher'
            $script:config|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $script:configPath -Encoding utf8
            $output=& $script:pwsh -NoProfile -File $script:launcher --config-file $script:configPath --catalog-offline --list-minecraft-versions 2>&1|Out-String
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'Windows-only %LOCALAPPDATA%'
            $output | Should -Match '1.20.5'
        }finally{$env:XDG_DATA_HOME=$previousXdg}
    }
}
