package org.pycodersmod.mmtl.agent;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import static org.junit.Assert.*;

public final class AgentEventSinkTest {
    @Rule public TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test public void lanPublishEventRecordsPortButNeverTheSessionToken() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        StringBuilder hash = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.UTF_8)))
            hash.append(String.format("%02x", value & 255));
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/host.jsonl");
        Files.createDirectories(sink.getParent());
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Host", "Host,Guest", token,
                hash.toString(), root.toString(), sink.toString(), 25565);
        assertTrue(new AgentEventSink(context).emitLanPublished(25565, "127.0.0.1", "session_a", "minecraft:overworld", "host-player"));
        String event = new String(Files.readAllBytes(sink), StandardCharsets.UTF_8);
        assertTrue(event.contains("\"port\":25565"));
        assertTrue(event.contains("\"bindAddress\":\"127.0.0.1\""));
        assertTrue(event.contains("\"worldKey\":\"session_a\""));
        assertTrue(event.contains("\"dimensionKey\":\"minecraft:overworld\""));
        assertTrue(event.contains("\"playerIdentity\":\"host-player\""));
        assertTrue(event.contains("\"sessionNonceHash\":\"" + hash + "\""));
        assertFalse(event.contains(token));
    }

    @Test public void lanPublishedEventRequiresAndRecordsExactLoopbackBinding() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        String hash = sha256(token);
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/host.jsonl");
        Files.createDirectories(sink.getParent());
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Host", "Host,Guest", token,
                hash, root.toString(), sink.toString(), 25565);

        boolean emitted = new AgentEventSink(context).emitLanPublished(25565, "127.0.0.1", "session_a", "minecraft:overworld", "host-player");

        assertTrue(emitted);
        String event = new String(Files.readAllBytes(sink), StandardCharsets.UTF_8);
        assertTrue(event.contains("\"eventType\":\"LAN_PUBLISHED\""));
        assertTrue(event.contains("\"port\":25565"));
        assertTrue(event.contains("\"bindAddress\":\"127.0.0.1\""));
        assertTrue(event.contains("\"worldKey\":\"session_a\""));
        assertFalse(event.contains(token));
    }

    @Test public void lanPublishedEventRejectsAnyNonLoopbackBinding() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        String hash = sha256(token);
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/host.jsonl");
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Host", "Host,Guest", token,
                hash, root.toString(), sink.toString(), 25565);

        assertFalse(new AgentEventSink(context).emitLanPublished(25565, "0.0.0.0", "session_a", "minecraft:overworld", "host-player"));
        assertFalse(Files.exists(sink));
    }

    @Test public void sharedStateWrittenEventSerializesOnlyTheApprovedMarkerProof() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        String hash = sha256(token);
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/host.jsonl");
        Files.createDirectories(sink.getParent());
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Host", "Host,Guest", token,
                hash, root.toString(), sink.toString(), 25565);

        boolean emitted = new AgentEventSink(context).emitSharedStateWritten("world-identity-1", "testmod:dimension/branch",
                "offline-player-a", "a".repeat(32), "marker-01", "b".repeat(64));

        assertTrue(emitted);
        String event = new String(Files.readAllBytes(sink), StandardCharsets.UTF_8);
        assertTrue(event.contains("\"eventType\":\"SHARED_STATE_WRITTEN\""));
        assertTrue(event.contains("\"worldKey\":\"world-identity-1\""));
        assertTrue(event.contains("\"dimensionKey\":\"testmod:dimension/branch\""));
        assertTrue(event.contains("\"playerIdentity\":\"offline-player-a\""));
        assertTrue(event.contains("\"protocolId\":\"mmtl-block-marker-v1\""));
        assertTrue(event.contains("\"operationCode\":\"PLACE_BLOCK_MARKER\""));
        assertTrue(event.contains("\"markerId\":\"marker-01\""));
        assertTrue(event.contains("\"stateSha256\":\"" + "b".repeat(64) + "\""));
        assertTrue(event.contains("\"observed\":true"));
        assertTrue(event.contains("\"sessionNonceHash\":\"" + hash + "\""));
        assertFalse(event.contains(token));
    }

    @Test public void worldJoinedEventCarriesSessionScopedWorldDimensionAndPlayerIdentity() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        String hash = sha256(token);
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/client.jsonl");
        Files.createDirectories(sink.getParent());
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_world_a", "Client", "Client,Host,Guest", token,
                hash, root.toString(), sink.toString());

        boolean emitted = new AgentEventSink(context).emitWorldJoined("session_world_a", "minecraft:overworld",
                "123e4567-e89b-12d3-a456-426614174000");

        assertTrue(emitted);
        String event = new String(Files.readAllBytes(sink), StandardCharsets.UTF_8);
        assertTrue(event.contains("\"eventType\":\"WORLD_JOINED\""));
        assertTrue(event.contains("\"worldKey\":\"session_world_a\""));
        assertTrue(event.contains("\"dimensionKey\":\"minecraft:overworld\""));
        assertTrue(event.contains("\"playerIdentity\":\"123e4567-e89b-12d3-a456-426614174000\""));
        assertTrue(event.contains("\"sessionNonceHash\":\"" + hash + "\""));
        assertFalse(event.contains(token));
    }

    @Test public void invalidWorldJoinedIdentityIsRejectedBeforeItCreatesTheEventFile() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        String hash = sha256(token);
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/client.jsonl");
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_world_a", "Client", "Client,Host,Guest", token,
                hash, root.toString(), sink.toString());

        boolean emitted = new AgentEventSink(context).emitWorldJoined("../other-session", "not a dimension", "bad identity");

        assertFalse(emitted);
        assertFalse(Files.exists(sink));
    }

    @Test public void guestWorldJoinedEventRecordsTheVerifiedLoopbackPort() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        String hash = sha256(token);
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        Files.createDirectories(sink.getParent());
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Guest", "Host,Guest", token,
                hash, root.toString(), sink.toString(), 0, 25565);

        assertTrue(new AgentEventSink(context).emitWorldJoined("session_a", "minecraft:overworld", "guest-player"));
        String event = new String(Files.readAllBytes(sink), StandardCharsets.UTF_8);
        assertTrue(event.contains("\"eventType\":\"WORLD_JOINED\""));
        assertTrue(event.contains("\"port\":25565"));
        assertFalse(event.contains(token));
    }

    @Test public void sharedStateObservedEventCorrelatesToTheActorAction() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        String hash = sha256(token);
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        Files.createDirectories(sink.getParent());
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Guest", "Host,Guest", token,
                hash, root.toString(), sink.toString(), 0, 25565);

        boolean emitted = new AgentEventSink(context).emitSharedStateObserved("world-identity-1", "minecraft:overworld",
                "offline-player-b", "a".repeat(32), "marker-01", "b".repeat(64));

        assertTrue(emitted);
        String event = new String(Files.readAllBytes(sink), StandardCharsets.UTF_8);
        assertTrue(event.contains("\"eventType\":\"SHARED_STATE_OBSERVED\""));
        assertTrue(event.contains("\"actorActionId\":\"" + "a".repeat(32) + "\""));
        assertTrue(event.contains("\"observationCode\":\"OBSERVE_BLOCK_MARKER\""));
        assertFalse(event.contains("\"actionId\":"));
        assertFalse(event.contains(token));
    }

    @Test public void invalidSharedStateProofIsRejectedBeforeItCreatesTheEventFile() throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        String hash = sha256(token);
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/host.jsonl");
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Host", "Host,Guest", token,
                hash, root.toString(), sink.toString(), 25565);

        boolean emitted = new AgentEventSink(context).emitSharedStateWritten("world-identity-1", "minecraft:overworld",
                "offline-player-a", "invalid-action", "marker-01", "not-a-hash");

        assertFalse(emitted);
        assertFalse(Files.exists(sink));
    }

    private static String sha256(String value) throws Exception {
        StringBuilder hash = new StringBuilder();
        for (byte item : MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)))
            hash.append(String.format("%02x", item & 255));
        return hash.toString();
    }
}
