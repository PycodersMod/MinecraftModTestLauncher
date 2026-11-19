package org.pycodersmod.mmtl.agent;

import org.junit.Test;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.MessageDigest;
import static org.junit.Assert.*;

public final class AgentHandshakeTest {
    private static String hash(String value) throws Exception {
        byte[] bytes=MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
        StringBuilder result=new StringBuilder();for(byte b:bytes)result.append(String.format("%02x",b&255));return result.toString();
    }
    @Test public void missingHandshakeKeepsAgentInert() { assertNull(AgentHandshake.fromProperties(null,null,null,null,null,null,null)); }
    @Test public void validHostHandshakeRequiresAllowedRoleAndContainedSink() throws Exception {
        String token="agent-test-token-0123456789abcdef";Path root=Path.of("/tmp/session_a");
        AgentHandshake.Context context=AgentHandshake.fromProperties("session_a","Host","Host,Guest",token,hash(token),root.toString(),root.resolve("events/host.jsonl").toString());
        assertNotNull(context);assertEquals("Host",context.role);
    }
    @Test public void rejectsWrongNonceRoleAndEscapingSink() throws Exception {
        String token="agent-test-token-0123456789abcdef";Path root=Path.of("/tmp/session_a");String valid=hash(token);
        assertNull(AgentHandshake.fromProperties("session_a","Host","Guest",token,valid,root.toString(),root.resolve("event.jsonl").toString()));
        assertNull(AgentHandshake.fromProperties("session_a","Host","Host",token,"0".repeat(64),root.toString(),root.resolve("event.jsonl").toString()));
        assertNull(AgentHandshake.fromProperties("session_a","Host","Host",token,valid,root.toString(),root.resolve("../outside.jsonl").toString()));
    }
    @Test public void integratedLanPortIsHostOnlyAndRangeChecked() throws Exception {
        String token="agent-test-token-0123456789abcdef";Path root=Path.of("/tmp/session_a");String valid=hash(token);
        assertEquals(25565, AgentHandshake.fromProperties("session_a","Host","Host,Guest",token,valid,root.toString(),root.resolve("events/host.jsonl").toString(),25565).integratedLanPort);
        assertNull(AgentHandshake.fromProperties("session_a","Guest","Host,Guest",token,valid,root.toString(),root.resolve("events/guest.jsonl").toString(),25565));
        assertNull(AgentHandshake.fromProperties("session_a","Host","Host",token,valid,root.toString(),root.resolve("events/host.jsonl").toString(),65536));
        assertEquals(25565, AgentHandshake.fromProperties("session_a","Guest","Host,Guest",token,valid,root.toString(),root.resolve("events/guest.jsonl").toString(),0,25565).expectedLoopbackPort);
        assertNull(AgentHandshake.fromProperties("session_a","Client","Client,Guest",token,valid,root.toString(),root.resolve("events/client.jsonl").toString(),0,25565));
        assertNull(AgentHandshake.fromProperties("session_a","Guest","Host,Guest",token,valid,root.toString(),root.resolve("events/guest.jsonl").toString()));
    }
}
