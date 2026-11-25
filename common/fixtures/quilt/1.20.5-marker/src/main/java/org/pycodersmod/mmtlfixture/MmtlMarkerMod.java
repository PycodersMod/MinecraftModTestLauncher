package org.pycodersmod.mmtlfixture;

import net.fabricmc.api.ModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class MmtlMarkerMod implements ModInitializer {
    private static final Logger LOGGER = LoggerFactory.getLogger("mmtl_marker");

    @Override
    public void onInitialize() {
        LOGGER.info("MMTL_QUILT_MARKER_INITIALIZED target=Quilt@1.20.5 mod=mmtl_marker");
    }
}