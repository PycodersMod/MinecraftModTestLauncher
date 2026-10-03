Set-StrictMode -Version Latest

$script:DeepLevels = @('CATALOGUED', 'RESOLVED', 'BUILD_VERIFIED', 'SERVER_VERIFIED', 'CLIENT_LAUNCH_VERIFIED', 'INTEGRATION_VERIFIED')
$script:FailureCodes = @(
    'RESOLVE_FAILED', 'BUILD_FAILED_PROJECT_SOURCE', 'BUILD_FAILED_MMTL', 'BUILD_FAILED_TOOLCHAIN',
    'BUILD_FAILED_NETWORK', 'BUILD_TIMEOUT', 'BUILD_JAVA_UNAVAILABLE', 'RUNTIME_JAVA_UNAVAILABLE',
    'SERVER_EULA_REQUIRED', 'SERVER_READY_TIMEOUT', 'CLIENT_AUTH_REQUIRED', 'CLIENT_LAUNCH_TIMEOUT',
    'CLIENT_CRASH', 'UPSTREAM_UNAVAILABLE', 'PLATFORM_UNSUPPORTED', 'UNTRUSTED_FIXTURE_REJECTED',
    'ARTIFACT_MISSING', 'EVIDENCE_INVALID'
)

function Get-MmtlDeepValidationLevels {
    [CmdletBinding()]
    param()
    return @($script:DeepLevels)
}

function Get-MmtlValidationFailureCodes {
    [CmdletBinding()]
    param()
    return @($script:FailureCodes)
}

function Test-MmtlAdvancedValidationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('SERVER_VERIFIED', 'CLIENT_LAUNCH_VERIFIED', 'INTEGRATION_VERIFIED')][string]$Level,
        [Parameter(Mandatory)]$Validation
    )

    $valid = $false
    $reason = $null
    $message = $null
    switch ($Level) {
        'SERVER_VERIFIED' {
            $server = if ($Validation.PSObject.Properties['serverEvidence']) { $Validation.serverEvidence } elseif ($Validation.PSObject.Properties['marker'] -and $Validation.PSObject.Properties['process'] -and $Validation.marker -and $Validation.process) {
                [pscustomobject]@{readyMarkerMatched=($Validation.marker.kind -eq 'serverReady' -and $Validation.marker.matched);readyMarker=$Validation.marker.text;processIdentityMatched=$Validation.process.identityMatched;portListening=$Validation.process.portListening;stopMethod=$Validation.stopMethod;processExited=$Validation.process.exited;portReleased=$Validation.process.portReleased}
            } else { $null }
            $valid = $server -and
                $server.readyMarkerMatched -eq $true -and
                -not [string]::IsNullOrWhiteSpace([string]$server.readyMarker) -and
                $server.processIdentityMatched -eq $true -and
                $server.portListening -eq $true -and
                $server.stopMethod -in @('ConsoleStop', 'Terminate') -and
                $server.processExited -eq $true -and
                $server.portReleased -eq $true
            $reason = 'SERVER_VERIFIED_CLAIM_MISSING_EVIDENCE'
            $message = '服务端验证需要匹配就绪标记和进程，并确认端口正在监听、安全停止、进程退出且端口已释放。'
        }
        'CLIENT_LAUNCH_VERIFIED' {
            $client = if ($Validation.PSObject.Properties['clientEvidence']) { $Validation.clientEvidence } elseif ($Validation.PSObject.Properties['marker'] -and $Validation.PSObject.Properties['process'] -and $Validation.marker -and $Validation.process) {
                [pscustomobject]@{initializationMarkerMatched=($Validation.marker.kind -eq 'clientInitialized' -and $Validation.marker.matched);initializationMarker=$Validation.marker.text;processIdentityMatched=$Validation.process.identityMatched;liveAtMarker=$Validation.process.liveAtMarker}
            } else { $null }
            $valid = $client -and
                $client.initializationMarkerMatched -eq $true -and
                -not [string]::IsNullOrWhiteSpace([string]$client.initializationMarker) -and
                $client.processIdentityMatched -eq $true -and
                $client.liveAtMarker -eq $true
            $reason = 'CLIENT_LAUNCH_VERIFIED_CLAIM_MISSING_EVIDENCE'
            $message = '客户端验证需要真实的初始化标记，以及与之匹配且仍在运行的 Minecraft 进程。'
        }
        'INTEGRATION_VERIFIED' {
            $integration = if ($Validation.PSObject.Properties['integrationEvidence']) { $Validation.integrationEvidence } else { $null }
            $valid = $integration -and
                -not [string]::IsNullOrWhiteSpace([string]$integration.scenario) -and
                $integration.completed -eq $true -and
                [int]$integration.assertionsPassed -ge 1
            $reason = 'INTEGRATION_VERIFIED_CLAIM_MISSING_EVIDENCE'
            $message = '集成验证需要具名且已完成的场景，并至少有一项断言通过。'
        }
    }

    if ($valid) {
        return [pscustomobject]@{ valid = $true; reasonCode = $null; message = $null }
    }
    return [pscustomobject]@{ valid = $false; reasonCode = $reason; message = $message }
}

function New-MmtlValidationTargetId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MinecraftId,
        [Parameter(Mandatory)][string]$LoaderId,
        [Parameter(Mandatory)][string]$OS,
        [Parameter(Mandatory)][string]$Architecture,
        [int]$JavaMajor
    )
    $tuple = @($MinecraftId, $LoaderId, $OS, $Architecture)
    if ($JavaMajor -gt 0) { $tuple += "Java$JavaMajor" }
    $id = ($tuple -join '-').ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    return ($id -replace '-{2,}', '-').Trim('-')
}

Export-ModuleMember -Function Get-MmtlDeepValidationLevels, Get-MmtlValidationFailureCodes, Test-MmtlAdvancedValidationEvidence, New-MmtlValidationTargetId
