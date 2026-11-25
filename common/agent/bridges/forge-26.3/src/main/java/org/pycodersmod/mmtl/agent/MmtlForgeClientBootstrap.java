package org.pycodersmod.mmtl.agent;

import net.minecraftforge.common.MinecraftForge;

public final class MmtlForgeClientBootstrap {
    private MmtlForgeClientBootstrap() {}

    public static void register(AgentHandshake.Context context, AgentEventSink events) {
        MinecraftForge.EVENT_BUS.register(new MmtlForgeClientEvents(context, events));
    }
}
