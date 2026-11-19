package org.pycodersmod.mmtl.agent.mixin;

import net.minecraft.client.server.IntegratedServer;
import net.minecraft.world.level.GameType;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;

@Mixin(IntegratedServer.class)
public interface IntegratedServerInvoker {
    @Invoker("publishServer")
    boolean mmtl$publishServer(GameType gameType, boolean allowCommands, int port);
}
