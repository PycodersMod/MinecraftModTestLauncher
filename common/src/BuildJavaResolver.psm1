Set-StrictMode -Version Latest

$script:MmtlBuildJavaFallbackRegistry=@(
    [pscustomobject]@{pattern='^1\.(?:[0-9]|1[0-6])(?:\.|$)';major=8;reason='旧版 Minecraft 构建兼容性回退值；项目的明确要求优先。'}
    [pscustomobject]@{pattern='^1\.17(?:\.|$)';major=16;reason='Minecraft 1.17 时期的回退值；请根据实际 Gradle 工具链核实。'}
    [pscustomobject]@{pattern='^1\.(?:18|19|20)(?:\.|$)';major=17;reason='Minecraft 1.18–1.20 兼容性回退值；请根据实际 Gradle 工具链核实。'}
    [pscustomobject]@{pattern='^(?:1\.(?:20\.(?:[5-9]|[1-9][0-9]+)|2[1-9](?:\.|$))|[2-9][0-9]*\.)';major=21;reason='Minecraft 1.20.5 及更新版本的兼容性回退值；请根据实际 Gradle 工具链核实。'}
)

function Get-MmtlBuildJavaCompatibilityFallback {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MinecraftId)
    foreach($rule in $script:MmtlBuildJavaFallbackRegistry){if($MinecraftId -match $rule.pattern){return [pscustomobject]@{major=$rule.major;preferredMajor=$rule.major;minimumMajor=$null;exactMajor=$null;source='BuildJavaCompatibilityFallbackRegistry';confidence='Low';requirementKind='Preferred';basisKind='CompatibilityFallback';reason=$rule.reason}}}
    [pscustomobject]@{major=$null;preferredMajor=$null;minimumMajor=$null;exactMajor=$null;source='Unknown';confidence='Unknown';requirementKind='Unknown';basisKind='Unknown';reason='没有兼容性回退规则匹配此 Minecraft 版本。'}
}

function Get-MmtlGradleWrapperRuntimeJavaRequirement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $path=Join-Path $ProjectRoot 'gradle/wrapper/gradle-wrapper.properties'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [pscustomobject]@{major=$null;source='Unknown';confidence='Unknown';gradleVersion=$null;reason='Gradle Wrapper 属性文件不可用。'}}
    $content=Get-Content -LiteralPath $path -Raw
    $match=[regex]::Match($content,'(?im)^\s*distributionUrl\s*=\s*.*?/gradle-([0-9]+)\.([0-9]+)(?:\.([0-9]+))?-(?:bin|all)\.zip')
    if(-not $match.Success){return [pscustomobject]@{major=$null;source='Unknown';confidence='Unknown';gradleVersion=$null;reason='无法识别 Gradle Wrapper 发行版版本。'}}
    $gradleMajor=[int]$match.Groups[1].Value;$gradleMinor=[int]$match.Groups[2].Value;$gradleVersion="$gradleMajor.$gradleMinor"
    $minimum=if($gradleMajor -ge 9){17}elseif($gradleMajor -ge 5){8}elseif($gradleMajor -eq 4 -and $gradleMinor -ge 3){7}else{$null}
    [pscustomobject]@{major=$minimum;minimumMajor=$minimum;preferredMajor=$null;exactMajor=$null;requirementKind=if($minimum){'Minimum'}else{'Unknown'};source=if($minimum){'GradleWrapperRuntimeCompatibility'}else{'Unknown'};confidence=if($minimum){'High'}else{'Unknown'};gradleVersion=$gradleVersion;reason=if($minimum -eq 17){'Gradle 9 需要 JVM 17 或更高版本。'}elseif($minimum -eq 8){'Gradle 5 及更新版本需要 JVM 8 或更高版本。'}elseif($minimum -eq 7){'Gradle 4.3 支持在 JVM 7 或更高版本上运行。'}else{'此 Wrapper 版本未记录最低 JVM 要求。'};provenance=if($minimum){'https://docs.gradle.org/current/userguide/compatibility.html'}else{$null}}
}

Export-ModuleMember -Function Get-MmtlBuildJavaCompatibilityFallback,Get-MmtlGradleWrapperRuntimeJavaRequirement
