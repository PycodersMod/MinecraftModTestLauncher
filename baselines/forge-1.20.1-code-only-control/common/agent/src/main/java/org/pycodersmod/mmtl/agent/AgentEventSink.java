package org.pycodersmod.mmtl.agent;

import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.file.LinkOption;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.UUID;

final class AgentEventSink {
    private final AgentHandshake.Context context;
    private long lastWriteWarningNanos;
    private int suppressedWriteWarnings;
    AgentEventSink(AgentHandshake.Context context) { this.context = context; }

    synchronized void emit(String type, String summary) { emitInternal(type, summary, null, null, null, null); }

    synchronized void emit(String type, String summary, String actionId) {
        emitInternal(type, summary, null, actionId, null, null);
    }

    synchronized void emit(String type, String summary, Integer port) {
        emitInternal(type, summary, port, null, null, null);
    }

    synchronized void emit(String type, String summary, Integer port, String bindAddress) {
        emitInternal(type, summary, port, null, bindAddress, null);
    }

    synchronized void emitPlayerName(String type, String summary, String playerName) {
        emitInternal(type, summary, null, null, null, playerName);
    }

    private void emitInternal(String type, String summary, Integer port, String actionId, String bindAddress, String playerName) {
        if (context == null || !context.eventSink.startsWith(context.sessionRoot)) return;
        try {
            Path parent = context.eventSink.getParent();
            if (parent == null || hasSymbolicLink(context.sessionRoot, context.eventSink)) return;
            String line = "{\"schemaVersion\":1,\"sessionId\":\"" + escape(context.sessionId)
                    + "\",\"role\":\"" + escape(context.role) + "\",\"eventId\":\"" + UUID.randomUUID()
                    + "\",\"eventType\":\"" + escape(type) + "\",\"timestampUtc\":\"" + Instant.now()
                    + "\",\"sessionNonceHash\":\"" + context.nonceHash + "\",\"summary\":\"" + escape(summary) + "\""
                    + (port != null && port >= 1 && port <= 65535 ? ",\"port\":" + port : "")
                    + (actionId != null && actionId.matches("[a-f0-9]{32}") ? ",\"actionId\":\"" + actionId + "\"" : "")
                    + (bindAddress != null && "127.0.0.1".equals(bindAddress) ? ",\"bindAddress\":\"127.0.0.1\"" : "")
                    + (playerName != null && playerName.matches("[A-Za-z0-9_]{1,16}") ? ",\"playerName\":\"" + escape(playerName) + "\"" : "") + "}\n";
            byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
            try (FileChannel channel = FileChannel.open(context.eventSink,
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE, StandardOpenOption.APPEND,
                    LinkOption.NOFOLLOW_LINKS)) {
                ByteBuffer buffer = ByteBuffer.wrap(bytes);
                while (buffer.hasRemaining()) channel.write(buffer);
            }
        } catch (IOException failure) {
            warnWriteFailure(type, failure);
        }
    }

    private void warnWriteFailure(String type, IOException failure) {
        long now = System.nanoTime();
        if (lastWriteWarningNanos != 0 && now - lastWriteWarningNanos < 5_000_000_000L) {
            suppressedWriteWarnings++;
            return;
        }
        PrintStream error = System.err;
        error.println("[MMTL Agent] event write failed type=" + type
                + " error=" + failure.getClass().getSimpleName() + ": " + failure.getMessage()
                + (suppressedWriteWarnings == 0 ? "" : " (suppressed " + suppressedWriteWarnings + " similar warnings)"));
        lastWriteWarningNanos = now;
        suppressedWriteWarnings = 0;
    }

    private static boolean hasSymbolicLink(Path root, Path target) {
        if (Files.isSymbolicLink(root)) return true;
        Path current = root;
        for (Path part : root.relativize(target)) {
            current = current.resolve(part);
            if (Files.isSymbolicLink(current)) return true;
        }
        return false;
    }

    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"")
                .replace("\r", " ").replace("\n", " ");
    }
}
