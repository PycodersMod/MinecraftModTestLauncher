package org.pycodersmod.mmtl.gradle;

import org.junit.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;

public class LoomArchiveContentHashTest {
    @Test
    public void ignoresArchiveEntryTimestampsAndOrder() throws Exception {
        Path first = createArchive("first.jar", 1_600_000_000_000L, false, "stable");
        Path second = createArchive("second.jar", 1_700_000_000_000L, true, "stable");

        assertNotEquals(sha256(first), sha256(second));
        assertEquals(LoomArchiveContentHash.compute(first), LoomArchiveContentHash.compute(second));
    }

    @Test
    public void contentChangesChangeCanonicalHash() throws Exception {
        Path first = createArchive("first.jar", 1_600_000_000_000L, false, "trusted");
        Path changed = createArchive("changed.jar", 1_600_000_000_000L, false, "modified");

        assertNotEquals(LoomArchiveContentHash.compute(first), LoomArchiveContentHash.compute(changed));
    }

    @Test
    public void rejectsUnsafeArchiveEntries() throws Exception {
        Path unsafe = createTempArchivePath("unsafe");
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(unsafe))) {
            put(zip, "../escape.txt", 1_600_000_000_000L, "bad");
        }

        try {
            LoomArchiveContentHash.compute(unsafe);
        } catch (IllegalArgumentException expected) {
            return;
        }
        throw new AssertionError("unsafe ZIP entry should be rejected");
    }

    private static Path createArchive(String name, long time, boolean reverse, String content) throws IOException {
        Path path = createTempArchivePath(name.replace('.', '-'));
        try (ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(path))) {
            if (reverse) {
                put(zip, "z.txt", time, "tail");
                put(zip, "a.txt", time, content);
            } else {
                put(zip, "a.txt", time, content);
                put(zip, "z.txt", time, "tail");
            }
        }
        return path;
    }

    private static Path createTempArchivePath(String prefix) throws IOException {
        Path directory = Paths.get("build", "tmp", "loom-content-hash-tests");
        Files.createDirectories(directory);
        return Files.createTempFile(directory, "mmtl-" + prefix + "-", ".jar");
    }

    private static void put(ZipOutputStream zip, String name, long time, String value) throws IOException {
        ZipEntry entry = new ZipEntry(name);
        entry.setTime(time);
        zip.putNextEntry(entry);
        zip.write(value.getBytes(java.nio.charset.StandardCharsets.UTF_8));
        zip.closeEntry();
    }

    private static String sha256(Path path) throws Exception {
        byte[] digest = java.security.MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(path));
        StringBuilder hex = new StringBuilder(digest.length * 2);
        for (byte value : digest) hex.append(String.format("%02x", value & 0xff));
        return hex.toString();
    }
}
