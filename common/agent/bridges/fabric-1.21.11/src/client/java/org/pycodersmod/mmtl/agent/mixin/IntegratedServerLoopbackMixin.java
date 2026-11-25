package org.pycodersmod.mmtl.agent.mixin;

import net.minecraft.client.server.IntegratedServer;
import org.pycodersmod.mmtl.agent.FabricAgentBootstrap;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyArg;

import java.net.InetAddress;

@Mixin(IntegratedServer.class)
abstract class IntegratedServerLoopbackMixin {
    @ModifyArg(
            method = "publishServer(Lnet/minecraft/world/level/GameType;ZI)Z",
            at = @At(value = "INVOKE", target = "Lnet/minecraft/server/network/ServerConnectionListener;startTcpServerListener(Ljava/net/InetAddress;I)V"),
            index = 0,
            require = 1
    )
    private InetAddress mmtl$bindManagedLanToLoopback(InetAddress requestedAddress, int port) {
        return FabricAgentBootstrap.selectManagedBindAddress(port, requestedAddress);
    }
}
