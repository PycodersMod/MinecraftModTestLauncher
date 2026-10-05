package net.minecraft.server;

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
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;

/** 仅供 MMTL 自动化演练使用的 loopback 假服务器，不启动 Minecraft 或触及 EULA。 */
public final class Main {
    private Main() { }

    public static void main(String[] args) throws Exception {
        Path runtime = Paths.get(args.length == 0 ? "." : args[0]);
        int requestedPort = args.length < 2 ? 0 : Integer.parseInt(args[1]);
        try (ServerSocket server = new ServerSocket(requestedPort, 8, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(30000);
            Path portFile = runtime.resolve("server.port");
            Path temporaryPortFile = runtime.resolve("server.port.tmp");
            Files.write(temporaryPortFile, String.valueOf(server.getLocalPort()).getBytes(StandardCharsets.UTF_8));
            try {
                Files.move(temporaryPortFile, portFile, StandardCopyOption.ATOMIC_MOVE);
            } catch (java.nio.file.AtomicMoveNotSupportedException ignored) {
                Files.move(temporaryPortFile, portFile, StandardCopyOption.REPLACE_EXISTING);
            }
            Thread.sleep(250L);
            log(runtime, "Done (0.1s)! For help, type \"help\"");
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
