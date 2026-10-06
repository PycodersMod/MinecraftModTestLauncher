package org.pycodersmod.mmtl.agent.mixin;

import net.minecraft.client.server.IntegratedServer;
import net.minecraft.world.level.GameType;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;

@Mixin(value = IntegratedServer.class, remap = false)
public interface IntegratedServerInvoker {
    @Invoker(value = "publishServer", remap = false)
    boolean mmtl$publishServer(GameType gameType, boolean allowCommands, int port);
}
