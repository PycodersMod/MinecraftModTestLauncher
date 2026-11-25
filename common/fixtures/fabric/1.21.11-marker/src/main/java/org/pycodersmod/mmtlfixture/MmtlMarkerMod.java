package org.pycodersmod.mmtlfixture;

import net.fabricmc.api.ModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class MmtlMarkerMod implements ModInitializer {
    public static final String MOD_ID = "mmtl_marker";
    private static final Logger LOGGER = LoggerFactory.getLogger(MOD_ID);

    @Override
    public void onInitialize() {
        LOGGER.info("MMTL Fabric marker initialized");
    }
}