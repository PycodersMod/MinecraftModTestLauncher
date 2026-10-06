package org.pycodersmod.mmtl.agent;

import java.net.InetAddress;

final class LanPublishPolicy {
    private LanPublishPolicy() {}

    static boolean isAuthorizedHostPort(boolean activeHost, String role, int port) {
        return activeHost && "Host".equals(role) && port >= 1 && port <= 65535;
    }

    static boolean shouldSuppressLanAdvertisement(boolean activeHost, String role, int port) {
        return isAuthorizedHostPort(activeHost, role, port);
    }

    static boolean canPublishIntegratedServer(boolean validHandshake, boolean dedicatedServer, String role, int port) {
        return validHandshake && !dedicatedServer && isAuthorizedHostPort(true, role, port);
    }

    static InetAddress selectBindAddress(boolean activeHost, String role, int port, InetAddress originalAddress) {
        if (!isAuthorizedHostPort(activeHost, role, port)) return originalAddress;
        try { return InetAddress.getByAddress(new byte[] {127, 0, 0, 1}); }
        catch (java.net.UnknownHostException impossible) { throw new IllegalStateException(impossible); }
    }
}
