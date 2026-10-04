BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:repositoryRoot = Split-Path -Parent $script:repoRoot
    if(-not $global:MmtlPlatformProvider){
        if([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)){$providerDir='windows';$providerModule='WindowsPlatformProvider.psm1';$register='Register-MmtlWindowsPlatform'}
        elseif([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)){$providerDir='macos';$providerModule='MacOSPlatformProvider.psm1';$register='Register-MmtlMacOSPlatform'}
        else{$providerDir='linux';$providerModule='LinuxPlatformProvider.psm1';$register='Register-MmtlLinuxPlatform'}
        Import-Module (Join-Path $script:repositoryRoot "$providerDir/src/$providerModule") -Force
        & $register -RepositoryRoot $script:repositoryRoot
    }
    if(-not(Get-Command Get-MmtlProject -ErrorAction SilentlyContinue)){Import-Module (Join-Path $script:repoRoot 'src/ProjectDetector.psm1')}
}

Describe 'Repository and nested Gradle project discovery' {
    It 'discovers nested projects and reports repository roots separately' {
        $workspace = Join-Path $TestDrive 'workspace'
        $repository = Join-Path $workspace 'mod-repository'
        $forgeProject = Join-Path $repository 'forge/1.20.1'
        $fabricProject = Join-Path $repository 'fabric/1.21.6'
        New-Item -ItemType Directory -Path (Join-Path $repository '.git'), (Join-Path $forgeProject 'src/main/resources/META-INF'), (Join-Path $fabricProject 'src/main/resources') -Force | Out-Null
        'plugins { id ''net.minecraftforge.gradle'' }' | Set-Content (Join-Path $forgeProject 'build.gradle')
        'minecraft_version=1.20.1' | Set-Content (Join-Path $forgeProject 'gradle.properties')
        'modLoader="javafml"' | Set-Content (Join-Path $forgeProject 'src/main/resources/META-INF/mods.toml')
        'plugins { id ''fabric-loom'' version ''1.7.4'' }' | Set-Content (Join-Path $fabricProject 'build.gradle.kts')
        'minecraft_version=1.21.6' | Set-Content (Join-Path $fabricProject 'gradle.properties')
        '{"schemaVersion":1,"id":"testmod","depends":{"minecraft":"1.21.6","fabricloader":">=0.16.0"}}' | Set-Content (Join-Path $fabricProject 'src/main/resources/fabric.mod.json')

        $projects = @(Find-MmtlGradleProjects -Path $workspace)

        $projects.Count | Should -Be 2
        ($projects | Where-Object ProjectRoot -CEQ $forgeProject).RepositoryRoot | Should -BeExactly $repository
        ($projects | Where-Object ProjectRoot -CEQ $fabricProject).RepositoryRoot | Should -BeExactly $repository
        ($projects | Where-Object ProjectRoot -CEQ $forgeProject).Loader | Should -BeExactly 'Forge'
        ($projects | Where-Object ProjectRoot -CEQ $forgeProject).MinecraftVersion | Should -BeExactly '1.20.1'
        ($projects | Where-Object ProjectRoot -CEQ $fabricProject).Loader | Should -BeExactly 'Fabric'
        ($projects | Where-Object ProjectRoot -CEQ $fabricProject).MinecraftVersion | Should -BeExactly '1.21.6'
    }

    It 'ignores generated and temporary Gradle descriptors' {
        $workspace = Join-Path $TestDrive 'excluded-workspace'
        $repository = Join-Path $workspace 'mod-repository'
        New-Item -ItemType Directory -Path (Join-Path $repository '.git') -Force | Out-Null
        foreach ($folder in @('.gradle', 'build', 'run', 'out', 'runtime', 'node_modules', 'cache', 'tmp', 'fixtures')) {
            $path = Join-Path $repository $folder
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            'plugins {}' | Set-Content (Join-Path $path 'build.gradle')
        }

        @(Find-MmtlGradleProjects -Path $workspace).Count | Should -Be 0
    }

    It '从 Kotlin DSL 的 Forge Maven 坐标解析 Loader 版本' {
        $projectRoot=Join-Path $TestDrive 'kotlin-forge/forge/1.20.1'
        New-Item -ItemType Directory -Path (Join-Path $projectRoot 'src/main/resources/META-INF') -Force|Out-Null
        'plugins { id("net.minecraftforge.gradle") version "6.0.24" }'|Set-Content (Join-Path $projectRoot 'build.gradle.kts')
        'org.gradle.jvmargs=-Xmx2G'|Set-Content (Join-Path $projectRoot 'gradle.properties')
        'dependencies { minecraft("net.minecraftforge:forge:1.20.1-47.2.0") }'|Add-Content (Join-Path $projectRoot 'build.gradle.kts')
        'modLoader="javafml"'|Set-Content (Join-Path $projectRoot 'src/main/resources/META-INF/mods.toml')
        $project=Get-MmtlProject -Path $projectRoot
        $project.Loader | Should -BeExactly 'Forge'
        $project.MinecraftVersion | Should -BeExactly '1.20.1'
        $project.LoaderVersion | Should -BeExactly '47.2.0'
    }

    It 'does not tie imported runtime directories to a fixed project depth' {
        $workspaceRoot = Split-Path -Parent $script:repoRoot
        $projects = @(Find-MmtlGradleProjects -Path $workspaceRoot)
        if ($projects.Count -ne 10) { return }

        $fixedDepthRuntimePaths = @()
        foreach ($project in $projects) {
            $buildPath = Join-Path $project.ProjectRoot $project.BuildFile
            $buildText = Get-Content -LiteralPath $buildPath -Raw
            if ($buildText -match '(?i)\.\./\.\./runtime/legacy-import/') {
                $fixedDepthRuntimePaths += $project.ProjectRoot
            }
        }

        $fixedDepthRuntimePaths.Count | Should -Be 0
    }
}
