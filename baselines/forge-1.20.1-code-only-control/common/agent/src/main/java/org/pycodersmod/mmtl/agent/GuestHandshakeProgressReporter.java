package org.pycodersmod.mmtl.agent;

import java.util.regex.Pattern;

final class GuestHandshakeProgressReporter {
    private static final Pattern SAFE_LABEL = Pattern.compile("[A-Za-z][A-Za-z0-9_$]{0,63}");
    private final AgentEventSink events;
    private final int expectedPort;
    private final boolean enabled;

    GuestHandshakeProgressReporter(AgentEventSink events, int expectedPort, boolean enabled) {
        this.events = events;
        this.expectedPort = expectedPort;
        this.enabled = enabled;
    }

    void recordInbound(String handler, String packetType, int sequence) {
        if (!enabled || events == null || expectedPort < 1 || expectedPort > 65535) return;
        if (!isSafeLabel(handler) || !isSafeLabel(packetType) || sequence < -1 || sequence > 65535) return;

        String summary = "inbound handler=" + handler + " packet=" + packetType
                + (sequence < 0 ? "" : " sequence=" + sequence);
        events.emit("GUEST_HANDSHAKE_PROGRESS", summary, expectedPort);
    }

    private static boolean isSafeLabel(String value) {
        return value != null && SAFE_LABEL.matcher(value).matches();
    }
}
