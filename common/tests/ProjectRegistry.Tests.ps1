BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'src/ProjectImport.psm1') -Force
}

Describe '通用 Mod 项目导入与本地注册表' {
    BeforeEach {
        $script:workspace = Join-Path $TestDrive 'generic-workspace'
        $script:runtime = Join-Path $TestDrive 'runtime'
        $script:target = Join-Path $script:workspace 'module-a'
        New-Item -ItemType Directory -Path (Join-Path $script:target 'src/main/resources') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:workspace '.git') -Value 'fixture'
        Set-Content -LiteralPath (Join-Path $script:target 'settings.gradle') -Value "rootProject.name = 'unrelated-project'"
        Set-Content -LiteralPath (Join-Path $script:target 'build.gradle') -Value "plugins { id 'fabric-loom' version '1.7.4' }"
        Set-Content -LiteralPath (Join-Path $script:target 'gradle.properties') -Value "minecraft_version=1.21.6`nloader_version=0.16.14"
        Set-Content -LiteralPath (Join-Path $script:target 'src/main/resources/fabric.mod.json') -Value '{"schemaVersion":1,"id":"arbitrary_mod","version":"1.0.0","name":"Arbitrary Mod"}'
        $script:sourceHash = (Get-FileHash -LiteralPath (Join-Path $script:target 'build.gradle') -Algorithm SHA256).Hash
    }

    It '导入陌生 Fabric 项目并生成不含本机路径语义的注册 ID' {
        $result = Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime

        $result.status | Should -BeExactly 'Imported'
        $result.targets.Count | Should -Be 1
        $result.targets[0].loaderId | Should -BeExactly 'Fabric'
        $result.targets[0].modIds | Should -Contain 'arbitrary_mod'
        $result.projectId | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        $result.projectId | Should -Not -Be ([IO.Path]::GetFullPath($workspace))
        (Test-Path -LiteralPath (Join-Path $runtime 'project-registry.json')) | Should -BeTrue
    }

    It '重复导入相同路径时保留稳定 project ID' {
        $first = Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime
        $second = Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime

        $second.projectId | Should -BeExactly $first.projectId
        (Get-MmtlProjectRegistry -RuntimeRoot $script:runtime).projects.Count | Should -Be 1
    }

    It '读取尚不存在的 Registry 返回空列表且不创建 Runtime Root' {
        $emptyRuntime = Join-Path $TestDrive ('missing-runtime-' + [guid]::NewGuid().ToString('N'))
        $registryRead = Get-MmtlProjectRegistry -RuntimeRoot $emptyRuntime

        $registryRead.projects | Should -BeNullOrEmpty
        Test-Path -LiteralPath $emptyRuntime | Should -BeFalse
    }

    It '匿名 Fabric 元数据发现多个 Mod、入口点、Mixin 和 package 来源并标记歧义' {
        $resources = Join-Path $script:target 'src/main/resources'
        Set-Content -LiteralPath (Join-Path $resources 'fabric.mod.json') -Value (@{
            schemaVersion = 1; id = 'sample_alpha'; name = 'Alpha';
            entrypoints = @{ main = @('org.example.alpha.Main'); client = @('org.example.client.ClientEntrypoint') };
            mixins = @('sample.mixins.json')
        } | ConvertTo-Json -Depth 10)
        Set-Content -LiteralPath (Join-Path $resources 'quilt.mod.json') -Value '{"quilt_loader":{"id":"sample_beta","metadata":{"name":"Beta"}}}'
        $source = Join-Path $script:target 'src/main/java/org/example/alpha'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'Main.java') -Value 'package org.example.alpha; public class Main {}'
        Set-Content -LiteralPath (Join-Path $resources 'sample.mixins.json') -Value '{"package":"org.example.mixin","mixins":["FeatureMixin"]}'

        $result = Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime -PrimaryModId 'sample_beta'
        $target = $result.targets[0]

        $target.modIds | Should -Contain 'sample_alpha'
        $target.modIds | Should -Contain 'sample_beta'
        $target.primaryModId | Should -BeExactly 'sample_beta'
        $target.primaryModStatus | Should -BeExactly 'ResolvedByProfile'
        @($target.packageCandidates | ForEach-Object packageName) | Should -Contain 'org.example.alpha'
        @($target.packageCandidates | ForEach-Object packageName) | Should -Contain 'org.example.mixin'
        @($target.packageCandidates | ForEach-Object source | Select-Object -Unique) | Should -Contain 'Entrypoint'
        @($target.packageCandidates | ForEach-Object source | Select-Object -Unique) | Should -Contain 'SourceScan'
        @($target.packageCandidates | ForEach-Object source | Select-Object -Unique) | Should -Contain 'Mixin'
    }

    It '识别 NeoForge metadata 中的多个 mods 条目' {
        Remove-Item -LiteralPath (Join-Path $script:target 'src/main/resources/fabric.mod.json') -Force
        Set-Content -LiteralPath (Join-Path $script:target 'build.gradle') -Value "plugins { id 'net.neoforged.moddev' version '2.0.80' }"
        $meta = Join-Path $script:target 'src/main/resources/META-INF'
        New-Item -ItemType Directory -Path $meta -Force | Out-Null
        @'
modLoader="javafml"
[[mods]]
modId="neo_primary"
displayName="Neo Primary"
[[mods]]
modId="neo_addon"
displayName="Neo Addon"
'@ | Set-Content -LiteralPath (Join-Path $meta 'neoforge.mods.toml')

        $target = (Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime).targets[0]

        $target.loaderId | Should -BeExactly 'NeoForge'
        $target.modIds | Should -Contain 'neo_primary'
        $target.modIds | Should -Contain 'neo_addon'
        $target.primaryModStatus | Should -BeExactly 'AMBIGUOUS_PRIMARY_MOD'
    }

    It '保留 malformed metadata 诊断并拒绝无效的显式 primaryModId' {
        Set-Content -LiteralPath (Join-Path $script:target 'src/main/resources/fabric.mod.json') -Value '{not-json'
        $result = Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime

        $result.targets[0].metadataErrors | Should -Contain 'fabric.mod.json:INVALID_JSON'
        { Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime -PrimaryModId 'not_present' } | Should -Throw 'PRIMARY_MOD_ID_NOT_FOUND'
    }

    It '扫描 repository 内的 nested Gradle targets' {
        $nested = Join-Path $script:workspace 'modules/nested'
        New-Item -ItemType Directory -Path (Join-Path $nested 'src/main/resources/META-INF') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:workspace 'settings.gradle') -Value "rootProject.name = 'parent'`ninclude ':modules:nested'"
        Set-Content -LiteralPath (Join-Path $script:workspace 'build.gradle') -Value "plugins { id 'base' }"
        Set-Content -LiteralPath (Join-Path $nested 'build.gradle') -Value "plugins { id 'net.minecraftforge.gradle' version '6.0.54' }"
        Set-Content -LiteralPath (Join-Path $nested 'gradle.properties') -Value "minecraft_version=1.20.1`nmod_id=nested_mod"
        @'
modLoader="javafml"
[[mods]]
modId="nested_mod"
displayName="Nested Mod"
'@ | Set-Content -LiteralPath (Join-Path $nested 'src/main/resources/META-INF/mods.toml')

        $result = Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime

        $result.targets.Count | Should -Be 3
        @($result.targets | ForEach-Object loaderId) | Should -Contain 'Forge'
        @($result.targets | ForEach-Object modIds) | Should -Contain 'nested_mod'
    }

    It '移除注册项不会删除或修改用户项目' {
        $result = Import-MmtlProject -Path $script:workspace -RuntimeRoot $script:runtime
        $removed = Remove-MmtlProjectRegistryEntry -RuntimeRoot $script:runtime -ProjectId $result.projectId

        $removed | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:workspace 'module-a/build.gradle')) | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $script:workspace 'module-a/build.gradle') -Algorithm SHA256).Hash | Should -BeExactly $script:sourceHash
        (Get-MmtlProjectRegistry -RuntimeRoot $script:runtime).projects.Count | Should -Be 0
    }

    It '拒绝无 Gradle 项目的导入' {
        $invalid = Join-Path $TestDrive 'not-a-project'
        New-Item -ItemType Directory -Path $invalid -Force | Out-Null

        { Import-MmtlProject -Path $invalid -RuntimeRoot $script:runtime } | Should -Throw '*Gradle*'
    }
}
