package org.pycodersmod.mmtl.agent;

import org.junit.Test;
import java.net.InetAddress;
import static org.junit.Assert.*;

public final class LanPublishPolicyTest {
    @Test public void managedHostWithValidPortBindsOnlyLoopback() throws Exception {
        InetAddress original = InetAddress.getByName("0.0.0.0");
        InetAddress selected = LanPublishPolicy.selectBindAddress(true, "Host", 25565, original);
        assertTrue(selected.isLoopbackAddress());
        assertEquals("127.0.0.1", selected.getHostAddress());
    }

    @Test public void ordinaryVanillaPublishAddressIsPreserved() throws Exception {
        InetAddress original = InetAddress.getByName("0.0.0.0");
        assertSame(original, LanPublishPolicy.selectBindAddress(false, "Host", 25565, original));
        assertSame(original, LanPublishPolicy.selectBindAddress(true, "Guest", 25565, original));
    }

    @Test public void rejectsMissingOrInvalidHostPortForLoopbackOverride() throws Exception {
        InetAddress original = InetAddress.getByName("0.0.0.0");
        assertSame(original, LanPublishPolicy.selectBindAddress(true, "Host", 0, original));
        assertSame(original, LanPublishPolicy.selectBindAddress(true, "Host", 65536, original));
        assertSame(original, LanPublishPolicy.selectBindAddress(true, "Dedicated", 25565, original));
    }

    @Test public void suppressesOnlyManagedHostLanDiscoveryBroadcast() {
        assertTrue(LanPublishPolicy.shouldSuppressLanAdvertisement(true, "Host", 25565));
        assertFalse(LanPublishPolicy.shouldSuppressLanAdvertisement(false, "Host", 25565));
        assertFalse(LanPublishPolicy.shouldSuppressLanAdvertisement(true, "Guest", 25565));
        assertFalse(LanPublishPolicy.shouldSuppressLanAdvertisement(true, "Host", 0));
    }

    @Test public void integratedPublishRequiresValidHostHandshakeAndIntegratedServer() {
        assertTrue(LanPublishPolicy.canPublishIntegratedServer(true, false, "Host", 25565));
        assertFalse(LanPublishPolicy.canPublishIntegratedServer(false, false, "Host", 25565));
        assertFalse(LanPublishPolicy.canPublishIntegratedServer(true, true, "Host", 25565));
        assertFalse(LanPublishPolicy.canPublishIntegratedServer(true, false, "Guest", 25565));
        assertFalse(LanPublishPolicy.canPublishIntegratedServer(true, false, "Host", 0));
    }
}
