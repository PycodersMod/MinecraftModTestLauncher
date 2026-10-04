BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Execution/ExecutionPlanner.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/SessionLifecycle.psm1') -Force
    function New-TestSessionPlan {
        $repo=Join-Path $TestDrive 'repo';$projectRoot=Join-Path $repo 'mod';New-Item -ItemType Directory -Path $projectRoot -Force|Out-Null
        $jdk=Join-Path $TestDrive 'jdk17';New-Item -ItemType Directory -Path (Join-Path $jdk 'bin') -Force|Out-Null
        New-Item -ItemType File -Path (Join-Path $jdk 'bin/java.exe') -Force|Out-Null
        @('JAVA_VERSION="17.0.1"','IMPLEMENTOR="Test Vendor"','OS_ARCH="amd64"')|Set-Content (Join-Path $jdk 'release')
        $platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false;capabilities=[pscustomobject]@{Build='Native';Launch='Native'}}
        $project=[pscustomobject]@{RepositoryRoot=$repo;Root=$projectRoot;MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';ModId='fixture';LoaderStack=[pscustomobject]@{primaryLoader=[pscustomobject]@{id='Forge';version='47.2.0'};overlayLoaders=@()};Toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'};BuildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'};BuildTask='build';Wrapper=$true;BuildJavaRequirement=[pscustomobject]@{major=17;minimumMajor=17;requirementKind='Minimum';source='Fixture';confidence='High'}}
        $profile=[pscustomobject]@{project=$projectRoot;mode='Single';players=1;hostUsername='Dev';autoBuild=$true;cleanBuild=$false;acceptEula=$false;port='Auto';memoryMb=1024;jvmArgs=@();gameArgs=@()}
        $config=[pscustomobject]@{defaultProfile='fixture';javaHomes=[pscustomobject]@{'17'=$jdk};javaHomesByPlatform=[pscustomobject]@{Windows=[pscustomobject]@{};Linux=[pscustomobject]@{};MacOS=[pscustomobject]@{}}}
        New-MmtlExecutionPlan -Project $project -Profile $profile -Config $config -Platform $platform -RuntimeRoot (Join-Path $TestDrive 'runtime') -ProfileName fixture -PhysicalMemoryMb 8192
    }
}

Describe 'Session 生命周期 v2' {
    It '将语义 Plan 和工件摘要绑定到新 Session，允许合法状态转换' {
        $plan=New-TestSessionPlan
        $session=Join-Path $TestDrive 'runtime/sessions/fixture-session';New-Item -ItemType Directory -Path $session -Force|Out-Null
        $manifest=Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $plan
        $manifest.schemaVersion | Should -Be 2
        (Test-MmtlSessionV2 -SessionPath $session).status | Should -BeExactly 'Valid'
        (Set-MmtlSessionV2State -SessionPath $session -State Building).state | Should -BeExactly 'Building'
        (Set-MmtlSessionV2State -SessionPath $session -State Completed).state | Should -BeExactly 'Completed'
        {Set-MmtlSessionV2State -SessionPath $session -State Running} | Should -Throw '*SESSION_STATE_TRANSITION_INVALID*'
    }

    It '區分缺失的 Plan 工件與摘要损坏' {
        $plan=New-TestSessionPlan
        $session=Join-Path $TestDrive 'runtime/sessions/missing-session';New-Item -ItemType Directory -Path $session -Force|Out-Null
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $plan|Out-Null
        Remove-Item (Join-Path $session 'execution-plan.json')
        (Test-MmtlSessionV2 -SessionPath $session).status | Should -BeExactly 'ArtifactMissing'
    }

    It '拒绝篡改的 Plan 工件' {
        $plan=New-TestSessionPlan
        $session=Join-Path $TestDrive 'runtime/sessions/tamper-session';New-Item -ItemType Directory -Path $session -Force|Out-Null
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $plan|Out-Null
        Add-Content -LiteralPath (Join-Path $session 'execution-plan.json') 'tampered'
        $result=Test-MmtlSessionV2 -SessionPath $session
        $result.valid | Should -BeFalse
        $result.errors | Should -Contain 'SESSION_ARTIFACT_HASH_MISMATCH'
    }

    It '拒绝 Session 外的 Plan 文件链接并保护目标内容' {
        $plan=New-TestSessionPlan
        $session=Join-Path $TestDrive 'runtime/linked-plan-session';New-Item -ItemType Directory -Path $session -Force|Out-Null
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $plan|Out-Null
        $external=Join-Path $TestDrive 'external-plan.json';Copy-Item (Join-Path $session 'execution-plan.json') $external
        Remove-Item (Join-Path $session 'execution-plan.json')
        try{New-Item -ItemType SymbolicLink -Path (Join-Path $session 'execution-plan.json') -Target $external -ErrorAction Stop|Out-Null}catch{Set-ItResult -Skipped -Because '当前平台不允许创建符号链接';return}

        $result=Test-MmtlSessionV2 -SessionPath $session

        $result.valid | Should -BeFalse
        $result.status | Should -BeExactly 'UnsafePath'
        $result.errors | Should -Contain 'SESSION_PATH_REPARSE_POINT'
        (Test-Path -LiteralPath $external -PathType Leaf) | Should -BeTrue
    }

    It 'Session 状态更新拒绝链接 manifest 并保护 Session 外文件' {
        $plan=New-TestSessionPlan
        $session=Join-Path $TestDrive 'runtime/linked-manifest-session';New-Item -ItemType Directory -Path $session -Force|Out-Null
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $plan|Out-Null
        $external=Join-Path $TestDrive 'external-session.json';Copy-Item (Join-Path $session 'session.v2.json') $external
        Remove-Item (Join-Path $session 'session.v2.json')
        try{New-Item -ItemType SymbolicLink -Path (Join-Path $session 'session.v2.json') -Target $external -ErrorAction Stop|Out-Null}catch{Set-ItResult -Skipped -Because '当前平台不允许创建符号链接';return}

        {Set-MmtlSessionV2State -SessionPath $session -State Building} | Should -Throw '*SESSION_PATH_REPARSE_POINT*'
        (Get-Content -LiteralPath $external -Raw | ConvertFrom-Json).state | Should -BeExactly 'Created'
    }

    It '重新验证 Session 中已记录 JAR 的 SHA-256，并区分丢失与篡改' {
        $plan=New-TestSessionPlan
        $session=Join-Path $TestDrive 'runtime/artifact-session';New-Item -ItemType Directory -Path $session -Force|Out-Null
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $plan|Out-Null
        $artifact=Join-Path $plan.project.projectRoot 'build/libs/fixture.jar';New-Item -ItemType Directory -Path (Split-Path $artifact) -Force|Out-Null
        Set-Content -LiteralPath $artifact -Value 'fixture jar bytes'
        $hash=(Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
        @{metadata=@{project=$plan.project.projectRoot};jarPath=$artifact;jarSha256=$hash}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $session 'session.json')

        (Test-MmtlSessionV2 -SessionPath $session).valid | Should -BeTrue
        Set-Content -LiteralPath $artifact -Value 'changed bytes'
        (Test-MmtlSessionV2 -SessionPath $session).errors | Should -Contain 'SESSION_ARTIFACT_HASH_MISMATCH'
        Remove-Item -LiteralPath $artifact
        $missing=Test-MmtlSessionV2 -SessionPath $session
        $missing.status | Should -BeExactly 'ArtifactMissing'
        $missing.errors | Should -Contain 'SESSION_ARTIFACT_MISSING'
    }
}
