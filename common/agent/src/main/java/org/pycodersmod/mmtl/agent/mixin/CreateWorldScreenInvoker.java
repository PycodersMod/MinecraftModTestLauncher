package org.pycodersmod.mmtl.agent.mixin;

import net.minecraft.client.gui.screens.worldselection.CreateWorldScreen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Invoker;

@Mixin(value = CreateWorldScreen.class, remap = false)
public interface CreateWorldScreenInvoker {
    @Invoker(value = "onCreate", remap = false)
    void mmtl$submitManagedWorldCreation();
}
