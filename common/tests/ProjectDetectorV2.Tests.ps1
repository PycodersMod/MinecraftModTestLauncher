BeforeAll { $root=Split-Path -Parent $PSScriptRoot;Import-Module (Join-Path $root 'src/Platform/Platform.psm1') -Force;Import-Module (Join-Path $root 'src/ProjectDetector.psm1') -Force;Import-Module (Join-Path $root 'src/Adapters/Fabric.psm1') -Force;Import-Module (Join-Path $root 'src/Adapters/NeoForge.psm1') -Force;Import-Module (Join-Path $root 'src/Adapters/Quilt.psm1') -Force;Import-Module (Join-Path $root 'src/Adapters/Forge.psm1') -Force }
Describe 'Evidence based project detection' {
    It 'identifies ModDevGradle before the broader NeoForge Gradle plugin marker' {
        $project=Join-Path $TestDrive 'neoforge-moddevgradle';New-Item -ItemType Directory -Path (Join-Path $project 'src/main/resources/META-INF') -Force|Out-Null
        "plugins { id 'net.neoforged.moddev' version '2.0.1' }"|Set-Content (Join-Path $project 'build.gradle')
        "minecraft_version=1.21.1`nneo_version=21.1.200`nmod_id=fixture"|Set-Content (Join-Path $project 'gradle.properties')
        'modLoader="javafml"'|Set-Content (Join-Path $project 'src/main/resources/META-INF/neoforge.mods.toml')
        $provider=Get-MmtlPlatformProvider;Set-Content (Join-Path $project $provider.GradleWrapper) -Value ''

        $result=Get-MmtlProject -Path $project

        $result.Loader | Should -BeExactly 'NeoForge'
        $result.Toolchain.id | Should -BeExactly 'ModDevGradle'
        $result.MinecraftVersion | Should -BeExactly '1.21.1'
        $result.LoaderVersion | Should -BeExactly '21.1.200'
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $plans=New-MmtlNeoForgeAdapterPlans -Project $result -Universe $universe
        $plans.targetId | Should -BeExactly 'NeoForge@1.21.1'
        $plans.launchPlan.task | Should -BeExactly 'runClient'
    }

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
        $provider=Get-MmtlPlatformProvider;Set-Content (Join-Path $project $provider.GradleWrapper) -Value ''
        $result=Get-MmtlProject -Path $project
        $result.Loader | Should -BeExactly 'Quilt';$result.Toolchain.id | Should -BeExactly 'QuiltLoom';$result.DetectionStatus | Should -BeExactly 'Resolved';$result.MinecraftVersion | Should -BeExactly '1.20.6';$result.LoaderVersion | Should -BeExactly '0.26.3'
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $plans=New-MmtlQuiltAdapterPlans -Project $result -Universe $universe
        $plans.targetId | Should -BeExactly 'Quilt@1.20.6'
        $plans.launchPlan.task | Should -BeExactly 'runClient'
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

    It 'detects and creates gated Build and Launch plans for every exact NeoForge universe target' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'NeoForge' -and $_.availability -ceq 'Available'})
        $projectRoot=Join-Path $TestDrive 'all-neoforge-targets'
        $resources=Join-Path $projectRoot 'src/main/resources/META-INF'
        New-Item -ItemType Directory -Path $resources -Force|Out-Null
        "plugins { id 'net.neoforged.gradle.userdev' version '7.1.0' }"|Set-Content (Join-Path $projectRoot 'build.gradle')
        'modLoader="javafml"'|Set-Content (Join-Path $resources 'neoforge.mods.toml')
        $provider=Get-MmtlPlatformProvider
        Set-Content -LiteralPath (Join-Path $projectRoot $provider.GradleWrapper) -Value ''
        $failures=[Collections.Generic.List[string]]::new()

        foreach($target in $targets){
            if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){$failures.Add("$($target.targetId):CANDIDATES_UNRESOLVED");continue}
            "minecraft_version=$($target.minecraftId)`nneo_version=$($target.loaderVersionCandidates[0])`nmod_id=fixture"|Set-Content (Join-Path $projectRoot 'gradle.properties')
            $project=Get-MmtlProject -Path $projectRoot
            $plans=New-MmtlNeoForgeAdapterPlans -Project $project -Universe $universe
            if($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'NeoForge' -or $project.MinecraftVersion -cne [string]$target.minecraftId -or $project.LoaderVersion -cne [string]$target.loaderVersionCandidates[0] -or $project.Toolchain.id -cne 'NeoGradle' -or $plans.status -cne 'Resolved' -or $plans.targetId -cne [string]$target.targetId -or $plans.buildPlan.task -cne 'build' -or $plans.buildPlan.executionGate -cne 'TRUSTED_VALIDATION_RUNNER_REQUIRED' -or $plans.launchPlan.task -cne 'runClient' -or $plans.launchPlan.runtimeJavaRequirement.major -ne $target.runtimeJavaRequirement.major -or $plans.launchPlan.launchCheckStatus -cne 'Unverified' -or $plans.buildPlan.isExecutablePlan -or $plans.launchPlan.isExecutablePlan){$failures.Add("$($target.targetId):DETECTION_BINDING_OR_PLAN_MISMATCH")}
        }

        $failures | Should -BeNullOrEmpty
        $targets.Count | Should -Be 23
    }

    It 'detects and creates gated Build and Launch plans for every exact Quilt universe target' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Quilt' -and $_.availability -ceq 'Available'})
        $projectRoot=Join-Path $TestDrive 'all-quilt-targets'
        $resources=Join-Path $projectRoot 'src/main/resources'
        $versionCatalog=Join-Path $projectRoot 'gradle'
        New-Item -ItemType Directory -Path $resources,$versionCatalog -Force|Out-Null
        "plugins { alias libs.plugins.quilt.loom }"|Set-Content (Join-Path $projectRoot 'build.gradle')
        '{"schema_version":1,"quilt_loader":{"id":"fixture"}}'|Set-Content (Join-Path $resources 'quilt.mod.json')
        $provider=Get-MmtlPlatformProvider
        Set-Content -LiteralPath (Join-Path $projectRoot $provider.GradleWrapper) -Value ''
        $failures=[Collections.Generic.List[string]]::new()

        foreach($target in $targets){
            if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){$failures.Add("$($target.targetId):CANDIDATES_UNRESOLVED");continue}
            @'
[versions]
minecraft = "__MINECRAFT__"
quilt_loader = "__QUILT_LOADER__"
[plugins]
quilt_loom = { id = "org.quiltmc.loom", version = "1.7.4" }
'@.Replace('__MINECRAFT__',[string]$target.minecraftId).Replace('__QUILT_LOADER__',[string]$target.loaderVersionCandidates[0])|Set-Content (Join-Path $versionCatalog 'libs.versions.toml')
            $project=Get-MmtlProject -Path $projectRoot
            $plans=New-MmtlQuiltAdapterPlans -Project $project -Universe $universe
            if($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'Quilt' -or $project.MinecraftVersion -cne [string]$target.minecraftId -or $project.LoaderVersion -cne [string]$target.loaderVersionCandidates[0] -or $project.Toolchain.id -cne 'QuiltLoom' -or $plans.status -cne 'Resolved' -or $plans.targetId -cne [string]$target.targetId -or $plans.buildPlan.task -cne 'build' -or $plans.buildPlan.executionGate -cne 'TRUSTED_VALIDATION_RUNNER_REQUIRED' -or $plans.launchPlan.task -cne 'runClient' -or $plans.launchPlan.runtimeJavaRequirement.major -ne $target.runtimeJavaRequirement.major -or $plans.launchPlan.launchCheckStatus -cne 'Unverified' -or $plans.buildPlan.isExecutablePlan -or $plans.launchPlan.isExecutablePlan){$failures.Add("$($target.targetId):DETECTION_BINDING_OR_PLAN_MISMATCH")}
        }

        $failures | Should -BeNullOrEmpty
        $targets.Count | Should -Be 441
    }

    It 'detects every exact Forge universe target from project coordinates' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'Forge' -and $_.availability -ceq 'Available'})
        $projectRoot=Join-Path $TestDrive 'all-forge-targets'
        $resources=Join-Path $projectRoot 'src/main/resources/META-INF'
        New-Item -ItemType Directory -Path $resources -Force|Out-Null
        "plugins { id 'net.minecraftforge.gradle' version '2.3-SNAPSHOT' }"|Set-Content (Join-Path $projectRoot 'build.gradle')
        'modLoader="javafml"'|Set-Content (Join-Path $resources 'mods.toml')
        $failures=[Collections.Generic.List[string]]::new()

        foreach($target in $targets){
            if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){$failures.Add("$($target.targetId):CANDIDATES_UNRESOLVED");continue}
            @("minecraft_version=$($target.minecraftId)","forge_version=$($target.loaderVersionCandidates[0])",'mod_id=fixture') -join [Environment]::NewLine | Set-Content (Join-Path $projectRoot 'gradle.properties')
            $project=Get-MmtlProject -Path $projectRoot
            if($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'Forge' -or $project.MinecraftVersion -cne [string]$target.minecraftId -or $project.LoaderVersion -cne [string]$target.loaderVersionCandidates[0] -or $project.Toolchain.id -cne 'ForgeGradle'){$failures.Add("$($target.targetId):DETECTION_BINDING_MISMATCH")}
        }

        $failures | Should -BeNullOrEmpty
        $targets.Count | Should -Be 76
    }

    It 'detects every exact LegacyFabric universe target from Legacy Looming coordinates' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'LegacyFabric' -and $_.availability -ceq 'Available'})
        $projectRoot=Join-Path $TestDrive 'all-legacyfabric-targets'
        $resources=Join-Path $projectRoot 'src/main/resources'
        New-Item -ItemType Directory -Path $resources -Force|Out-Null
        "plugins { id 'legacy-looming' version '1.9-SNAPSHOT' }"|Set-Content (Join-Path $projectRoot 'build.gradle')
        '{"schemaVersion":1,"id":"fixture"}'|Set-Content (Join-Path $resources 'fabric.mod.json')
        $failures=[Collections.Generic.List[string]]::new()

        foreach($target in $targets){
            if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){$failures.Add("$($target.targetId):CANDIDATES_UNRESOLVED");continue}
            @("minecraft_version=$($target.minecraftId)","loader_version=$($target.loaderVersionCandidates[0])",'mod_id=fixture') -join [Environment]::NewLine | Set-Content (Join-Path $projectRoot 'gradle.properties')
            $project=Get-MmtlProject -Path $projectRoot
            if($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'LegacyFabric' -or $project.MinecraftVersion -cne [string]$target.minecraftId -or $project.LoaderVersion -cne [string]$target.loaderVersionCandidates[0] -or $project.Toolchain.id -cne 'LegacyLooming'){$failures.Add("$($target.targetId):DETECTION_BINDING_MISMATCH")}
        }

        $failures | Should -BeNullOrEmpty
        $targets.Count | Should -Be 76
    }

    It 'detects every exact OrnitheLoader universe target from Ploceus coordinates' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'OrnitheLoader' -and $_.availability -ceq 'Available'})
        $projectRoot=Join-Path $TestDrive 'all-ornithe-targets'
        New-Item -ItemType Directory -Path $projectRoot -Force|Out-Null
        @("plugins { id 'ploceus' version '1.18-SNAPSHOT' }","dependencies { modImplementation 'net.ornithemc:ornithe-loader:0.1.2' }") -join [Environment]::NewLine | Set-Content (Join-Path $projectRoot 'build.gradle')
        $failures=[Collections.Generic.List[string]]::new()

        foreach($target in $targets){
            if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0){$failures.Add("$($target.targetId):CANDIDATES_UNRESOLVED");continue}
            @("minecraft_version=$($target.minecraftId)","loader_version=$($target.loaderVersionCandidates[0])",'mod_id=fixture') -join [Environment]::NewLine | Set-Content (Join-Path $projectRoot 'gradle.properties')
            $project=Get-MmtlProject -Path $projectRoot
            if($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'OrnitheLoader' -or $project.MinecraftVersion -cne [string]$target.minecraftId -or $project.LoaderVersion -cne [string]$target.loaderVersionCandidates[0] -or $project.Toolchain.id -cne 'Ploceus' -or $project.Toolchain.ecosystem -cne 'Ornithe'){$failures.Add("$($target.targetId):DETECTION_BINDING_MISMATCH")}
        }

        $failures | Should -BeNullOrEmpty
        $targets.Count | Should -Be 406
    }

    It 'detects every exact LiteLoader universe target from official metadata candidates' {
        $repositoryRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $universe=Get-Content -Raw (Join-Path $repositoryRoot 'compatibility/universe-preview.json')|ConvertFrom-Json
        $targets=@($universe.targets|Where-Object{$_.loaderId -ceq 'LiteLoader' -and $_.availability -ceq 'Available'})
        $projectRoot=Join-Path $TestDrive 'all-liteloader-targets'
        $resources=Join-Path $projectRoot 'src/main/resources'
        New-Item -ItemType Directory -Path $resources -Force|Out-Null
        "plugins { id 'net.minecraftforge.gradle.liteloader' version '2.2' }"|Set-Content (Join-Path $projectRoot 'build.gradle')
        $liteModTemplate=@('{','  "name": "fixture",','  "version": "1.0",','  "revision": "1",','  "mcversion": "__MINECRAFT__"','}') -join [Environment]::NewLine
        $failures=[Collections.Generic.List[string]]::new()

        foreach($target in $targets){
            if([string]$target.candidateStatus -cne 'Resolved' -or @($target.loaderVersionCandidates).Count -eq 0 -or [string]$target.candidateSourceUrl -cne 'https://dl.liteloader.com/versions/versions.json' -or [string]$target.candidateSourceHash -notmatch '^(?i:[a-f0-9]{64})$'){$failures.Add("$($target.targetId):CANDIDATE_PROVENANCE_INVALID");continue}
            "minecraft_version=$($target.minecraftId)`nliteloader_version=$($target.loaderVersionCandidates[0])"|Set-Content (Join-Path $projectRoot 'gradle.properties')
            $liteModTemplate.Replace('__MINECRAFT__',[string]$target.minecraftId)|Set-Content (Join-Path $resources 'litemod.json')
            $project=Get-MmtlProject -Path $projectRoot
            if($project.DetectionStatus -cne 'Resolved' -or $project.Loader -cne 'LiteLoader' -or $project.MinecraftVersion -cne [string]$target.minecraftId -or $project.LoaderVersion -cne [string]$target.loaderVersionCandidates[0] -or $project.Toolchain.id -cne 'ForgeGradle' -or @($project.LoaderStack|Where-Object{$_ -ceq 'Forge'}).Count -gt 0){$failures.Add("$($target.targetId):DETECTION_BINDING_MISMATCH")}
        }

        $failures | Should -BeNullOrEmpty
        $targets.Count | Should -Be 16
    }
}
