package org.pycodersmod.mmtl.agent;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.UUID;
import java.util.regex.Pattern;

final class AgentEventSink {
    private static final Pattern WORLD_KEY = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}");
    private static final Pattern DIMENSION_KEY = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}");
    private static final Pattern PLAYER_IDENTITY = Pattern.compile("[A-Za-z0-9._:-]{1,80}");
    private static final Pattern MARKER_ID = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._-]{0,63}");
    private static final Pattern ACTION_ID = Pattern.compile("[a-f0-9]{32}");
    private static final Pattern STATE_HASH = Pattern.compile("[a-f0-9]{64}");
    private final AgentHandshake.Context context;
    AgentEventSink(AgentHandshake.Context context) { this.context = context; }

    synchronized void emit(String type, String summary) { emitInternal(type, summary, null, null); }

    synchronized void emit(String type, String summary, String actionId) {
        emitInternal(type, summary, null, actionId);
    }

    synchronized void emit(String type, String summary, Integer port) {
        emitInternal(type, summary, port, null);
    }

    synchronized boolean emitLanPublished(int port, String bindAddress, String worldKey,
                                          String dimensionKey, String playerIdentity) {
        if (context == null || !"Host".equals(context.role) || port < 1 || port > 65535
                || port != context.integratedLanPort || !"127.0.0.1".equals(bindAddress)
                || !validWorldIdentity(worldKey, dimensionKey, playerIdentity)) return false;
        return emitStructuredEvent("LAN_PUBLISHED", "Managed IntegratedLAN listener is ready on loopback",
                ",\"port\":" + port + ",\"bindAddress\":\"127.0.0.1\",\"worldKey\":\""
                        + escape(worldKey) + "\",\"dimensionKey\":\"" + escape(dimensionKey)
                        + "\",\"playerIdentity\":\"" + escape(playerIdentity) + "\"");
    }

    synchronized boolean emitWorldJoined(String worldKey, String dimensionKey, String playerIdentity) {
        if (context == null || worldKey == null || !WORLD_KEY.matcher(worldKey).matches()
                || dimensionKey == null || !DIMENSION_KEY.matcher(dimensionKey).matches()
                || playerIdentity == null || !PLAYER_IDENTITY.matcher(playerIdentity).matches()) return false;
        String properties = ",\"worldKey\":\"" + escape(worldKey)
                + "\",\"dimensionKey\":\"" + escape(dimensionKey)
                + "\",\"playerIdentity\":\"" + escape(playerIdentity) + "\"";
        if ("Guest".equals(context.role)) {
            if (context.expectedLoopbackPort < 1 || context.expectedLoopbackPort > 65535) return false;
            properties += ",\"port\":" + context.expectedLoopbackPort;
        }
        return emitStructuredEvent("WORLD_JOINED", "Managed player entered a loaded world", properties);
    }

    private static boolean validWorldIdentity(String worldKey, String dimensionKey, String playerIdentity) {
        return worldKey != null && WORLD_KEY.matcher(worldKey).matches()
                && dimensionKey != null && DIMENSION_KEY.matcher(dimensionKey).matches()
                && playerIdentity != null && PLAYER_IDENTITY.matcher(playerIdentity).matches();
    }

    synchronized boolean emitSharedStateWritten(String worldKey, String dimensionKey, String playerIdentity,
                                                String actionId, String markerId, String stateSha256) {
        if (!validSharedState(worldKey, dimensionKey, playerIdentity, markerId, stateSha256)
                || actionId == null || !ACTION_ID.matcher(actionId).matches()) return false;
        String properties = ",\"worldKey\":\"" + escape(worldKey)
                + "\",\"dimensionKey\":\"" + escape(dimensionKey)
                + "\",\"playerIdentity\":\"" + escape(playerIdentity)
                + "\",\"actionId\":\"" + actionId
                + "\",\"protocolId\":\"mmtl-block-marker-v1\",\"operationCode\":\"PLACE_BLOCK_MARKER\""
                + "\",\"markerId\":\"" + escape(markerId)
                + "\",\"stateSha256\":\"" + stateSha256 + "\",\"observed\":true";
        return emitSharedStateEvent("SHARED_STATE_WRITTEN", "Managed actor observed its shared marker state", properties);
    }

    synchronized boolean emitSharedStateObserved(String worldKey, String dimensionKey, String playerIdentity,
                                                 String actorActionId, String markerId, String stateSha256) {
        if (!validSharedState(worldKey, dimensionKey, playerIdentity, markerId, stateSha256)
                || actorActionId == null || !ACTION_ID.matcher(actorActionId).matches()) return false;
        String properties = ",\"worldKey\":\"" + escape(worldKey)
                + "\",\"dimensionKey\":\"" + escape(dimensionKey)
                + "\",\"playerIdentity\":\"" + escape(playerIdentity)
                + "\",\"actorActionId\":\"" + actorActionId
                + "\",\"protocolId\":\"mmtl-block-marker-v1\",\"observationCode\":\"OBSERVE_BLOCK_MARKER\""
                + "\",\"markerId\":\"" + escape(markerId)
                + "\",\"stateSha256\":\"" + stateSha256 + "\",\"observed\":true";
        return emitSharedStateEvent("SHARED_STATE_OBSERVED", "Independent guest observed the shared marker state", properties);
    }

    private static boolean validSharedState(String worldKey, String dimensionKey, String playerIdentity,
                                            String markerId, String stateSha256) {
        return worldKey != null && WORLD_KEY.matcher(worldKey).matches()
                && dimensionKey != null && DIMENSION_KEY.matcher(dimensionKey).matches()
                && playerIdentity != null && PLAYER_IDENTITY.matcher(playerIdentity).matches()
                && markerId != null && MARKER_ID.matcher(markerId).matches()
                && stateSha256 != null && STATE_HASH.matcher(stateSha256).matches();
    }

    private boolean emitSharedStateEvent(String type, String summary, String properties) {
        return emitStructuredEvent(type, summary, properties);
    }

    private boolean emitStructuredEvent(String type, String summary, String properties) {
        if (context == null || !context.eventSink.startsWith(context.sessionRoot)) return false;
        try {
            Path parent = context.eventSink.getParent();
            if (parent == null || hasSymbolicLink(context.sessionRoot, context.eventSink)) return false;
            String line = "{\"schemaVersion\":1,\"sessionId\":\"" + escape(context.sessionId)
                    + "\",\"role\":\"" + escape(context.role) + "\",\"eventId\":\"" + UUID.randomUUID()
                    + "\",\"eventType\":\"" + type + "\",\"timestampUtc\":\"" + Instant.now()
                    + "\",\"sessionNonceHash\":\"" + context.nonceHash + "\",\"summary\":\"" + escape(summary)
                    + "\"" + properties + "}\n";
            Files.write(context.eventSink, line.getBytes(StandardCharsets.UTF_8),
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND, LinkOption.NOFOLLOW_LINKS);
            return true;
        } catch (IOException ignored) { return false; }
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
            Files.write(context.eventSink, line.getBytes(StandardCharsets.UTF_8),
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
