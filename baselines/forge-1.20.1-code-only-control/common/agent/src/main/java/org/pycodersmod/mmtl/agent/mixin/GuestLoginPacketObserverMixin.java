package org.pycodersmod.mmtl.agent.mixin;

import io.netty.channel.ChannelHandlerContext;
import net.minecraft.network.Connection;
import net.minecraft.network.protocol.Packet;
import org.pycodersmod.mmtl.agent.MmtlForgeAgent;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Connection.class)
public abstract class GuestLoginPacketObserverMixin {
    @Inject(method = "channelRead0(Lio/netty/channel/ChannelHandlerContext;Lnet/minecraft/network/protocol/Packet;)V", at = @At("HEAD"))
    private void mmtl$recordDecodedLoginPacket(ChannelHandlerContext context, Packet<?> packet, CallbackInfo callbackInfo) {
        if (packet != null && MmtlForgeAgent.isManagedGuestLoginPacketDiagnosticsEnabled()) {
            MmtlForgeAgent.reportManagedGuestLoginPacket(packet.getClass().getName());
        }
    }
}
