package net.minecraft.client.main;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.Arrays;

/** 仅供 MMTL 自动化演练使用的本地假客户端，不加载 Minecraft。 */
public final class Main {
    private Main() { }

    public static void main(String[] args) throws Exception {
        String scenario = args.length == 0 ? "normal" : args[0];
        Path runtime = Paths.get(args.length < 2 ? "." : args[1]);
        String[] gameArgs = args.length < 3 ? new String[0] : Arrays.copyOfRange(args, "guest".equals(scenario) ? 3 : 2, args.length);
        System.out.println("MMTL_FIXTURE_JAVA=" + System.getProperty("java.version") + "|" + System.getProperty("java.vendor"));
        System.out.println("MMTL_FIXTURE_JVM_ARG=" + System.getProperty("mmtl.rehearsal.test", "missing"));
        System.out.println("MMTL_FIXTURE_GAME_ARGS=" + String.join(" ", gameArgs));
        if ("early-exit".equals(scenario)) {
            System.exit(23);
        }
        log(runtime, "[Render thread/INFO]: Setting user: MMTL_Rehearsal");
        if ("crash-after-init".equals(scenario)) {
            throw new IllegalStateException("MMTL synthetic rehearsal crash");
        }
        if ("timeout".equals(scenario)) {
            Thread.sleep(30000L);
        }
        if ("guest".equals(scenario)) {
            if (args.length < 3) throw new IllegalArgumentException("Missing rehearsal server port");
            try (Socket remote = new Socket(InetAddress.getByName("127.0.0.1"), Integer.parseInt(args[2]));
                 BufferedReader input = new BufferedReader(new InputStreamReader(remote.getInputStream(), "UTF-8"));
                 PrintWriter output = new PrintWriter(remote.getOutputStream(), true)) {
                output.println("GUEST");
                if (!"GUEST_OK".equals(input.readLine())) throw new IllegalStateException("Dummy server rejected guest");
            }
            Files.write(runtime.resolve("guest.connected"), "GUEST_OK".getBytes(StandardCharsets.UTF_8));
            System.out.println("MMTL_DUMMY_GUEST_CONNECTED");
        }
        log(runtime, "[Render thread/INFO]: Main menu initialized");
        try (ServerSocket server = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(30000);
            Files.write(runtime.resolve("control.port"), String.valueOf(server.getLocalPort()).getBytes(StandardCharsets.UTF_8));
            if ("host".equals(scenario)) {
                Thread.sleep(500L);
                log(runtime, "[Server thread/INFO]: Local game hosted on port " + server.getLocalPort());
            } else {
                System.out.println("MMTL_CONTROL_PORT=" + server.getLocalPort());
            }
            System.out.flush();
            boolean stopped = false;
            while (!stopped) {
                try (Socket socket = server.accept();
                     BufferedReader input = new BufferedReader(new InputStreamReader(socket.getInputStream(), "UTF-8"));
                     PrintWriter output = new PrintWriter(socket.getOutputStream(), true)) {
                    String command = input.readLine();
                    if ("STOP".equals(command)) {
                        output.println("STOPPED");
                        System.out.println("MMTL_SAFE_STOP");
                        stopped = true;
                    } else if ("GUEST".equals(command)) {
                        output.println("GUEST_OK");
                        System.out.println("MMTL_DUMMY_GUEST_CONNECTED");
                    } else {
                        output.println("UNKNOWN");
                    }
                }
            }
        }
    }

    private static void log(Path runtime, String line) throws Exception {
        Files.createDirectories(runtime.resolve("logs"));
        Files.write(runtime.resolve("logs").resolve("latest.log"), (line + System.lineSeparator()).getBytes(StandardCharsets.UTF_8), StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        System.out.println(line);
    }
}
