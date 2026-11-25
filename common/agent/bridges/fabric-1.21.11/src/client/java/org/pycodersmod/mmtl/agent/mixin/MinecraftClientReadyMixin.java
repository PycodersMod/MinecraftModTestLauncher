package org.pycodersmod.mmtl.agent.mixin;

import net.minecraft.client.Minecraft;
import org.pycodersmod.mmtl.agent.FabricClientController;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Minecraft.class)
public abstract class MinecraftClientReadyMixin {
    @Inject(method = "tick", at = @At("TAIL"))
    private void mmtl$reportReadyTitleScreen(CallbackInfo callbackInfo) {
        Minecraft client = (Minecraft) (Object) this;
        FabricClientController.onClientTick(client);
    }
}
