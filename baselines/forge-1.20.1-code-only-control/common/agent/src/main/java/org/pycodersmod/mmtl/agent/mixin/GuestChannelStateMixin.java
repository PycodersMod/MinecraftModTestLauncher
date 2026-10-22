package org.pycodersmod.mmtl.agent.mixin;

import io.netty.channel.ChannelHandlerContext;
import net.minecraft.network.Connection;
import org.pycodersmod.mmtl.agent.MmtlForgeAgent;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Connection.class)
public abstract class GuestChannelStateMixin {
    @Inject(method = "channelActive(Lio/netty/channel/ChannelHandlerContext;)V", at = @At("TAIL"))
    private void mmtl$observeManagedGuestChannel(ChannelHandlerContext context, CallbackInfo callbackInfo) {
        if (context != null) MmtlForgeAgent.observeManagedGuestChannel(context.channel());
    }
}
