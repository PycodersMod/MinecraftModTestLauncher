package org.pycodersmod.mmtl.agent;

import org.junit.Test;

import static org.junit.Assert.*;

public class GuestConnectionTriggerTest {
    @Test public void startsOnlyAfterMainMenuForAgentModeGuest() {
        assertTrue(GuestConnectionTrigger.shouldStart("Guest", "AgentAfterMainMenu", true, false));
        assertFalse(GuestConnectionTrigger.shouldStart("Guest", "QuickPlay", true, false));
        assertFalse(GuestConnectionTrigger.shouldStart("Guest", "AgentAfterMainMenu", false, false));
        assertFalse(GuestConnectionTrigger.shouldStart("Host", "AgentAfterMainMenu", true, false));
        assertFalse(GuestConnectionTrigger.shouldStart("Guest", "AgentAfterMainMenu", true, true));
    }

    @Test public void buildsOnlyLoopbackAddressForValidatedPort() {
        assertEquals("127.0.0.1:39127", GuestConnectionTrigger.loopbackAddress(39127));
        assertThrows(IllegalArgumentException.class, () -> GuestConnectionTrigger.loopbackAddress(0));
        assertThrows(IllegalArgumentException.class, () -> GuestConnectionTrigger.loopbackAddress(65536));
    }
}
