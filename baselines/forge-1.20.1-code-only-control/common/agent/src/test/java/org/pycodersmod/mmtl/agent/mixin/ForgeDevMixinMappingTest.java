package org.pycodersmod.mmtl.agent.mixin;

import org.junit.Test;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.charset.StandardCharsets;

import static org.junit.Assert.assertTrue;

public class ForgeDevMixinMappingTest {
    @Test
    public void reobfuscationRefmapMapsRuntimeMixinTargetsToSrgNames() throws Exception {
        Path refmapPath = Path.of(System.getProperty("user.dir"), "build", "tmp", "compileJava", "mmtl-agent.refmap.json");
        assertTrue("MixinGradle must generate the Agent refmap", Files.isRegularFile(refmapPath));
        String refmap = Files.readString(refmapPath, StandardCharsets.UTF_8);
        assertTrue("The production Forge client uses SRG names for IntegratedServer.publishServer", refmap.contains("m_7386_"));
        assertTrue("The production Forge client uses SRG names for ServerConnectionListener.startTcpServerListener", refmap.contains("m_9711_"));
        assertTrue("The production Forge client uses SRG names for CreateWorldScreen.onCreate", refmap.contains("m_100972_"));
        Path mixinConfig = Path.of(System.getProperty("user.dir"), "src", "main", "resources", "mmtl-agent.mixins.json");
        assertTrue("The Forge Agent must wire the Guest login-disconnect observer", Files.readString(mixinConfig, StandardCharsets.UTF_8).contains("GuestLoginDisconnectMixin"));
        assertTrue("The Forge Agent must wire the opt-in Guest handshake progress observer", Files.readString(mixinConfig, StandardCharsets.UTF_8).contains("GuestHandshakeProgressMixin"));
        assertTrue("The Forge Agent must wire the opt-in Guest login packet observer", Files.readString(mixinConfig, StandardCharsets.UTF_8).contains("GuestLoginPacketObserverMixin"));
        assertTrue("Guest channel diagnostics must not inject into Connection.channelActive", !Files.readString(mixinConfig, StandardCharsets.UTF_8).contains("GuestChannelStateMixin"));
    }
}
