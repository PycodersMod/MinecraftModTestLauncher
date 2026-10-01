BeforeAll { $root=Split-Path -Parent $PSScriptRoot;Import-Module (Join-Path $root 'src/ProjectDetector.psm1') -Force }
Describe 'Evidence based project detection' {
    It 'detects Quilt Loom over its compatible fabric.mod.json marker' {
        $project=Join-Path $TestDrive 'quilt';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources') -Force|Out-Null
        'plugins { alias libs.plugins.quilt.loom }'|Set-Content (Join-Path $project 'build.gradle');'{}'|Set-Content (Join-Path $project 'src/main/resources/fabric.mod.json');New-Item -ItemType Directory -Path (Join-Path $project 'gradle') -Force|Out-Null
        $toml=@'
[versions]
minecraft = "1.20.6"
quilt_loader = "0.26.3"
[plugins]
quilt_loom = { id = "org.quiltmc.loom", version = "1.7.4" }
'@
        $toml|Set-Content (Join-Path $project 'gradle/libs.versions.toml')
        $result=Get-MmtlProject -Path $project
        $result.Loader | Should -BeExactly 'Quilt';$result.Toolchain.id | Should -BeExactly 'QuiltLoom';$result.DetectionStatus | Should -BeExactly 'Resolved';$result.MinecraftVersion | Should -BeExactly '1.20.6';$result.LoaderVersion | Should -BeExactly '0.26.3'
    }
    It 'surfaces conflicting loader markers as ambiguous' {
        $project=Join-Path $TestDrive 'conflict';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources/META-INF') -Force|Out-Null
        'plugins { id ''fabric-loom'' version ''1.7.4'' }'|Set-Content (Join-Path $project 'build.gradle');'{}'|Set-Content (Join-Path $project 'src/main/resources/fabric.mod.json');'modLoader="javafml"'|Set-Content (Join-Path $project 'src/main/resources/META-INF/mods.toml')
        $result=Get-MmtlProject -Path $project
        $result.DetectionStatus | Should -BeExactly 'Ambiguous';$result.DetectionConflicts.Count | Should -Be 1
    }
}
