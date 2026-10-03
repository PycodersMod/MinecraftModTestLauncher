BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Validation/Contracts.psm1') -Force
}

Describe 'Validation evidence level semantics' {
    It 'keeps all six levels distinct and failure codes enumerable' {
        Get-MmtlDeepValidationLevels | Should -Be @('CATALOGUED','RESOLVED','BUILD_VERIFIED','SERVER_VERIFIED','CLIENT_LAUNCH_VERIFIED','INTEGRATION_VERIFIED')
        Get-MmtlValidationFailureCodes | Should -Contain 'SERVER_READY_TIMEOUT'
        Get-MmtlValidationFailureCodes | Should -Contain 'CLIENT_AUTH_REQUIRED'
    }

    It 'requires ready marker, matching process, port, safe stop, process exit, and port release for server proof' {
        $valid=[pscustomobject]@{serverEvidence=[pscustomobject]@{readyMarker='Done (2.0s)!';readyMarkerMatched=$true;processIdentityMatched=$true;portListening=$true;stopMethod='ConsoleStop';processExited=$true;portReleased=$true}}
        (Test-MmtlAdvancedValidationEvidence -Level SERVER_VERIFIED -Validation $valid).valid | Should -BeTrue
        $valid.serverEvidence.portListening=$false
        (Test-MmtlAdvancedValidationEvidence -Level SERVER_VERIFIED -Validation $valid).reasonCode | Should -Be 'SERVER_VERIFIED_CLAIM_MISSING_EVIDENCE'
    }

    It 'requires a real client initialization marker and matching live process' {
        $validation=[pscustomobject]@{clientEvidence=[pscustomobject]@{initializationMarker='Minecraft main thread';initializationMarkerMatched=$true;processIdentityMatched=$true;liveAtMarker=$true}}
        (Test-MmtlAdvancedValidationEvidence -Level CLIENT_LAUNCH_VERIFIED -Validation $validation).valid | Should -BeTrue
        $validation.clientEvidence.initializationMarker=''
        (Test-MmtlAdvancedValidationEvidence -Level CLIENT_LAUNCH_VERIFIED -Validation $validation).valid | Should -BeFalse
    }

    It 'requires a named completed integration scenario with a passed assertion' {
        $validation=[pscustomobject]@{integrationEvidence=[pscustomobject]@{scenario='mod loads and responds to a fixture interaction';completed=$true;assertionsPassed=1}}
        (Test-MmtlAdvancedValidationEvidence -Level INTEGRATION_VERIFIED -Validation $validation).valid | Should -BeTrue
        $validation.integrationEvidence.assertionsPassed=0
        (Test-MmtlAdvancedValidationEvidence -Level INTEGRATION_VERIFIED -Validation $validation).valid | Should -BeFalse
    }

    It 'creates stable safe target IDs from the exact platform and Java tuple' {
        New-MmtlValidationTargetId -MinecraftId '1.20.1' -LoaderId 'NeoForge' -OS 'Windows' -Architecture 'x64' -JavaMajor 21 | Should -Be '1.20.1-neoforge-windows-x64-java21'
    }
}
