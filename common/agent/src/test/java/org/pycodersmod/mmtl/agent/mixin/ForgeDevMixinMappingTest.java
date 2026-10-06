package org.pycodersmod.mmtl.agent.mixin;

import org.junit.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class ForgeDevMixinMappingTest {
    @Test
    public void forgeGradleDevelopmentRunsKeepOfficialMixinTargetNames() throws Exception {
        Path refmapPath = Path.of(System.getProperty("user.dir"), "build", "tmp", "compileJava", "mmtl-agent.refmap.json");
        assertTrue("MixinGradle must generate the Agent refmap", Files.isRegularFile(refmapPath));
        String refmap = Files.readString(refmapPath, StandardCharsets.UTF_8);
        assertFalse("ForgeGradle development uses official names for publishServer", refmap.contains("m_7386_"));
        assertFalse("ForgeGradle development uses official names for startTcpServerListener", refmap.contains("m_9711_"));
        assertFalse("ForgeGradle development uses official names for CreateWorldScreen.onCreate", refmap.contains("m_100972_"));
    }
}
