package org.pycodersmod.mmtl.agent;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.core.BlockPos;
import net.minecraft.network.chat.Component;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.Blocks;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.Base64;
import java.security.MessageDigest;

final class ManagedAgentActionProcessor {
    private final AgentHandshake.Context context;
    private final AgentEventSink events;
    private long lastSize;
    private boolean busy;
    private JsonObject pendingMarkerObservation;
    private long markerObservationDeadlineNanos;

    ManagedAgentActionProcessor(AgentHandshake.Context context, AgentEventSink events) { this.context=context;this.events=events; }

    void tick(Minecraft minecraft) {
        if (context == null || minecraft.player == null || minecraft.player.connection == null) return;
        if (pendingMarkerObservation != null) { pollMarkerObservation(minecraft); return; }
        if (busy) return;
        Path queue=ManagedAgentActionPolicy.safeSessionPath(context.sessionRoot,"agent-actions/"+context.role.toLowerCase(java.util.Locale.ROOT)+".jsonl");
        if (queue == null || !Files.isRegularFile(queue, LinkOption.NOFOLLOW_LINKS)) return;
        try {
            long size=Files.size(queue); if(size<lastSize)lastSize=0;if(size==lastSize)return;
            byte[] all=Files.readAllBytes(queue);int start=(int)lastSize;int newline=-1;
            for(int i=start;i<all.length;i++)if(all[i]=='\n'){newline=i;break;}
            if(newline<0)return;
            lastSize=newline+1L;String raw=new String(all,start,newline-start,StandardCharsets.UTF_8).trim();if(raw.isEmpty())return;
            process(JsonParser.parseString(raw).getAsJsonObject(),minecraft);
        } catch(Exception invalid) { /* Invalid local requests are ignored and never escape the Session. */ }
    }

    private void process(JsonObject request,Minecraft minecraft) throws IOException {
        String session=value(request,"sessionId"),role=value(request,"role"),id=value(request,"actionId"),action=value(request,"action");
        String command64=value(request,"commandBase64"),output=value(request,"outputRelativePath"),signature=value(request,"signature");
        if ("PLACE_BLOCK_MARKER".equals(action) || "OBSERVE_BLOCK_MARKER".equals(action)) {
            String actorActionId=value(request,"actorActionId"),markerId=value(request,"markerId"),dimensionKey=value(request,"dimensionKey");
            int x=request.get("x").getAsInt(),y=request.get("y").getAsInt(),z=request.get("z").getAsInt();
            String stateSha256=value(request,"stateSha256");
            if(!ManagedAgentActionPolicy.isAuthorizedSharedMarker(context.sessionId,context.role,session,role,id,action,
                    actorActionId,markerId,dimensionKey,x,y,z,stateSha256,signature,context.token))return;
            String expectedState=sharedMarkerStateHash(session,markerId,dimensionKey,x,y,z);
            if(!expectedState.equals(stateSha256)){events.emit("ACTION_FAILED","Shared marker state hash did not match the fixed protocol",id);return;}
            events.emit("ACTION_RECEIVED","Signed shared marker action accepted",id);busy=true;
            if("PLACE_BLOCK_MARKER".equals(action))placeSharedMarker(minecraft,id,markerId,dimensionKey,x,y,z,stateSha256);
            else {pendingMarkerObservation=request.deepCopy();markerObservationDeadlineNanos=System.nanoTime()+30_000_000_000L;pollMarkerObservation(minecraft);}
            return;
        }
        if(!ManagedAgentActionPolicy.isAuthorized(context.sessionId,context.role,session,role,id,action,command64,output,signature,context.token))return;
        events.emit("ACTION_RECEIVED","Managed local test action accepted",id);busy=true;
        if("SEND_COMMAND".equals(action)){
            minecraft.player.connection.sendCommand(new String(Base64.getDecoder().decode(command64),StandardCharsets.UTF_8));
            events.emit("ACTION_COMPLETED","Managed local test command was sent",id);busy=false;return;
        }
        Path target=ManagedAgentActionPolicy.safeSessionPath(context.sessionRoot,output);
        if(target==null||Files.exists(target,LinkOption.NOFOLLOW_LINKS)){events.emit("ACTION_FAILED","Screenshot target was not a new Session-local file",id);busy=false;return;}
        Files.createDirectories(target.getParent());
        if(hasLink(context.sessionRoot,target)){events.emit("ACTION_FAILED","Screenshot path contains a symbolic link",id);busy=false;return;}
        Screenshot.grab(target.toFile(),minecraft.gameRenderer.mainRenderTarget(),(Component result)->{
            if(Files.isRegularFile(target,LinkOption.NOFOLLOW_LINKS))events.emit("ACTION_COMPLETED","Session-local screenshot captured",id);
            else events.emit("ACTION_FAILED","Screenshot capture did not produce a file",id);
            busy=false;
        });
    }

    private void placeSharedMarker(Minecraft minecraft,String actionId,String markerId,String dimensionKey,int x,int y,int z,String stateSha256){
        MinecraftServer server=minecraft.getSingleplayerServer();
        if(server==null||server.isDedicatedServer()||minecraft.level==null
                ||!dimensionKey.equals(minecraft.level.dimension().identifier().toString())){failAction("Shared marker Host world was unavailable",actionId);return;}
        ServerLevel level=server.getLevel(minecraft.level.dimension());BlockPos position=new BlockPos(x,y,z);
        if(level==null||!level.getWorldBorder().isWithinBounds(position)||!level.hasChunkAt(position)){failAction("Shared marker position was outside the loaded managed Host world",actionId);return;}
        server.execute(()->{
            boolean placed=level.setBlock(position,Blocks.GOLD_BLOCK.defaultBlockState(),3);
            boolean verified=level.getBlockState(position).is(Blocks.GOLD_BLOCK);
            if(placed&&verified){
                String dimension=level.dimension().identifier().toString();String player=minecraft.player.getUUID().toString();
                if(events.emitSharedStateWritten(context.sessionId,dimension,player,actionId,markerId,stateSha256))events.emit("ACTION_COMPLETED","Host placed and verified the shared gold block marker",actionId);
                else events.emit("ACTION_FAILED","Host marker event could not be written",actionId);
            }else events.emit("ACTION_FAILED","Host marker block was not verified in the managed world",actionId);
            busy=false;
        });
    }

    private void pollMarkerObservation(Minecraft minecraft){
        JsonObject request=pendingMarkerObservation;if(request==null)return;
        if(System.nanoTime()>markerObservationDeadlineNanos){failAction("Guest did not observe the shared marker before timeout",value(request,"actionId"));pendingMarkerObservation=null;return;}
        String dimensionKey=value(request,"dimensionKey");
        if(minecraft.level==null||!dimensionKey.equals(minecraft.level.dimension().identifier().toString()))return;
        int x=request.get("x").getAsInt(),y=request.get("y").getAsInt(),z=request.get("z").getAsInt();BlockPos position=new BlockPos(x,y,z);
        if(!minecraft.level.hasChunkAt(position)||!minecraft.level.getBlockState(position).is(Blocks.GOLD_BLOCK))return;
        String markerId=value(request,"markerId"),stateSha256=value(request,"stateSha256"),actorActionId=value(request,"actorActionId");
        boolean emitted=events.emitSharedStateObserved(context.sessionId,dimensionKey,minecraft.player.getUUID().toString(),actorActionId,markerId,stateSha256);
        if(emitted)events.emit("ACTION_COMPLETED","Guest observed the Host marker in the shared world",value(request,"actionId"));
        else events.emit("ACTION_FAILED","Guest marker observation event could not be written",value(request,"actionId"));
        pendingMarkerObservation=null;busy=false;
    }

    private void failAction(String summary,String actionId){events.emit("ACTION_FAILED",summary,actionId);busy=false;}

    private static String sharedMarkerStateHash(String sessionId,String markerId,String dimensionKey,int x,int y,int z){
        String canonical="mmtl-block-marker-v1|"+sessionId+"|"+markerId+"|"+dimensionKey+"|"+x+"|"+y+"|"+z+"|minecraft:gold_block";
        try{return java.util.HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(canonical.getBytes(StandardCharsets.UTF_8)));}
        catch(Exception impossible){throw new IllegalStateException("SHA-256 is unavailable",impossible);}
    }

    private boolean hasLink(Path root,Path target){Path current=root;if(Files.isSymbolicLink(current))return true;for(Path part:root.relativize(target)){current=current.resolve(part);if(Files.isSymbolicLink(current))return true;}return false;}
    private static String value(JsonObject object,String key){return object.has(key)&&!object.get(key).isJsonNull()?object.get(key).getAsString():"";}
}
