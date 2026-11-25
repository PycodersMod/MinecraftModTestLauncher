package org.pycodersmod.mmtlfixture;

import org.quiltmc.loader.api.ModContainer;
import org.quiltmc.qsl.base.api.entrypoint.ModInitializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class MmtlMarkerMod implements ModInitializer {
    private static final Logger LOGGER = LoggerFactory.getLogger("mmtl_marker");

    @Override
    public void onInitialize(ModContainer mod) {
        LOGGER.info("MMTL_QUILT_MARKER_INITIALIZED target=Quilt@1.20.6 mod={}", mod.metadata().id());
    }
}