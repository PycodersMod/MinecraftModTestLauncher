package org.pycodersmod.mmtl.agent;

import net.minecraft.server.MinecraftServer;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.entity.player.PlayerEvent;
import net.minecraftforge.eventbus.api.listener.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.loading.FMLEnvironment;
import net.minecraftforge.api.distmarker.Dist;

@Mod("mmtl_agent")
public final class MmtlForgeAgent {
    private static volatile AgentHandshake.Context contextForLanPolicy;
    private static volatile boolean managedPublishInProgress;
    private final AgentHandshake.Context context;
    private final AgentEventSink events;

    public MmtlForgeAgent() {
        this.context = AgentHandshake.fromSystemProperties();
        if (context == null) {
            this.events = null;
            return;
        }
        if ("Host".equals(context.role) && context.integratedLanPort > 0) contextForLanPolicy = context;
        this.events = new AgentEventSink(context);
        MinecraftForge.EVENT_BUS.register(this);
        if ("Guest".equals(context.role) || "Client".equals(context.role)
                || ("Host".equals(context.role) && context.integratedLanPort > 0)) {
            if (FMLEnvironment.dist == Dist.CLIENT) {
                try {
                    Class<?> bootstrap = Class.forName("org.pycodersmod.mmtl.agent.MmtlForgeClientBootstrap", true, getClass().getClassLoader());
                    bootstrap.getMethod("register", AgentHandshake.Context.class, AgentEventSink.class).invoke(null, context, events);
                } catch (ReflectiveOperationException failure) {
                    throw new IllegalStateException("Unable to register the MMTL client Agent", failure);
                }
            }
        }
        events.emit("AGENT_STARTED", "Forge Agent handshake accepted for role " + context.role);
        if ("Guest".equals(context.role)) events.emit("GUEST_CONNECTING", "Offline Guest is awaiting the managed loopback connection");
    }

    @SubscribeEvent
    public void onPlayerLoggedIn(PlayerEvent.PlayerLoggedInEvent event) {
        if (context == null || event.getEntity().level().getServer() == null) return;
        MinecraftServer server = event.getEntity().level().getServer();
        if ("Host".equals(context.role) && !server.isDedicatedServer()) {
            events.emit("INTEGRATED_SERVER_READY", "Integrated server is active for the MMTL Host role");
        }
    }

    public static boolean shouldBindLoopback(int port) {
        AgentHandshake.Context current = contextForLanPolicy;
        return managedPublishInProgress && current != null && LanPublishPolicy.isAuthorizedHostPort(true,
                current.role, port) && current.integratedLanPort == port;
    }

    public static java.net.InetAddress selectBindAddress(int port, java.net.InetAddress requestedAddress) {
        AgentHandshake.Context current = contextForLanPolicy;
        return LanPublishPolicy.selectBindAddress(shouldBindLoopback(port),
                current == null ? "None" : current.role, port, requestedAddress);
    }

    public static void setManagedPublishInProgress(boolean value) { managedPublishInProgress = value; }

    public static boolean shouldSuppressLanAdvertisement() {
        AgentHandshake.Context current = contextForLanPolicy;
        return current != null && LanPublishPolicy.shouldSuppressLanAdvertisement(true,
                current.role, current.integratedLanPort);
    }

}
