package org.pycodersmod.mmtl.agent;

final class GuestLoginDisconnectReporter {
    private GuestLoginDisconnectReporter() {}

    static String format(String translationKey, String detail) {
        if ("disconnect.timeout".equals(translationKey)) {
            return "Guest Netty read timeout (disconnect.timeout): " + detail;
        }
        return "Guest login disconnected: " + detail;
    }
}
