package org.pycodersmod.mmtl.agent;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.network.chat.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.Base64;

final class ManagedAgentActionProcessor {
    private final AgentHandshake.Context context;
    private final AgentEventSink events;
    private long lastSize;
    private boolean busy;

    ManagedAgentActionProcessor(AgentHandshake.Context context, AgentEventSink events) { this.context=context;this.events=events; }

    void tick(Minecraft minecraft) {
        if (context == null || busy || minecraft.player == null || minecraft.player.connection == null) return;
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
        Screenshot.grab(target.toFile(),"mmtl",minecraft.getMainRenderTarget(),(Component result)->{
            if(Files.isRegularFile(target,LinkOption.NOFOLLOW_LINKS))events.emit("ACTION_COMPLETED","Session-local screenshot captured",id);
            else events.emit("ACTION_FAILED","Screenshot capture did not produce a file",id);
            busy=false;
        });
    }

    private boolean hasLink(Path root,Path target){Path current=root;if(Files.isSymbolicLink(current))return true;for(Path part:root.relativize(target)){current=current.resolve(part);if(Files.isSymbolicLink(current))return true;}return false;}
    private static String value(JsonObject object,String key){return object.has(key)&&!object.get(key).isJsonNull()?object.get(key).getAsString():"";}
}
