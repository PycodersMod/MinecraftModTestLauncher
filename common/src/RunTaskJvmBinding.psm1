Set-StrictMode -Version Latest

function New-MmtlRunTaskJvmBindingInitScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$RuntimeJavaMajor)

    if ($RuntimeJavaMajor -lt 1 -or $RuntimeJavaMajor -gt 100) { throw 'RUNTIME_JAVA_MAJOR_INVALID' }

    @'
def mmtlRuntimeJavaHome = System.getenv('MMTL_RUNTIME_JAVA_HOME')
def mmtlRuntimeJavaExecutable = System.getenv('MMTL_RUNTIME_JAVA_EXECUTABLE')
def mmtlRuntimeJavaMajor = Integer.parseInt(System.getenv('MMTL_RUNTIME_JAVA_MAJOR') ?: '0')
if (!mmtlRuntimeJavaHome || !mmtlRuntimeJavaExecutable || mmtlRuntimeJavaMajor < 1) {
    throw new GradleException('MMTL_RUNTIME_JAVA_BINDING_INPUT_INVALID')
}
def mmtlExpectedExecutable = new File(mmtlRuntimeJavaExecutable).canonicalFile
def mmtlRuntimeDirectoryValue = gradle.startParameter.projectProperties['pycodersRuntimeDir']
def mmtlRuntimeDirectory = mmtlRuntimeDirectoryValue ? new File(mmtlRuntimeDirectoryValue).canonicalFile : null
def mmtlRuntimeJvmArgumentPayload = gradle.startParameter.projectProperties['pycodersJavaArgsB64'] ?: ''
def mmtlRuntimeJvmArgs = []
if (mmtlRuntimeJvmArgumentPayload) {
    try {
        mmtlRuntimeJvmArgs = mmtlRuntimeJvmArgumentPayload.split(/\./, -1).collect { encodedArgument ->
            encodedArgument == '_' ? '' : new String(java.util.Base64.decoder.decode(encodedArgument), java.nio.charset.StandardCharsets.UTF_8)
        }
    } catch (IllegalArgumentException invalidPayload) {
        throw new GradleException('MMTL_RUN_JVM_ARGUMENTS_INVALID', invalidPayload)
    }
}
def mmtlRuntimeUsername = gradle.startParameter.projectProperties['pycodersUsername'] ?: ''
if (mmtlRuntimeUsername && !(mmtlRuntimeUsername ==~ /[A-Za-z0-9_]{1,16}/)) {
    throw new GradleException('MMTL_RUN_USERNAME_INVALID')
}
def mmtlRuntimeGameArgumentPayload = gradle.startParameter.projectProperties['pycodersGameArgsB64'] ?: ''
def mmtlRuntimeGameArgs = []
if (mmtlRuntimeGameArgumentPayload) {
    try {
        mmtlRuntimeGameArgs = mmtlRuntimeGameArgumentPayload.split(/\./, -1).collect { encodedArgument ->
            encodedArgument == '_' ? '' : new String(java.util.Base64.decoder.decode(encodedArgument), java.nio.charset.StandardCharsets.UTF_8)
        }
    } catch (IllegalArgumentException invalidPayload) {
        throw new GradleException('MMTL_RUN_GAME_ARGUMENTS_INVALID', invalidPayload)
    }
}
def mmtlReservedIdentityArguments = ['--username', '--uuid', '--accessToken', '--userType'] as Set
if (mmtlRuntimeGameArgs.any { argument -> mmtlReservedIdentityArguments.contains(argument) || mmtlReservedIdentityArguments.any { reserved -> argument.startsWith(reserved + '=') } }) {
    throw new GradleException('MMTL_RUN_GAME_IDENTITY_OVERRIDE_REJECTED')
}
if (mmtlRuntimeDirectory != null && !mmtlRuntimeDirectory.isDirectory()) {
    throw new GradleException('MMTL_RUNTIME_DIRECTORY_MISSING:' + mmtlRuntimeDirectory)
}
def mmtlTaskNames = ['runClient', 'runServer'] as Set
gradle.projectsEvaluated {
    gradle.rootProject.allprojects.each { mmtlProject ->
        def mmtlConfigureRuntimeTask = { mmtlTask ->
            def mmtlTaskName = mmtlTask.name
            if (mmtlTaskName in mmtlTaskNames) {
            if (!(mmtlTask instanceof org.gradle.api.tasks.JavaExec)) {
                throw new GradleException('MMTL_RUNTIME_LAUNCHER_TASK_UNSUPPORTED:' + mmtlTask.path)
            }
            if (!mmtlRuntimeJvmArgs.isEmpty()) {
                mmtlTask.jvmArgs(mmtlRuntimeJvmArgs)
            }
            if (mmtlTaskName == 'runClient') {
                def mmtlEffectiveGameArgs = new ArrayList(mmtlTask.args ?: [])
                for (int mmtlIndex = mmtlEffectiveGameArgs.size() - 1; mmtlIndex >= 0; mmtlIndex--) {
                    def mmtlArgument = mmtlEffectiveGameArgs[mmtlIndex]?.toString() ?: ''
                    if (mmtlArgument == '--username') {
                        mmtlEffectiveGameArgs.remove(mmtlIndex)
                        if (mmtlIndex < mmtlEffectiveGameArgs.size()) {
                            mmtlEffectiveGameArgs.remove(mmtlIndex)
                        }
                    } else if (mmtlArgument.startsWith('--username=')) {
                        mmtlEffectiveGameArgs.remove(mmtlIndex)
                    }
                }
                if (mmtlRuntimeUsername) {
                    mmtlEffectiveGameArgs.add('--username')
                    mmtlEffectiveGameArgs.add(mmtlRuntimeUsername)
                }
                mmtlEffectiveGameArgs.addAll(mmtlRuntimeGameArgs)
                mmtlTask.setArgs(mmtlEffectiveGameArgs)
            }
            if (mmtlRuntimeDirectory != null) {
                def mmtlLoomExtension = mmtlProject.extensions.findByName('loom')
                def mmtlRunContainer = mmtlLoomExtension != null && mmtlLoomExtension.hasProperty('runs') ? mmtlLoomExtension.runs : null
                if (mmtlRunContainer != null) {
                    def mmtlRunName = mmtlTaskName == 'runServer' ? 'server' : 'client'
                    def mmtlRunConfiguration = mmtlRunContainer.findByName(mmtlRunName)
                    if (mmtlRunConfiguration != null) {
                        if (mmtlRunConfiguration.hasProperty('runDirectory')) {
                            mmtlRunConfiguration.runDirectory = mmtlRuntimeDirectory
                        } else if (mmtlRunConfiguration.hasProperty('runDir')) {
                            mmtlRunConfiguration.runDir = mmtlRuntimeDirectory.absolutePath
                        }
                    }
                }
                mmtlTask.workingDir = mmtlRuntimeDirectory
            }
            def mmtlToolchains = mmtlProject.extensions.findByName('javaToolchains')
            if (mmtlTask.hasProperty('javaLauncher') && mmtlToolchains != null) {
                def mmtlLauncherProvider = mmtlToolchains.launcherFor {
                    languageVersion = org.gradle.jvm.toolchain.JavaLanguageVersion.of(mmtlRuntimeJavaMajor)
                }
                mmtlTask.javaLauncher.set(mmtlLauncherProvider)
                mmtlTask.doFirst {
                    def mmtlActualExecutable = mmtlTask.javaLauncher.get().executablePath.asFile.canonicalFile
                    if (mmtlActualExecutable != mmtlExpectedExecutable) {
                        throw new GradleException('MMTL_RUNTIME_LAUNCHER_MISMATCH:' + mmtlActualExecutable)
                    }
                    println('MMTL_RUNTIME_LAUNCHER_JSON:' + groovy.json.JsonOutput.toJson([task:mmtlTask.path, javaExecutable:mmtlActualExecutable.absolutePath, javaMajor:mmtlRuntimeJavaMajor, binding:'javaLauncher']))
                }
            } else {
                mmtlTask.setExecutable(mmtlExpectedExecutable.absolutePath)
                mmtlTask.doFirst {
                    def mmtlActualExecutable = new File(mmtlTask.executable).canonicalFile
                    if (mmtlActualExecutable != mmtlExpectedExecutable) {
                        throw new GradleException('MMTL_RUNTIME_LAUNCHER_MISMATCH:' + mmtlActualExecutable)
                    }
                    println('MMTL_RUNTIME_LAUNCHER_JSON:' + groovy.json.JsonOutput.toJson([task:mmtlTask.path, javaExecutable:mmtlActualExecutable.absolutePath, javaMajor:mmtlRuntimeJavaMajor, binding:'executable']))
                }
            }
            }
        }
        def mmtlGradleVersion = org.gradle.util.GradleVersion.current()
        if (mmtlGradleVersion >= org.gradle.util.GradleVersion.version('4.9')) {
            mmtlProject.tasks.configureEach(mmtlConfigureRuntimeTask)
        } else {
            mmtlProject.tasks.all(mmtlConfigureRuntimeTask)
        }
    }
}
'@
}

function Get-MmtlRunTaskJvmBindingSourceFingerprint {
    [CmdletBinding()]
    param()
    $repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $relativePaths=@('common/src/RuntimeBindingProbe.psm1','common/src/RunTaskJvmBinding.psm1')
    $sources=[Collections.Generic.List[object]]::new()
    foreach($relativePath in $relativePaths){
        $sourcePath=Join-Path $repositoryRoot ($relativePath.Replace('/',[IO.Path]::DirectorySeparatorChar))
        if(-not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw "RUNTIME_BINDING_SOURCE_MISSING:$relativePath"}
        $hash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $sources.Add([pscustomobject][ordered]@{path=$relativePath;sha256=$hash})
    }
    $canonical=(($sources|ForEach-Object{"$($_.path):$($_.sha256)"}) -join "`n")+"`n"
    $fingerprint=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
    [pscustomobject][ordered]@{sha256=$fingerprint;sources=@($sources.ToArray())}
}

Export-ModuleMember -Function New-MmtlRunTaskJvmBindingInitScript,Get-MmtlRunTaskJvmBindingSourceFingerprint
