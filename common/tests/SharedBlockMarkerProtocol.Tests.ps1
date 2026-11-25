BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:repoRoot 'src/Agent/AgentActions.psm1') -Force
}

Describe 'Signed shared block marker protocol' {
    It 'computes a stable state hash bound to session, dimension, marker, and coordinates' {
        $first = Get-MmtlSharedBlockMarkerStateHash -SessionId 'session_123' -MarkerId 'marker-01' -DimensionKey 'minecraft:overworld' -X 0 -Y 100 -Z 0
        $again = Get-MmtlSharedBlockMarkerStateHash -SessionId 'session_123' -MarkerId 'marker-01' -DimensionKey 'minecraft:overworld' -X 0 -Y 100 -Z 0
        $otherPosition = Get-MmtlSharedBlockMarkerStateHash -SessionId 'session_123' -MarkerId 'marker-01' -DimensionKey 'minecraft:overworld' -X 1 -Y 100 -Z 0

        $first | Should -Match '^[a-f0-9]{64}$'
        $again | Should -BeExactly $first
        $otherPosition | Should -Not -BeExactly $first
    }

    It 'rejects marker positions outside the managed world bounds' {
        { Get-MmtlSharedBlockMarkerStateHash -SessionId 'session_123' -MarkerId 'marker-01' -DimensionKey 'minecraft:overworld' -X 65 -Y 100 -Z 0 } | Should -Throw '*SCENARIO_SHARED_MARKER_COORDINATES_INVALID*'
    }
}
