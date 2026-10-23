package org.pycodersmod.mmtl.agent.mixin;

import net.minecraftforge.network.HandshakeHandler;
import net.minecraftforge.network.HandshakeMessages;
import net.minecraftforge.network.NetworkEvent;
import org.pycodersmod.mmtl.agent.MmtlForgeAgent;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

import java.util.function.IntSupplier;
import java.util.function.Supplier;

@Mixin(value = HandshakeHandler.class, remap = false)
public abstract class GuestHandshakeProgressMixin {
    @Inject(method = "handleServerModListOnClient", at = @At("HEAD"))
    private void mmtl$recordServerModList(HandshakeMessages.S2CModList message,
            Supplier<NetworkEvent.Context> context, CallbackInfo callbackInfo) {
        MmtlForgeAgent.reportManagedGuestHandshakeProgress("handleServerModListOnClient", "S2CModList", -1);
    }

    @Inject(method = "handleModData", at = @At("HEAD"))
    private void mmtl$recordModData(HandshakeMessages.S2CModData message,
            Supplier<NetworkEvent.Context> context, CallbackInfo callbackInfo) {
        MmtlForgeAgent.reportManagedGuestHandshakeProgress("handleModData", "S2CModData", -1);
    }

    @Inject(method = "handleIndexedMessage", at = @At("HEAD"))
    private void mmtl$recordIndexedMessage(IntSupplier message,
            Supplier<NetworkEvent.Context> context, CallbackInfo callbackInfo) {
        MmtlForgeAgent.reportManagedGuestHandshakeProgress("handleIndexedMessage",
                message.getClass().getSimpleName(), message.getAsInt());
    }

    @Inject(method = "handleModMismatchData", at = @At("HEAD"))
    private void mmtl$recordModMismatch(HandshakeMessages.S2CChannelMismatchData message,
            Supplier<NetworkEvent.Context> context, CallbackInfo callbackInfo) {
        MmtlForgeAgent.reportManagedGuestHandshakeProgress("handleModMismatchData", "S2CChannelMismatchData", -1);
    }

    @Inject(method = "handleRegistryMessage", at = @At("HEAD"))
    private void mmtl$recordRegistry(HandshakeMessages.S2CRegistry message,
            Supplier<NetworkEvent.Context> context, CallbackInfo callbackInfo) {
        MmtlForgeAgent.reportManagedGuestHandshakeProgress("handleRegistryMessage", "S2CRegistry", message.getAsInt());
    }

    @Inject(method = "handleConfigSync", at = @At("HEAD"))
    private void mmtl$recordConfigSync(HandshakeMessages.S2CConfigData message,
            Supplier<NetworkEvent.Context> context, CallbackInfo callbackInfo) {
        MmtlForgeAgent.reportManagedGuestHandshakeProgress("handleConfigSync", "S2CConfigData", message.getAsInt());
    }
}
