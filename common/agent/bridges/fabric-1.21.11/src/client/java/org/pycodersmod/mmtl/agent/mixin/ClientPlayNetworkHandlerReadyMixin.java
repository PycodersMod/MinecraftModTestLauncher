package org.pycodersmod.mmtl.agent.mixin;

import net.minecraft.client.multiplayer.ClientPacketListener;
import net.minecraft.network.protocol.game.ClientboundLoginPacket;
import org.pycodersmod.mmtl.agent.FabricAgentBootstrap;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(ClientPacketListener.class)
public abstract class ClientPlayNetworkHandlerReadyMixin {
    @Inject(method = "handleLogin", at = @At("TAIL"))
    private void mmtl$reportReadyAfterJoin(ClientboundLoginPacket packet, CallbackInfo callbackInfo) {
        FabricAgentBootstrap.reportLogin(((ClientPacketListener) (Object) this).getConnection().getRemoteAddress());
    }
}
