package org.pycodersmod.mmtl.agent;

import java.util.Locale;
import java.util.regex.Pattern;

final class FabricWorldCreationPolicy {
    private static final Pattern NAME = Pattern.compile("[A-Za-z0-9._ -]{1,64}");
    private static final Pattern SEED = Pattern.compile("-?\\d{1,20}");
    final String name;
    final String gameMode;
    final String difficulty;
    final String seed;
    final boolean allowCommands;

    private FabricWorldCreationPolicy(String name, String gameMode, String difficulty, String seed, boolean allowCommands) {
        this.name = name;
        this.gameMode = gameMode;
        this.difficulty = difficulty;
        this.seed = seed;
        this.allowCommands = allowCommands;
    }

    static FabricWorldCreationPolicy fromProperties(String role, String enabled, String name,
                                                     String gameMode, String difficulty,
                                                     String seed, String allowCommands) {
        if (!("Host".equals(role) || "Client".equals(role)) || !"true".equalsIgnoreCase(enabled)) return null;
        if (name == null || !NAME.matcher(name).matches() || ".".equals(name) || "..".equals(name)) return null;
        String normalizedMode = gameMode == null ? "" : gameMode.toLowerCase(Locale.ROOT);
        if (!("survival".equals(normalizedMode) || "creative".equals(normalizedMode))) return null;
        String normalizedDifficulty = difficulty == null ? "" : difficulty.toLowerCase(Locale.ROOT);
        if (!("peaceful".equals(normalizedDifficulty) || "easy".equals(normalizedDifficulty)
                || "normal".equals(normalizedDifficulty) || "hard".equals(normalizedDifficulty))) return null;
        String normalizedSeed = seed == null ? "" : seed;
        if (!normalizedSeed.isEmpty() && !SEED.matcher(normalizedSeed).matches()) return null;
        return new FabricWorldCreationPolicy(name, normalizedMode, normalizedDifficulty, normalizedSeed,
                Boolean.parseBoolean(allowCommands));
    }
}
