import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;

/** TechEmpower-style benchmark server: JDK HttpServer + virtual threads + JDBC pool. */
public final class Bench {
    private static final int POOL = 16;

    private static final class Db {
        final Connection c;
        final PreparedStatement world;
        final PreparedStatement fortune;
        final PreparedStatement update;

        Db(Connection c) throws SQLException {
            this.c = c;
            this.world = c.prepareStatement("SELECT id, randomnumber FROM world WHERE id = ?");
            this.fortune = c.prepareStatement("SELECT id, message FROM fortune");
            this.update = c.prepareStatement("UPDATE world SET randomnumber = ? WHERE id = ?");
        }
    }

    private static final ArrayBlockingQueue<Db> pool = new ArrayBlockingQueue<>(POOL);

    private static Db acquire() throws InterruptedException { return pool.take(); }
    private static void release(Db db) { pool.offer(db); }

    private static int randId() { return ThreadLocalRandom.current().nextInt(1, 10001); }

    private static int clampQ(String q) {
        if (q == null) return 1;
        try {
            int v = Integer.parseInt(q);
            return Math.max(1, Math.min(500, v));
        } catch (NumberFormatException e) {
            return 1;
        }
    }

    private static String param(String query, String name) {
        if (query == null) return null;
        for (String part : query.split("&")) {
            int eq = part.indexOf('=');
            if (eq < 0) continue;
            if (part.substring(0, eq).equals(name)) return part.substring(eq + 1);
        }
        return null;
    }

    private static String escape(String s) {
        StringBuilder b = new StringBuilder(s.length() + 16);
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            switch (ch) {
                case '&' -> b.append("&amp;");
                case '<' -> b.append("&lt;");
                case '>' -> b.append("&gt;");
                case '"' -> b.append("&quot;");
                case '\'' -> b.append("&#x27;");
                case '/' -> b.append("&#x2F;");
                default -> b.append(ch);
            }
        }
        return b.toString();
    }

    private static void send(HttpExchange ex, int code, String type, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", type);
        ex.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static String db() throws SQLException, InterruptedException {
        Db db = acquire();
        try {
            db.world.setInt(1, randId());
            try (ResultSet rs = db.world.executeQuery()) {
                rs.next();
                return "{\"id\":" + rs.getInt(1) + ",\"randomNumber\":" + rs.getInt(2) + "}";
            }
        } finally {
            release(db);
        }
    }

    private static String queries(int q) throws SQLException, InterruptedException {
        Db db = acquire();
        try {
            StringBuilder sb = new StringBuilder(q * 40 + 2);
            sb.append('[');
            for (int i = 0; i < q; i++) {
                db.world.setInt(1, randId());
                try (ResultSet rs = db.world.executeQuery()) {
                    rs.next();
                    if (i > 0) sb.append(',');
                    sb.append("{\"id\":").append(rs.getInt(1))
                      .append(",\"randomNumber\":").append(rs.getInt(2)).append('}');
                }
            }
            sb.append(']');
            return sb.toString();
        } finally {
            release(db);
        }
    }

    private static String updates(int q) throws SQLException, InterruptedException {
        Db db = acquire();
        try {
            int[] ids = new int[q];
            StringBuilder sb = new StringBuilder(q * 40 + 2);
            sb.append('[');
            for (int i = 0; i < q; i++) {
                ids[i] = randId();
                db.world.setInt(1, ids[i]);
                try (ResultSet rs = db.world.executeQuery()) {
                    rs.next();
                    int rn = ThreadLocalRandom.current().nextInt(1, 10001);
                    db.update.setInt(1, rn);
                    db.update.setInt(2, ids[i]);
                    db.update.executeUpdate();
                    if (i > 0) sb.append(',');
                    sb.append("{\"id\":").append(ids[i])
                      .append(",\"randomNumber\":").append(rn).append('}');
                }
            }
            sb.append(']');
            return sb.toString();
        } finally {
            release(db);
        }
    }

    private static final class Row {
        final int id;
        final String msg;
        Row(int id, String msg) { this.id = id; this.msg = msg; }
    }

    private static String fortunes() throws SQLException, InterruptedException {
        Db db = acquire();
        List<Row> rows = new ArrayList<>(16);
        try (ResultSet rs = db.fortune.executeQuery()) {
            while (rs.next()) rows.add(new Row(rs.getInt(1), rs.getString(2)));
        } finally {
            release(db);
        }
        rows.add(new Row(0, "Additional fortune added at request time."));
        rows.sort((a, b) -> a.msg.compareTo(b.msg));
        StringBuilder sb = new StringBuilder(2048);
        sb.append("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>")
          .append("<tr><th>id</th><th>message</th></tr>");
        for (Row r : rows) {
            sb.append("<tr><td>").append(r.id).append("</td><td>")
              .append(escape(r.msg)).append("</td></tr>");
        }
        sb.append("</table></body></html>");
        return sb.toString();
    }

    private static void handle(HttpExchange ex) throws IOException {
        try {
            String path = ex.getRequestURI().getPath();
            String rawQuery = ex.getRequestURI().getRawQuery();
            switch (path) {
                case "/plaintext" -> send(ex, 200, "text/plain", "Hello, World!");
                case "/json" -> send(ex, 200, "application/json", "{\"message\":\"Hello, World!\"}");
                case "/db" -> send(ex, 200, "application/json", db());
                case "/queries" -> {
                    String q = param(rawQuery, "q");
                    if (q == null) q = param(rawQuery, "queries");
                    send(ex, 200, "application/json", queries(clampQ(q)));
                }
                case "/updates" -> {
                    String q = param(rawQuery, "q");
                    if (q == null) q = param(rawQuery, "queries");
                    send(ex, 200, "application/json", updates(clampQ(q)));
                }
                case "/fortunes" -> send(ex, 200, "text/html; charset=utf-8", fortunes());
                default -> send(ex, 404, "text/plain", "Not Found");
            }
        } catch (Exception e) {
            send(ex, 500, "text/plain", "error");
        } finally {
            ex.close();
        }
    }

    public static void main(String[] args) throws Exception {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : 18085;
        String url = System.getenv().getOrDefault("POSTGRES_JDBC_URL", "jdbc:postgresql://127.0.0.1:5432/hello_world");
        String user = System.getenv().getOrDefault("POSTGRES_USER", "benchmarkdbuser");
        String pass = System.getenv().getOrDefault("POSTGRES_PASSWORD", "benchmarkdbpass");
        for (int i = 0; i < POOL; i++) {
            Connection c = DriverManager.getConnection(url, user, pass);
            c.setAutoCommit(true);
            pool.add(new Db(c));
        }
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 4096);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/", Bench::handle);
        server.start();
        System.out.println("started Java server on port " + port);
    }
}
