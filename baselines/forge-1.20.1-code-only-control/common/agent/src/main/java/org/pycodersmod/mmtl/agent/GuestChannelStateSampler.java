package org.pycodersmod.mmtl.agent;

import io.netty.channel.Channel;
import io.netty.channel.ChannelFuture;

import java.lang.reflect.Field;
import java.net.InetSocketAddress;
import java.nio.channels.SelectionKey;
final class GuestChannelStateSampler {
    private static final long SAMPLE_INTERVAL_NANOS = 1_000_000_000L;

    private final Channel channel;
    private final GuestChannelStateReporter reporter;
    private volatile boolean stopped;
    private long lastSampleNanos;

    GuestChannelStateSampler(Channel channel, GuestChannelStateReporter reporter) {
        this.channel = channel;
        this.reporter = reporter;
    }

    static GuestChannelStateSampler start(Channel channel, AgentEventSink events, int expectedPort, boolean enabled) {
        if (!enabled || channel == null || events == null || expectedPort < 1 || expectedPort > 65535
                || !isExpectedLoopback(channel.remoteAddress(), expectedPort)) return null;
        GuestChannelStateSampler sampler = new GuestChannelStateSampler(channel,
                new GuestChannelStateReporter(events, expectedPort, true));
        ChannelFuture closeFuture = channel.closeFuture();
        closeFuture.addListener(ignored -> sampler.stop());
        return sampler;
    }

    void stop() {
        stopped = true;
    }

    void tick(long nowNanos) {
        if (stopped || (lastSampleNanos != 0 && nowNanos - lastSampleNanos < SAMPLE_INTERVAL_NANOS)) return;
        lastSampleNanos = nowNanos;
        boolean registered = safe(channel::isRegistered);
        boolean active = safe(channel::isActive);
        boolean open = safe(channel::isOpen);
        boolean autoRead;
        try {
            autoRead = channel.config().isAutoRead();
        } catch (RuntimeException failure) {
            reporter.record(registered, active, open, false, "unavailable:channel-config");
            stop();
            return;
        }
        reporter.record(registered, active, open, autoRead, selectionKeyState(channel));
        if (!active || !open) stop();
    }

    private static boolean safe(BooleanSupplier supplier) {
        try { return supplier.get(); }
        catch (RuntimeException failure) { return false; }
    }

    private static boolean isExpectedLoopback(java.net.SocketAddress address, int expectedPort) {
        return address instanceof InetSocketAddress inet && inet.getAddress() != null
                && inet.getAddress().isLoopbackAddress() && inet.getPort() == expectedPort;
    }

    private static String selectionKeyState(Channel channel) {
        Field selectionKeyField = null;
        for (Class<?> type = channel.getClass(); type != null; type = type.getSuperclass()) {
            try {
                selectionKeyField = type.getDeclaredField("selectionKey");
                break;
            } catch (NoSuchFieldException ignored) { }
        }
        if (selectionKeyField == null || !SelectionKey.class.isAssignableFrom(selectionKeyField.getType()))
            return "unavailable:field-not-found";
        try {
            if (!selectionKeyField.canAccess(channel) && !selectionKeyField.trySetAccessible())
                return "unavailable:inaccessible";
            SelectionKey key = (SelectionKey) selectionKeyField.get(channel);
            if (key == null) return "unavailable:null-key";
            if (!key.isValid()) return "valid=false,interestOps=-1,readyOps=-1";
            return "valid=true,interestOps=" + key.interestOps() + ",readyOps=" + key.readyOps();
        } catch (ReflectiveOperationException failure) {
            return "unavailable:inaccessible";
        } catch (RuntimeException failure) {
            return "unavailable:" + safeReason(failure);
        }
    }

    private static String safeReason(RuntimeException failure) {
        String type = failure.getClass().getSimpleName();
        return type.matches("[A-Za-z0-9_-]{1,48}") ? type : "runtime-error";
    }

    @FunctionalInterface
    private interface BooleanSupplier { boolean get(); }
}
