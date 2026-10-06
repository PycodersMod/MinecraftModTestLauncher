package org.pycodersmod.mmtl.agent;

import net.minecraft.client.Minecraft;
import net.minecraft.client.server.IntegratedServer;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraftforge.client.event.ClientPlayerNetworkEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.event.TickEvent;
import org.pycodersmod.mmtl.agent.mixin.IntegratedServerInvoker;

import java.net.InetSocketAddress;
import java.net.SocketAddress;

final class MmtlForgeClientEvents {
    private final AgentHandshake.Context context;
    private final AgentEventSink events;
    private final ManagedHostActionGate publishGate = new ManagedHostActionGate();
    private boolean clientReadyReported;

    MmtlForgeClientEvents(AgentHandshake.Context context, AgentEventSink events) {
        this.context = context;
        this.events = events;
    }

    @SubscribeEvent
    public void onClientLoggingIn(ClientPlayerNetworkEvent.LoggingIn event) {
        if ("Host".equals(context.role) && context.integratedLanPort > 0) {
            reportClientReady("Managed Host client reached its world login event");
            publishManagedIntegratedLan();
            return;
        }
        if (!("Guest".equals(context.role) || "Client".equals(context.role))) return;
        if ("Guest".equals(context.role) && !isExpectedLoopback(event.getConnection().getRemoteAddress())) {
            events.emit("AGENT_ERROR", "Guest connection endpoint did not match the managed loopback target");
            return;
        }
        reportClientReady("Managed client reached its login event");
        if ("Guest".equals(context.role)) events.emit("GUEST_CONNECTED", "Offline Guest joined the managed local session");
        events.emit("WORLD_JOINED", "Client player entered the joined world");
    }

    @SubscribeEvent
    public void onClientTick(TickEvent.ClientTickEvent event) {
        if (event.phase != TickEvent.Phase.END || clientReadyReported) return;
        if (Minecraft.getInstance().screen instanceof TitleScreen) reportClientReady("Minecraft main menu is ready");
    }

    private void reportClientReady(String summary) {
        if (clientReadyReported) return;
        clientReadyReported = true;
        events.emit("CLIENT_READY", summary);
    }

    private void publishManagedIntegratedLan() {
        if (!publishGate.tryClaim()) return;
        IntegratedServer server = Minecraft.getInstance().getSingleplayerServer();
        if (server == null || !LanPublishPolicy.canPublishIntegratedServer(context != null,
                server != null && server.isDedicatedServer(), context.role, context.integratedLanPort)) {
            events.emit("AGENT_ERROR", "Managed IntegratedLAN host server was unavailable");
            return;
        }
        try {
            IntegratedServerInvoker invoker = (IntegratedServerInvoker) server;
            server.setUsesAuthentication(false);
            events.emit("OFFLINE_AUTH_ENABLED", "Offline authentication enabled for the managed IntegratedLAN host");
            events.emit("LAN_PUBLISH_REQUESTED", "Managed offline IntegratedLAN publish requested on loopback", context.integratedLanPort);
            boolean result;
            MmtlForgeAgent.setManagedPublishInProgress(true);
            try {
                result = invoker.mmtl$publishServer(server.getDefaultGameType(), false,
                        context.integratedLanPort);
            } finally { MmtlForgeAgent.setManagedPublishInProgress(false); }
            if (result) events.emit("LAN_PUBLISHED", "Managed IntegratedLAN listener is ready on loopback", context.integratedLanPort);
            else events.emit("LAN_PUBLISH_FAILED", "IntegratedLAN publish returned false", context.integratedLanPort);
        } catch (RuntimeException failure) {
            MmtlForgeAgent.setManagedPublishInProgress(false);
            events.emit("AGENT_ERROR", "Managed IntegratedLAN publish failed: " + failure.getClass().getSimpleName());
        }
    }

    private boolean isExpectedLoopback(SocketAddress address) {
        if (!(address instanceof InetSocketAddress inet) || inet.getAddress() == null || !inet.getAddress().isLoopbackAddress()) return false;
        return inet.getPort() == context.expectedLoopbackPort;
    }
}
