package org.pycodersmod.mmtl.agent;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.UUID;

final class AgentEventSink {
    private final AgentHandshake.Context context;
    AgentEventSink(AgentHandshake.Context context) { this.context = context; }

    synchronized void emit(String type, String summary) { emitInternal(type, summary, null, null); }

    synchronized void emit(String type, String summary, String actionId) {
        emitInternal(type, summary, null, actionId);
    }

    synchronized void emit(String type, String summary, Integer port) {
        emitInternal(type, summary, port, null);
    }

    private void emitInternal(String type, String summary, Integer port, String actionId) {
        if (context == null || !context.eventSink.startsWith(context.sessionRoot)) return;
        try {
            Path parent = context.eventSink.getParent();
            if (parent == null || hasSymbolicLink(context.sessionRoot, context.eventSink)) return;
            String line = "{\"schemaVersion\":1,\"sessionId\":\"" + escape(context.sessionId)
                    + "\",\"role\":\"" + escape(context.role) + "\",\"eventId\":\"" + UUID.randomUUID()
                    + "\",\"eventType\":\"" + escape(type) + "\",\"timestampUtc\":\"" + Instant.now()
                    + "\",\"sessionNonceHash\":\"" + context.nonceHash + "\",\"summary\":\"" + escape(summary) + "\""
                    + (port != null && port >= 1 && port <= 65535 ? ",\"port\":" + port : "")
                    + (actionId != null && actionId.matches("[a-f0-9]{32}") ? ",\"actionId\":\"" + actionId + "\"" : "") + "}\n";
            Files.writeString(context.eventSink, line, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND, LinkOption.NOFOLLOW_LINKS);
        } catch (IOException ignored) { /* Telemetry must never crash or block the game. */ }
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
