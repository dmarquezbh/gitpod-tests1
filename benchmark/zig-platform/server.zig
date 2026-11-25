// Zig "platform" entry: sockets crus (std.posix) + libpq via @cImport, os seis testes.
const std = @import("std");
const PGconn = opaque {};
const PGresult = opaque {};
extern fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;
extern fn PQexec(conn: *PGconn, query: [*:0]const u8) ?*PGresult;
extern fn PQntuples(res: *PGresult) c_int;
extern fn PQgetvalue(res: *PGresult, i: c_int, j: c_int) [*:0]u8;
extern fn PQclear(res: *PGresult) void;

const PORT: u16 = 8098;

threadlocal var conn: ?*PGconn = null;

fn connectDb() void {
    conn = PQconnectdb("postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world");
    if (conn == null) @panic("libpq: sem conexao");
}

fn queryInt(sql: [:0]const u8, out: *[1024]u8) []const u8 {
    const r = PQexec(conn.?, sql.ptr) orelse return "";
    defer PQclear(r);
    const n = PQntuples(r);
    if (n != 1) return "";
    const id = std.mem.span(PQgetvalue(r, 0, 0));
    const rn = std.mem.span(PQgetvalue(r, 0, 1));
    return std.fmt.bufPrint(out, "{{\"id\":{s},\"randomNumber\":{s}}}", .{ id, rn }) catch "";
}

fn fortunes(out: *std.ArrayList(u8)) void {
    const r = PQexec(conn.?, "SELECT id, message FROM fortune") orelse return;
    defer PQclear(r);
    const n = PQntuples(r);
    out.appendSlice("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>") catch return;
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const id = std.mem.span(PQgetvalue(r, i, 0));
        const msg = std.mem.span(PQgetvalue(r, i, 1));
        out.appendSlice("<tr><td>") catch return;
        out.appendSlice(id) catch return;
        out.appendSlice("</td><td>") catch return;
        for (msg) |ch| switch (ch) {
            '&' => out.appendSlice("&amp;") catch return,
            '<' => out.appendSlice("&lt;") catch return,
            '>' => out.appendSlice("&gt;") catch return,
            '"' => out.appendSlice("&quot;") catch return,
            else => out.append(ch) catch return,
        };
        out.appendSlice("</td></tr>") catch return;
    }
    out.appendSlice("</table></body></html>") catch return;
}

fn responder(fd: std.posix.fd_t, corpo: []const u8, tipo: []const u8) void {
    var head: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ tipo, corpo.len }) catch return;
    _ = std.posix.write(fd, h) catch {};
    var enviado: usize = 0;
    while (enviado < corpo.len) enviado += std.posix.write(fd, corpo[enviado..]) catch break;
}

fn qtd(path: []const u8) usize {
    const i = std.mem.indexOf(u8, path, "q=") orelse return 1;
    var n: usize = 0;
    for (path[i + 2 ..]) |ch| {
        if (ch < '0' or ch > '9') break;
        n = n * 10 + (ch - '0');
    }
    return @min(@max(n, 1), 500);
}

fn tratar(fd: std.posix.fd_t, req: []const u8, alloc: std.mem.Allocator) void {
    const linha = std.mem.sliceTo(req, '\r');
    var partes = std.mem.tokenizeScalar(u8, linha, ' ');
    _ = partes.next();
    const caminho = partes.next() orelse return;
    if (std.mem.eql(u8, caminho, "/plaintext")) {
        responder(fd, "Hello, World!", "text/plain");
    } else if (std.mem.eql(u8, caminho, "/json")) {
        responder(fd, "{\"message\":\"Hello, World!\"}", "application/json");
    } else if (std.mem.eql(u8, caminho, "/db")) {
        var buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&buf, "SELECT id, randomnumber FROM world WHERE id = {d}", .{std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
        var saida: [1024]u8 = undefined;
        const body = queryInt(sql, &saida);
        responder(fd, body, "application/json");
    } else if (std.mem.startsWith(u8, caminho, "/queries")) {
        var lista: [2048]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&lista);
        const w = fbs.writer();
        var saida: [8192]u8 = undefined;
        var ob = std.io.fixedBufferStream(&saida);
        const ow = ob.writer();
        ow.writeAll("[") catch return;
        const q = qtd(caminho);
        var i: usize = 0;
        while (i < q) : (i += 1) {
            if (i > 0) w.writeAll(",") catch return;
            w.print("{d}", .{std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
        }
        var sqlbuf: [4096]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&sqlbuf, "SELECT id, randomnumber FROM world WHERE id IN ({s})", .{fbs.getWritten()}) catch return;
        const r = PQexec(conn.?, sql.ptr) orelse return;
        defer PQclear(r);
        var j: c_int = 0;
        while (j < PQntuples(r)) : (j += 1) {
            if (j > 0) ow.writeAll(",") catch return;
            ow.print("{{\"id\":{s},\"randomNumber\":{s}}}", .{ std.mem.span(PQgetvalue(r, j, 0)), std.mem.span(PQgetvalue(r, j, 1)) }) catch return;
        }
        ow.writeAll("]") catch return;
        responder(fd, ob.getWritten(), "application/json");
    } else if (std.mem.startsWith(u8, caminho, "/updates")) {
        const q = qtd(caminho);
        var pares: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&pares);
        const w = fbs.writer();
        var i: usize = 0;
        while (i < q) : (i += 1) {
            if (i > 0) w.writeAll(",") catch return;
            w.print("({d},{d})", .{ std.crypto.random.intRangeAtMost(u16, 1, 10000), std.crypto.random.intRangeAtMost(u16, 1, 10000) }) catch return;
        }
        var sqlbuf: [4096]u8 = undefined;
        const sql = std.fmt.bufPrintZ(&sqlbuf, "UPDATE world SET randomnumber = v.rn FROM (VALUES {s}) AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber", .{fbs.getWritten()}) catch return;
        const r = PQexec(conn.?, sql.ptr) orelse return;
        defer PQclear(r);
        var saida: [8192]u8 = undefined;
        var ob = std.io.fixedBufferStream(&saida);
        const ow = ob.writer();
        ow.writeAll("[") catch return;
        var j: c_int = 0;
        while (j < PQntuples(r)) : (j += 1) {
            if (j > 0) ow.writeAll(",") catch return;
            ow.print("{{\"id\":{s},\"randomNumber\":{s}}}", .{ std.mem.span(PQgetvalue(r, j, 0)), std.mem.span(PQgetvalue(r, j, 1)) }) catch return;
        }
        ow.writeAll("]") catch return;
        responder(fd, ob.getWritten(), "application/json");
    } else if (std.mem.eql(u8, caminho, "/fortunes")) {
        var out = std.ArrayList(u8).init(alloc);
        defer out.deinit();
        fortunes(&out);
        responder(fd, out.items, "text/html; charset=utf-8");
    } else {
        _ = std.posix.write(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n") catch {};
    }
}

fn worker() void {
    const alloc = std.heap.page_allocator;
    connectDb();
    const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return;
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch {};
    const endereco = std.net.Address.parseIp("0.0.0.0", PORT) catch return;
    std.posix.bind(sock, &endereco.any, endereco.getOsSockLen()) catch return;
    std.posix.listen(sock, 4096) catch return;
    var buf: [65536]u8 = undefined;
    while (true) {
        const cliente = std.posix.accept(sock, null, null, 0) catch continue;
        while (true) {
            const n = std.posix.read(cliente, &buf) catch break;
            if (n == 0) break;
            var pos: usize = 0;
            while (pos < n) {
                const fim = std.mem.indexOfPos(u8, buf[0..n], pos, "\r\n\r\n") orelse break;
                tratar(cliente, buf[pos .. fim + 4], alloc);
                pos = fim + 4;
            }
        }
        std.posix.close(cliente);
    }
}

pub fn main() !void {
    const n = std.Thread.getCpuCount() catch 2;
    const total = @max(@as(usize, 1), @min(n, 4));
    var threads: [4]std.Thread = undefined;
    std.debug.print("zig-platform on :{d} ({d} threads)\n", .{ PORT, total });
    for (0..total) |i| threads[i] = try std.Thread.spawn(.{}, worker, .{});
    for (0..total) |i| threads[i].join();
}
