package org.pycodersmod.mmtl.agent;

import org.junit.Test;
import static org.junit.Assert.*;

public final class ManagedHostActionGateTest {
    @Test public void hostLanPublishCannotBeReplayedWithinTheSameClientSession() {
        ManagedHostActionGate gate = new ManagedHostActionGate();
        assertTrue(gate.tryClaim());
        assertFalse(gate.tryClaim());
    }
}
