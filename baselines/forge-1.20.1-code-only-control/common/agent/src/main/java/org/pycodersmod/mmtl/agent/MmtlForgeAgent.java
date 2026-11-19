package org.pycodersmod.mmtl.agent;

import net.minecraft.server.MinecraftServer;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.entity.player.PlayerEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.DistExecutor;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraft.network.chat.contents.TranslatableContents;
import io.netty.channel.Channel;

@Mod("mmtl_agent")
public final class MmtlForgeAgent {
    private static volatile AgentHandshake.Context contextForLanPolicy;
    private static volatile boolean managedPublishInProgress;
    private static volatile AgentEventSink managedGuestEvents;
    private static volatile GuestHandshakeProgressReporter managedGuestHandshakeProgress;
    private static volatile GuestLoginPacketReporter managedGuestLoginPacketReporter;
    private static volatile boolean managedGuestLoginPacketDiagnosticsEnabled;
    private static volatile GuestChannelStateSampler managedGuestChannelStateSampler;
    private static volatile int managedGuestPort;
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
        if ("Guest".equals(context.role)) {
            managedGuestEvents = events;
            managedGuestPort = context.expectedLoopbackPort;
            managedGuestLoginPacketDiagnosticsEnabled = Boolean.getBoolean("mmtl.agent.guestHandshakeDiagnostics");
            managedGuestHandshakeProgress = new GuestHandshakeProgressReporter(events, managedGuestPort,
                    managedGuestLoginPacketDiagnosticsEnabled);
            managedGuestLoginPacketReporter = new GuestLoginPacketReporter(events, managedGuestPort,
                    managedGuestLoginPacketDiagnosticsEnabled);
        }
        MinecraftForge.EVENT_BUS.register(this);
        if ("Guest".equals(context.role) || "Client".equals(context.role)
                || ("Host".equals(context.role) && context.integratedLanPort > 0)) {
            DistExecutor.unsafeRunWhenOn(Dist.CLIENT,
                    () -> () -> MinecraftForge.EVENT_BUS.register(new MmtlForgeClientEvents(context, events)));
        }
        events.emit("AGENT_STARTED", "Forge Agent handshake accepted for role " + context.role);
        if ("Guest".equals(context.role)) events.emit("GUEST_CONNECTING", "Offline Guest is awaiting the managed loopback connection");
    }

    @SubscribeEvent
    public void onPlayerLoggedIn(PlayerEvent.PlayerLoggedInEvent event) {
        if (context == null || event.getEntity().getServer() == null) return;
        MinecraftServer server = event.getEntity().getServer();
        if ("Host".equals(context.role) && !server.isDedicatedServer()) {
            events.emit("INTEGRATED_SERVER_READY", "Integrated server is active for the MMTL Host role");
            events.emitPlayerName("PLAYER_JOINED", "A managed test player joined the Host world", event.getEntity().getGameProfile().getName());
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

    public static void reportManagedGuestLoginDisconnect(net.minecraft.network.chat.Component reason) {
        AgentEventSink sink = managedGuestEvents;
        int port = managedGuestPort;
        if (sink == null || port < 1 || port > 65535) return;
        String detail = reason == null ? "unknown disconnect reason" : reason.getString();
        detail = detail.replaceAll("[\\p{Cntrl}]", " ").replaceAll("\\s+", " ").trim();
        if (detail.isEmpty()) detail = "unknown disconnect reason";
        if (detail.length() > 160) detail = detail.substring(0, 160);
        String translationKey = reason != null && reason.getContents() instanceof TranslatableContents translated
                ? translated.getKey() : null;
        sink.emit("GUEST_CONNECTION_FAILED", GuestLoginDisconnectReporter.format(translationKey, detail), port);
        stopManagedGuestChannelDiagnostics();
    }

    public static void reportManagedGuestHandshakeProgress(String handler, String packetType, int sequence) {
        GuestHandshakeProgressReporter reporter = managedGuestHandshakeProgress;
        if (reporter != null) reporter.recordInbound(handler, packetType, sequence);
    }

    public static void reportManagedGuestLoginPacket(String packetClassName) {
        GuestLoginPacketReporter reporter = managedGuestLoginPacketReporter;
        if (reporter != null) reporter.recordInbound(packetClassName);
    }

    public static boolean isManagedGuestLoginPacketDiagnosticsEnabled() {
        return managedGuestLoginPacketDiagnosticsEnabled;
    }

    public static synchronized void observeManagedGuestChannel(Channel channel) {
        if (managedGuestEvents == null || managedGuestPort < 1 || !managedGuestLoginPacketDiagnosticsEnabled) return;
        GuestChannelStateSampler previous = managedGuestChannelStateSampler;
        if (previous != null) previous.stop();
        managedGuestChannelStateSampler = GuestChannelStateSampler.start(channel, managedGuestEvents,
                managedGuestPort, true);
    }

    public static synchronized void stopManagedGuestChannelDiagnostics() {
        GuestChannelStateSampler sampler = managedGuestChannelStateSampler;
        managedGuestChannelStateSampler = null;
        if (sampler != null) sampler.stop();
    }

    public static boolean shouldSuppressLanAdvertisement() {
        AgentHandshake.Context current = contextForLanPolicy;
        return current != null && LanPublishPolicy.shouldSuppressLanAdvertisement(true,
                current.role, current.integratedLanPort);
    }

}
