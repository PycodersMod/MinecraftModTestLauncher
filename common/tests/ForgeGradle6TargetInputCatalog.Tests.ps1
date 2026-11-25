BeforeAll {
    $script:repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:catalogPath=Join-Path $script:repoRoot 'compatibility/forge-gradle6-target-inputs/Forge-1.16.5.json'
    $script:schemaPath=Join-Path $script:repoRoot 'common/schemas/forge-gradle6-target-inputs.schema.json'
    Import-Module (Join-Path $script:repoRoot 'common/src/Adapters/ForgeSecureBuild.psm1') -Force
}

Describe 'ForgeGradle 6 target input catalog' {
    It 'loads exact schema v2 catalogs for all staged modern FG6 family targets' {
        foreach($minecraftId in @('1.18.2','1.19.2','1.19.4','1.20','1.20.1')){
            $path=Join-Path $script:repoRoot ('compatibility/forge-gradle6-target-inputs/Forge-'+$minecraftId+'.json')
            $resolved=Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $path

            $resolved.catalog.schemaVersion | Should -Be 2
            $resolved.catalog.targetId | Should -BeExactly ('Forge@'+$minecraftId)
            $resolved.mcpTools | Should -HaveCount 5
            $resolved.artifacts | Should -HaveCount 11
            (Test-Json -LiteralPath $path -SchemaFile $script:schemaPath) | Should -BeTrue
        }
    }

    It 'preserves duplicate userdev library declarations for hash-pinned schema v2 catalogs' {
        $path=Join-Path $script:repoRoot 'compatibility/forge-gradle6-target-inputs/Forge-1.18.2.json'
        $catalog=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        (@($catalog.userdev.libraries|Group-Object|Where-Object Count -gt 1)).Count | Should -BeGreaterThan 0
        (Test-Json -LiteralPath $path -SchemaFile $script:schemaPath) | Should -BeTrue
    }

    It 'compares modern userdev library declarations with duplicate multiplicity intact' {
        InModuleScope ForgeSecureBuild {
            $actual=@('cpw.mods:securejarhandler:1.0.8','org.ow2.asm:asm:9.7.1','cpw.mods:securejarhandler:1.0.8')
            (Test-MmtlForgeGradle6UserdevLibraries -Actual $actual -Expected $actual) | Should -BeTrue
            { Test-MmtlForgeGradle6UserdevLibraries -Actual $actual -Expected @('cpw.mods:securejarhandler:1.0.8','org.ow2.asm:asm:9.7.1') } | Should -Throw '*FORGE_GRADLE6_USERDEV_CONFIG_MISMATCH*'
        }
    }

    It 'validates the exact official MDK, userdev, MCP mappings and Mojang metadata closure' {
        $resolved=Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $script:catalogPath
        $resolved.catalogHash | Should -BeExactly 'a32ecc9b98e434ee0ea5eda4d641e4a15dfd5fe9a544651dbe12c4f67a820b3e'
        $resolved.artifacts | Should -HaveCount 13
        $resolved.catalog.userdev.libraries | Should -HaveCount 26
        (Test-Json -LiteralPath $script:catalogPath -SchemaFile $script:schemaPath) | Should -BeTrue
    }

    It 'validates a target-specific FG6 input catalog with exact target-bound artifact and Mojang identities' {
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw|ConvertFrom-Json
        $catalog.targetId='Forge@1.18.2'
        $catalog.forgeVersion='1.18.2-40.3.11'
        $catalog.resolver='ForgeGradle 6.0.54 official MDK Gradle 8.8 cache capture'
        $mcpVersion='1.18.2-test-mcp'
        foreach($artifact in $catalog.artifacts){
            if([string]$artifact.group -ceq 'net.minecraftforge' -and [string]$artifact.artifact -ceq 'forge'){
                $oldVersion=[string]$artifact.version
                $artifact.version=$catalog.forgeVersion
                $artifact.file=([string]$artifact.file).Replace($oldVersion,[string]$catalog.forgeVersion)
                $artifact.url=([string]$artifact.url).Replace($oldVersion,[string]$catalog.forgeVersion)
            }elseif([string]$artifact.kind -ceq 'mcpConfig'){
                $oldVersion=[string]$artifact.version
                $artifact.version=$mcpVersion
                $artifact.file=([string]$artifact.file).Replace($oldVersion,$mcpVersion)
                $artifact.url=([string]$artifact.url).Replace($oldVersion,$mcpVersion)
            }
        }
        $catalog.mcpConfig.coordinate='de.oceanlabs.mcp:mcp_config:'+ $mcpVersion +'@zip'
        $catalog.userdev.mcpCoordinate=$catalog.mcpConfig.coordinate
        $catalog.mojangVersion.url='https://piston-meta.mojang.com/v1/packages/'+('a'*40)+'/1.18.2.json'
        $catalog.mojangVersion.sha1='a'*40
        $catalog.mojangVersion.sha256='b'*64
        $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
        $path=Join-Path $TestDrive 'Forge-1.18.2-target-inputs.json'
        ConvertTo-Json -InputObject $catalog -Depth 30|Set-Content -LiteralPath $path -Encoding utf8

        $resolved=Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.18.2'
        $resolved.catalog.forgeVersion | Should -BeExactly '1.18.2-40.3.11'
        $resolved.catalog.mojangVersion.url | Should -Match '/1\.18\.2\.json$'
        $resolved.artifacts | Should -HaveCount 13
        (Test-Json -LiteralPath $path -SchemaFile $script:schemaPath) | Should -BeTrue
    }

    It 'accepts MCP-config-driven tool pins for a modern FG6 target without legacy-only artifacts' {
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw|ConvertFrom-Json
        $catalog.schemaVersion=2
        $catalog.targetId='Forge@1.18.2'
        $catalog.forgeVersion='1.18.2-40.3.11'
        $catalog.resolver='ForgeGradle 6.0.54 official MDK Gradle 8.8 cache capture'
        $catalog.artifacts=@($catalog.artifacts|Where-Object kind -in @('mdk','userdev','forgeSources','forgeUniversal','mcpConfig','accesstransformers','binarypatcher'))
        foreach($artifact in $catalog.artifacts){
            if([string]$artifact.group -ceq 'net.minecraftforge' -and [string]$artifact.artifact -ceq 'forge'){
                $oldVersion=[string]$artifact.version
                $artifact.version=$catalog.forgeVersion
                $artifact.file=([string]$artifact.file).Replace($oldVersion,[string]$catalog.forgeVersion)
                $artifact.url=([string]$artifact.url).Replace($oldVersion,[string]$catalog.forgeVersion)
            }
        }
        $mcpVersion='1.18.2-20220404.173914'
        $catalog.mcpConfig.coordinate='de.oceanlabs.mcp:mcp_config:'+ $mcpVersion +'@zip'
        $mcpArtifact=@($catalog.artifacts|Where-Object kind -CEQ 'mcpConfig')[0]
        $mcpArtifact.version=$mcpVersion
        $mcpArtifact.file='mcp_config-'+$mcpVersion+'.zip'
        $mcpArtifact.url='https://maven.minecraftforge.net/de/oceanlabs/mcp/mcp_config/'+$mcpVersion+'/'+$mcpArtifact.file
        $catalog.userdev.mcpCoordinate=$catalog.mcpConfig.coordinate
        $catalog.userdev.libraries=@('net.minecraftforge:accesstransformers:8.0.4','cpw.mods:modlauncher:9.1.3','cpw.mods:bootstraplauncher:1.0.0')
        $catalog.userdev.binarypatcher='net.minecraftforge:binarypatcher:1.0.12:fatjar'
        $catalog.mojangVersion.url='https://piston-meta.mojang.com/v1/packages/'+('a'*40)+'/1.18.2.json'
        $catalog.mojangVersion.sha1='a'*40
        $catalog.mojangVersion.sha256='b'*64

        $toolPins=@(
            @{functionName='decompile';coordinate='net.minecraftforge:forgeflower:1.5.498.29'},
            @{functionName='merge';coordinate='net.minecraftforge:mergetool:1.1.3:fatjar'},
            @{functionName='rename';coordinate='net.minecraftforge:ForgeAutoRenamingTool:0.1.17:all'},
            @{functionName='mergeMappings';coordinate='net.minecraftforge:installertools:1.2.0:fatjar'},
            @{functionName='bundleExtractJar';coordinate='net.minecraftforge:installertools:1.2.10:fatjar'}
        )
        $catalog|Add-Member -NotePropertyName mcpTools -NotePropertyValue @($toolPins)
        foreach($pin in $toolPins){
            $parts=[string]$pin.coordinate -split ':'
            $group=$parts[0];$artifactName=$parts[1];$version=$parts[2];$classifier=''
            if($parts.Count -gt 3){$classifier='-'+$parts[3]}
            $file=$artifactName+'-'+$version+$classifier+'.jar'
            $catalog.artifacts+=@([pscustomobject]@{kind='mcpTool';group=$group;artifact=$artifactName;version=$version;file=$file;bytes=1;sha256=('c'*64);url=('https://maven.minecraftforge.net/'+$group.Replace('.','/')+'/'+$artifactName+'/'+$version+'/'+$file)})
        }
        $core=[ordered]@{};foreach($property in $catalog.PSObject.Properties){if($property.Name -cne 'catalogHash'){$core[$property.Name]=$property.Value}}
        $catalog.catalogHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $core -Depth 30 -Compress)))).ToLowerInvariant()
        $path=Join-Path $TestDrive 'Forge-1.18.2-mcp-tools.json'
        ConvertTo-Json -InputObject $catalog -Depth 30|Set-Content -LiteralPath $path -Encoding utf8

        $resolved=Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $path

        $resolved.catalog.targetId | Should -BeExactly 'Forge@1.18.2'
        $resolved.artifacts | Should -HaveCount 12
        $resolved.mcpTools | Should -HaveCount 5
        (Test-Json -LiteralPath $path -SchemaFile $script:schemaPath) | Should -BeTrue
    }

    It 'requires MCP function versions to match the target catalog tool pins' {
        InModuleScope ForgeSecureBuild {
            $config=[pscustomobject]@{functions=[pscustomobject]@{
                decompile=[pscustomobject]@{version='net.minecraftforge:forgeflower:1.5.498.29'}
                merge=[pscustomobject]@{version='net.minecraftforge:mergetool:1.1.3:fatjar'}
            }}
            $pins=@(
                [pscustomobject]@{functionName='decompile';coordinate='net.minecraftforge:forgeflower:1.5.498.29'},
                [pscustomobject]@{functionName='merge';coordinate='net.minecraftforge:mergetool:1.1.3:fatjar'}
            )

            (Test-MmtlForgeGradle6McpToolPins -Config $config -ExpectedTools $pins) | Should -BeTrue
            $pins[0].coordinate='net.minecraftforge:forgeflower:9.9.9'
            { Test-MmtlForgeGradle6McpToolPins -Config $config -ExpectedTools $pins } | Should -Throw '*FORGE_GRADLE6_MCP_TOOLS_MISMATCH*'
        }
    }

    It 'rejects a catalog whose contents were modified without a matching trusted catalog hash' {
        $catalog=Get-Content -LiteralPath $script:catalogPath -Raw|ConvertFrom-Json
        $catalog.userdev.libraries[0]='attacker:replacement:1.0'
        $path=Join-Path $TestDrive 'tampered-forge-gradle6-target-inputs.json'
        ConvertTo-Json -InputObject $catalog -Depth 30|Set-Content -LiteralPath $path -Encoding utf8
        { Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $path } | Should -Throw '*FORGE_GRADLE6_TARGET_INPUT_CATALOG_HASH_MISMATCH*'
    }

    It 'rejects an untrusted cached artifact before adding it to the Maven mirror' {
        $catalog=Get-MmtlForgeGradle6TargetInputCatalog -CatalogPath $script:catalogPath
        $cacheRoot=Join-Path $TestDrive 'forge-gradle6-target-cache'
        $artifactCache=Join-Path $cacheRoot 'artifact-cache';$null=New-Item -ItemType Directory -Path $artifactCache -Force
        [IO.File]::WriteAllText((Join-Path $artifactCache ([string]$catalog.artifacts[0].sha256)),'corrupt')
        Mock Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild { throw 'unexpected download' }

        { Get-MmtlForgeGradle6TargetInputMirror -CatalogPath $script:catalogPath -CacheRoot $cacheRoot } | Should -Throw '*FORGE_GRADLE6_TARGET_INPUT_CACHE_INVALID*'
        Should -Invoke Invoke-MmtlForgeHttpsDownload -ModuleName ForgeSecureBuild -Times 0
        @(Get-ChildItem -LiteralPath (Join-Path $cacheRoot 'maven-mirror') -Recurse -File -ErrorAction SilentlyContinue) | Should -HaveCount 0
    }
}
