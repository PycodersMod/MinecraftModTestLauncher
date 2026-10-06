package org.pycodersmod.mmtl.agent;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Set;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

public final class AgentHandshake {
    private static final Pattern SESSION = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._-]{0,127}");
    private static final Pattern TOKEN = Pattern.compile("[A-Za-z0-9._-]{32,128}");
    private static final Pattern NONCE_HASH = Pattern.compile("[a-f0-9]{64}");
    private static final Set<String> ROLES = Set.of("Client", "Host", "Guest", "Server");

    private AgentHandshake() {}

    public static Context fromSystemProperties() {
        String token = readSessionToken(System.getProperty("mmtl.agent.sessionTokenFile"),
                System.getProperty("mmtl.agent.sessionRoot"));
        return fromProperties(System.getProperty("mmtl.agent.sessionId"),
                System.getProperty("mmtl.agent.role"),
                System.getProperty("mmtl.agent.allowedRoles"),
                token,
                System.getProperty("mmtl.agent.sessionNonceHash"),
                System.getProperty("mmtl.agent.sessionRoot"),
                System.getProperty("mmtl.agent.eventSink"));
    }

    private static String readSessionToken(String tokenFile, String sessionRoot) {
        if (tokenFile == null || sessionRoot == null) return null;
        try {
            Path root = Path.of(sessionRoot).toAbsolutePath().normalize();
            Path file = Path.of(tokenFile).toAbsolutePath().normalize();
            if (!file.startsWith(root) || file.equals(root) || Files.isSymbolicLink(file)
                    || !Files.isRegularFile(file, java.nio.file.LinkOption.NOFOLLOW_LINKS)) return null;
            return Files.readString(file, StandardCharsets.UTF_8);
        } catch (Exception invalidFile) { return null; }
    }

    static Context fromProperties(String sessionId, String role, String allowedRoles,
                                  String token, String expectedNonceHash, String sessionRoot,
                                  String eventSink) {
        if (sessionId == null || !SESSION.matcher(sessionId).matches() || role == null || !ROLES.contains(role)
                || allowedRoles == null || token == null || !TOKEN.matcher(token).matches()
                || expectedNonceHash == null || !NONCE_HASH.matcher(expectedNonceHash).matches()
                || sessionRoot == null || eventSink == null) return null;
        Set<String> allowed = Arrays.stream(allowedRoles.split(","))
                .map(String::trim).filter(ROLES::contains).collect(Collectors.toSet());
        if (!allowed.contains(role) || !constantTimeEquals(hash(token), expectedNonceHash)) return null;
        try {
            Path root = Path.of(sessionRoot).toAbsolutePath().normalize();
            Path sink = Path.of(eventSink).toAbsolutePath().normalize();
            if (!sink.startsWith(root) || sink.equals(root)) return null;
            return new Context(sessionId, role, token, expectedNonceHash, root, sink);
        } catch (RuntimeException invalidPath) {
            return null;
        }
    }

    private static String hash(String value) {
        try {
            byte[] bytes = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder result = new StringBuilder(64);
            for (byte b : bytes) result.append(String.format("%02x", b & 0xff));
            return result.toString();
        } catch (Exception impossible) { throw new IllegalStateException(impossible); }
    }

    private static boolean constantTimeEquals(String left, String right) {
        return MessageDigest.isEqual(left.getBytes(StandardCharsets.US_ASCII), right.getBytes(StandardCharsets.US_ASCII));
    }

    static final class Context {
        final String sessionId, role, token, nonceHash;
        final Path sessionRoot, eventSink;
        Context(String sessionId, String role, String token, String nonceHash, Path sessionRoot, Path eventSink) {
            this.sessionId=sessionId; this.role=role; this.token=token; this.nonceHash=nonceHash;
            this.sessionRoot=sessionRoot; this.eventSink=eventSink;
        }
    }
}
