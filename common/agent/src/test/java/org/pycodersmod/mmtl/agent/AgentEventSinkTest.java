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
        new AgentEventSink(context).emit("LAN_PUBLISHED", "listener ready", 25565);
        String event = Files.readString(sink);
        assertTrue(event.contains("\"port\":25565"));
        assertTrue(event.contains("\"sessionNonceHash\":\"" + hash + "\""));
        assertFalse(event.contains(token));
    }
}
