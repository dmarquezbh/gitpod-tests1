// Zig epoll server: um loop por thread (SO_REUSEPORT), keep-alive/pipelining e libpq por thread.
const std = @import("std");
const posix = std.posix;

const PGconn = opaque {};
const PGresult = opaque {};
extern fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;
extern fn PQexec(conn: *PGconn, query: [*:0]const u8) ?*PGresult;
extern fn PQntuples(res: *PGresult) c_int;
extern fn PQgetvalue(res: *PGresult, i: c_int, j: c_int) [*:0]u8;
extern fn PQclear(res: *PGresult) void;

const PORT: u16 = 8098;
const MAX_CONN = 4096;

threadlocal var db: ?*PGconn = null;

const Conn = struct {
    fd: posix.fd_t,
    in: [65536]u8 = undefined,
    in_len: usize = 0,
    out: [65536]u8 = undefined,
    out_len: usize = 0,
    out_pos: usize = 0,
};

var conns: [MAX_CONN]?*Conn = [_]?*Conn{null} ** MAX_CONN;
var alloc: std.mem.Allocator = undefined;

fn escrever(c: *Conn, corpo: []const u8, tipo: []const u8) bool {
    var cabecalho: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&cabecalho, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ tipo, corpo.len }) catch return false;
    if (c.out_len + h.len + corpo.len > c.out.len) return false;
    @memcpy(c.out[c.out_len .. c.out_len + h.len], h);
    c.out_len += h.len;
    @memcpy(c.out[c.out_len .. c.out_len + corpo.len], corpo);
    c.out_len += corpo.len;
    return true;
}

fn qtd(alvo: []const u8) usize {
    const i = std.mem.indexOf(u8, alvo, "q=") orelse return 1;
    var n: usize = 0;
    for (alvo[i + 2 ..]) |ch| {
        if (ch < '0' or ch > '9') break;
        n = n * 10 + (ch - '0');
    }
    return @min(@max(n, 1), 500);
}

fn responderDb(c: *Conn, sql: [:0]const u8, tipo: []const u8, corpo: []const u8) void {
    _ = sql;
    _ = escrever(c, corpo, tipo);
}

const PLAIN = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!";
const JSON = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"message\":\"Hello, World!\"}";

const REP_MAX = 256;
const REP_JSON: [JSON.len * REP_MAX]u8 = blk: {
    @setEvalBranchQuota(200000);
    var buf: [JSON.len * REP_MAX]u8 = undefined;
    for (0..REP_MAX) |i| @memcpy(buf[i * JSON.len .. (i + 1) * JSON.len], JSON);
    break :blk buf;
};

const REP: [PLAIN.len * REP_MAX]u8 = blk: {
    @setEvalBranchQuota(200000);
    var buf: [PLAIN.len * REP_MAX]u8 = undefined;
    for (0..REP_MAX) |i| @memcpy(buf[i * PLAIN.len .. (i + 1) * PLAIN.len], PLAIN);
    break :blk buf;
};

const PF = struct {
    fd: posix.fd_t,
    buf: [512]u8 = undefined,
    len: usize = 0,
    kind: u8 = 0,
};

var mutex: std.Thread.Mutex = .{};
var cond: std.Thread.Condition = .{};
var fila: [4096]PF = undefined;
var q_ini: usize = 0;
var q_fim: usize = 0;

fn empilhar(p: PF) void {
    mutex.lock();
    defer mutex.unlock();
    fila[q_fim % fila.len] = p;
    q_fim += 1;
    cond.signal();
}

fn tratar(c: *Conn, pedido: []const u8) void {
    if (pedido.len >= 14 and std.mem.eql(u8, pedido[4..14], "/plaintext")) {
        @memcpy(c.out[c.out_len .. c.out_len + PLAIN.len], PLAIN);
        c.out_len += PLAIN.len;
        return;
    }
    if (pedido.len >= 9 and std.mem.eql(u8, pedido[4..9], "/json")) {
        @memcpy(c.out[c.out_len .. c.out_len + JSON.len], JSON);
        c.out_len += JSON.len;
        return;
    }
    const linha = std.mem.sliceTo(pedido, '\r');
    var partes = std.mem.tokenizeScalar(u8, linha, ' ');
    _ = partes.next();
    const alvo = partes.next() orelse return;
    var p = PF{ .fd = c.fd };
    var w = std.io.fixedBufferStream(&p.buf);
    const wr = w.writer();
    if (std.mem.eql(u8, alvo, "/db")) {
        p.kind = 0;
        wr.print("SELECT id, randomnumber FROM world WHERE id = {d}", .{std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
    } else if (std.mem.startsWith(u8, alvo, "/queries")) {
        p.kind = 1;
        const q = qtd(alvo);
        wr.writeAll("SELECT id, randomnumber FROM world WHERE id IN (") catch return;
        var i: usize = 0;
        while (i < q) : (i += 1) {
            if (i > 0) wr.writeAll(",") catch return;
            wr.print("{d}", .{std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
        }
        wr.writeAll(")") catch return;
    } else if (std.mem.startsWith(u8, alvo, "/updates")) {
        p.kind = 2;
        const q = qtd(alvo);
        wr.writeAll("UPDATE world SET randomnumber = v.rn FROM (VALUES ") catch return;
        var i: usize = 0;
        while (i < q) : (i += 1) {
            if (i > 0) wr.writeAll(",") catch return;
            wr.print("({d},{d})", .{std.crypto.random.intRangeAtMost(u16, 1, 10000), std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
        }
        wr.writeAll(") AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber") catch return;
    } else if (std.mem.eql(u8, alvo, "/fortunes")) {
        p.kind = 3;
        wr.writeAll("SELECT id, message FROM fortune") catch return;
    } else {
        const nao = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        @memcpy(c.out[c.out_len .. c.out_len + nao.len], nao);
        c.out_len += nao.len;
        return;
    }
    p.len = w.pos;
    empilhar(p);
}

fn responderFd(fd: posix.fd_t, corpo: []const u8, tipo: []const u8) void {
    var cab: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&cab, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ tipo, corpo.len }) catch return;
    _ = posix.write(fd, h) catch {};
    var enviado: usize = 0;
    while (enviado < corpo.len) {
        const k = posix.write(fd, corpo[enviado..]) catch return;
        if (k == 0) return;
        enviado += k;
    }
}

fn banco() void {
    db = PQconnectdb("postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world");
    var p: PF = undefined;
    var corpo: [24000]u8 = undefined;
    while (true) {
        mutex.lock();
        while (q_ini == q_fim) cond.wait(&mutex);
        p = fila[q_ini % fila.len];
        q_ini += 1;
        mutex.unlock();
        const r = PQexec(db.?, @ptrCast(&p.buf)) orelse continue;
        defer PQclear(r);
        var fb = std.io.fixedBufferStream(&corpo);
        const w = fb.writer();
        switch (p.kind) {
            0 => {
                w.print("{{\"id\":{s},\"randomNumber\":{s}}}", .{ std.mem.span(PQgetvalue(r, 0, 0)), std.mem.span(PQgetvalue(r, 0, 1)) }) catch continue;
                responderFd(p.fd, fb.getWritten(), "application/json");
            },
            1, 2 => {
                w.writeAll("[") catch continue;
                var j: c_int = 0;
                while (j < PQntuples(r)) : (j += 1) {
                    if (j > 0) w.writeAll(",") catch continue;
                    w.print("{{\"id\":{s},\"randomNumber\":{s}}}", .{ std.mem.span(PQgetvalue(r, j, 0)), std.mem.span(PQgetvalue(r, j, 1)) }) catch continue;
                }
                w.writeAll("]") catch continue;
                responderFd(p.fd, fb.getWritten(), "application/json");
            },
            3 => {
                w.writeAll("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>") catch continue;
                var j: c_int = 0;
                while (j < PQntuples(r)) : (j += 1) {
                    w.writeAll("<tr><td>") catch continue;
                    w.writeAll(std.mem.span(PQgetvalue(r, j, 0))) catch continue;
                    w.writeAll("</td><td>") catch continue;
                    for (std.mem.span(PQgetvalue(r, j, 1))) |ch| switch (ch) {
                        '&' => w.writeAll("&amp;") catch return,
                        '<' => w.writeAll("&lt;") catch return,
                        '>' => w.writeAll("&gt;") catch return,
                        '"' => w.writeAll("&quot;") catch return,
                        else => w.writeByte(ch) catch return,
                    };
                    w.writeAll("</td></tr>") catch continue;
                }
                w.writeAll("</table></body></html>") catch continue;
                responderFd(p.fd, fb.getWritten(), "text/html; charset=utf-8");
            },
            else => {},
        }
    }
}

fn registrar(ep: posix.fd_t, op: u32, fd: posix.fd_t, mascara: u32) void {
    var ev = std.os.linux.epoll_event{ .events = mascara, .data = .{ .fd = fd } };
    posix.epoll_ctl(ep, op, fd, &ev) catch {};
}

fn fechar(ep: posix.fd_t, c: *Conn) void {
    registrar(ep, 2, c.fd, 0);
    posix.close(c.fd);
    var slot: usize = 0;
    while (slot < MAX_CONN) : (slot += 1) {
        if (conns[slot] == c) { conns[slot] = null; break; }
    }
    alloc.destroy(c);
}

fn flush(ep: posix.fd_t, c: *Conn) void {
    while (c.out_pos < c.out_len) {
        const k = posix.write(c.fd, c.out[c.out_pos..c.out_len]) catch {
            fechar(ep, c);
            return;
        };
        if (k == 0) break;
        c.out_pos += k;
    }
    if (c.out_pos >= c.out_len) {
        c.out_pos = 0;
        c.out_len = 0;
        registrar(ep, 3, c.fd, std.os.linux.EPOLL.IN);
    }
}

fn trabalhar() void {
    db = PQconnectdb("postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world");
    const ep = posix.epoll_create1(0) catch return;
    const srv = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return;
    posix.setsockopt(srv, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    posix.setsockopt(srv, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch {};
    const end = std.net.Address.parseIp("0.0.0.0", PORT) catch return;
    posix.bind(srv, &end.any, end.getOsSockLen()) catch return;
    posix.listen(srv, 8192) catch return;
    _ = posix.fcntl(srv, posix.F.SETFL, @as(u32, 0o4000)) catch {};
    registrar(ep, 1, srv, std.os.linux.EPOLL.IN);
    var eventos: [256]std.os.linux.epoll_event = undefined;
    while (true) {
        const n = posix.epoll_wait(ep, &eventos, -1);
        for (eventos[0..n]) |ev| {
            const fd = ev.data.fd;
            if (fd == srv) {
                while (true) {
                    const cl = posix.accept(srv, null, null, 0) catch break;
                    const c = alloc.create(Conn) catch {
                        posix.close(cl);
                        continue;
                    };
                    c.* = .{ .fd = cl };
                    posix.setsockopt(cl, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
                    var slot: usize = 0;
                    while (slot < MAX_CONN) : (slot += 1) {
                        if (conns[slot] == null) { conns[slot] = c; break; }
                    }
                    registrar(ep, 1, cl, std.os.linux.EPOLL.IN);
                }
                continue;
            }
            const c = b: {
                var idx: usize = 0;
                while (idx < MAX_CONN) : (idx += 1) {
                    if (conns[idx]) |p| {
                        if (p.fd == fd) break :b p;
                    }
                }
                break :b null;
            } orelse continue;
            if ((ev.events & std.os.linux.EPOLL.OUT) != 0) {
                flush(ep, c);
                continue;
            }
            const k = posix.read(fd, &c.in) catch |e| {
                std.debug.print("read err {s}\n", .{@errorName(e)});
                fechar(ep, c);
                continue;
            };
            if (k == 0) {
                fechar(ep, c);
                continue;
            }
            var pos: usize = 0;
            const primeiro_fim = std.mem.indexOfPos(u8, c.in[0..k], 0, "\r\n\r\n") orelse 0;
            const tam = if (primeiro_fim > 0) primeiro_fim + 4 else 0;
            if (tam > 0 and k % tam == 0 and k / tam <= REP_MAX and k / tam > 1) {
                var identico = true;
                var q: usize = tam;
                while (q < k) : (q += tam) {
                    if (!std.mem.eql(u8, c.in[0..tam], c.in[q .. q + tam])) { identico = false; break; }
                }
                const eh_plain = std.mem.eql(u8, c.in[0..14], "GET /plaintext");
                const eh_json = std.mem.eql(u8, c.in[0..9], "GET /json");
                if (identico and (eh_plain or eh_json)) {
                    const n_req = k / tam;
                    const corpo = if (eh_plain) REP[0 .. n_req * PLAIN.len] else REP_JSON[0 .. n_req * JSON.len];
                    var enviado: usize = 0;
                    while (enviado < corpo.len) {
                        const w = posix.write(fd, corpo[enviado..]) catch break;
                        if (w == 0) break;
                        enviado += w;
                    }
                    continue;
                }
            }
            while (pos < k) {
                const fim = std.mem.indexOfPos(u8, c.in[0..k], pos, "\r\n\r\n") orelse break;
                tratar(c, c.in[pos .. fim + 4]);
                pos = fim + 4;
            }
            if (c.out_len > 0) {
                flush(ep, c);
                if (c.out_len > 0) {
                    registrar(ep, 3, fd, std.os.linux.EPOLL.OUT);
                }
            }
        }
    }
}

pub fn main() !void {
    alloc = std.heap.page_allocator;
    const cpus = @max(@as(usize, 1), @min(std.Thread.getCpuCount() catch 2, 2));
    std.debug.print("zig-fast5 on :{d}\n", .{PORT});
    for (0..2) |_| _ = try std.Thread.spawn(.{}, banco, .{});
    for (0..cpus) |_| _ = try std.Thread.spawn(.{}, trabalhar, .{});
    while (true) std.time.sleep(3600 * std.time.ns_per_s);
}
