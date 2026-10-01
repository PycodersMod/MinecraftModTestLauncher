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

Export-ModuleMember -Function Get-MmtlBuildJavaCompatibilityFallback
