package org.pycodersmod.mmtl.agent;

import org.junit.Test;
import static org.junit.Assert.*;

public final class FabricWorldCreationPolicyTest {
    @Test
    public void acceptsOnlyValidatedManagedHostWorldSettings() {
        FabricWorldCreationPolicy policy = FabricWorldCreationPolicy.fromProperties(
                "Host", "true", "MMTL Test World", "creative", "peaceful", "42", "true");

        assertNotNull(policy);
        assertEquals("MMTL Test World", policy.name);
        assertEquals("creative", policy.gameMode);
        assertEquals("peaceful", policy.difficulty);
        assertEquals("42", policy.seed);
        assertTrue(policy.allowCommands);
    }

    @Test
    public void rejectsNonHostRolesAndUnsafeWorldNames() {
        assertNull(FabricWorldCreationPolicy.fromProperties("Guest", "true", "World", "survival", "normal", "", "false"));
        assertNull(FabricWorldCreationPolicy.fromProperties("Client", "false", "World", "survival", "normal", "", "false"));
        assertNull(FabricWorldCreationPolicy.fromProperties("Host", "true", "../outside", "survival", "normal", "", "false"));
        assertNull(FabricWorldCreationPolicy.fromProperties("Host", "true", "..", "survival", "normal", "", "false"));
    }

    @Test
    public void allowsOnlyExplicitManagedSingleClientWorldCreation() {
        FabricWorldCreationPolicy policy = FabricWorldCreationPolicy.fromProperties(
                "Client", "true", "MMTL-Single", "survival", "normal", "", "false");

        assertNotNull(policy);
        assertEquals("MMTL-Single", policy.name);
        assertEquals("survival", policy.gameMode);
        assertFalse(policy.allowCommands);
        assertNull(FabricWorldCreationPolicy.fromProperties("Guest", "true", "MMTL-Single", "survival", "normal", "", "false"));
    }

    @Test
    public void rejectsUnsupportedGameModesDifficultiesAndSeeds() {
        assertNull(FabricWorldCreationPolicy.fromProperties("Host", "true", "World", "spectator", "normal", "", "false"));
        assertNull(FabricWorldCreationPolicy.fromProperties("Host", "true", "World", "survival", "invalid", "", "false"));
        assertNull(FabricWorldCreationPolicy.fromProperties("Host", "true", "World", "survival", "normal", "1;stop", "false"));
    }
}
