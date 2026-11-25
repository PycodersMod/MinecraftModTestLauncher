package org.pycodersmod.mmtl.agent;

import org.junit.Rule;
import org.junit.Test;
import org.junit.Assume;
import org.junit.rules.TemporaryFolder;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.io.IOException;
import static org.junit.Assert.*;

public final class ManagedAgentActionPolicyTest {
    @Rule public TemporaryFolder temporaryFolder = new TemporaryFolder();
    private static final String TOKEN="test-token-with-enough-entropy-0123456789";
    private String signature(String payload)throws Exception{
        Mac mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(TOKEN.getBytes(StandardCharsets.UTF_8),"HmacSHA256"));
        byte[] bytes = mac.doFinal(payload.getBytes(StandardCharsets.UTF_8));
        StringBuilder hex = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) hex.append(String.format("%02x", value & 0xff));
        return hex.toString();
    }
    @Test public void acceptsOnlyMatchingRoleSessionAndSignedScreenshotPath()throws Exception{
        String id="0123456789abcdef0123456789abcdef",encoded="",output="screenshots/Guest/"+id+".png";
        String payload=ManagedAgentActionPolicy.signedPayload("session_a","Guest",id,"SCREENSHOT",encoded,output);
        assertTrue(ManagedAgentActionPolicy.isAuthorized("session_a","Guest","session_a","Guest",id,"SCREENSHOT",encoded,output,signature(payload),TOKEN));
        assertFalse(ManagedAgentActionPolicy.isAuthorized("session_a","Host","session_a","Guest",id,"SCREENSHOT",encoded,output,signature(payload),TOKEN));
        assertFalse(ManagedAgentActionPolicy.isAuthorized("session_a","Guest","other","Guest",id,"SCREENSHOT",encoded,output,signature(payload),TOKEN));
        assertFalse(ManagedAgentActionPolicy.isAuthorized("session_a","Guest","session_a","Guest",id,"SCREENSHOT",encoded,"../../outside.png",signature(payload),TOKEN));
    }
    @Test public void commandRequestsRejectManagementAndLineBreakCommands()throws Exception{
        String id="0123456789abcdef0123456789abcdef",encoded=java.util.Base64.getEncoder().encodeToString("say hello".getBytes(StandardCharsets.UTF_8));
        String payload=ManagedAgentActionPolicy.signedPayload("session_a","Client",id,"SEND_COMMAND",encoded,"");
        assertTrue(ManagedAgentActionPolicy.isAuthorized("session_a","Client","session_a","Client",id,"SEND_COMMAND",encoded,"",signature(payload),TOKEN));
        for(String command:new String[]{"stop","op player","say hello\nstop","/say hello"}){
            String bad=java.util.Base64.getEncoder().encodeToString(command.getBytes(StandardCharsets.UTF_8));
            String signed=ManagedAgentActionPolicy.signedPayload("session_a","Client",id,"SEND_COMMAND",bad,"");
            assertFalse(command,ManagedAgentActionPolicy.isAuthorized("session_a","Client","session_a","Client",id,"SEND_COMMAND",bad,"",signature(signed),TOKEN));
        }
        assertFalse(ManagedAgentActionPolicy.isAuthorized("session_a","Client","session_a","Client",id,"SEND_COMMAND",encoded,"","00",TOKEN));
    }
    @Test public void commandRequestsRejectUnicodeWhitespaceOnlyPayloads()throws Exception{
        String id="0123456789abcdef0123456789abcdef";
        String encoded=java.util.Base64.getEncoder().encodeToString("\u2003".getBytes(StandardCharsets.UTF_8));
        String payload=ManagedAgentActionPolicy.signedPayload("session_a","Client",id,"SEND_COMMAND",encoded,"");
        assertFalse(ManagedAgentActionPolicy.isAuthorized("session_a","Client","session_a","Client",id,"SEND_COMMAND",encoded,"",signature(payload),TOKEN));
    }
    @Test public void sharedMarkerActionsAreRoleBoundAndSignedToAWorldPosition()throws Exception{
        String id="0123456789abcdef0123456789abcdef",marker="goal-marker-01",dimension="minecraft:overworld";
        String state="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        String payload=ManagedAgentActionPolicy.sharedMarkerPayload("session_a","Host",id,"PLACE_BLOCK_MARKER",id,marker,dimension,12,70,-4,state);
        assertTrue(ManagedAgentActionPolicy.isAuthorizedSharedMarker("session_a","Host","session_a","Host",id,"PLACE_BLOCK_MARKER",id,marker,dimension,12,70,-4,state,signature(payload),TOKEN));
        String guestId="fedcba9876543210fedcba9876543210";
        String guestPayload=ManagedAgentActionPolicy.sharedMarkerPayload("session_a","Guest",guestId,"OBSERVE_BLOCK_MARKER",id,marker,dimension,12,70,-4,state);
        assertTrue(ManagedAgentActionPolicy.isAuthorizedSharedMarker("session_a","Guest","session_a","Guest",guestId,"OBSERVE_BLOCK_MARKER",id,marker,dimension,12,70,-4,state,signature(guestPayload),TOKEN));
        assertFalse(ManagedAgentActionPolicy.isAuthorizedSharedMarker("session_a","Guest","session_a","Guest",guestId,"PLACE_BLOCK_MARKER",id,marker,dimension,12,70,-4,state,signature(payload),TOKEN));
        assertFalse(ManagedAgentActionPolicy.isAuthorizedSharedMarker("session_a","Host","session_a","Host",id,"OBSERVE_BLOCK_MARKER",id,marker,dimension,12,70,-4,state,signature(guestPayload),TOKEN));
        assertFalse(ManagedAgentActionPolicy.isAuthorizedSharedMarker("session_a","Host","session_a","Host",id,"PLACE_BLOCK_MARKER",id,marker,dimension,1000,70,-4,state,signature(payload),TOKEN));
        assertFalse(ManagedAgentActionPolicy.isAuthorizedSharedMarker("session_a","Host","session_a","Host",id,"PLACE_BLOCK_MARKER",id,marker,dimension,12,70,-4,state,"00",TOKEN));
    }
    @Test public void pathsMustStayUnderSession()throws Exception{
        Path root=temporaryFolder.getRoot().toPath();
        assertEquals(root.resolve("screenshots/Host/test.png"),ManagedAgentActionPolicy.safeSessionPath(root,"screenshots/Host/test.png"));
        assertNull(ManagedAgentActionPolicy.safeSessionPath(root,"../outside.png"));
    }
    @Test public void rejectsSymlinkPathsWhenPlatformCanCreateSymlinks()throws Exception{
        Path root=temporaryFolder.getRoot().toPath();
        Path link=root.resolve("linked");
        try {
            Files.createSymbolicLink(link,temporaryFolder.newFolder("target").toPath());
        } catch (IOException | UnsupportedOperationException | SecurityException unavailable) {
            Assume.assumeNoException(unavailable);
        }
        assertNull(ManagedAgentActionPolicy.safeSessionPath(root,"linked/file.png"));
    }
}
