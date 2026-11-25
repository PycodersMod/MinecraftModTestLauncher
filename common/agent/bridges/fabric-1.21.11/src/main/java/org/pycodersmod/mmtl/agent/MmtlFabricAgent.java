package org.pycodersmod.mmtl.agent;

import net.fabricmc.api.ModInitializer;

public final class MmtlFabricAgent implements ModInitializer {
    @Override
    public void onInitialize() {
        FabricAgentBootstrap.start();
    }
}
