package org.pycodersmod.mmtl.agent;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.TitleScreen;
import net.minecraft.client.gui.screens.worldselection.CreateWorldScreen;
import net.minecraft.client.gui.screens.worldselection.WorldCreationUiState;
import net.minecraft.client.server.IntegratedServer;
import net.minecraft.world.Difficulty;
import org.pycodersmod.mmtl.agent.mixin.CreateWorldScreenInvoker;
import org.pycodersmod.mmtl.agent.mixin.IntegratedServerInvoker;

public final class FabricClientController {
    private FabricClientController() {}

    public static synchronized void onClientTick(Minecraft client) {
        if (FabricAgentBootstrap.activeContext == null || FabricAgentBootstrap.activeEvents == null || client == null) return;
        if (client.screen instanceof TitleScreen) {
            FabricAgentBootstrap.reportClientReady();
            FabricWorldCreationPolicy policy = FabricAgentBootstrap.worldCreationPolicy;
            if (policy != null && !FabricAgentBootstrap.worldCreationRequested) {
                FabricAgentBootstrap.worldCreationRequested = true;
                FabricAgentBootstrap.activeEvents.emit("WORLD_CREATE_REQUESTED",
                        "Managed Host requested creation of its isolated test world");
                CreateWorldScreen.openFresh(client, () -> {});
                return;
            }
        }
        FabricWorldCreationPolicy policy = FabricAgentBootstrap.worldCreationPolicy;
        if (policy != null && FabricAgentBootstrap.worldCreationRequested && !FabricAgentBootstrap.worldCreationSubmitted
                && client.screen instanceof CreateWorldScreen createWorldScreen) {
            WorldCreationUiState settings = createWorldScreen.getUiState();
            settings.setName(policy.name);
            settings.setGameMode("creative".equals(policy.gameMode)
                    ? WorldCreationUiState.SelectedGameMode.CREATIVE : WorldCreationUiState.SelectedGameMode.SURVIVAL);
            settings.setDifficulty(switch (policy.difficulty) {
                case "peaceful" -> Difficulty.PEACEFUL;
                case "easy" -> Difficulty.EASY;
                case "hard" -> Difficulty.HARD;
                default -> Difficulty.NORMAL;
            });
            settings.setAllowCommands(policy.allowCommands);
            settings.setSeed(policy.seed);
            FabricAgentBootstrap.worldCreationSubmitted = true;
            FabricAgentBootstrap.activeEvents.emit("WORLD_CREATE_SUBMITTED",
                    "MMTL submitted validated world settings to Minecraft");
            ((CreateWorldScreenInvoker) createWorldScreen).mmtl$submitManagedWorldCreation();
            return;
        }
        if (client.level != null && client.player != null) {
            publishManagedLan(client.getSingleplayerServer(), client.level.dimension().identifier().toString(),
                    client.player.getUUID().toString());
            FabricAgentBootstrap.reportWorldJoined(client.level.dimension().identifier().toString(),
                    client.player.getUUID().toString());
        }
    }

    private static void publishManagedLan(IntegratedServer server, String dimensionKey, String playerIdentity) {
        AgentHandshake.Context context = FabricAgentBootstrap.activeContext;
        AgentEventSink events = FabricAgentBootstrap.activeEvents;
        ManagedHostActionGate gate = FabricAgentBootstrap.publishGate;
        if (context == null || events == null || gate == null || !"Host".equals(context.role)
                || context.integratedLanPort < 1 || server == null || server.isDedicatedServer()
                || !server.isReady() || server.isPublished()
                || !LanPublishPolicy.canPublishIntegratedServer(true, false, context.role, context.integratedLanPort)
                || !gate.tryClaim()) return;

        int port = context.integratedLanPort;
        server.setUsesAuthentication(false);
        events.emit("OFFLINE_AUTH_ENABLED", "Offline authentication enabled for the managed IntegratedLAN host");
        events.emit("LAN_PUBLISH_REQUESTED", "Managed IntegratedLAN publish requested on loopback", port);
        FabricAgentBootstrap.managedPublishPort = port;
        FabricAgentBootstrap.managedPublishInProgress = true;
        boolean published;
        try {
            published = ((IntegratedServerInvoker) server).mmtl$publishServer(server.getDefaultGameType(), false, port);
        } catch (RuntimeException failure) {
            published = false;
            events.emit("AGENT_ERROR", "Managed IntegratedLAN publish failed: " + failure.getClass().getSimpleName());
        } finally {
            FabricAgentBootstrap.managedPublishInProgress = false;
            FabricAgentBootstrap.managedPublishPort = 0;
        }

        if (published && server.isPublished() && server.getPort() == port
                && events.emitLanPublished(port, "127.0.0.1", context.sessionId, dimensionKey, playerIdentity)) {
            FabricAgentBootstrap.managedLanPublished = true;
            return;
        }
        events.emit("LAN_PUBLISH_FAILED", "IntegratedLAN publish did not produce the expected managed listener", port);
    }
}
