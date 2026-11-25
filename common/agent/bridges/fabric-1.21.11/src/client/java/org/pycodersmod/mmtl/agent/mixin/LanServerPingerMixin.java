package org.pycodersmod.mmtl.agent.mixin;

import net.minecraft.client.server.LanServerPinger;
import org.pycodersmod.mmtl.agent.FabricAgentBootstrap;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(LanServerPinger.class)
abstract class LanServerPingerMixin {
    @Inject(method = "run()V", at = @At("HEAD"), cancellable = true, require = 1)
    private void mmtl$suppressManagedLanAdvertisement(CallbackInfo callback) {
        if (FabricAgentBootstrap.shouldSuppressLanAdvertisement()) callback.cancel();
    }
}
