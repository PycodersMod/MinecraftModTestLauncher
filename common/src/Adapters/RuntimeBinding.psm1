Set-StrictMode -Version Latest

function New-MmtlRuntimeBindingEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AdapterId,
        [Parameter(Mandatory)][ValidateSet('Direct','SameAsBuildJvm','ToolchainManaged','Unsupported','Unknown')][string]$Mode,
        [AllowEmptyString()][string]$EvidenceSource = '',
        [ValidateSet('High','Medium','Low','Unknown')][string]$Confidence = 'Unknown',
        [bool]$RuntimeJavaControllable = $false,
        [bool]$RequiresBuildJvmMatch = $false,
        [string]$ProbeStrategy = '',
        [string]$ReasonCode = '',
        [string]$Notes = '',
        [AllowEmptyCollection()][object[]]$EvidenceDetails = @()
    )

    [pscustomobject][ordered]@{
        schemaVersion = 1
        adapterId = $AdapterId
        mode = $Mode
        evidenceSource = $EvidenceSource
        confidence = $Confidence
        runtimeJavaControllable = $RuntimeJavaControllable
        requiresBuildJvmMatch = $RequiresBuildJvmMatch
        probeStrategy = $ProbeStrategy
        reasonCode = $ReasonCode
        notes = $Notes
        evidenceDetails = @($EvidenceDetails)
        conflicts = @()
    }
}

function Resolve-MmtlRuntimeBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence)

    $items = @($Evidence)
    $selected = $null
    $reason = ''
    $conflicts = @()

    if ($items.Count -eq 0) {
        $reason = 'RUNTIME_BINDING_EVIDENCE_MISSING'
    } elseif (@($items | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.evidenceSource) }).Count -gt 0) {
        $reason = 'RUNTIME_BINDING_EVIDENCE_SOURCE_MISSING'
    } else {
        $modes = @($items | ForEach-Object { [string]$_.mode } | Select-Object -Unique)
        if ($modes.Count -ne 1) {
            $conflicts = $items
            $reason = 'RUNTIME_BINDING_EVIDENCE_CONFLICT'
        } else {
            $selected = $items[0]
            switch ([string]$selected.mode) {
                'Direct' {
                    if (-not $selected.runtimeJavaControllable) {
                        $reason = 'RUNTIME_BINDING_DIRECT_CONTROL_UNPROVEN'
                    } elseif (@($items | ForEach-Object { @($_.evidenceDetails) } | Where-Object { $_.task -and $_.taskType -eq 'JavaExec' -and $_.launcherSource }).Count -eq 0) {
                        $reason = 'RUNTIME_BINDING_DIRECT_EVIDENCE_MISSING'
                    }
                }
                'SameAsBuildJvm' {
                    if (@($items | Where-Object { -not $_.requiresBuildJvmMatch -or @($_.evidenceDetails).Count -eq 0 }).Count -gt 0) {
                        $reason = 'RUNTIME_BINDING_BUILD_JVM_MATCH_UNPROVEN'
                    }
                }
                { $_ -in 'ToolchainManaged','Unsupported' } {
                    if (@($items | Where-Object { @($_.evidenceDetails).Count -eq 0 }).Count -gt 0) {
                        $reason = 'RUNTIME_BINDING_EVIDENCE_DETAILS_MISSING'
                    }
                }
                default { }
            }
        }
    }

    if ($reason) {
        $mode = 'Unknown'
        $details = @($items | ForEach-Object { @($_.evidenceDetails) })
        $sources = @($items | ForEach-Object { [string]$_.evidenceSource } | Where-Object { $_ } | Select-Object -Unique)
        $confidence = 'Unknown'
        $adapterId = if ($items.Count -eq 1) { [string]$items[0].adapterId } else { 'Composite' }
        $controllable = $false
        $requiresMatch = $false
        $strategy = if ($items.Count) { [string]$items[0].probeStrategy } else { '' }
        $notes = ''
    } else {
        $mode = [string]$selected.mode
        $details = @($items | ForEach-Object { @($_.evidenceDetails) })
        $sources = @($items | ForEach-Object { [string]$_.evidenceSource } | Select-Object -Unique)
        $confidence = [string]$selected.confidence
        $adapterId = if ($items.Count -eq 1) { [string]$selected.adapterId } else { 'Composite' }
        $controllable = [bool]$selected.runtimeJavaControllable
        $requiresMatch = [bool]$selected.requiresBuildJvmMatch
        $strategy = [string]$selected.probeStrategy
        $notes = [string]$selected.notes
    }

    [pscustomobject][ordered]@{
        schemaVersion = 1
        adapterId = $adapterId
        mode = $mode
        evidenceSource = ($sources -join ';')
        confidence = $confidence
        runtimeJavaControllable = $controllable
        requiresBuildJvmMatch = $requiresMatch
        probeStrategy = $strategy
        reasonCode = if ($reason) { $reason } elseif ($selected.reasonCode) { [string]$selected.reasonCode } else { '' }
        notes = $notes
        evidenceDetails = @($details)
        conflicts = @($conflicts)
    }
}

Export-ModuleMember -Function New-MmtlRuntimeBindingEvidence,Resolve-MmtlRuntimeBinding
