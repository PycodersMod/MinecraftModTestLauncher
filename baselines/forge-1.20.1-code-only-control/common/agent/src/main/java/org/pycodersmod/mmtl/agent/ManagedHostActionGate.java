package org.pycodersmod.mmtl.agent;

import java.util.concurrent.atomic.AtomicBoolean;

final class ManagedHostActionGate {
    private final AtomicBoolean claimed = new AtomicBoolean();

    boolean tryClaim() { return claimed.compareAndSet(false, true); }
}
