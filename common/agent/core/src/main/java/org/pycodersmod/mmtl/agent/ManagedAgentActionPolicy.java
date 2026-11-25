package org.pycodersmod.mmtl.agent;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.regex.Pattern;

final class ManagedAgentActionPolicy {
    private static final Pattern ID = Pattern.compile("[a-f0-9]{32}");
    private static final Set<String> ROLES = Collections.unmodifiableSet(
            new HashSet<>(Arrays.asList("Host", "Guest", "Client")));
    private static final Set<String> BLOCKED_COMMANDS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
            "stop", "op", "deop", "save-all", "save-off", "save-on", "whitelist", "ban", "pardon")));
    private ManagedAgentActionPolicy() {}

    static String signedPayload(String sessionId, String role, String id, String action, String commandBase64, String output) {
        return sessionId + "|" + role + "|" + id + "|" + action + "|" + commandBase64 + "|" + output;
    }

    static String sharedMarkerPayload(String sessionId, String role, String id, String action, String actorActionId, String markerId,
                                      String dimensionKey, int x, int y, int z, String stateSha256) {
        return signedPayload(sessionId, role, id, action, "", "") + "|" + actorActionId + "|" + markerId + "|" + dimensionKey
                + "|" + x + "|" + y + "|" + z + "|" + stateSha256;
    }

    static boolean isAuthorizedSharedMarker(String expectedSession, String expectedRole, String session, String role,
                                            String id, String action, String actorActionId, String markerId, String dimensionKey,
                                            int x, int y, int z, String stateSha256, String signature, String token) {
        if (expectedSession == null || !expectedSession.equals(session) || expectedRole == null
                || !expectedRole.equals(role) || !ID.matcher(id == null ? "" : id).matches()
                || !("Host".equals(role) && "PLACE_BLOCK_MARKER".equals(action)
                || "Guest".equals(role) && "OBSERVE_BLOCK_MARKER".equals(action))
                || !ID.matcher(actorActionId == null ? "" : actorActionId).matches()
                || ("Host".equals(role) && !id.equals(actorActionId))
                || markerId == null || !markerId.matches("[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
                || dimensionKey == null || !dimensionKey.matches("[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}")
                || x < -64 || x > 64 || z < -64 || z > 64 || y < -64 || y > 320
                || stateSha256 == null || !stateSha256.matches("[a-f0-9]{64}")) return false;
        String payload = sharedMarkerPayload(session, role, id, action, actorActionId, markerId, dimensionKey, x, y, z, stateSha256);
        return isSignatureValid(payload, signature, token);
    }

    static boolean isAuthorized(String expectedSession, String expectedRole, String session, String role,
                                String id, String action, String commandBase64, String output, String signature, String token) {
        if (expectedSession == null || !expectedSession.equals(session) || expectedRole == null || !expectedRole.equals(role)
                || !ROLES.contains(role) || id == null || !ID.matcher(id).matches()
                || !("SEND_COMMAND".equals(action) || "SCREENSHOT".equals(action)) || token == null || signature == null) return false;
        if ("SCREENSHOT".equals(action)) {
            if (commandBase64 != null && !commandBase64.isEmpty()) return false;
            if (output == null || !output.equals("screenshots/" + role + "/" + id + ".png")) return false;
        } else {
            if (output == null || !output.isEmpty() || commandBase64 == null) return false;
            try {
                String command = new String(java.util.Base64.getDecoder().decode(commandBase64), StandardCharsets.UTF_8);
                if (isBlank(command) || command.length() > 256 || command.startsWith("/") || command.contains("\n") || command.contains("\r")) return false;
                String commandName=command.trim().split("\\s+",2)[0];
                if(commandName.contains(":"))commandName=commandName.substring(commandName.lastIndexOf(':')+1);
                if(BLOCKED_COMMANDS.contains(commandName.toLowerCase(java.util.Locale.ROOT)))return false;
            } catch (IllegalArgumentException invalid) { return false; }
        }
        return isSignatureValid(signedPayload(session, role, id, action, commandBase64, output), signature, token);
    }

    private static boolean isSignatureValid(String payload, String signature, String token) {
        if (token == null || signature == null) return false;
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(token.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            byte[] expected = mac.doFinal(payload.getBytes(StandardCharsets.UTF_8));
            return MessageDigest.isEqual(expected, decodeHex(signature));
        } catch (Exception invalid) { return false; }
    }

    private static byte[] decodeHex(String value) {
        if (value == null || (value.length() & 1) != 0) throw new IllegalArgumentException("Invalid hexadecimal value");
        byte[] decoded = new byte[value.length() / 2];
        for (int i = 0; i < decoded.length; i++) {
            int high = Character.digit(value.charAt(i * 2), 16);
            int low = Character.digit(value.charAt(i * 2 + 1), 16);
            if (high < 0 || low < 0) throw new IllegalArgumentException("Invalid hexadecimal value");
            decoded[i] = (byte) ((high << 4) | low);
        }
        return decoded;
    }

    private static boolean isBlank(String value) {
        if (value == null || value.isEmpty()) return true;
        for (int i = 0; i < value.length(); i++) {
            if (!Character.isWhitespace(value.charAt(i))) return false;
        }
        return true;
    }

    static Path safeSessionPath(Path root, String relative) {
        if (root == null || relative == null) return null;
        Path target = root.resolve(relative).normalize();
        if (!target.startsWith(root.normalize()) || target.equals(root.normalize())) return null;
        Path current = root.normalize();
        if (java.nio.file.Files.isSymbolicLink(current)) return null;
        for (Path part : current.relativize(target)) {
            current = current.resolve(part);
            if (java.nio.file.Files.isSymbolicLink(current)) return null;
        }
        return target;
    }
}
