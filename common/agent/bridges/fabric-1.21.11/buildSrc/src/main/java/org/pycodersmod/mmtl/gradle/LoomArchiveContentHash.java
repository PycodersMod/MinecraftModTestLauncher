package org.pycodersmod.mmtl.gradle;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/** Stable content digest for locally generated Loom archives. ZIP timestamps and compression are excluded. */
public final class LoomArchiveContentHash {
    private LoomArchiveContentHash() { }

    public static String compute(Path archivePath) throws IOException {
        List<ZipEntry> entries = new ArrayList<ZipEntry>();
        Set<String> names = new HashSet<String>();
        try (ZipFile archive = new ZipFile(archivePath.toFile())) {
            Enumeration<? extends ZipEntry> enumeration = archive.entries();
            while (enumeration.hasMoreElements()) {
                ZipEntry entry = enumeration.nextElement();
                String name = entry.getName();
                validateName(name);
                if (!names.add(name)) throw new IllegalArgumentException("Duplicate ZIP entry: " + name);
                entries.add(entry);
            }
            Collections.sort(entries, new Comparator<ZipEntry>() {
                @Override public int compare(ZipEntry left, ZipEntry right) {
                    return left.getName().compareTo(right.getName());
                }
            });

            MessageDigest archiveDigest = sha256();
            updateInt(archiveDigest, entries.size());
            byte[] buffer = new byte[8192];
            for (ZipEntry entry : entries) {
                byte[] name = entry.getName().getBytes(StandardCharsets.UTF_8);
                updateInt(archiveDigest, name.length);
                archiveDigest.update(name);

                MessageDigest entryDigest = sha256();
                long length = 0;
                try (InputStream input = archive.getInputStream(entry)) {
                    int read;
                    while ((read = input.read(buffer)) != -1) {
                        entryDigest.update(buffer, 0, read);
                        length += read;
                    }
                }
                updateLong(archiveDigest, length);
                archiveDigest.update(entryDigest.digest());
            }
            return hex(archiveDigest.digest());
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }

    private static void validateName(String name) {
        if (name == null || name.isEmpty() || name.indexOf('\\') >= 0 || name.startsWith("/") || name.matches("^[A-Za-z]:.*")) {
            throw new IllegalArgumentException("Unsafe ZIP entry name");
        }
        String[] parts = name.split("/", -1);
        for (int i = 0; i < parts.length; i++) {
            String part = parts[i];
            boolean allowedDirectoryTerminator = i == parts.length - 1 && part.isEmpty() && name.endsWith("/");
            if ((!allowedDirectoryTerminator && part.isEmpty()) || ".".equals(part) || "..".equals(part)) {
                throw new IllegalArgumentException("Unsafe ZIP entry name");
            }
        }
    }

    private static MessageDigest sha256() throws NoSuchAlgorithmException {
        return MessageDigest.getInstance("SHA-256");
    }

    private static void updateInt(MessageDigest digest, int value) {
        digest.update((byte) (value >>> 24));
        digest.update((byte) (value >>> 16));
        digest.update((byte) (value >>> 8));
        digest.update((byte) value);
    }

    private static void updateLong(MessageDigest digest, long value) {
        for (int shift = 56; shift >= 0; shift -= 8) digest.update((byte) (value >>> shift));
    }

    private static String hex(byte[] bytes) {
        char[] alphabet = "0123456789abcdef".toCharArray();
        char[] output = new char[bytes.length * 2];
        for (int i = 0; i < bytes.length; i++) {
            int value = bytes[i] & 0xff;
            output[i * 2] = alphabet[value >>> 4];
            output[i * 2 + 1] = alphabet[value & 0x0f];
        }
        return new String(output);
    }
}
