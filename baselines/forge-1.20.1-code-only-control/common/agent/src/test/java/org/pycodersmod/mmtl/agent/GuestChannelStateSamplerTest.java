package org.pycodersmod.mmtl.agent;

import io.netty.channel.embedded.EmbeddedChannel;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;

import static org.junit.Assert.assertEquals;

public final class GuestChannelStateSamplerTest {
    @Rule public TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test public void samplesOnlyWhenCallerTicksAtOneSecondIntervals() throws Exception {
        Path root = temporaryFolder.getRoot().toPath();
        Path sink = root.resolve("events/guest.jsonl");
        String token = "agent-test-token-0123456789abcdef";
        StringBuilder hash = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.UTF_8)))
            hash.append(String.format("%02x", value & 255));
        Files.createDirectories(sink.getParent());
        AgentHandshake.Context context = AgentHandshake.fromProperties("session_a", "Guest", "Guest", token,
                hash.toString(), root.toString(), sink.toString(), 0, 25565);
        AgentEventSink events = new AgentEventSink(context);
        GuestChannelStateReporter reporter = new GuestChannelStateReporter(events, 25565, true);
        EmbeddedChannel channel = new EmbeddedChannel();
        GuestChannelStateSampler sampler = new GuestChannelStateSampler(channel, reporter);

        sampler.tick(1_000_000_000L);
        assertEquals(1, Files.readAllLines(sink).size());
        sampler.tick(1_999_999_999L);
        assertEquals(1, Files.readAllLines(sink).size());
        sampler.tick(2_000_000_000L);
        assertEquals(2, Files.readAllLines(sink).size());
        sampler.stop();
        sampler.tick(3_000_000_000L);
        assertEquals(2, Files.readAllLines(sink).size());
        channel.finishAndReleaseAll();
    }
}
