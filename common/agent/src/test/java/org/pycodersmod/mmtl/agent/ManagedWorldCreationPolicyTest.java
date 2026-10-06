package org.pycodersmod.mmtl.agent;

import net.minecraft.world.Difficulty;
import net.minecraft.world.level.GameType;
import org.junit.Test;

import static org.junit.Assert.*;

public class ManagedWorldCreationPolicyTest {
    @Test public void onlyManagedHostMayCreateConfiguredWorld() {
        assertNull(ManagedWorldCreationPolicy.fromProperties("Client", "true", "Test", "creative", "normal", "", "false"));
        assertNull(ManagedWorldCreationPolicy.fromProperties("Host", "false", "Test", "creative", "normal", "", "false"));
        ManagedWorldCreationPolicy policy=ManagedWorldCreationPolicy.fromProperties("Host", "true", "MMTL-Test", "creative", "peaceful", "42", "true");
        assertNotNull(policy);assertEquals(GameType.CREATIVE,policy.gameType);assertEquals(Difficulty.PEACEFUL,policy.difficulty);
        assertEquals("42",policy.seed);assertTrue(policy.allowCommands);
    }

    @Test public void rejectsInvalidOrTraversalLikeWorldSettings() {
        assertNull(ManagedWorldCreationPolicy.fromProperties("Host", "true", "..", "creative", "normal", "", "false"));
        assertNull(ManagedWorldCreationPolicy.fromProperties("Host", "true", "safe", "unknown", "normal", "", "false"));
        assertNull(ManagedWorldCreationPolicy.fromProperties("Host", "true", "safe", "creative", "unknown", "", "false"));
        assertNull(ManagedWorldCreationPolicy.fromProperties("Host", "true", "safe", "creative", "normal", "../../bad", "false"));
    }
}
