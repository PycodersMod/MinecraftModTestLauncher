Set-StrictMode -Version Latest

function New-MmtlLiteLoaderRunInitScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)]$LoaderLaunchPlan,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Artifacts
    )

    if ($TaskName -notin @('runClient','runServer')) { throw 'LITELOADER_RUN_TASK_INVALID' }
    if ([string]$LoaderLaunchPlan.mainClass -cne 'net.minecraft.launchwrapper.Launch' -or [string]$LoaderLaunchPlan.tweakClass -cne 'com.mumfrey.liteloader.launch.LiteLoaderTweaker') { throw 'LITELOADER_RUN_ENTRYPOINT_INVALID' }
    $artifactPins = [ordered]@{}
    foreach ($artifactName in @('client','server')) {
        $artifactKey = $artifactName + 'Artifact'
        $artifact = if ($LoaderLaunchPlan -is [Collections.IDictionary]) { $LoaderLaunchPlan[$artifactKey] } elseif ($LoaderLaunchPlan.PSObject.Properties[$artifactKey]) { $LoaderLaunchPlan.$artifactKey } else { $null }
        $artifactUri = $null
        if (-not $artifact -or -not [Uri]::TryCreate([string]$artifact.url,[UriKind]::Absolute,[ref]$artifactUri) -or $artifactUri.Scheme -cne 'https' -or $artifactUri.Host -cnotin @('launcher.mojang.com','piston-data.mojang.com') -or $artifactUri.Port -ne 443 -or $artifactUri.UserInfo -or $artifactUri.Query -or $artifactUri.Fragment -or [string]$artifact.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [long]$artifact.bytes -le 0 -or $artifactUri.AbsolutePath -cnotmatch ('^/v1/objects/'+[regex]::Escape([string]$artifact.sha1)+'/'+$artifactName+'\.jar$')) { throw "LITELOADER_$($artifactName.ToUpperInvariant())_ARTIFACT_PIN_INVALID" }
        $artifactPins[$artifactName] = [ordered]@{url=$artifactUri.AbsoluteUri;sha1=([string]$artifact.sha1).ToLowerInvariant();bytes=[long]$artifact.bytes}
    }
    $versionMetadata = $LoaderLaunchPlan.versionMetadata
    $versionMetadataUri = $null
    if (-not $versionMetadata -or -not [Uri]::TryCreate([string]$versionMetadata.url,[UriKind]::Absolute,[ref]$versionMetadataUri) -or $versionMetadataUri.Scheme -cne 'https' -or $versionMetadataUri.Host -cne 'piston-meta.mojang.com' -or $versionMetadataUri.Port -ne 443 -or $versionMetadataUri.UserInfo -or $versionMetadataUri.Query -or $versionMetadataUri.Fragment -or [string]$versionMetadata.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [string]$versionMetadata.sha256 -notmatch '^(?i:[a-f0-9]{64})$' -or [long]$versionMetadata.bytes -le 0 -or $versionMetadataUri.AbsolutePath -notmatch ('^/v1/packages/'+[regex]::Escape([string]$versionMetadata.sha1)+'/')) { throw 'LITELOADER_VERSION_METADATA_PIN_INVALID' }
    $assetIndex = $LoaderLaunchPlan.assetIndex
    $assetIndexUri = $null
    if (-not $assetIndex -or [string]$assetIndex.id -cne [string]$LoaderLaunchPlan.minecraftId -or -not [Uri]::TryCreate([string]$assetIndex.url,[UriKind]::Absolute,[ref]$assetIndexUri) -or $assetIndexUri.Scheme -cne 'https' -or $assetIndexUri.Host -cne 'launchermeta.mojang.com' -or $assetIndexUri.Port -ne 443 -or $assetIndexUri.UserInfo -or $assetIndexUri.Query -or $assetIndexUri.Fragment -or [string]$assetIndex.sha1 -notmatch '^(?i:[a-f0-9]{40})$' -or [long]$assetIndex.bytes -le 0 -or $assetIndexUri.AbsolutePath -notmatch ('^/v1/packages/'+[regex]::Escape([string]$assetIndex.sha1)+'/')) { throw 'LITELOADER_ASSET_INDEX_PIN_INVALID' }
    $session = [IO.Path]::GetFullPath($SessionPath)
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($artifact in $Artifacts) {
        $path = [IO.Path]::GetFullPath([string]$artifact.path)
        $relative = [IO.Path]::GetRelativePath($session,$path)
        if ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith('..'+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'LITELOADER_RUN_ARTIFACT_OUTSIDE_SESSION' }
        $item = Get-Item -LiteralPath $path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Extension -cne '.jar') { throw 'LITELOADER_RUN_ARTIFACT_INVALID' }
        $paths.Add($path)
    }
    if ($paths.Count -ne (@($LoaderLaunchPlan.libraries).Count + 1)) { throw 'LITELOADER_RUN_ARTIFACT_SET_INCOMPLETE' }

    $config = [ordered]@{ taskName=$TaskName; sessionPath=$session; minecraftId=[string]$LoaderLaunchPlan.minecraftId; mainClass=[string]$LoaderLaunchPlan.mainClass; tweakClass=[string]$LoaderLaunchPlan.tweakClass; classpath=@($paths.ToArray()); clientArtifact=$artifactPins.client; serverArtifact=$artifactPins.server; versionMetadata=[ordered]@{url=$versionMetadataUri.AbsoluteUri;sha1=([string]$versionMetadata.sha1).ToLowerInvariant();bytes=[long]$versionMetadata.bytes}; assetIndex=[ordered]@{url=$assetIndexUri.AbsoluteUri;sha1=([string]$assetIndex.sha1).ToLowerInvariant();bytes=[long]$assetIndex.bytes} }
    $json = $config | ConvertTo-Json -Depth 8 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    return @"
def mmtlLiteLoaderConfig = new groovy.json.JsonSlurper().parseText(new String(java.util.Base64.decoder.decode('$encoded'), java.nio.charset.StandardCharsets.UTF_8))
gradle.projectsEvaluated {
    def mmtlConfigurePinnedDownload = { mmtlTaskName, mmtlPin, mmtlArtifactName, mmtlAllowTrailingLineFeed ->
        def mmtlDownloadTask = gradle.rootProject.tasks.findByName(mmtlTaskName)
        if (mmtlDownloadTask == null) { throw new GradleException('MMTL_LITELOADER_' + mmtlArtifactName.toUpperCase() + '_DOWNLOAD_TASK_MISSING') }
        def mmtlUrlSetter = mmtlDownloadTask.class.methods.find { it.name == 'setUrl' && it.parameterTypes.length == 1 }
        if (mmtlUrlSetter == null) { throw new GradleException('MMTL_LITELOADER_' + mmtlArtifactName.toUpperCase() + '_SET_URL_UNSUPPORTED') }
        def mmtlUrlType = mmtlUrlSetter.parameterTypes[0]
        if (mmtlUrlType == String) {
            mmtlUrlSetter.invoke(mmtlDownloadTask, mmtlPin.url)
        } else if (mmtlUrlType.name == 'net.minecraftforge.gradle.delayed.DelayedString') {
            def mmtlDelayedUrl = mmtlUrlType.getConstructor(org.gradle.api.Project, String).newInstance(gradle.rootProject, mmtlPin.url)
            mmtlUrlSetter.invoke(mmtlDownloadTask, mmtlDelayedUrl)
        } else if (mmtlUrlType == Object) {
            mmtlUrlSetter.invoke(mmtlDownloadTask, mmtlPin.url)
        } else {
            throw new GradleException('MMTL_LITELOADER_' + mmtlArtifactName.toUpperCase() + '_SET_URL_TYPE_UNSUPPORTED:' + mmtlUrlType.name)
        }
        def mmtlArtifactFile = mmtlDownloadTask.hasProperty('output') ? mmtlDownloadTask.output : mmtlDownloadTask.file
        def mmtlArtifactPinValid = {
            if (mmtlArtifactFile == null || !mmtlArtifactFile.isFile()) { return false }
            byte[] mmtlArtifactBytes = java.nio.file.Files.readAllBytes(mmtlArtifactFile.toPath())
            if (mmtlAllowTrailingLineFeed && mmtlArtifactBytes.length == mmtlPin.bytes + 1 && mmtlArtifactBytes[mmtlArtifactBytes.length - 1] == 10) {
                mmtlArtifactBytes = java.util.Arrays.copyOf(mmtlArtifactBytes, mmtlArtifactBytes.length - 1)
            }
            if (mmtlArtifactBytes.length != mmtlPin.bytes) { return false }
            byte[] mmtlArtifactDigest = java.security.MessageDigest.getInstance('SHA-1').digest(mmtlArtifactBytes)
            String mmtlArtifactSha1 = mmtlArtifactDigest.collect { String.format('%02x', it & 0xff) }.join()
            return mmtlArtifactSha1 == mmtlPin.sha1
        }
        def mmtlStagedArtifactPinValid = {
            if (!(['CLIENT','SERVER'].contains(mmtlArtifactName.toUpperCase()))) { return true }
            File mmtlStageSessionRoot = new File(mmtlLiteLoaderConfig.sessionPath).canonicalFile
            File mmtlStageDirectory = new File(mmtlStageSessionRoot, 'gradle-loader/minecraft-artifacts').canonicalFile
            File mmtlStagedArtifact = new File(mmtlStageDirectory, mmtlArtifactName.toLowerCase() + '-' + mmtlLiteLoaderConfig.minecraftId + '.jar').canonicalFile
            if (!mmtlStageDirectory.toPath().startsWith(mmtlStageSessionRoot.toPath()) || !mmtlStagedArtifact.toPath().startsWith(mmtlStageSessionRoot.toPath()) || !mmtlStagedArtifact.isFile() || java.nio.file.Files.isSymbolicLink(mmtlStageDirectory.toPath()) || java.nio.file.Files.isSymbolicLink(mmtlStagedArtifact.toPath())) { return false }
            byte[] mmtlStagedBytes = java.nio.file.Files.readAllBytes(mmtlStagedArtifact.toPath())
            if (mmtlStagedBytes.length != mmtlPin.bytes) { return false }
            byte[] mmtlStagedDigest = java.security.MessageDigest.getInstance('SHA-1').digest(mmtlStagedBytes)
            return mmtlStagedDigest.collect { String.format('%02x', it & 0xff) }.join() == mmtlPin.sha1
        }
        mmtlDownloadTask.outputs.upToDateWhen { mmtlArtifactPinValid() && mmtlStagedArtifactPinValid() }
        mmtlDownloadTask.doLast {
            if (!mmtlArtifactPinValid()) { throw new GradleException('MMTL_LITELOADER_' + mmtlArtifactName.toUpperCase() + '_SHA1_MISMATCH:' + mmtlDownloadTask.path) }
            if (mmtlArtifactName.toUpperCase() in ['CLIENT','SERVER']) {
                File mmtlStageSessionRoot = new File(mmtlLiteLoaderConfig.sessionPath).canonicalFile
                File mmtlStageDirectory = new File(mmtlStageSessionRoot, 'gradle-loader/minecraft-artifacts').canonicalFile
                if (!mmtlStageDirectory.toPath().startsWith(mmtlStageSessionRoot.toPath())) { throw new GradleException('MMTL_LITELOADER_PINNED_DOWNLOAD_STAGE_OUTSIDE_SESSION') }
                if (!mmtlStageDirectory.mkdirs() && !mmtlStageDirectory.isDirectory()) { throw new GradleException('MMTL_LITELOADER_PINNED_DOWNLOAD_STAGE_DIRECTORY_FAILED') }
                if (java.nio.file.Files.isSymbolicLink(mmtlStageDirectory.toPath()) || java.nio.file.Files.isSymbolicLink(mmtlArtifactFile.toPath())) { throw new GradleException('MMTL_LITELOADER_PINNED_DOWNLOAD_STAGE_REPARSE') }
                File mmtlStagedArtifact = new File(mmtlStageDirectory, mmtlArtifactName.toLowerCase() + '-' + mmtlLiteLoaderConfig.minecraftId + '.jar').canonicalFile
                if (!mmtlStagedArtifact.toPath().startsWith(mmtlStageSessionRoot.toPath())) { throw new GradleException('MMTL_LITELOADER_PINNED_DOWNLOAD_STAGE_OUTSIDE_SESSION') }
                try {
                    java.nio.file.Files.copy(mmtlArtifactFile.toPath(), mmtlStagedArtifact.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
                    byte[] mmtlStagedBytes = java.nio.file.Files.readAllBytes(mmtlStagedArtifact.toPath())
                    byte[] mmtlStagedDigest = java.security.MessageDigest.getInstance('SHA-1').digest(mmtlStagedBytes)
                    String mmtlStagedSha1 = mmtlStagedDigest.collect { String.format('%02x', it & 0xff) }.join()
                    if (mmtlStagedBytes.length != mmtlPin.bytes || mmtlStagedSha1 != mmtlPin.sha1) { throw new GradleException('MMTL_LITELOADER_PINNED_DOWNLOAD_STAGE_HASH_MISMATCH') }
                } catch (Exception mmtlStageError) {
                    throw new GradleException('MMTL_LITELOADER_PINNED_DOWNLOAD_STAGE_FAILED:' + mmtlArtifactName, mmtlStageError)
                }
            }
        }
    }
    mmtlConfigurePinnedDownload('getVersionJson', mmtlLiteLoaderConfig.versionMetadata, 'VERSION_METADATA', true)
    mmtlConfigurePinnedDownload('getAssetsIndex', mmtlLiteLoaderConfig.assetIndex, 'ASSET_INDEX', true)
    def mmtlStartGenerationTask = gradle.rootProject.tasks.findByName('makeStart')
    if (mmtlStartGenerationTask == null) { throw new GradleException('MMTL_LITELOADER_START_GENERATION_TASK_MISSING') }
    def mmtlBounceSources = [[
        fileName: 'GradleStart.java',
        unsupportedBounce: 'return "com.mumfrey.liteloader.debug.Start";',
        standardBounce: 'return "net.minecraft.launchwrapper.Launch";',
        unsupportedCode: 'MMTL_LITELOADER_BOUNCE_CLASS_UNSUPPORTED'
    ]]
    if (mmtlLiteLoaderConfig.taskName == 'runServer') {
        mmtlBounceSources.add([
            fileName: 'GradleStartServer.java',
            unsupportedBounce: 'return "net.minecraft.server.MinecraftServer";',
            standardBounce: 'return "net.minecraft.launchwrapper.Launch";',
            unsupportedCode: 'MMTL_LITELOADER_SERVER_BOUNCE_CLASS_UNSUPPORTED'
        ])
    }
    File mmtlSessionRoot = new File(mmtlLiteLoaderConfig.sessionPath).canonicalFile
    File mmtlPatchedStartDirectory = new File(mmtlSessionRoot, 'gradle-loader/patched-start').canonicalFile
    if (!mmtlPatchedStartDirectory.toPath().startsWith(mmtlSessionRoot.toPath())) { throw new GradleException('MMTL_LITELOADER_PATCHED_START_OUTSIDE_SESSION') }
    def mmtlLaunchTask = null
    def mmtlLaunchCompileClasspath = null
    mmtlStartGenerationTask.outputs.upToDateWhen {
        File mmtlBuildRoot = gradle.rootProject.buildDir.canonicalFile
        return mmtlBounceSources.every { mmtlBounceSource ->
            File mmtlGeneratedSource = new File(gradle.rootProject.projectDir, 'build/tmp/makeStart/extracted/' + mmtlBounceSource.fileName).canonicalFile
            if (!mmtlGeneratedSource.toPath().startsWith(mmtlBuildRoot.toPath()) || !mmtlGeneratedSource.isFile() || java.nio.file.Files.isSymbolicLink(mmtlGeneratedSource.toPath())) { return false }
            File mmtlCompiledClass = new File(mmtlPatchedStartDirectory, mmtlBounceSource.fileName.replace('.java', '.class'))
            if (!mmtlCompiledClass.isFile() || java.nio.file.Files.isSymbolicLink(mmtlCompiledClass.toPath())) { return false }
            String mmtlSourceText = new String(java.nio.file.Files.readAllBytes(mmtlGeneratedSource.toPath()), java.nio.charset.StandardCharsets.UTF_8)
            return !mmtlSourceText.contains(mmtlBounceSource.unsupportedBounce) && mmtlSourceText.contains(mmtlBounceSource.standardBounce)
        }
    }
    mmtlStartGenerationTask.doLast {
        File mmtlBuildRoot = gradle.rootProject.buildDir.canonicalFile
        mmtlBounceSources.each { mmtlBounceSource ->
            File mmtlGeneratedSource = new File(gradle.rootProject.projectDir, 'build/tmp/makeStart/extracted/' + mmtlBounceSource.fileName).canonicalFile
            if (!mmtlGeneratedSource.toPath().startsWith(mmtlBuildRoot.toPath()) || !mmtlGeneratedSource.isFile()) {
                throw new GradleException('MMTL_LITELOADER_START_SOURCE_OUTSIDE_BUILD_OR_MISSING:' + mmtlBounceSource.fileName)
            }
            if (java.nio.file.Files.isSymbolicLink(mmtlGeneratedSource.toPath())) {
                throw new GradleException('MMTL_LITELOADER_START_SOURCE_REPARSE:' + mmtlBounceSource.fileName)
            }
            String mmtlSourceText = new String(java.nio.file.Files.readAllBytes(mmtlGeneratedSource.toPath()), java.nio.charset.StandardCharsets.UTF_8)
            int mmtlUnsupportedBounceCount = mmtlSourceText.count(mmtlBounceSource.unsupportedBounce)
            if (mmtlUnsupportedBounceCount == 1) {
                mmtlSourceText = mmtlSourceText.replace(mmtlBounceSource.unsupportedBounce, mmtlBounceSource.standardBounce)
                java.nio.file.Files.write(mmtlGeneratedSource.toPath(), mmtlSourceText.getBytes(java.nio.charset.StandardCharsets.UTF_8))
            } else if (mmtlUnsupportedBounceCount != 0 || !mmtlSourceText.contains(mmtlBounceSource.standardBounce)) {
                throw new GradleException(mmtlBounceSource.unsupportedCode)
            }
        }
        if (mmtlLaunchTask == null || mmtlLaunchCompileClasspath == null) { throw new GradleException('MMTL_LITELOADER_LAUNCH_TASK_MISSING_FOR_COMPILE') }
        if (!mmtlPatchedStartDirectory.mkdirs() && !mmtlPatchedStartDirectory.isDirectory()) { throw new GradleException('MMTL_LITELOADER_PATCHED_START_DIRECTORY_CREATE_FAILED') }
        if (java.nio.file.Files.isSymbolicLink(mmtlPatchedStartDirectory.toPath())) { throw new GradleException('MMTL_LITELOADER_PATCHED_START_DIRECTORY_REPARSE') }
        javax.tools.JavaCompiler mmtlCompiler = javax.tools.ToolProvider.getSystemJavaCompiler()
        if (mmtlCompiler == null) { throw new GradleException('MMTL_LITELOADER_JAVA_COMPILER_UNAVAILABLE') }
        def mmtlDiagnostics = new javax.tools.DiagnosticCollector<javax.tools.JavaFileObject>()
        def mmtlFileManager = mmtlCompiler.getStandardFileManager(mmtlDiagnostics, null, java.nio.charset.StandardCharsets.UTF_8)
        try {
            def mmtlCompilationUnits = mmtlFileManager.getJavaFileObjectsFromFiles(mmtlBounceSources.collect { new File(gradle.rootProject.projectDir, 'build/tmp/makeStart/extracted/' + it.fileName).canonicalFile })
            def mmtlCompileOptions = ['-classpath', mmtlLaunchCompileClasspath, '-d', mmtlPatchedStartDirectory.path]
            boolean mmtlCompiled = mmtlCompiler.getTask(null, mmtlFileManager, mmtlDiagnostics, mmtlCompileOptions, null, mmtlCompilationUnits).call()
            if (!mmtlCompiled) {
                String mmtlDiagnosticText = mmtlDiagnostics.diagnostics.collect { it.toString() }.join(' | ')
                throw new GradleException('MMTL_LITELOADER_START_COMPILATION_FAILED:' + mmtlDiagnosticText)
            }
        } finally {
            mmtlFileManager.close()
        }
    }
    ['client','server'].each { mmtlArtifactName ->
        mmtlConfigurePinnedDownload('download' + mmtlArtifactName.capitalize(), mmtlLiteLoaderConfig[mmtlArtifactName + 'Artifact'], mmtlArtifactName.toUpperCase(), false)
    }
    gradle.rootProject.allprojects.each { mmtlProject ->
        def mmtlTask = mmtlProject.tasks.findByName(mmtlLiteLoaderConfig.taskName)
        if (mmtlTask != null) {
            if (!(mmtlTask instanceof org.gradle.api.tasks.JavaExec)) {
                throw new GradleException('MMTL_LITELOADER_TASK_UNSUPPORTED:' + mmtlTask.path)
            }
            mmtlLaunchTask = mmtlTask
            mmtlLaunchCompileClasspath = mmtlTask.classpath.asPath
            def mmtlRuntimeClasspath = mmtlProject.files(mmtlPatchedStartDirectory) + mmtlProject.files(mmtlLiteLoaderConfig.classpath)
            if (mmtlLiteLoaderConfig.taskName == 'runClient') {
                File mmtlSessionRootForClient = new File(mmtlLiteLoaderConfig.sessionPath).canonicalFile
                File mmtlSessionClientArtifact = new File(mmtlSessionRootForClient, 'gradle-loader/minecraft-artifacts/client-' + mmtlLiteLoaderConfig.minecraftId + '.jar').canonicalFile
                if (!mmtlSessionClientArtifact.toPath().startsWith(mmtlSessionRootForClient.toPath())) { throw new GradleException('MMTL_LITELOADER_CLIENT_ARTIFACT_OUTSIDE_SESSION') }
                if (!mmtlSessionClientArtifact.isFile() || java.nio.file.Files.isSymbolicLink(mmtlSessionClientArtifact.toPath()) || mmtlSessionClientArtifact.length() != mmtlLiteLoaderConfig.clientArtifact.bytes) { throw new GradleException('MMTL_LITELOADER_CLIENT_SESSION_ARTIFACT_INVALID') }
                byte[] mmtlClientDigest = java.security.MessageDigest.getInstance('SHA-1').digest(java.nio.file.Files.readAllBytes(mmtlSessionClientArtifact.toPath()))
                String mmtlClientSha1 = mmtlClientDigest.collect { String.format('%02x', it & 0xff) }.join()
                if (mmtlClientSha1 != mmtlLiteLoaderConfig.clientArtifact.sha1) { throw new GradleException('MMTL_LITELOADER_CLIENT_SESSION_ARTIFACT_INVALID') }
                mmtlRuntimeClasspath += mmtlProject.files(mmtlSessionClientArtifact)
            }
            mmtlTask.classpath = mmtlRuntimeClasspath + mmtlTask.classpath
            // Preserve the Loader/ForgeGradle-specific bootstrap main class. It configures
            // the deobfuscated game classpath and native library path before LaunchWrapper.
            def mmtlArgs = new ArrayList(mmtlTask.args ?: [])
            def mmtlLiteLoaderTweakerPresent = false
            for (int mmtlArgIndex = 0; mmtlArgIndex < mmtlArgs.size(); mmtlArgIndex++) {
                if (mmtlArgs[mmtlArgIndex] == '--tweakClass') {
                    if (mmtlArgIndex + 1 >= mmtlArgs.size()) {
                        throw new GradleException('MMTL_LITELOADER_TWEAK_CLASS_ARGUMENT_MISSING:' + mmtlTask.path)
                    }
                    if (mmtlArgs[mmtlArgIndex + 1] == mmtlLiteLoaderConfig.tweakClass) {
                        mmtlLiteLoaderTweakerPresent = true
                    }
                }
            }
            if (!mmtlLiteLoaderTweakerPresent) {
                mmtlArgs.add('--tweakClass')
                mmtlArgs.add(mmtlLiteLoaderConfig.tweakClass)
            }
            mmtlTask.setArgs(mmtlArgs)
        }
    }
}
"@
}

Export-ModuleMember -Function New-MmtlLiteLoaderRunInitScript
