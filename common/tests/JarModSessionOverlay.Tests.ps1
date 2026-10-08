BeforeAll {
    $script:repoRoot=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Execution/ExecutionPlanner.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/SessionLifecycle.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'src/Catalog/Providers/JarModSessionOverlay.psm1') -Force

    function New-TestOverlaySession {
        Import-Module (Join-Path $script:repoRoot 'src/SessionLifecycle.psm1') -Force
        $repo=Join-Path $TestDrive 'repo';$project=Join-Path $repo 'mod';New-Item -ItemType Directory -Path $project -Force|Out-Null
        $jdk=Join-Path $TestDrive 'jdk17';New-Item -ItemType Directory -Path (Join-Path $jdk 'bin') -Force|Out-Null
        New-Item -ItemType File -Path (Join-Path $jdk 'bin/java.exe') -Force|Out-Null
        @('JAVA_VERSION="17.0.1"','IMPLEMENTOR="Test Vendor"','OS_ARCH="amd64"')|Set-Content (Join-Path $jdk 'release')
        $platform=[pscustomobject]@{os='Windows';arch='x64';isWSL=$false;capabilities=[pscustomobject]@{Build='Native';Launch='Native'}}
        $projectRecord=[pscustomobject]@{RepositoryRoot=$repo;Root=$project;MinecraftVersion='1.20.1';Loader='Forge';LoaderVersion='47.2.0';ModId='fixture';LoaderStack=[pscustomobject]@{primaryLoader=[pscustomobject]@{id='Forge';version='47.2.0'};overlayLoaders=@()};Toolchain=[pscustomobject]@{id='ForgeGradle';version='6.0'};BuildSystem=[pscustomobject]@{id='GradleWrapper';version='8.8'};BuildTask='build';Wrapper=$true;BuildJavaRequirement=[pscustomobject]@{major=17;minimumMajor=17;requirementKind='Minimum';source='Fixture';confidence='High'}}
        $profile=[pscustomobject]@{project=$project;mode='Single';players=1;hostUsername='Dev';autoBuild=$true;cleanBuild=$false;acceptEula=$false;port='Auto';memoryMb=1024;jvmArgs=@();gameArgs=@()}
        $config=[pscustomobject]@{defaultProfile='fixture';javaHomes=[pscustomobject]@{'17'=$jdk};javaHomesByPlatform=[pscustomobject]@{Windows=[pscustomobject]@{};Linux=[pscustomobject]@{};MacOS=[pscustomobject]@{}}}
        $runtime=Join-Path $TestDrive 'runtime';$session=Join-Path $runtime ('sessions/fixture-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $session -Force|Out-Null
        $plan=New-MmtlExecutionPlan -Project $projectRecord -Profile $profile -Config $config -Platform $platform -RuntimeRoot $runtime -ProfileName fixture -PhysicalMemoryMb 8192
        Initialize-MmtlSessionV2 -SessionPath $session -ExecutionPlan $plan|Out-Null
        return $session
    }

    function New-TestZip {
        param([string]$Path,[hashtable]$Entries)
        $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false);try{foreach($name in $Entries.Keys){$entry=$archive.CreateEntry([string]$name);$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write([string]$Entries[$name])}finally{$writer.Dispose()}}}finally{$archive.Dispose()}}finally{$stream.Dispose()}
    }
}

Describe 'JarMod Session-isolated overlay' {
    It '仅在 Session 输出副本合并 patch entry，保留原输入并登记 SHA-256 artifacts' {
        $session=New-TestOverlaySession
        $base=Join-Path $TestDrive 'base.jar';$patch=Join-Path $TestDrive 'patch.zip'
        New-TestZip $base @{ 'net/minecraft/Keep.class'='base';'net/minecraft/Replace.class'='old' }
        New-TestZip $patch @{ 'net/minecraft/Replace.class'='new';'mods/example.txt'='added' }
        $baseHash=(Get-FileHash $base -Algorithm SHA256).Hash;$patchHash=(Get-FileHash $patch -Algorithm SHA256).Hash

        $result=New-MmtlJarModSessionOverlay -SessionPath $session -BaseJarPath $base -PatchArchivePath $patch -PatchStrategy OverlayReplaceConflicts

        $result.patchApplied | Should -BeTrue
        $result.executePermission | Should -BeExactly 'Denied'
        $result.outputPath.StartsWith($session,[StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
        (Get-FileHash $base -Algorithm SHA256).Hash | Should -BeExactly $baseHash
        (Get-FileHash $patch -Algorithm SHA256).Hash | Should -BeExactly $patchHash
        $output=[IO.Compression.ZipFile]::OpenRead($result.outputPath)
        try{ $reader=[IO.StreamReader]::new($output.GetEntry('net/minecraft/Replace.class').Open());try{$reader.ReadToEnd()|Should -BeExactly 'new'}finally{$reader.Dispose()};$output.Entries.FullName | Should -Contain 'mods/example.txt' }finally{$output.Dispose()}
        (Test-MmtlSessionV2 -SessionPath $session).valid | Should -BeTrue
        @((Get-Content (Join-Path $session 'session.v2.json') -Raw|ConvertFrom-Json).artifacts|Where-Object kind -like 'JarMod*').Count | Should -BeGreaterThan 0
    }

    It '冲突策略为 Reject 时不产出 patched jar 且不更改输入' {
        $session=New-TestOverlaySession;$base=Join-Path $TestDrive 'conflict-base.jar';$patch=Join-Path $TestDrive 'conflict-patch.zip'
        New-TestZip $base @{ 'same.txt'='base' };New-TestZip $patch @{ 'same.txt'='patch' }
        $baseHash=(Get-FileHash $base -Algorithm SHA256).Hash

        { New-MmtlJarModSessionOverlay -SessionPath $session -BaseJarPath $base -PatchArchivePath $patch -PatchStrategy OverlayRejectConflicts } | Should -Throw '*JARMOD_ENTRY_CONFLICT*'

        (Get-FileHash $base -Algorithm SHA256).Hash | Should -BeExactly $baseHash
        @(Get-ChildItem (Join-Path $session 'artifacts/jarmod') -Filter 'patched.jar' -Recurse -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It '拒绝 ZIP 路径穿越、签名 Jar 和不支持的终态 Session' {
        $session=New-TestOverlaySession;$base=Join-Path $TestDrive 'unsafe-base.jar';$patch=Join-Path $TestDrive 'unsafe-patch.zip'
        New-TestZip $base @{ 'ok.txt'='ok' };New-TestZip $patch @{ '../escape.txt'='bad' }
        { New-MmtlJarModSessionOverlay -SessionPath $session -BaseJarPath $base -PatchArchivePath $patch -PatchStrategy OverlayReplaceConflicts } | Should -Throw '*JARMOD_ENTRY_PATH_INVALID*'

        $signedBase=Join-Path $TestDrive 'signed-base.jar';New-TestZip $signedBase @{ 'META-INF/TEST.SF'='sig';'x.txt'='x' }
        $safePatch=Join-Path $TestDrive 'safe-patch.zip';New-TestZip $safePatch @{ 'new.txt'='ok' }
        { New-MmtlJarModSessionOverlay -SessionPath $session -BaseJarPath $signedBase -PatchArchivePath $safePatch -PatchStrategy OverlayReplaceConflicts } | Should -Throw '*JARMOD_SIGNED_ARCHIVE_UNSUPPORTED*'

        $manifestPath=Join-Path $session 'session.v2.json';$manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json;$manifest.state='Completed';$manifest|ConvertTo-Json -Depth 30|Set-Content $manifestPath
        { New-MmtlJarModSessionOverlay -SessionPath $session -BaseJarPath $base -PatchArchivePath $patch -PatchStrategy OverlayReplaceConflicts } | Should -Throw '*JARMOD_SESSION_STATE_UNSUPPORTED*'
    }

    It '拒绝重复 ZIP entry 且失败时清理本次隔离目录' {
        $session=New-TestOverlaySession;$base=Join-Path $TestDrive 'duplicate-base.jar';$patch=Join-Path $TestDrive 'duplicate-patch.zip'
        New-TestZip $base @{ 'base.txt'='base' }
        $stream=[IO.File]::Open($patch,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false);try{foreach($value in @('one','two')){$entry=$archive.CreateEntry('dup.txt');$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write($value)}finally{$writer.Dispose()}}}finally{$archive.Dispose()}}finally{$stream.Dispose()}
        { New-MmtlJarModSessionOverlay -SessionPath $session -BaseJarPath $base -PatchArchivePath $patch -PatchStrategy OverlayReplaceConflicts } | Should -Throw '*JARMOD_ENTRY_DUPLICATE*'
        @(Get-ChildItem (Join-Path $session 'artifacts/jarmod') -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Test-MmtlSessionV2 -SessionPath $session).valid | Should -BeTrue
    }
}
