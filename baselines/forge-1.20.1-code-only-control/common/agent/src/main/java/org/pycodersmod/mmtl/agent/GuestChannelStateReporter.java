package org.pycodersmod.mmtl.agent;

import java.util.regex.Pattern;

final class GuestChannelStateReporter {
    private static final Pattern SAFE_SELECTION_KEY_STATE = Pattern.compile(
            "(?:valid=(?:true|false),interestOps=-?\\d+,readyOps=-?\\d+|unavailable:[A-Za-z0-9_-]{1,48})");

    private final AgentEventSink events;
    private final int expectedPort;
    private final boolean enabled;

    GuestChannelStateReporter(AgentEventSink events, int expectedPort, boolean enabled) {
        this.events = events;
        this.expectedPort = expectedPort;
        this.enabled = enabled;
    }

    void record(boolean registered, boolean active, boolean open, boolean autoRead, String selectionKeyState) {
        if (!enabled || events == null || expectedPort < 1 || expectedPort > 65535) return;
        String keyState = selectionKeyState != null && SAFE_SELECTION_KEY_STATE.matcher(selectionKeyState).matches()
                ? selectionKeyState : "unavailable:invalid-state";
        String summary = "channel registered=" + registered + " active=" + active + " open=" + open
                + " autoRead=" + autoRead + " selectionKey=" + keyState;
        events.emit("GUEST_CHANNEL_STATE", summary, expectedPort);
    }
}
