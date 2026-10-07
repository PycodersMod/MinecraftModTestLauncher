BeforeAll { $root=Split-Path -Parent $PSScriptRoot;Import-Module (Join-Path $root 'src/Platform/Platform.psm1') -Force;Import-Module (Join-Path $root 'src/ProjectDetector.psm1') -Force;Import-Module (Join-Path $root 'src/Adapters/Fabric.psm1') -Force }
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

    It 'detects and binds every exact Fabric universe target without claiming build support' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Fabric' -and $_.availability -ceq 'Available'})
        $projectRoot=Join-Path $TestDrive 'all-fabric-targets'
        $resources=Join-Path $projectRoot 'src/main/resources'
        New-Item -ItemType Directory -Path $resources -Force|Out-Null
        "plugins { id 'fabric-loom' version '1.7.4' }"|Set-Content (Join-Path $projectRoot 'build.gradle')
        '{"schemaVersion":1,"id":"fixture"}'|Set-Content (Join-Path $resources 'fabric.mod.json')
        $provider=Get-MmtlPlatformProvider
        $wrapperPath=Join-Path $projectRoot $provider.GradleWrapper
        Set-Content -LiteralPath $wrapperPath -Value ''
        $failures=[Collections.Generic.List[string]]::new()

        foreach($target in $targets){
            if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){$failures.Add("$($target.targetId):CANDIDATES_UNRESOLVED");continue}
            "minecraft_version=$($target.minecraftId)`nloader_version=$($target.loaderVersionCandidates[0])"|Set-Content (Join-Path $projectRoot 'gradle.properties')
            $project=Get-MmtlProject -Path $projectRoot
            $resolution=Resolve-MmtlFabricAdapterTarget -Project $project -Universe $universe
            $plans=New-MmtlFabricAdapterPlans -Project $project -Universe $universe
            if($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'Fabric' -or $project.MinecraftVersion -cne [string]$target.minecraftId -or $project.LoaderVersion -cne [string]$target.loaderVersionCandidates[0] -or $resolution.status -cne 'Resolved' -or $resolution.targetId -cne [string]$target.targetId -or $plans.targetId -cne [string]$target.targetId -or $plans.buildPlan.task -cne 'build' -or $plans.launchPlan.task -cne 'runClient' -or $plans.buildPlan.isExecutablePlan -or $plans.launchPlan.isExecutablePlan){$failures.Add("$($target.targetId):DETECTION_BINDING_OR_PLAN_MISMATCH")}
        }

        $failures | Should -BeNullOrEmpty
        $targets.Count | Should -Be 530
    }
}
