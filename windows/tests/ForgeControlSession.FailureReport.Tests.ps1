BeforeAll {
    $script:repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:repositoryRoot 'windows/src/WindowsPlatformProvider.psm1') -Force
    $script:sessionModule = Import-Module (Join-Path $script:repositoryRoot 'windows/src/ForgeControl/ForgeControlSession.psm1') -Force -PassThru
}

Describe 'Forge Control startup failure reporting' {
    It 'captures a Java-style stderr version banner without treating it as a terminating error' {
        InModuleScope $script:sessionModule.Name {
            $capture = Invoke-MmtlForgeProcessCapture -ExecutablePath $env:ComSpec -Arguments '/d /c echo java version "17.0.19" 1>&2'
            $capture.exitCode | Should -Be 0
            ($capture.standardError + $capture.standardOutput) | Should -Match 'java version "17\.0\.19"'
        }
    }

    It 'labels an authenticated Guest login disconnect as a world-entry failure' {
        InModuleScope $script:sessionModule.Name {
            Mock Wait-MmtlAgentClientReady { [pscustomobject]@{ready=$true} }
            Mock Wait-MmtlAgentWorldJoined { throw 'GUEST_LOGIN_DISCONNECTED: Guest login disconnected: Timed out' }
            $client=[pscustomobject]@{eventPath='guest.jsonl';playerName='Dev_1';processId=51002;processIdentity='test-start';state='Starting'}
            try {
                Wait-MmtlForgeAgentClient -Client $client -SessionPath 'C:\session' -SessionId 'session_a' -NonceHash ('a'*64) -Role Guest
                throw 'EXPECTED_FAILURE_NOT_THROWN'
            } catch {
                $_.Exception.Message | Should -Match 'GUEST_LOGIN_DISCONNECTED'
                $_.Exception.Data['mmtlFailureStage'] | Should -BeExactly 'waiting-guest-world:Dev_1'
            }
        }
    }

    It 'extracts the root cause and path from a Forge crash report' {
        InModuleScope $script:sessionModule.Name {
            $gameDirectory = Join-Path $TestDrive 'client-with-crash'
            $crashDirectory = Join-Path $gameDirectory 'crash-reports'
            New-Item -ItemType Directory -Path $crashDirectory -Force | Out-Null
            $crashPath = Join-Path $crashDirectory 'crash-2026-10-27_00.19.08-fml.txt'
            [IO.File]::WriteAllText($crashPath, @'
---- Minecraft Crash Report ----
Description: Mod loading error has occurred
-- MOD taczintetra --
Failure message: TaCZ in Tetra has failed to load correctly
        org.spongepowered.asm.mixin.transformer.throwables.IllegalClassLoadError: example.RootCause
'@)

            $diagnostics = Get-MmtlForgeCrashDiagnostics -GameDirectory $gameDirectory

            $diagnostics.crashReportPath | Should -BeExactly $crashPath
            $diagnostics.description | Should -BeExactly 'Mod loading error has occurred'
            $diagnostics.modFailures | Should -Contain 'taczintetra: TaCZ in Tetra has failed to load correctly'
            $diagnostics.rootCause | Should -Match 'IllegalClassLoadError: example.RootCause'
        }
    }

    It 'classifies a dead client with a crash report as a mod-loading crash' {
        InModuleScope $script:sessionModule.Name {
            $gameDirectory = Join-Path $TestDrive 'client-crash-classification'
            $crashDirectory = Join-Path $gameDirectory 'crash-reports'
            New-Item -ItemType Directory -Path $crashDirectory -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $crashDirectory 'crash.txt'), "Description: Mod loading error has occurred`nIllegalClassLoadError: mixin package class referenced directly")
            Mock Wait-MmtlAgentClientReady { throw 'AGENT_CLIENT_PROCESS_EXITED' }
            $client = [pscustomobject]@{
                eventPath = 'client.jsonl'; playerName = 'Dev'; processId = 58932
                processIdentity = 'test-start'; state = 'Starting'; gameDirectory = $gameDirectory
            }

            try {
                Wait-MmtlForgeAgentClient -Client $client -SessionPath $gameDirectory -SessionId 'session_crash_001' -NonceHash ('b' * 64) -Role Client
                throw 'EXPECTED_FAILURE_NOT_THROWN'
            } catch {
                $_.Exception.Message | Should -Match 'FORGE_CLIENT_CRASHED: IllegalClassLoadError'
                $_.Exception.Data['mmtlFailureStage'] | Should -BeExactly 'client-mod-loading:Dev'
            }
        }
    }

    It 'treats a process already stopped by MMTL as a successful stop when stopResults is absent' {
        $fixtureRoot = Join-Path $TestDrive 'already-exited-process'
        InModuleScope $script:sessionModule.Name -Parameters @{ FixtureRoot = $fixtureRoot } {
            $sessionPath = Join-Path $FixtureRoot 'sessions/session-stopped-001'
            New-Item -ItemType Directory -Path $sessionPath -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $sessionPath 'pids.json'), (@([pscustomobject]@{
                PID = 58931; Role = 'Client'; Username = 'Dev'; StartIdentity = '2026-10-27T00:00:00Z'
                StatePath = (Join-Path $sessionPath 'process-58931.exit.json')
            }) | ConvertTo-Json -Depth 5))
            [IO.File]::WriteAllText((Join-Path $sessionPath 'process-58931.exit.json'), (@{
                PID = 58931; ExitCode = 0; StopRequested = $true
            } | ConvertTo-Json))
            [IO.File]::WriteAllText((Join-Path $sessionPath 'session.json'), (@{ sessionId = 'session-stopped-001' } | ConvertTo-Json))
            Mock Get-Process { $null }

            $result = Stop-MmtlForgeClient -SessionPath $sessionPath -Client ([pscustomobject]@{ processId = 58931 })

            $result.stopped | Should -BeTrue
            $result.graceful | Should -BeTrue
            $result.method | Should -BeExactly 'AlreadyStoppedByController'
        }
    }

    It 'retains the original failure, partial LAN assertions, stop outcomes and copies JSON plus Markdown' {
        $fixtureRoot = Join-Path $TestDrive 'failure-report'
        InModuleScope $script:sessionModule.Name -Parameters @{ FixtureRoot = $fixtureRoot } {
            Mock Get-MmtlForgeAvailableMemoryMb { 24000 }
            Mock Register-MmtlWindowsPlatform {}
            Mock Get-MmtlAgentProviderStatus { [pscustomobject]@{ status = 'Supported' } }
            Mock Get-MmtlForgeLoopbackPort { 25432 }
            Mock New-MmtlSession {
                param($RuntimeRoot, $Name, $Metadata)
                $sessionId = 'session-failure-001'
                $sessionPath = Join-Path $FixtureRoot "sessions/$sessionId"
                New-Item -ItemType Directory -Path (Join-Path $sessionPath 'agent-events') -Force | Out-Null
                $record = [pscustomobject]@{
                    sessionId = $sessionId
                    testIdentities = @(
                        [pscustomobject]@{ username = 'Dev'; processIdentity = $null },
                        [pscustomobject]@{ username = 'Dev_1'; processIdentity = $null }
                    )
                }
                [IO.File]::WriteAllText((Join-Path $sessionPath 'session.json'), ($record | ConvertTo-Json -Depth 10))
                [IO.File]::WriteAllText((Join-Path $sessionPath 'pids.json'), '[]')
                return $sessionPath
            }
            Mock Start-MmtlForgeControlClient {
                param($Config, $SessionPath, $SessionId, $SessionToken, $ProviderRoot, $Role, $PlayerName, $LanPort, $GuestPort)
                $pidValue = if ($Role -eq 'Host') { 51001 } else { 51002 }
                $identity = "test-process-$pidValue"
                $eventName = if ($Role -eq 'Host') { 'host-host-00.jsonl' } else { 'guest-guest-01.jsonl' }
                $eventPath = Join-Path $SessionPath "agent-events/$eventName"
                $gameDirectory = Join-Path $SessionPath $PlayerName
                New-Item -ItemType Directory -Path $gameDirectory -Force | Out-Null
                if ($Role -eq 'Guest') {
                    $crashDirectory = Join-Path $gameDirectory 'crash-reports'
                    New-Item -ItemType Directory -Path $crashDirectory -Force | Out-Null
                    [IO.File]::WriteAllText((Join-Path $crashDirectory 'crash-test.txt'), "Description: Mod loading error has occurred`n-- MOD taczintetra --`nFailure message: TaCZ in Tetra has failed to load correctly`n    org.spongepowered.asm.mixin.transformer.throwables.IllegalClassLoadError: mixin package class referenced directly")
                }
                $nonceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($SessionToken))).ToLowerInvariant()
                $records = [Collections.Generic.List[string]]::new()
                $types = if ($Role -eq 'Host') { @('AGENT_STARTED','CLIENT_READY','WORLD_JOINED','LAN_PUBLISHED','PLAYER_JOINED') } else { @('AGENT_STARTED','GUEST_CONNECTING') }
                foreach ($type in $types) {
                    $event = [ordered]@{
                        schemaVersion = 1; sessionId = $SessionId; role = $Role; eventId = [guid]::NewGuid().ToString()
                        eventType = $type; timestampUtc = [DateTimeOffset]::UtcNow.ToString('o'); sessionNonceHash = $nonceHash; summary = $type
                    }
                    if ($type -eq 'LAN_PUBLISHED') { $event.port = $LanPort; $event.bindAddress = '127.0.0.1' }
                    if ($type -eq 'PLAYER_JOINED') { $event.playerName = 'Dev' }
                    $records.Add(($event | ConvertTo-Json -Compress))
                }
                [IO.File]::WriteAllLines($eventPath, $records, [Text.UTF8Encoding]::new($false))
                $registryPath = Join-Path $SessionPath 'pids.json'
                $registry = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json)
                $registry += [pscustomobject]@{
                    PID = $pidValue; Role = $Role; Username = $PlayerName; StartIdentity = $identity
                    LogPath = (Join-Path $SessionPath "logs/$Role-$PlayerName.stdout.log")
                    WorkingDirectory = (Join-Path $SessionPath $PlayerName); CommandLine = "java -Dmmtl.agent.eventSink=$eventPath"
                    StatePath = (Join-Path $SessionPath "process-$pidValue.exit.json")
                }
                [IO.File]::WriteAllText($registryPath, ($registry | ConvertTo-Json -Depth 8))
                return [pscustomobject]@{
                    instanceId = "$Role-$PlayerName"; processId = $pidValue; processIdentity = $identity
                    playerName = $PlayerName; role = $Role; eventPath = $eventPath
                    logPath = (Join-Path $SessionPath "logs/$Role-$PlayerName.stdout.log")
                    gameDirectory = $gameDirectory; state = 'Starting'
                }
            }
            Mock Wait-MmtlForgeAgentClient {
                param($Client, $SessionPath, $SessionId, $NonceHash, $Role)
                if ($Role -eq 'Guest') { throw [IO.IOException]::new('The process cannot access guest event JSONL because it is being used by another process.') }
                $Client.state = 'WorldJoined'
            }
            Mock Wait-MmtlAgentIntegratedLanReady {
                [pscustomobject]@{ ready = $true; port = 25432; bindAddress = '127.0.0.1' }
            }
            Mock Stop-MmtlForgeClient {
                param($SessionPath, $Client, $TimeoutSeconds)
                [pscustomobject]@{ processId = $Client.processId; stopped = $true; graceful = $true; method = 'TestStop' }
            }

            $config = [pscustomobject]@{
                javaPath = 'C:\Java\17\bin\java.exe'; memoryMb = 1024; clientCount = 2
                players = @('Dev','Dev_1'); configPath = 'profile.json'; target = [pscustomobject]@{ minecraftVersion = '1.20.1'; loader = 'Forge'; loaderVersion = '47.4.23' }
                worldName = 'MMTL-Test'; lanEnabled = $true; runtimeRoot = $FixtureRoot; reportRoot = (Join-Path $FixtureRoot 'reports')
            }

            { Start-MmtlForgeControlSession -Config $config } | Should -Throw '*cannot access guest event JSONL*'
            $sessionPath = Join-Path $FixtureRoot 'sessions/session-failure-001'
            $reportPath = Join-Path $FixtureRoot 'reports/session-failure-001.json'
            $markdownPath = Join-Path $FixtureRoot 'reports/session-failure-001.md'
            Test-Path -LiteralPath $reportPath | Should -BeTrue
            Test-Path -LiteralPath $markdownPath | Should -BeTrue
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            $report.failureStage | Should -BeExactly 'waiting-guest-ready:Dev_1'
            $report.originalError.message | Should -Match 'cannot access guest event JSONL'
            $report.processes.Count | Should -Be 2
            $report.gameAssertions.integratedLan | Should -BeTrue
            $report.gameAssertions.hostObservedPlayers | Should -Contain 'Dev'
            $report.stopResults.Count | Should -Be 2
            $report.stopResults | Where-Object { -not $_.stopped } | Should -BeNullOrEmpty
            $report.processes | Where-Object { -not $_.minecraftLogPath -or -not $_.eventPath } | Should -BeNullOrEmpty
            $guestReport = $report.processes | Where-Object { $_.role -eq 'Guest' }
            $guestReport.crashDiagnostics.crashReportPath | Should -Match 'crash-test\.txt$'
            $guestReport.crashDiagnostics.rootCause | Should -Match 'IllegalClassLoadError'
            (Get-Content -LiteralPath $markdownPath -Raw) | Should -Match 'waiting-guest-ready:Dev_1'
            (Get-Content -LiteralPath $markdownPath -Raw) | Should -Match '安全停止结果'
            $sessionRecord = Get-Content -LiteralPath (Join-Path $sessionPath 'session.json') -Raw | ConvertFrom-Json
            $sessionRecord.status | Should -BeExactly 'Failed'
            $sessionRecord.processes.Count | Should -Be 2
        }
    }
}
