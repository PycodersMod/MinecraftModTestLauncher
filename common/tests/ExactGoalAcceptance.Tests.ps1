$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repositoryRoot 'common/src/Compatibility/ExactGoalAcceptance.psm1'
if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force }

Describe 'Test-MmtlExactGoalAcceptance' {
    It 'keeps Build and ClientLaunch-only reports PARTIAL when multiplayer evidence is missing' {
        $universeHash = 'a' * 64
        $targetSpecHash = 'b' * 64
        $buildHash = 'c' * 64
        $launchHash = 'd' * 64
        $target = [pscustomobject]@{
            targetId = 'Fabric@1.21.11'
            loaderId = 'Fabric'
            minecraftId = '1.21.11'
            loaderVersionCandidates = @('0.19.5')
            availability = 'Available'
            sourceHash = 'e' * 64
        }
        $universe = [pscustomobject]@{ schemaVersion = 1; catalogHash = $universeHash; targets = @($target) }
        $evidenceIndex = [pscustomobject]@{
            schemaVersion = 1
            universeHash = $universeHash
            entries = @(
                [pscustomobject]@{ targetId = $target.targetId; dimension = 'BuildVerified'; targetSpecHash = $targetSpecHash; evidencePath = 'build/Fabric-1.21.11.json'; evidenceSha256 = $buildHash }
                [pscustomobject]@{ targetId = $target.targetId; dimension = 'LaunchCheck'; targetSpecHash = $targetSpecHash; evidencePath = 'launch/Fabric-1.21.11.json'; evidenceSha256 = $launchHash }
            )
        }
        $targetReport = [pscustomobject]@{
            targetId = $target.targetId
            runId = 'current-goal-run'
            loaderVersion = '0.19.5'
            freshExecution = $true
            scenarioConfiguration = [pscustomobject]@{ effective = [pscustomobject]@{ clientCount = 1; transport = 'None' } }
            compatibilityIdentity = [pscustomobject]@{
                targetId = $target.targetId
                universeHash = $universeHash
                sourceHash = $target.sourceHash
                toolchainHash = 'f' * 64
                targetSpecHash = $targetSpecHash
            }
            stageResults = @(
                [pscustomobject]@{ dimension = 'BuildExact'; status = 'PASS'; evidenceRefs = @('build/Fabric-1.21.11.json'); evidenceSha256 = @($buildHash); freshExecution = $true }
                [pscustomobject]@{ dimension = 'ClientLaunch'; status = 'PASS'; evidenceRefs = @('launch/Fabric-1.21.11.json'); evidenceSha256 = @($launchHash); freshExecution = $true }
            )
            overallResult = 'PARTIAL'
        }

        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'

        $result.goalVerdict | Should -Be 'PARTIAL'
        $result.multiplayerPass | Should -Be 0
        $result.targetDimensionResults[0].dimensions.Multiplayer | Should -BeExactly 'NotRequested'
        $result.targetDimensionResults[0].clientCount | Should -Be 1
        $result.targetDimensionResults[0].dimensions.SafeStop | Should -BeExactly 'Missing'
        $result.dimensionStatusCounts.SafeStop.missing | Should -Be 1
        $result.fullTargetPassUnique | Should -Be 0
        $result.reasons | Should -Contain 'FULL_GOAL_CLIENT_COUNT_MUST_BE_TWO'
        $result.reasons | Should -Contain 'REQUIRED_MULTIPLAYER_EVIDENCE_MISSING'
        $result.reasons | Should -Contain 'TARGET_REPORT_IDENTITY_INVALID'
    }

    It 'reports tampered evidence hashes as invalid references' {
        $universeHash = 'a' * 64
        $targetSpecHash = 'b' * 64
        $buildHash = 'c' * 64
        $launchHash = 'd' * 64
        $target = [pscustomobject]@{
            targetId = 'Fabric@1.21.11'; sourceHash = 'e' * 64
            loaderId = 'Fabric'; minecraftId = '1.21.11'; loaderVersionCandidates = @('0.19.5')
        }
        $universe = [pscustomobject]@{ catalogHash = $universeHash; targets = @($target) }
        $evidenceIndex = [pscustomobject]@{
            universeHash = $universeHash
            entries = @(
                [pscustomobject]@{ targetId = $target.targetId; dimension = 'BuildVerified'; targetSpecHash = $targetSpecHash; evidencePath = 'build/result.json'; evidenceSha256 = $buildHash }
                [pscustomobject]@{ targetId = $target.targetId; dimension = 'LaunchCheck'; targetSpecHash = $targetSpecHash; evidencePath = 'launch/result.json'; evidenceSha256 = $launchHash }
            )
        }
        $targetReport = [pscustomobject]@{
            targetId = $target.targetId; runId = 'current-goal-run'; loaderVersion = '0.19.5'; freshExecution = $true
            compatibilityIdentity = [pscustomobject]@{
                targetId = $target.targetId; universeHash = $universeHash; sourceHash = $target.sourceHash
                targetSpecHash = $targetSpecHash
            }
            stageResults = @(
                [pscustomobject]@{ dimension = 'BuildExact'; status = 'PASS'; evidenceRefs = @('build/result.json'); evidenceSha256 = @(('f' * 64)); freshExecution = $true }
                [pscustomobject]@{ dimension = 'ClientLaunch'; status = 'PASS'; evidenceRefs = @('launch/result.json'); evidenceSha256 = @($launchHash); freshExecution = $true }
            )
            overallResult = 'PARTIAL'
        }

        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'

        $result.goalVerdict | Should -Be 'PARTIAL'
        $result.invalidEvidenceRefs | Should -Contain 'Fabric@1.21.11/BuildExact:build/result.json'
        $result.reasons | Should -Contain 'INVALID_EVIDENCE_REFERENCES'
    }

    It 'never counts a modern release as HistoricalDedicatedEquivalent' {
        $universeHash = 'a' * 64
        $targetSpecHash = 'b' * 64
        $multiplayerHash = 'c' * 64
        $historicalHash = 'd' * 64
        $nativeLanHash = '9' * 64
        $adapterHash = '8' * 64
        $toolchainHash = '7' * 64
        $target = [pscustomobject]@{
            targetId = 'Fabric@1.21.11'; loaderId = 'Fabric'; minecraftId = '1.21.11'; minecraftType = 'release'
            loaderVersionCandidates = @('0.19.5'); sourceHash = 'e' * 64
        }
        $universe = [pscustomobject]@{ catalogHash = $universeHash; targets = @($target) }
        $evidenceIndex = [pscustomobject]@{
            universeHash = $universeHash
            entries = @(
                [pscustomobject]@{ targetId = $target.targetId; dimension = 'MultiplayerJoinAndAssertion'; targetSpecHash = $targetSpecHash; adapterSha256 = $adapterHash; toolchainHash = $toolchainHash; evidencePath = 'proof/multiplayer.json'; evidenceSha256 = $multiplayerHash }
                [pscustomobject]@{ targetId = $target.targetId; dimension = 'HistoricalDedicatedEquivalent'; targetSpecHash = $targetSpecHash; adapterSha256 = $adapterHash; toolchainHash = $toolchainHash; evidencePath = 'proof/historical.json'; evidenceSha256 = $historicalHash }
                [pscustomobject]@{ targetId = $target.targetId; dimension = 'NativeIntegratedLAN'; targetSpecHash = $targetSpecHash; adapterSha256 = $adapterHash; toolchainHash = $toolchainHash; evidencePath = 'proof/native-lan.json'; evidenceSha256 = $nativeLanHash }
            )
        }
        $proof = [pscustomobject]@{
            passed = $true; sharedWorldKey = 'world:session-1';
            actorA = [pscustomobject]@{ processId = 101; playerIdentity = 'player-a' }
            observerB = [pscustomobject]@{ processId = 202; playerIdentity = 'player-b' }
            actionProof = [pscustomobject]@{ processId = 101; stateSha256 = 'f' * 64; eventId = 'event-a' }
            observationProof = [pscustomobject]@{ processId = 202; stateSha256 = 'f' * 64; eventId = 'event-b' }
        }
        $targetReport = [pscustomobject]@{
            targetId = $target.targetId; loaderId = 'Fabric'; minecraftId = '1.21.11'; loaderVersion = '0.19.5'
            runId = 'current-goal-run'; freshExecution = $true; multiplayerPath = 'HistoricalDedicatedEquivalent'
            historicalPathEligibilityVerified = $true; worldProof = $proof
            capabilityRequirements = [pscustomobject]@{ agent = 'NotApplicable'; dedicatedServer = 'NotApplicable' }
            agentNotApplicableReason = 'This capability is not applicable for this target'
            agentApplicabilityEvidence = 'a narrative statement without an indexed evidence reference'
            dedicatedNotApplicableReason = 'Dedicated server is not required for this target'
            dedicatedApplicabilityEvidence = 'another narrative statement without an indexed evidence reference'
            compatibilityIdentity = [pscustomobject]@{ targetId = $target.targetId; universeHash = $universeHash; sourceHash = $target.sourceHash; targetSpecHash = $targetSpecHash; adapterSha256 = $adapterHash; toolchainHash = $toolchainHash }
            stageResults = @(
                [pscustomobject]@{ dimension = 'MultiplayerJoinAndAssertion'; status = 'PASS'; evidenceRefs = @('proof/multiplayer.json'); evidenceSha256 = @($multiplayerHash); freshExecution = $true }
                [pscustomobject]@{ dimension = 'HistoricalDedicatedEquivalent'; status = 'PASS'; evidenceRefs = @('proof/historical.json'); evidenceSha256 = @($historicalHash); freshExecution = $true }
                [pscustomobject]@{ dimension = 'NativeIntegratedLAN'; status = 'PASS'; evidenceRefs = @('proof/native-lan.json'); evidenceSha256 = @($nativeLanHash); freshExecution = $true }
            )
            overallResult = 'PARTIAL'
        }

        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'

        $result.multiplayerPass | Should -Be 0
        $result.historicalDedicatedEquivalentPass | Should -Be 0
        $result.nativeLanPass | Should -Be 0
        $result.reasons | Should -Contain 'MULTIPLAYER_PATH_EVIDENCE_CONFLICT'
        $result.targetDimensionResults[0].dimensions.IntegratedLanPublished | Should -BeExactly 'Failed'
        $result.agentAndDedicatedPass | Should -Be 0
    }

    It 'does not count report files unless their paths and hashes exist in the evidence index' {
        $universeHash = 'a' * 64
        $targetSpecHash = 'b' * 64
        $stageHash = 'c' * 64
        $jsonHash = 'd' * 64
        $markdownHash = 'e' * 64
        $adapterHash = '8' * 64
        $toolchainHash = '9' * 64
        $target = [pscustomobject]@{
            targetId = 'Fabric@1.21.11'; loaderId = 'Fabric'; minecraftId = '1.21.11'
            loaderVersionCandidates = @('0.19.5'); sourceHash = 'f' * 64
        }
        $universe = [pscustomobject]@{ catalogHash = $universeHash; targets = @($target) }
        $evidenceIndex = [pscustomobject]@{
            universeHash = $universeHash
            entries = @([pscustomobject]@{
                targetId = $target.targetId; dimension = 'TargetReport'; targetSpecHash = $targetSpecHash
                adapterSha256 = $adapterHash; toolchainHash = $toolchainHash
                evidencePath = 'evidence/report-stage.json'; evidenceSha256 = $stageHash
            })
        }
        $targetReport = [pscustomobject]@{
            targetId = $target.targetId; loaderId = 'Fabric'; minecraftId = '1.21.11'; loaderVersion = '0.19.5'
            runId = 'current-goal-run'; freshExecution = $true; overallResult = 'PARTIAL'
            compatibilityIdentity = [pscustomobject]@{ targetId = $target.targetId; universeHash = $universeHash; sourceHash = $target.sourceHash; targetSpecHash = $targetSpecHash; adapterSha256 = $adapterHash; toolchainHash = $toolchainHash }
            stageResults = @([pscustomobject]@{
                dimension = 'TargetReport'; status = 'PASS'; freshExecution = $true
                evidenceRefs = @('evidence/report-stage.json'); evidenceSha256 = @($stageHash)
            })
            reportProof = [pscustomobject]@{
                schemaValidated = $true; jsonRef = 'reports/Fabric-1.21.11.json'; markdownRef = 'reports/Fabric-1.21.11.md'
                jsonSha256 = $jsonHash; markdownSha256 = $markdownHash
            }
        }

        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'

        $result.targetReportPass | Should -Be 0

        $evidenceIndex.entries += @(
            [pscustomobject]@{ targetId = $target.targetId; dimension = 'TargetReport'; targetSpecHash = $targetSpecHash; adapterSha256 = $adapterHash; toolchainHash = $toolchainHash; evidencePath = 'reports/Fabric-1.21.11.json'; evidenceSha256 = $jsonHash }
            [pscustomobject]@{ targetId = $target.targetId; dimension = 'TargetReport'; targetSpecHash = $targetSpecHash; adapterSha256 = $adapterHash; toolchainHash = $toolchainHash; evidencePath = 'reports/Fabric-1.21.11.md'; evidenceSha256 = $markdownHash }
        )
        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'
        $result.targetReportPass | Should -Be 1
    }

    It 'accepts a session-bound single-client Agent event without requiring a window pair' {
        $universeHash = 'a' * 64; $targetSpecHash = 'b' * 64; $adapterHash = 'c' * 64
        $toolchainHash = 'd' * 64; $sourceHash = 'e' * 64; $eventHash = 'f' * 64
        $target = [pscustomobject]@{
            targetId = 'Fabric@1.21.11'; loaderId = 'Fabric'; minecraftId = '1.21.11'
            loaderVersionCandidates = @('0.19.5'); sourceHash = $sourceHash
        }
        $universe = [pscustomobject]@{ catalogHash = $universeHash; targets = @($target) }
        $evidenceIndex = [pscustomobject]@{
            universeHash = $universeHash
            entries = @([pscustomobject]@{
                targetId = $target.targetId; dimension = 'SingleAssertion'; targetSpecHash = $targetSpecHash
                adapterSha256 = $adapterHash; toolchainHash = $toolchainHash
                evidencePath = 'events/single-assertion.json'; evidenceSha256 = $eventHash
            })
        }
        $targetReport = [pscustomobject]@{
            targetId = $target.targetId; loaderId = 'Fabric'; minecraftId = '1.21.11'; loaderVersion = '0.19.5'
            runId = 'current-goal-run'; sessionId = 'session-single-1'; freshExecution = $true; overallResult = 'PARTIAL'
            scenarioConfiguration = [pscustomobject]@{ effective = [pscustomobject]@{ clientCount = 1; transport = 'None' } }
            compatibilityIdentity = [pscustomobject]@{
                targetId = $target.targetId; universeHash = $universeHash; sourceHash = $sourceHash
                targetSpecHash = $targetSpecHash; adapterSha256 = $adapterHash; toolchainHash = $toolchainHash
            }
            stageResults = @([pscustomobject]@{
                dimension = 'SingleAssertion'; status = 'PASS'; freshExecution = $true
                evidenceRefs = @('events/single-assertion.json'); evidenceSha256 = @($eventHash)
            })
            windowPairProof = $null
            singleProof = [pscustomobject]@{ passed = $true; actionProof = $true; observationProof = $true }
        }

        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'
        $result.singlePass | Should -Be 0

        $agentEvent = [pscustomobject]@{
            schemaVersion = 1; sessionId = 'session-single-1'; role = 'Client'; pid = 101
            processIdentity = 'process-101-start-1'; sourceType = 'Agent'; eventCode = 'AGENT_SHARED_STATE_WRITTEN'
            timestampUtc = '2026-10-16T08:20:00Z'
            metadata = [pscustomobject]@{
                agentEventId = 'single-event-1'; agentNonceVerified = $true; sourceCategory = 'AGENT_OBSERVATION'
                actionId = '0123456789abcdef0123456789abcdef'; protocolId = 'mmtl-block-marker-v1'
                operationCode = 'PLACE_BLOCK_MARKER'; markerId = 'single-marker'; stateSha256 = ('9' * 64)
                observed = $true; worldKey = 'world:single-1'; dimensionKey = 'minecraft:overworld'; playerIdentity = 'player-single'
            }
        }
        $targetReport.singleProof = [pscustomobject]@{
            passed = $true; clientPid = 101; clientProcessIdentity = 'process-101-start-1'
            evidencePath = 'events/single-assertion.json'; evidenceSha256 = $eventHash; agentEvent = $agentEvent
        }
        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'
        $result.singlePass | Should -Be 1
        $result.multiplayerPass | Should -Be 0
        $result.targetDimensionResults[0].dimensions.Multiplayer | Should -BeExactly 'NotRequested'

        $targetReport.windowPairProof = [pscustomobject]@{
            passed = $true; clientAPid = 101; clientBPid = 202
            clientAWindowId = 'hwnd-101'; clientBWindowId = 'hwnd-202'
            readyEvents = @(
                [pscustomobject]@{ sessionId = 'session-single-1'; pid = 101; processIdentity = 'process-101-start-1'; role = 'Client'; sourceType = 'Agent' }
                [pscustomobject]@{ sessionId = 'session-single-1'; pid = 202; processIdentity = 'process-202-start-1'; role = 'Guest'; sourceType = 'Agent' }
            )
            simultaneousIntervalUtc = [pscustomobject]@{ start = '2026-10-16T08:20:01Z'; end = '2026-10-16T08:20:03Z' }
        }
        $targetReport.windowPairProof.simultaneousIntervalUtc.end = '2026-10-16T08:20:01Z'
        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'
        $result.singlePass | Should -Be 1
        $result.multiWindowPass | Should -Be 0

        $targetReport.windowPairProof.simultaneousIntervalUtc.end = '2026-10-16T08:20:03Z'
        $result = Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($targetReport) -RunId 'current-goal-run'
        $result.singlePass | Should -Be 1
        $result.multiWindowPass | Should -Be 0
    }

    It 'requires exact historical server artifact, user EULA consent, process and port stop proof' {
        $universeHash='a'*64;$targetSpecHash='b'*64;$adapterHash='c'*64;$toolchainHash='d'*64;$sourceHash='e'*64
        $multiplayerHash='1'*64;$historicalHash='2'*64
        $target=[pscustomobject]@{targetId='Forge@1.2.5';loaderId='Forge';minecraftId='1.2.5';minecraftType='release';loaderVersionCandidates=@('6.2');sourceHash=$sourceHash}
        $universe=[pscustomobject]@{catalogHash=$universeHash;targets=@($target)}
        $evidenceIndex=[pscustomobject]@{
            universeHash=$universeHash
            entries=@(
                [pscustomobject]@{targetId=$target.targetId;dimension='MultiplayerJoinAndAssertion';targetSpecHash=$targetSpecHash;adapterSha256=$adapterHash;toolchainHash=$toolchainHash;evidencePath='proof/multiplayer.json';evidenceSha256=$multiplayerHash}
                [pscustomobject]@{targetId=$target.targetId;dimension='HistoricalDedicatedEquivalent';targetSpecHash=$targetSpecHash;adapterSha256=$adapterHash;toolchainHash=$toolchainHash;evidencePath='proof/historical.json';evidenceSha256=$historicalHash}
            )
        }
        $world=[pscustomobject]@{
            passed=$true;sharedWorldKey='world:historical-1'
            actorA=[pscustomobject]@{processId=101;playerIdentity='host'}
            observerB=[pscustomobject]@{processId=202;playerIdentity='guest'}
            actionProof=[pscustomobject]@{processId=101;stateSha256=('f'*64);eventId='action-1'}
            observationProof=[pscustomobject]@{processId=202;stateSha256=('f'*64);eventId='observe-1'}
        }
        $historicalArtifact=[pscustomobject]@{targetId=$target.targetId;minecraftId='1.2.5';trust='VerifiedHistorical';sourceType='VerifiedLocalArchive';artifactSha256=('3'*64);catalogSha256=('4'*64);sourceEvidenceSha256=('5'*64)}
        $report=[pscustomobject]@{
            targetId=$target.targetId;loaderId='Forge';minecraftId='1.2.5';loaderVersion='6.2';runId='historical-run';freshExecution=$true
            scenarioConfiguration=[pscustomobject]@{effective=[pscustomobject]@{clientCount=2;transport='HistoricalDedicatedEquivalent';historicalServerArtifact=$historicalArtifact}}
            compatibilityIdentity=[pscustomobject]@{targetId=$target.targetId;universeHash=$universeHash;sourceHash=$sourceHash;targetSpecHash=$targetSpecHash;adapterSha256=$adapterHash;toolchainHash=$toolchainHash}
            multiplayerPath='HistoricalDedicatedEquivalent';historicalPathEligibilityVerified=$true;worldProof=$world;overallResult='PARTIAL'
            stageResults=@(
                [pscustomobject]@{dimension='MultiplayerJoinAndAssertion';status='PASS';evidenceRefs=@('proof/multiplayer.json');evidenceSha256=@($multiplayerHash);freshExecution=$true}
                [pscustomobject]@{dimension='HistoricalDedicatedEquivalent';status='PASS';evidenceRefs=@('proof/historical.json');evidenceSha256=@($historicalHash);freshExecution=$true}
            )
        }
        $result=Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($report) -RunId 'historical-run'
        $result.multiplayerPass | Should -Be 0
        $result.historicalDedicatedEquivalentPass | Should -Be 0
        $result.reasons | Should -Contain 'HISTORICAL_SERVER_PROOF_INVALID'
        $result.targetDimensionResults[0].dimensions.IntegratedLanPublished | Should -BeExactly 'UnsupportedByMinecraftVersion'
        $result.targetDimensionResults[0].dimensions.HistoricalDedicatedEquivalent | Should -BeExactly 'Failed'

        $historicalServerProof=[pscustomobject]@{
            passed=$true;targetId=$target.targetId;minecraftId='1.2.5'
            artifact=[pscustomobject]@{targetId=$target.targetId;minecraftId='1.2.5';trust='VerifiedHistorical';sourceType='VerifiedLocalArchive';artifactSha256=('3'*64);catalogSha256=('4'*64);sourceEvidenceSha256=('5'*64)}
            serverProcess=[pscustomobject]@{pid=303;processIdentity='server-process-303-start-1';role='DedicatedServer';listenerPort=25565;startedAtUtc='2026-10-18T00:00:00Z';readyEventId='server-ready-1'}
            eulaConsent=[pscustomobject]@{accepted=$true;authorizationRef='user-consent-record-1';eulaSha256=('6'*64);acceptedAtUtc='2026-10-18T00:00:00Z'}
            stopProof=[pscustomobject]@{processTreeStopped=$true;listenerPortsReleased=$true;stoppedProcessIds=@(303);releasedPorts=@(25565)}
        }
        $report | Add-Member -NotePropertyName historicalServerProof -NotePropertyValue $historicalServerProof
        $result=Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($report) -RunId 'historical-run'
        $result.multiplayerPass | Should -Be 1
        $result.historicalDedicatedEquivalentPass | Should -Be 1
        $result.targetDimensionResults[0].dimensions.IntegratedLanPublished | Should -BeExactly 'UnsupportedByMinecraftVersion'
        $result.targetDimensionResults[0].dimensions.HistoricalDedicatedEquivalent | Should -BeExactly 'PASS'

        $report.historicalServerProof.artifact.artifactSha256=('7'*64)
        $result=Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($report) -RunId 'historical-run'
        $result.multiplayerPass | Should -Be 0
        $report.historicalServerProof.artifact.artifactSha256=('3'*64)

        $report.historicalServerProof.eulaConsent.accepted=$false
        $result=Test-MmtlExactGoalAcceptance -Universe $universe -EvidenceIndex $evidenceIndex -TargetReports @($report) -RunId 'historical-run'
        $result.multiplayerPass | Should -Be 0
        $result.historicalDedicatedEquivalentPass | Should -Be 0
    }
}
