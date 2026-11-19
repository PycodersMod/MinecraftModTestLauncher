package org.pycodersmod.mmtl.agent;

final class GuestConnectionTrigger {
    private GuestConnectionTrigger() {}

    static boolean shouldStart(String role, String mode, boolean mainMenuReady, boolean alreadyRequested) {
        return "Guest".equals(role) && "AgentAfterMainMenu".equals(mode) && mainMenuReady && !alreadyRequested;
    }

    static String loopbackAddress(int port) {
        if (port < 1 || port > 65535) throw new IllegalArgumentException("Invalid loopback port");
        return "127.0.0.1:" + port;
    }
}
