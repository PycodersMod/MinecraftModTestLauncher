package org.pycodersmod.mmtlfixture;

import cpw.mods.fml.common.Mod;
import cpw.mods.fml.common.event.FMLInitializationEvent;
import cpw.mods.fml.common.event.FMLPreInitializationEvent;

@Mod(modid = MmtlMarkerMod.MOD_ID, name = "MMTL Marker Fixture", version = "1.0.0")
public final class MmtlMarkerMod {
    public static final String MOD_ID = "mmtl_marker_fixture";

    @Mod.EventHandler
    public void preInit(FMLPreInitializationEvent event) {
        System.out.println("MMTL_MARKER_FIXTURE_PREINIT");
    }

    @Mod.EventHandler
    public void init(FMLInitializationEvent event) {
        System.out.println("MMTL_MARKER_FIXTURE_INIT");
    }
}
