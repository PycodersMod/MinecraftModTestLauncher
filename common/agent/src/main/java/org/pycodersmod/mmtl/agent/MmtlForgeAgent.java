package org.pycodersmod.mmtl.agent;

import net.minecraft.server.MinecraftServer;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.entity.player.PlayerEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;

@Mod("mmtl_agent")
public final class MmtlForgeAgent {
    private final AgentHandshake.Context context;
    private final AgentEventSink events;

    public MmtlForgeAgent() {
        this.context = AgentHandshake.fromSystemProperties();
        if (context == null) {
            this.events = null;
            return;
        }
        this.events = new AgentEventSink(context);
        MinecraftForge.EVENT_BUS.register(this);
        events.emit("CLIENT_INITIALIZED", "Forge agent handshake accepted for role " + context.role);
    }

    @SubscribeEvent
    public void onPlayerLoggedIn(PlayerEvent.PlayerLoggedInEvent event) {
        if (context == null || event.getEntity().getServer() == null) return;
        MinecraftServer server = event.getEntity().getServer();
        if ("Host".equals(context.role) && !server.isDedicatedServer()) {
            events.emit("INTEGRATED_SERVER_DETECTED", "Integrated server is active for the MMTL Host role");
            events.emit("WORLD_JOINED", "Host player joined the integrated world");
        } else if ("Guest".equals(context.role)) {
            events.emit("GUEST_CONNECTED", "Offline Guest joined the managed local session");
        } else if ("Client".equals(context.role)) {
            events.emit("WORLD_JOINED", "Client player joined a world");
        }
    }
}
