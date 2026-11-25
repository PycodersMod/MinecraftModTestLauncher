package org.pycodersmod.mmtl.agent;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.security.MessageDigest;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.assertEquals;

public final class FabricAgentBootstrapTest {
    private static final String[] SESSION_PROPERTIES = {
            "mmtl.agent.sessionId", "mmtl.agent.role", "mmtl.agent.allowedRoles",
            "mmtl.agent.sessionTokenFile", "mmtl.agent.sessionNonceHash", "mmtl.agent.sessionRoot",
            "mmtl.agent.eventSink", "mmtl.agent.integratedLanPort", "mmtl.agent.expectedLoopbackPort",
            "mmtl.agent.autoCreateWorld", "mmtl.agent.worldName", "mmtl.agent.worldGameMode",
            "mmtl.agent.worldDifficulty", "mmtl.agent.worldSeed", "mmtl.agent.worldAllowCommands"
    };

    @Test
    public void doesNotActivateOrWriteEventsWithoutManagedSessionProperties() {
        withPropertiesCleared(() -> assertFalse(FabricAgentBootstrap.start()));
    }

    @Test
    public void acceptedSessionWritesOnlyNonceHashTelemetry() throws Exception {
        withPropertiesCleared(() -> {
            Path root = Files.createTempDirectory("mmtl-fabric-agent-test-");
            Path tokenFile = root.resolve("session.token");
            Path sink = root.resolve("events.jsonl");
            String token = "a".repeat(48);
            Files.write(tokenFile, token.getBytes(StandardCharsets.UTF_8));
            String nonceHash = sha256(token);
            System.setProperty("mmtl.agent.sessionId", "fabric_test_session");
            System.setProperty("mmtl.agent.role", "Client");
            System.setProperty("mmtl.agent.allowedRoles", "Client,Host,Guest");
            System.setProperty("mmtl.agent.sessionTokenFile", tokenFile.toString());
            System.setProperty("mmtl.agent.sessionNonceHash", nonceHash);
            System.setProperty("mmtl.agent.sessionRoot", root.toString());
            System.setProperty("mmtl.agent.eventSink", sink.toString());

            assertTrue(FabricAgentBootstrap.start());
            String event = new String(Files.readAllBytes(sink), StandardCharsets.UTF_8);
            assertTrue(event.contains("\"sessionNonceHash\":\"" + nonceHash + "\""));
            assertFalse(event.contains(token));
            assertEquals(1, Files.readAllLines(sink, StandardCharsets.UTF_8).size());
        });
    }

    @Test
    public void reportsClientReadyOnceAfterTheClientReadinessHook() throws Exception {
        withPropertiesCleared(() -> {
            Path root = Files.createTempDirectory("mmtl-fabric-client-ready-test-");
            Path tokenFile = root.resolve("session.token");
            Path sink = root.resolve("events.jsonl");
            String token = "b".repeat(48);
            Files.write(tokenFile, token.getBytes(StandardCharsets.UTF_8));
            System.setProperty("mmtl.agent.sessionId", "fabric_ready_session");
            System.setProperty("mmtl.agent.role", "Client");
            System.setProperty("mmtl.agent.allowedRoles", "Client,Host,Guest");
            System.setProperty("mmtl.agent.sessionTokenFile", tokenFile.toString());
            System.setProperty("mmtl.agent.sessionNonceHash", sha256(token));
            System.setProperty("mmtl.agent.sessionRoot", root.toString());
            System.setProperty("mmtl.agent.eventSink", sink.toString());

            assertTrue(FabricAgentBootstrap.start());
            FabricAgentBootstrap.reportClientReady();
            FabricAgentBootstrap.reportClientReady();

            java.util.List<String> events = Files.readAllLines(sink, StandardCharsets.UTF_8);
            assertEquals(2, events.size());
            assertTrue(events.get(0).contains("\"eventType\":\"AGENT_STARTED\""));
            assertTrue(events.get(1).contains("\"eventType\":\"CLIENT_READY\""));
        });
    }

    @Test
    public void acceptsGuestJoinOnlyFromTheExpectedLoopbackPort() throws Exception {
        withPropertiesCleared(() -> {
            Path root = Files.createTempDirectory("mmtl-fabric-guest-loopback-test-");
            Path tokenFile = root.resolve("session.token");
            Path sink = root.resolve("events.jsonl");
            String token = "c".repeat(48);
            Files.write(tokenFile, token.getBytes(StandardCharsets.UTF_8));
            System.setProperty("mmtl.agent.sessionId", "fabric_guest_session");
            System.setProperty("mmtl.agent.role", "Guest");
            System.setProperty("mmtl.agent.allowedRoles", "Client,Host,Guest");
            System.setProperty("mmtl.agent.sessionTokenFile", tokenFile.toString());
            System.setProperty("mmtl.agent.sessionNonceHash", sha256(token));
            System.setProperty("mmtl.agent.sessionRoot", root.toString());
            System.setProperty("mmtl.agent.eventSink", sink.toString());
            System.setProperty("mmtl.agent.expectedLoopbackPort", "25565");

            assertTrue(FabricAgentBootstrap.start());
            FabricAgentBootstrap.reportLogin(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 25565));
            FabricAgentBootstrap.reportWorldJoined("minecraft:overworld", "guest-player");
            java.util.List<String> events = Files.readAllLines(sink, StandardCharsets.UTF_8);
            assertEquals(5, events.size());
            assertTrue(events.get(1).contains("\"eventType\":\"GUEST_CONNECTING\""));
            assertTrue(events.get(2).contains("\"eventType\":\"GUEST_CONNECTED\""));
            assertTrue(events.get(2).contains("\"port\":25565"));
            assertTrue(events.get(3).contains("\"eventType\":\"CLIENT_READY\""));
            assertTrue(events.get(4).contains("\"eventType\":\"WORLD_JOINED\""));
            assertTrue(events.get(4).contains("\"port\":25565"));
            assertFalse(events.toString().contains(token));
        });
    }

    private static String sha256(String value) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
        StringBuilder output = new StringBuilder(64);
        for (byte item : digest) output.append(String.format("%02x", item & 0xff));
        return output.toString();
    }

    private static void withPropertiesCleared(ThrowingRunnable action) {
        String[] previous = new String[SESSION_PROPERTIES.length];
        for (int i = 0; i < SESSION_PROPERTIES.length; i++) {
            previous[i] = System.getProperty(SESSION_PROPERTIES[i]);
            System.clearProperty(SESSION_PROPERTIES[i]);
        }
        try {
            action.run();
        } catch (Exception failure) {
            throw new AssertionError(failure);
        } finally {
            for (int i = 0; i < SESSION_PROPERTIES.length; i++) {
                if (previous[i] == null) System.clearProperty(SESSION_PROPERTIES[i]);
                else System.setProperty(SESSION_PROPERTIES[i], previous[i]);
            }
        }
    }

    private interface ThrowingRunnable { void run() throws Exception; }
}
