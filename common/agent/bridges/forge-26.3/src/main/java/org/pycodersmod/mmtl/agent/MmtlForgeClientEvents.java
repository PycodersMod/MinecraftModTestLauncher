package org.pycodersmod.mmtl.agent;

import net.minecraft.client.Minecraft;
import net.minecraft.client.server.IntegratedServer;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraft.client.gui.screens.worldselection.CreateWorldScreen;
import net.minecraft.client.gui.screens.worldselection.WorldCreationUiState;
import net.minecraft.world.Difficulty;
import net.minecraftforge.client.event.ClientPlayerNetworkEvent;
import net.minecraftforge.eventbus.api.listener.SubscribeEvent;
import net.minecraftforge.event.TickEvent;
import org.pycodersmod.mmtl.agent.mixin.IntegratedServerInvoker;
import org.pycodersmod.mmtl.agent.mixin.CreateWorldScreenInvoker;

import java.net.InetSocketAddress;
import java.net.SocketAddress;

final class MmtlForgeClientEvents {
    private final AgentHandshake.Context context;
    private final AgentEventSink events;
    private final ManagedHostActionGate publishGate = new ManagedHostActionGate();
    private final ManagedAgentActionProcessor actionProcessor;
    private boolean clientReadyReported;
    private boolean worldCreationRequested;
    private boolean worldCreationSubmitted;
    private final ManagedWorldCreationPolicy worldCreationPolicy;

    MmtlForgeClientEvents(AgentHandshake.Context context, AgentEventSink events) {
        this.context = context;
        this.events = events;
        this.actionProcessor = new ManagedAgentActionProcessor(context, events);
        this.worldCreationPolicy = ManagedWorldCreationPolicy.fromProperties(context.role,
                System.getProperty("mmtl.agent.autoCreateWorld"),
                System.getProperty("mmtl.agent.worldName"),
                System.getProperty("mmtl.agent.worldGameMode"),
                System.getProperty("mmtl.agent.worldDifficulty"),
                System.getProperty("mmtl.agent.worldSeed"),
                System.getProperty("mmtl.agent.worldAllowCommands"));
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
        if ("Guest".equals(context.role)) events.emit("GUEST_CONNECTED", "Offline Guest joined the managed local session", context.expectedLoopbackPort);
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.level != null && minecraft.player != null) {
            events.emitWorldJoined(context.sessionId, minecraft.level.dimension().identifier().toString(),
                    minecraft.player.getUUID().toString());
        }
    }

    @SubscribeEvent
    public void onClientTick(TickEvent.ClientTickEvent.Post event) {
        Minecraft minecraft = Minecraft.getInstance();
        actionProcessor.tick(minecraft);
        if (worldCreationPolicy != null && !worldCreationRequested && minecraft.gui.screen() instanceof TitleScreen) {
            reportClientReady("Minecraft main menu is ready; MMTL will create the Session-local test world");
            worldCreationRequested = true;
            events.emit("WORLD_CREATE_REQUESTED", "Managed Host requested creation of its isolated test world");
            CreateWorldScreen.openFresh(minecraft, () -> minecraft.gui.setScreen(new TitleScreen()));
            return;
        }
        if (worldCreationPolicy != null && worldCreationRequested && !worldCreationSubmitted
                && minecraft.gui.screen() instanceof CreateWorldScreen createWorldScreen) {
            WorldCreationUiState settings = createWorldScreen.getUiState();
            settings.setName(worldCreationPolicy.name);
            settings.setGameMode(switch (worldCreationPolicy.gameType) {
                case CREATIVE -> WorldCreationUiState.SelectedGameMode.CREATIVE;
                case ADVENTURE -> WorldCreationUiState.SelectedGameMode.SURVIVAL;
                case SPECTATOR -> WorldCreationUiState.SelectedGameMode.SURVIVAL;
                default -> WorldCreationUiState.SelectedGameMode.SURVIVAL;
            });
            settings.setDifficulty(worldCreationPolicy.difficulty);
            settings.setAllowCommands(worldCreationPolicy.allowCommands);
            settings.setSeed(worldCreationPolicy.seed);
            worldCreationSubmitted = true;
            events.emit("WORLD_CREATE_SUBMITTED", "MMTL submitted validated world settings to the Minecraft world creation flow");
            ((CreateWorldScreenInvoker) createWorldScreen).mmtl$submitManagedWorldCreation();
            return;
        }
        if (!clientReadyReported && minecraft.gui.screen() instanceof TitleScreen) reportClientReady("Minecraft main menu is ready");
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
                result = invoker.mmtl$publishServer(net.minecraft.server.MinecraftServer.MultiplayerScope.LAN, worldCreationPolicy != null && worldCreationPolicy.allowCommands,
                        context.integratedLanPort);
            } finally { MmtlForgeAgent.setManagedPublishInProgress(false); }
            if (result) {
                Minecraft client = Minecraft.getInstance();
                if (client.level == null || client.player == null) {
                    events.emit("LAN_PUBLISH_FAILED", "Host world identity was unavailable after LAN publish", context.integratedLanPort);
                    return;
                }
                String dimensionKey = client.level.dimension().identifier().toString();
                String playerIdentity = client.player.getUUID().toString();
                if (!events.emitLanPublished(context.integratedLanPort, "127.0.0.1", context.sessionId,
                        dimensionKey, playerIdentity)) {
                    events.emit("LAN_PUBLISH_FAILED", "LAN listener evidence failed world identity validation", context.integratedLanPort);
                    return;
                }
                events.emitWorldJoined(context.sessionId, dimensionKey, playerIdentity);
            }
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
