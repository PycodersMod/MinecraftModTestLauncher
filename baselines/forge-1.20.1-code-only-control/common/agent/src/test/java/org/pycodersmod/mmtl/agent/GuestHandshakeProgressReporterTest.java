package org.pycodersmod.mmtl.agent;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;

import static org.junit.Assert.*;

public final class GuestHandshakeProgressReporterTest {
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

    @Test public void enabledReporterRecordsInboundHandlerAndSequence() throws Exception {
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        GuestHandshakeProgressReporter reporter = new GuestHandshakeProgressReporter(createSink(root, sink), 25565, true);

        reporter.recordInbound("handleIndexedMessage", "S2CRegistry", 4);

        String event = Files.readString(sink);
        assertTrue(event.contains("\"eventType\":\"GUEST_HANDSHAKE_PROGRESS\""));
        assertTrue(event.contains("handler=handleIndexedMessage"));
        assertTrue(event.contains("packet=S2CRegistry"));
        assertTrue(event.contains("sequence=4"));
        assertTrue(event.contains("\"port\":25565"));
        assertFalse(event.contains("agent-test-token-0123456789abcdef"));
    }

    @Test public void disabledReporterWritesNothing() throws Exception {
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        GuestHandshakeProgressReporter reporter = new GuestHandshakeProgressReporter(createSink(root, sink), 25565, false);

        reporter.recordInbound("handleIndexedMessage", "S2CRegistry", 4);

        assertFalse(Files.exists(sink));
    }

    @Test public void reporterRejectsUntrustedLabels() throws Exception {
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        GuestHandshakeProgressReporter reporter = new GuestHandshakeProgressReporter(createSink(root, sink), 25565, true);

        reporter.recordInbound("handle\nIndexedMessage", "S2CRegistry", 4);

        assertFalse(Files.exists(sink));
    }
}
