package org.pycodersmod.mmtl.agent;

import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.SocketAddress;

public final class FabricAgentBootstrap {
    static AgentHandshake.Context activeContext;
    static AgentEventSink activeEvents;
    static ManagedHostActionGate publishGate;
    static FabricWorldCreationPolicy worldCreationPolicy;
    static boolean clientReadyReported;
    static String lastWorldJoinIdentity;
    static boolean worldCreationRequested;
    static boolean worldCreationSubmitted;
    static volatile boolean managedPublishInProgress;
    static volatile boolean managedLanPublished;
    static volatile boolean guestLoopbackVerified;
    static volatile int managedPublishPort;

    private FabricAgentBootstrap() {}

    static synchronized boolean start() {
        activeContext = null;
        activeEvents = null;
        publishGate = null;
        worldCreationPolicy = null;
        clientReadyReported = false;
        lastWorldJoinIdentity = null;
        worldCreationRequested = false;
        worldCreationSubmitted = false;
        managedPublishInProgress = false;
        managedLanPublished = false;
        guestLoopbackVerified = false;
        managedPublishPort = 0;
        AgentHandshake.Context context = AgentHandshake.fromSystemProperties();
        if (context == null) return false;

        AgentEventSink events = new AgentEventSink(context);
        activeContext = context;
        activeEvents = events;
        publishGate = new ManagedHostActionGate();
        worldCreationPolicy = FabricWorldCreationPolicy.fromProperties(context.role,
                System.getProperty("mmtl.agent.autoCreateWorld"),
                System.getProperty("mmtl.agent.worldName"),
                System.getProperty("mmtl.agent.worldGameMode"),
                System.getProperty("mmtl.agent.worldDifficulty"),
                System.getProperty("mmtl.agent.worldSeed"),
                System.getProperty("mmtl.agent.worldAllowCommands"));
        events.emit("AGENT_STARTED", "Fabric Agent handshake accepted for role " + context.role);
        if ("Guest".equals(context.role)) {
            events.emit("GUEST_CONNECTING", "Offline Guest is awaiting the managed loopback connection");
        }
        return true;
    }

    public static synchronized void reportClientReady() {
        if (activeContext == null || activeEvents == null || clientReadyReported
                || !("Client".equals(activeContext.role) || "Host".equals(activeContext.role)
                || "Guest".equals(activeContext.role))) return;
        clientReadyReported = true;
        activeEvents.emit("CLIENT_READY", "Managed Fabric client reached a ready screen or joined its world");
    }

    public static synchronized void reportWorldJoined(String dimensionKey, String playerIdentity) {
        if (activeContext == null || activeEvents == null
                || !("Client".equals(activeContext.role) || "Host".equals(activeContext.role)
                || "Guest".equals(activeContext.role))) return;
        if ("Guest".equals(activeContext.role) && !guestLoopbackVerified) return;
        if ("Host".equals(activeContext.role) && activeContext.integratedLanPort > 0 && !managedLanPublished) return;
        String worldKey = activeContext.sessionId;
        String identity = worldKey + "|" + dimensionKey + "|" + playerIdentity;
        if (identity.equals(lastWorldJoinIdentity)) return;
        if (activeEvents.emitWorldJoined(worldKey, dimensionKey, playerIdentity)) {
            lastWorldJoinIdentity = identity;
            reportClientReady();
        }
    }

    public static synchronized void reportLogin(SocketAddress remoteAddress) {
        if (activeContext == null || activeEvents == null) return;
        if ("Guest".equals(activeContext.role)) {
            if (!isExpectedLoopback(remoteAddress, activeContext.expectedLoopbackPort)) {
                activeEvents.emit("AGENT_ERROR", "Guest connection endpoint did not match the managed loopback target");
                return;
            }
            guestLoopbackVerified = true;
            activeEvents.emit("GUEST_CONNECTED", "Offline Guest joined the managed local session", activeContext.expectedLoopbackPort);
        }
        reportClientReady();
    }

    public static synchronized InetAddress selectManagedBindAddress(int port, InetAddress requestedAddress) {
        AgentHandshake.Context context = activeContext;
        boolean authorized = managedPublishInProgress && context != null && managedPublishPort == port
                && context.integratedLanPort == port;
        return LanPublishPolicy.selectBindAddress(authorized, context == null ? "None" : context.role, port, requestedAddress);
    }

    public static synchronized boolean shouldSuppressLanAdvertisement() {
        AgentHandshake.Context context = activeContext;
        return context != null && LanPublishPolicy.shouldSuppressLanAdvertisement(true, context.role, context.integratedLanPort);
    }

    private static boolean isExpectedLoopback(SocketAddress address, int expectedPort) {
        if (!(address instanceof InetSocketAddress inet) || inet.getAddress() == null
                || !inet.getAddress().isLoopbackAddress()) return false;
        return expectedPort >= 1 && inet.getPort() == expectedPort;
    }
}
