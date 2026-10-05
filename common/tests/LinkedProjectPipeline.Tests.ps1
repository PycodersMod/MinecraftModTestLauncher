BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/RunManager.psm1') -Force
}

Describe 'linkedProjects 构建与产物流水线' {
    It '按 Primary 与 linkedProjects 配置顺序构建，并核对后续注入 JAR 哈希' {
        $root=Join-Path $TestDrive 'ordered';$null=New-Item -ItemType Directory -Path $root -Force
        $projects=@(foreach($name in @('primary','linked-a','linked-b')){$projectRoot=Join-Path $root $name;$null=New-Item -ItemType Directory -Path $projectRoot -Force;$path=Join-Path $projectRoot "$name.jar";Set-Content -LiteralPath $path $name;[pscustomobject]@{Root=$projectRoot;Name=$name;Jar=$path}})
        $order=[Collections.Generic.List[string]]::new()
        $result=Invoke-MmtlProjectBuildPipeline -Primary $projects[0] -LinkedProjects $projects[1..2] -JavaPath 'fixture-java' -SessionPath 'fixture-session' -AutoBuild -BuildAction {
            param($Project,$JavaPath,$SessionPath,$Clean)
            $order.Add($Project.Name)
            [pscustomobject]@{Project=$Project.Root;JarPath=$Project.Jar;JarSha256=(Get-FileHash -LiteralPath $Project.Jar -Algorithm SHA256).Hash;ExitCode=0}
        }
        $order.ToArray() | Should -Be @('primary','linked-a','linked-b')
        $result.builds.Count | Should -Be 3
        $result.linkedArtifacts.Count | Should -Be 2
        $result.linkedArtifacts[0].project | Should -Be $projects[1].Root
        $result.linkedArtifacts[1].project | Should -Be $projects[2].Root
        $result.expectedModHashes[$projects[1].Jar] | Should -Be (Get-FileHash -LiteralPath $projects[1].Jar -Algorithm SHA256).Hash
    }

    It 'linked project 构建失败后不构建后续项目，也不返回可注入产物' {
        $root=Join-Path $TestDrive 'failure';$null=New-Item -ItemType Directory -Path $root -Force
        $projects=@(foreach($name in @('primary','linked-a','linked-b')){$projectRoot=Join-Path $root $name;$null=New-Item -ItemType Directory -Path $projectRoot -Force;[pscustomobject]@{Root=$projectRoot;Name=$name;Jar=(Join-Path $projectRoot "$name.jar")}})
        $order=[Collections.Generic.List[string]]::new()
        { Invoke-MmtlProjectBuildPipeline -Primary $projects[0] -LinkedProjects $projects[1..2] -JavaPath 'fixture-java' -SessionPath 'fixture-session' -AutoBuild -BuildAction {
            param($Project,$JavaPath,$SessionPath,$Clean)
            $order.Add($Project.Name)
            if($Project.Name -eq 'linked-a'){throw 'FIXTURE_LINKED_BUILD_FAILED'}
            Set-Content -LiteralPath $Project.Jar 'fixture jar'
            [pscustomobject]@{Project=$Project.Root;JarPath=$Project.Jar;JarSha256=(Get-FileHash -LiteralPath $Project.Jar -Algorithm SHA256).Hash;ExitCode=0}
        } } | Should -Throw '*FIXTURE_LINKED_BUILD_FAILED*'
        $order.ToArray() | Should -Be @('primary','linked-a')
    }

    It '发现构建后 JAR 被修改时拒绝继续 launch preparation' {
        $root=Join-Path $TestDrive 'mutated';$primaryRoot=Join-Path $root 'primary';$projectRoot=Join-Path $root 'linked';$null=New-Item -ItemType Directory -Path $primaryRoot,$projectRoot -Force;$primaryJar=Join-Path $primaryRoot 'primary.jar';$path=Join-Path $projectRoot 'mutated.jar'
        { Invoke-MmtlProjectBuildPipeline -Primary ([pscustomobject]@{Root=$primaryRoot;Jar=$primaryJar}) -LinkedProjects @([pscustomobject]@{Root=$projectRoot;Jar=$path}) -JavaPath 'fixture-java' -SessionPath 'fixture-session' -AutoBuild -BuildAction {
            param($Project,$JavaPath,$SessionPath,$Clean)
            if($Project.Name -eq 'primary'){Set-Content -LiteralPath $Project.Jar 'primary';return [pscustomobject]@{Project=$Project.Root;JarPath=$Project.Jar;JarSha256=(Get-FileHash -LiteralPath $Project.Jar -Algorithm SHA256).Hash;ExitCode=0}}
            Set-Content -LiteralPath $Project.Jar 'after evidence'
            [pscustomobject]@{Project=$Project.Root;JarPath=$Project.Jar;JarSha256='not-the-final-hash';ExitCode=0}
        } } | Should -Throw '*LINKED_ARTIFACT_HASH_MISMATCH*'
    }
}
