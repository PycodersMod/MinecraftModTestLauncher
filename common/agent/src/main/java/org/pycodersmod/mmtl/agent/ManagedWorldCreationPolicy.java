package org.pycodersmod.mmtl.agent;

import net.minecraft.world.Difficulty;
import net.minecraft.world.level.GameType;

import java.util.Locale;
import java.util.regex.Pattern;

final class ManagedWorldCreationPolicy {
    private static final Pattern NAME = Pattern.compile("[A-Za-z0-9._ -]{1,64}");
    private static final Pattern SEED = Pattern.compile("-?\\d{1,20}");
    final String name;
    final GameType gameType;
    final Difficulty difficulty;
    final String seed;
    final boolean allowCommands;

    private ManagedWorldCreationPolicy(String name, GameType gameType, Difficulty difficulty, String seed, boolean allowCommands) {
        this.name=name;this.gameType=gameType;this.difficulty=difficulty;this.seed=seed;this.allowCommands=allowCommands;
    }

    static ManagedWorldCreationPolicy fromProperties(String role, String enabled, String name,
                                                       String gameMode, String difficulty,
                                                       String seed, String allowCommands) {
        if (!"Host".equals(role) || !"true".equalsIgnoreCase(enabled)) return null;
        if (name == null || !NAME.matcher(name).matches() || ".".equals(name) || "..".equals(name)) return null;
        GameType type = switch (gameMode == null ? "" : gameMode.toLowerCase(Locale.ROOT)) {
            case "survival" -> GameType.SURVIVAL;
            case "creative" -> GameType.CREATIVE;
            default -> null;
        };
        Difficulty level = switch (difficulty == null ? "" : difficulty.toLowerCase(Locale.ROOT)) {
            case "peaceful" -> Difficulty.PEACEFUL;
            case "easy" -> Difficulty.EASY;
            case "normal" -> Difficulty.NORMAL;
            case "hard" -> Difficulty.HARD;
            default -> null;
        };
        if (type == null || level == null) return null;
        if (seed != null && !seed.isEmpty() && !SEED.matcher(seed).matches()) return null;
        return new ManagedWorldCreationPolicy(name, type, level, seed == null ? "" : seed,
                Boolean.parseBoolean(allowCommands));
    }
}
