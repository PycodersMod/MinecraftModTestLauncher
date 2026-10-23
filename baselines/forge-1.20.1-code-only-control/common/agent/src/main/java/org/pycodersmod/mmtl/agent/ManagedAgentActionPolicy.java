package org.pycodersmod.mmtl.agent;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.Set;
import java.util.regex.Pattern;

final class ManagedAgentActionPolicy {
    private static final Pattern ID = Pattern.compile("[a-f0-9]{32}");
    private static final Set<String> ROLES = Set.of("Host", "Guest", "Client");
    private ManagedAgentActionPolicy() {}

    static String signedPayload(String sessionId, String role, String id, String action, String commandBase64, String output) {
        return sessionId + "|" + role + "|" + id + "|" + action + "|" + commandBase64 + "|" + output;
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
                if (command.isBlank() || command.length() > 256 || command.startsWith("/") || command.contains("\n") || command.contains("\r")) return false;
                String commandName=command.trim().split("\\s+",2)[0];
                if(commandName.contains(":"))commandName=commandName.substring(commandName.lastIndexOf(':')+1);
                if(Set.of("stop","op","deop","save-all","save-off","save-on","whitelist","ban","pardon").contains(commandName.toLowerCase(java.util.Locale.ROOT)))return false;
            } catch (IllegalArgumentException invalid) { return false; }
        }
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(token.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            byte[] expected = mac.doFinal(signedPayload(session, role, id, action, commandBase64, output).getBytes(StandardCharsets.UTF_8));
            return MessageDigest.isEqual(expected, HexFormat.of().parseHex(signature));
        } catch (Exception invalid) { return false; }
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
