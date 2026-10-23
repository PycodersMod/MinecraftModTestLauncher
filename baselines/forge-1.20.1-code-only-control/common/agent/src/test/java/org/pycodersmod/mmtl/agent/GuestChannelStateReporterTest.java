package org.pycodersmod.mmtl.agent;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;

import static org.junit.Assert.*;

public final class GuestChannelStateReporterTest {
    @Rule public TemporaryFolder temporaryFolder = new TemporaryFolder();

    private AgentEventSink createSink(Path root, Path sink) throws Exception {
        String token = "agent-test-token-0123456789abcdef";
        StringBuilder hash = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.UTF_8)))
            hash.append(String.format("%02x", value & 255));
        Files.createDirectories(sink.getParent());
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Guest", "Guest", token,
                hash.toString(), root.toString(), sink.toString(), 0, 25565);
        assertNotNull(context);
        return new AgentEventSink(context);
    }

    @Test public void enabledReporterRecordsOnlyBoundedChannelState() throws Exception {
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        GuestChannelStateReporter reporter = new GuestChannelStateReporter(createSink(root, sink), 25565, true);

        reporter.record(true, true, true, true, "valid=true,interestOps=1,readyOps=0");

        String event = Files.readString(sink);
        assertTrue(event.contains("\"eventType\":\"GUEST_CHANNEL_STATE\""));
        assertTrue(event.contains("channel registered=true active=true open=true autoRead=true"));
        assertTrue(event.contains("selectionKey=valid=true,interestOps=1,readyOps=0"));
        assertTrue(event.contains("\"port\":25565"));
        assertFalse(event.contains("agent-test-token-0123456789abcdef"));
    }

    @Test public void disabledReporterWritesNothing() throws Exception {
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        GuestChannelStateReporter reporter = new GuestChannelStateReporter(createSink(root, sink), 25565, false);

        reporter.record(true, true, true, true, "valid=true,interestOps=1,readyOps=0");

        assertFalse(Files.exists(sink));
    }

    @Test public void reporterRejectsUntrustedSelectionKeyText() throws Exception {
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        GuestChannelStateReporter reporter = new GuestChannelStateReporter(createSink(root, sink), 25565, true);

        reporter.record(true, true, true, false, "valid=true\nforged=true");

        String event = Files.readString(sink);
        assertTrue(event.contains("selectionKey=unavailable:invalid-state"));
        assertFalse(event.contains("forged=true"));
    }
}
