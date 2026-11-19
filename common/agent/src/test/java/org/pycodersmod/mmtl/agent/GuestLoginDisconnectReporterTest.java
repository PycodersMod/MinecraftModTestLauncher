package org.pycodersmod.mmtl.agent;

import org.junit.Test;

import static org.junit.Assert.assertEquals;

public final class GuestLoginDisconnectReporterTest {
    @Test public void timeoutReasonIdentifiesMinecraftNettyReadTimeout() {
        assertEquals("Guest Netty read timeout (disconnect.timeout): Timed out",
                GuestLoginDisconnectReporter.format("disconnect.timeout", "Timed out"));
    }

    @Test public void otherDisconnectReasonsKeepGenericClassification() {
        assertEquals("Guest login disconnected: Took too long to log in",
                GuestLoginDisconnectReporter.format("multiplayer.disconnect.slow_login", "Took too long to log in"));
    }

    @Test public void missingTranslationKeyKeepsGenericClassification() {
        assertEquals("Guest login disconnected: Disconnected",
                GuestLoginDisconnectReporter.format(null, "Disconnected"));
    }
}
