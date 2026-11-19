package org.pycodersmod.mmtl.agent.mixin;

import net.minecraft.client.multiplayer.ClientHandshakePacketListenerImpl;
import net.minecraft.network.chat.Component;
import org.pycodersmod.mmtl.agent.MmtlForgeAgent;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(ClientHandshakePacketListenerImpl.class)
public abstract class GuestLoginDisconnectMixin {
    @Inject(method = "onDisconnect", at = @At("HEAD"))
    private void mmtl$reportGuestLoginDisconnect(Component reason, CallbackInfo callbackInfo) {
        MmtlForgeAgent.reportManagedGuestLoginDisconnect(reason);
    }
}
