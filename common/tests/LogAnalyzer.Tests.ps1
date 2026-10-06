BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    $script:structured=Join-Path $root 'src/Logs/StructuredLogWorkspace.psm1'
    $script:analyzer=Join-Path $root 'src/Logs/ModAwareAnalyzer.psm1'
}

Describe 'Mod-aware rule analyzer' {
    BeforeEach {
        Import-Module $script:structured -Force
        Import-Module $script:analyzer -Force
        $script:session=Join-Path $TestDrive ('session-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $session -Force|Out-Null
        Initialize-MmtlStructuredLogWorkspace -SessionPath $session|Out-Null
        $script:metadata=[pscustomobject]@{modIds=@('fixturemod');primaryModId='fixturemod';modNames=@('Fixture Mod');loaderId='Forge';minecraftVersion='1.20.1';packageCandidates=@([pscustomobject]@{packageName='org.example.fixture';source='Entrypoint'});mixinConfigs=@('fixture.mixins.json');entrypointClasses=@('org.example.fixture.FixtureMod')}
    }

    It 'attributes a current Mod stack frame directly and keeps a context window' {
        $source=Join-Path $session 'logs/source/client.log';New-Item -ItemType Directory (Split-Path $source -Parent) -Force|Out-Null
        foreach($line in @('[12:00:00] [Render thread/ERROR]: java.lang.NullPointerException: test','    at org.example.fixture.Renderer.render(Renderer.java:42)','    at net.minecraft.client.Minecraft.run(Minecraft.java:1)','Caused by: java.lang.IllegalArgumentException: dependency cause','    at dependency.other.Api.call(Api.java:9)')){Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity MMTL_C01 -SourceFile $source -Line $line|Out-Null}
        $rawBefore=[IO.File]::ReadAllText((Join-Path $session 'logs/raw/Client-MMTL_C01.log'))
        $result=Invoke-MmtlRuleBasedAnalysis -SessionPath $session -ProjectMetadata $metadata
        $result.findings.Count | Should -Be 1
        $finding=$result.findings[0]
        $finding.attribution | Should -Be 'Direct';$finding.likelyCategory | Should -Be 'GENERIC_MOD_EXCEPTION';$finding.confidence | Should -Be 'High'
        $finding.evidence.Count | Should -BeGreaterOrEqual 3
        [IO.File]::ReadAllText((Join-Path $session 'logs/raw/Client-MMTL_C01.log')) | Should -Be $rawBefore
        Test-Path (Join-Path $session 'logs/relevant/fixturemod.jsonl') | Should -BeTrue
        Test-Path (Join-Path $session 'analysis/summary.md') | Should -BeTrue
    }

    It 'does not call a dependency-only crash Direct and leaves attribution Unknown' {
        $source=Join-Path $session 'logs/source/client.log';New-Item -ItemType Directory (Split-Path $source -Parent) -Force|Out-Null
        Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity MMTL_C01 -SourceFile $source -Line '[12:00:00] [main/ERROR]: java.lang.NoSuchMethodError: dependency.api.Call.run()'|Out-Null
        Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity MMTL_C01 -SourceFile $source -Line '    at dependency.other.Renderer.render(Renderer.java:9)'|Out-Null
        $result=Invoke-MmtlRuleBasedAnalysis -SessionPath $session -ProjectMetadata $metadata
        $result.findings.Count | Should -Be 1
        $result.findings[0].attribution | Should -Be 'Unknown'
        $result.findings[0].likelyCategory | Should -Be 'DEPENDENCY_BINARY_MISMATCH'
    }

    It 'classifies MMTL Agent failures as infrastructure instead of User Mod errors' {
        $source=Join-Path $session 'logs/source/agent.log';New-Item -ItemType Directory (Split-Path $source -Parent) -Force|Out-Null
        Add-MmtlStructuredLogLine -SessionPath $session -Role Agent -Identity Host -SourceFile $source -Line '[12:00:00] [Agent/ERROR]: java.lang.IllegalStateException: event sink failed'|Out-Null
        Add-MmtlStructuredLogLine -SessionPath $session -Role Agent -Identity Host -SourceFile $source -Line '    at dev.mmtl.agent.EventSink.write(EventSink.java:8)'|Out-Null
        $result=Invoke-MmtlRuleBasedAnalysis -SessionPath $session -ProjectMetadata $metadata
        $result.findings.Count | Should -Be 1
        $result.findings[0].likelyCategory | Should -Be 'MMTL_INFRASTRUCTURE'
        $result.findings[0].attribution | Should -Be 'Unknown'
    }

    It 'marks a named mixin-chain warning Indirect without claiming a direct root cause' {
        $source=Join-Path $session 'logs/source/client.log';New-Item -ItemType Directory (Split-Path $source -Parent) -Force|Out-Null
        Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity MMTL_C01 -SourceFile $source -Line '[12:00:00] [main/WARN]: mixin chain mentions fixture.mixins.json while dependency.other changes target behavior'|Out-Null
        $result=Invoke-MmtlRuleBasedAnalysis -SessionPath $session -ProjectMetadata $metadata
        $result.findings.Count | Should -Be 1
        $result.findings[0].attribution | Should -Be 'Indirect'
        $result.findings[0].likelyCategory | Should -Be 'RELEVANT_WARNING'
        $result.findings[0].confidence | Should -Be 'Medium'
    }

    It 'detects Loader resolution, mixin, network, resource, and crash report categories' {
        $source=Join-Path $session 'logs/source/client.log';New-Item -ItemType Directory (Split-Path $source -Parent) -Force|Out-Null
        $lines=@('[12:00:00] [main/ERROR]: Mod fixturemod requires missing dependency corelib','[12:00:01] [main/ERROR]: MixinApplyError: fixture.mixins.json failed','[12:00:02] [main/ERROR]: Network channel mismatch for fixturemod','[12:00:03] [main/ERROR]: Datapack resource reload failure','[12:00:04] [main/ERROR]: Crash report generated')
        foreach($line in $lines){Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity MMTL_C01 -SourceFile $source -Line $line|Out-Null}
        $result=Invoke-MmtlRuleBasedAnalysis -SessionPath $session -ProjectMetadata $metadata
        @($result.findings.likelyCategory) | Should -Contain 'MISSING_DEPENDENCY'
        @($result.findings.likelyCategory) | Should -Contain 'MIXIN_TRANSFORM'
        @($result.findings.likelyCategory) | Should -Contain 'NETWORK_CHANNEL'
        @($result.findings.likelyCategory) | Should -Contain 'RESOURCE_RELOAD'
        @($result.findings.likelyCategory) | Should -Contain 'CRASH_REPORT'
    }

    It 'recognizes the remaining first-release exception and loader rule classes' {
        $source=Join-Path $session 'logs/source/client.log';New-Item -ItemType Directory (Split-Path $source -Parent) -Force|Out-Null
        $lines=@(
            '[12:00:00] [main/ERROR]: ClassNotFoundException: missing.Type',
            '[12:00:01] [main/ERROR]: NoClassDefFoundError: missing/Type',
            '[12:00:02] [main/ERROR]: NoSuchMethodError: api.run()',
            '[12:00:03] [main/ERROR]: NoSuchFieldError: api.value',
            '[12:00:04] [main/ERROR]: Duplicate Mod ID detected',
            '[12:00:05] [main/ERROR]: Version mismatch: requires compatible version',
            '[12:00:06] [main/ERROR]: Invalid dist: client-only class loaded on Dedicated Server',
            '[12:00:07] [main/ERROR]: Registry freeze failed due to duplicate registry entry',
            '[12:00:08] [main/ERROR]: Config parse error: invalid toml',
            '[12:00:09] [main/ERROR]: OutOfMemoryError: Java heap space',
            '[12:00:10] [main/ERROR]: StackOverflowError',
            '[12:00:11] [main/ERROR]: JVM fatal error EXCEPTION_ACCESS_VIOLATION',
            '[12:00:12] [main/ERROR]: java.lang.NullPointerException: current frame follows'
        )
        foreach($line in $lines){Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity MMTL_C01 -SourceFile $source -Line $line|Out-Null}
        Add-MmtlStructuredLogLine -SessionPath $session -Role Client -Identity MMTL_C01 -SourceFile $source -Line '    at org.example.fixture.Renderer.render(Renderer.java:8)'|Out-Null
        $result=Invoke-MmtlRuleBasedAnalysis -SessionPath $session -ProjectMetadata $metadata
        $categories=@($result.findings.likelyCategory)
        foreach($expected in @('MISSING_CLASS','DEPENDENCY_BINARY_MISMATCH','DUPLICATE_MOD','VERSION_MISMATCH','INVALID_DIST','REGISTRY_FAILURE','CONFIG_PARSE','OUT_OF_MEMORY','STACK_OVERFLOW','JVM_CRASH','GENERIC_MOD_EXCEPTION')){$categories | Should -Contain $expected}
        @($result.findings|Where-Object{$_.likelyCategory -eq 'GENERIC_MOD_EXCEPTION' -and $_.attribution -eq 'Direct'}).Count | Should -Be 1
    }
}
