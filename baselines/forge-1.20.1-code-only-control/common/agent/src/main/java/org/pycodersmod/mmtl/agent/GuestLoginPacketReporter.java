package org.pycodersmod.mmtl.agent;

import java.util.regex.Pattern;

final class GuestLoginPacketReporter {
    private static final String LOGIN_PACKET_PREFIX = "net.minecraft.network.protocol.login.Clientbound";
    private static final Pattern SAFE_PACKET_TYPE = Pattern.compile("Clientbound[A-Za-z0-9_$]{0,64}");

    private final AgentEventSink events;
    private final int expectedPort;
    private final boolean enabled;

    GuestLoginPacketReporter(AgentEventSink events, int expectedPort, boolean enabled) {
        this.events = events;
        this.expectedPort = expectedPort;
        this.enabled = enabled;
    }

    void recordInbound(String packetClassName) {
        if (!enabled || events == null || expectedPort < 1 || expectedPort > 65535 || packetClassName == null)
            return;
        if (!packetClassName.startsWith(LOGIN_PACKET_PREFIX)) return;

        String packetType = packetClassName.substring(packetClassName.lastIndexOf('.') + 1);
        if (!SAFE_PACKET_TYPE.matcher(packetType).matches()) return;
        events.emit("GUEST_LOGIN_PACKET_RECEIVED", "decoded inbound login packet=" + packetType, expectedPort);
    }
}
