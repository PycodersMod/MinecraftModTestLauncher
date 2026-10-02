Set-StrictMode -Version Latest

$script:MmtlBuildJavaFallbackRegistry=@(
    [pscustomobject]@{pattern='^1\.(?:[0-9]|1[0-6])(?:\.|$)';major=8;reason='Legacy Minecraft build compatibility fallback; exact project requirement remains authoritative.'}
    [pscustomobject]@{pattern='^1\.17(?:\.|$)';major=16;reason='Minecraft 1.17 era fallback; verify against the actual Gradle toolchain.'}
    [pscustomobject]@{pattern='^1\.(?:18|19|20)(?:\.|$)';major=17;reason='Minecraft 1.18–1.20 compatibility fallback; verify against the actual Gradle toolchain.'}
    [pscustomobject]@{pattern='^(?:1\.(?:20\.(?:[5-9]|[1-9][0-9]+)|2[1-9](?:\.|$))|[2-9][0-9]*\.)';major=21;reason='Minecraft 1.20.5+ compatibility fallback; verify against the actual Gradle toolchain.'}
)

function Get-MmtlBuildJavaCompatibilityFallback {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId)
    foreach($rule in $script:MmtlBuildJavaFallbackRegistry){if($MinecraftId -match $rule.pattern){return [pscustomobject]@{major=$rule.major;source='BuildJavaCompatibilityFallbackRegistry';confidence='Low';requirementKind='CompatibilityFallback';reason=$rule.reason}}}
    [pscustomobject]@{major=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';reason='No compatibility fallback rule matches this Minecraft version.'}
}

function Get-MmtlGradleWrapperRuntimeJavaRequirement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path=Join-Path $ProjectRoot 'gradle/wrapper/gradle-wrapper.properties'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{major=$null;source='Unknown';confidence='Unknown';gradleVersion=$null;reason='Gradle wrapper properties are unavailable.'}}
    $content=Get-Content -LiteralPath $path -Raw
    $match=[regex]::Match($content,'(?im)^\s*distributionUrl\s*=\s*.*?/gradle-([0-9]+)\.([0-9]+)(?:\.([0-9]+))?-(?:bin|all)\.zip')
    if(-not $match.Success){return [pscustomobject]@{major=$null;source='Unknown';confidence='Unknown';gradleVersion=$null;reason='Gradle wrapper distribution version is not recognized.'}}
    $gradleMajor=[int]$match.Groups[1].Value;$gradleMinor=[int]$match.Groups[2].Value;$gradleVersion="$gradleMajor.$gradleMinor"
    $minimum=if($gradleMajor -ge 9){17}elseif($gradleMajor -ge 5){8}elseif($gradleMajor -eq 4 -and $gradleMinor -ge 3){7}else{$null}
    [pscustomobject]@{major=$minimum;source=if($minimum){'GradleWrapperRuntimeCompatibility'}else{'Unknown'};confidence=if($minimum){'High'}else{'Unknown'};gradleVersion=$gradleVersion;reason=if($minimum -eq 17){'Gradle 9 requires JVM 17 or later.'}elseif($minimum -eq 8){'Gradle 5 and later require JVM 8 or later.'}elseif($minimum -eq 7){'Gradle 4.3 supports execution on JVM 7 or later.'}else{'No minimum JVM rule is recorded for this wrapper version.'};provenance=if($minimum){'https://docs.gradle.org/current/userguide/compatibility.html'}else{$null}}
}

Export-ModuleMember -Function Get-MmtlBuildJavaCompatibilityFallback,Get-MmtlGradleWrapperRuntimeJavaRequirement
