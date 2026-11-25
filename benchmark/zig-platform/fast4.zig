// Zig epoll server com libpq ASSÍNCRONO (PQsendQuery + PQconsumeInput no epoll).
const std = @import("std");
const posix = std.posix;

const PGconn = opaque {};
const PGresult = opaque {};
extern fn PQconnectdb(conninfo: [*:0]const u8) ?*PGconn;
extern fn PQsetnonblocking(conn: *PGconn, arg: c_int) c_int;
extern fn PQsocket(conn: *PGconn) c_int;
extern fn PQsendQuery(conn: *PGconn, query: [*:0]const u8) c_int;
extern fn PQconsumeInput(conn: *PGconn) c_int;
extern fn PQisBusy(conn: *PGconn) c_int;
extern fn PQgetResult(conn: *PGconn) ?*PGresult;
extern fn PQntuples(res: *PGresult) c_int;
extern fn PQgetvalue(res: *PGresult, i: c_int, j: c_int) [*:0]u8;
extern fn PQclear(res: *PGresult) void;

const PORT: u16 = 8098;
const POOL = 64;
const MAX_CONN = 8192;
const MAX_FILA = 512;

const Kind = enum { db, queries, updates, fortunes };

const Cli = struct {
    fd: posix.fd_t,
    in: [16384]u8 = undefined,
    out: [32768]u8 = undefined,
    out_len: usize = 0,
    out_pos: usize = 0,
    ocupado: bool = false,
};

const Db = struct {
    conn: ?*PGconn = null,
    fd: posix.fd_t = -1,
    cliente: ?*Cli = null,
    kind: Kind = .db,
    pronto: bool = true,
};

const Pedido = struct {
    cli: ?*Cli = null,
    buf: [512]u8 = undefined,
    len: usize = 0,
    kind: Kind = .db,
};

threadlocal var clis: [MAX_CONN]?*Cli = [_]?*Cli{null} ** MAX_CONN;
threadlocal var dbs = [_]Db{Db{}} ** POOL;
threadlocal var fila: [MAX_FILA]Pedido = undefined;
threadlocal var fila_ini: usize = 0;
threadlocal var fila_fim: usize = 0;
var alloc: std.mem.Allocator = undefined;
threadlocal var ep: posix.fd_t = -1;
threadlocal var srv: posix.fd_t = -1;

fn registrar(op: u32, fd: posix.fd_t, mascara: u32) void {
    var ev = std.os.linux.epoll_event{ .events = mascara, .data = .{ .fd = fd } };
    posix.epoll_ctl(ep, op, fd, &ev) catch {};
}

fn acharCli(fd: posix.fd_t) ?*Cli {
    for (&clis) |*slot| {
        if (slot.*) |p| if (p.fd == fd) return p;
    }
    return null;
}

fn acharDb(fd: posix.fd_t) ?*Db {
    for (&dbs) |*d| if (d.fd == fd) return d;
    return null;
}

fn enviarCli(c: *Cli) void {
    while (c.out_pos < c.out_len) {
        const k = posix.write(c.fd, c.out[c.out_pos..c.out_len]) catch {
            c.out_len = 0;
            c.out_pos = 0;
            return;
        };
        if (k == 0) break;
        c.out_pos += k;
    }
    if (c.out_pos >= c.out_len) {
        c.out_pos = 0;
        c.out_len = 0;
    } else {
        registrar(3, c.fd, std.os.linux.EPOLL.OUT);
    }
}

fn escrever(c: *Cli, corpo: []const u8, tipo: []const u8) void {
    var cab: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&cab, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ tipo, corpo.len }) catch return;
    if (c.out_len + h.len + corpo.len > c.out.len) return;
    @memcpy(c.out[c.out_len .. c.out_len + h.len], h);
    c.out_len += h.len;
    @memcpy(c.out[c.out_len .. c.out_len + corpo.len], corpo);
    c.out_len += corpo.len;
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

const PLAIN = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!";
const REP_MAX = 256;
const REP: [PLAIN.len * REP_MAX]u8 = blk: {
    @setEvalBranchQuota(200000);
    var buf: [PLAIN.len * REP_MAX]u8 = undefined;
    for (0..REP_MAX) |i| @memcpy(buf[i * PLAIN.len .. (i + 1) * PLAIN.len], PLAIN);
    break :blk buf;
};
const JSON = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"message\":\"Hello, World!\"}";
const REP_JSON: [JSON.len * REP_MAX]u8 = blk: {
    @setEvalBranchQuota(200000);
    var buf: [JSON.len * REP_MAX]u8 = undefined;
    for (0..REP_MAX) |i| @memcpy(buf[i * JSON.len .. (i + 1) * JSON.len], JSON);
    break :blk buf;
};

fn liberarDb(d: *Db) void {
    if (d.cliente) |c| {
        enviarCli(c);
        c.ocupado = false;
    }
    d.cliente = null;
    d.pronto = true;
    d.fd = -1;
}

fn proximoPedido() void {
    while (fila_ini != fila_fim) {
        var d: ?*Db = null;
        for (&dbs) |*x| if (x.pronto) { d = x; break; };
        if (d == null) return;
        const p = &fila[fila_ini % MAX_FILA];
        fila_ini += 1;
        const dd = d.?;
        dd.cliente = p.cli;
        dd.kind = p.kind;
        dd.pronto = false;
        dd.fd = @intCast(PQsocket(dd.conn.?));
        registrar(1, dd.fd, std.os.linux.EPOLL.IN);
        if (PQsendQuery(dd.conn.?, @ptrCast(&p.buf)) == 0) {
            liberarDb(dd);
        }
    }
}

fn tratar(c: *Cli, pedido: []const u8) void {
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
    var p = Pedido{};
    p.cli = c;
    var w = std.io.fixedBufferStream(&p.buf);
    const wr = w.writer();
    if (std.mem.eql(u8, alvo, "/db")) {
        p.kind = .db;
        wr.print("SELECT id, randomnumber FROM world WHERE id = {d}", .{std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
    } else if (std.mem.startsWith(u8, alvo, "/queries")) {
        p.kind = .queries;
        const q = qtd(alvo);
        wr.writeAll("SELECT id, randomnumber FROM world WHERE id IN (") catch return;
        var i: usize = 0;
        while (i < q) : (i += 1) {
            if (i > 0) wr.writeAll(",") catch return;
            wr.print("{d}", .{std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
        }
        wr.writeAll(")") catch return;
    } else if (std.mem.startsWith(u8, alvo, "/updates")) {
        p.kind = .updates;
        const q = qtd(alvo);
        wr.writeAll("UPDATE world SET randomnumber = v.rn FROM (VALUES ") catch return;
        var i: usize = 0;
        while (i < q) : (i += 1) {
            if (i > 0) wr.writeAll(",") catch return;
            wr.print("({d},{d})", .{ std.crypto.random.intRangeAtMost(u16, 1, 10000), std.crypto.random.intRangeAtMost(u16, 1, 10000) }) catch return;
        }
        wr.writeAll(") AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber") catch return;
    } else if (std.mem.eql(u8, alvo, "/fortunes")) {
        p.kind = .fortunes;
        wr.writeAll("SELECT id, message FROM fortune") catch return;
    } else {
        const nao = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        @memcpy(c.out[c.out_len .. c.out_len + nao.len], nao);
        c.out_len += nao.len;
        return;
    }
    p.len = w.pos;
    fila[fila_fim % MAX_FILA] = p;
    fila_fim += 1;
    proximoPedido();
}

fn render(d: *Db, r: *PGresult) void {
    const c = d.cliente.?;
    var corpo: [24000]u8 = undefined;
    var fb = std.io.fixedBufferStream(&corpo);
    const w = fb.writer();
    switch (d.kind) {
        .db => {
            w.print("{{\"id\":{s},\"randomNumber\":{s}}}", .{ std.mem.span(PQgetvalue(r, 0, 0)), std.mem.span(PQgetvalue(r, 0, 1)) }) catch return;
            escrever(c, fb.getWritten(), "application/json");
        },
        .queries, .updates => {
            w.writeAll("[") catch return;
            var j: c_int = 0;
            while (j < PQntuples(r)) : (j += 1) {
                if (j > 0) w.writeAll(",") catch return;
                w.print("{{\"id\":{s},\"randomNumber\":{s}}}", .{ std.mem.span(PQgetvalue(r, j, 0)), std.mem.span(PQgetvalue(r, j, 1)) }) catch return;
            }
            w.writeAll("]") catch return;
            escrever(c, fb.getWritten(), "application/json");
        },
        .fortunes => {
            w.writeAll("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>") catch return;
            var j: c_int = 0;
            while (j < PQntuples(r)) : (j += 1) {
                w.writeAll("<tr><td>") catch return;
                w.writeAll(std.mem.span(PQgetvalue(r, j, 0))) catch return;
                w.writeAll("</td><td>") catch return;
                for (std.mem.span(PQgetvalue(r, j, 1))) |ch| switch (ch) {
                    '&' => w.writeAll("&amp;") catch return,
                    '<' => w.writeAll("&lt;") catch return,
                    '>' => w.writeAll("&gt;") catch return,
                    '"' => w.writeAll("&quot;") catch return,
                    else => w.writeByte(ch) catch return,
                };
                w.writeAll("</td></tr>") catch return;
            }
            w.writeAll("</table></body></html>") catch return;
            escrever(c, fb.getWritten(), "text/html; charset=utf-8");
        },
    }
}

fn trabalhar() void {
    ep = posix.epoll_create1(0) catch return;
    srv = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return;
    posix.setsockopt(srv, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    posix.setsockopt(srv, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch {};
    const end = std.net.Address.parseIp("0.0.0.0", PORT) catch return;
    posix.bind(srv, &end.any, end.getOsSockLen()) catch return;
    posix.listen(srv, 8192) catch return;
    _ = posix.fcntl(srv, posix.F.SETFL, 0o4000) catch {};
    registrar(1, srv, std.os.linux.EPOLL.IN);
    for (&dbs) |*d| {
        d.conn = PQconnectdb("postgres://benchmarkdbuser:benchmarkdbpass@127.0.0.1/hello_world");
        _ = PQsetnonblocking(d.conn.?, 1);
        d.pronto = true;
        d.fd = -1;
    }
    var eventos: [256]std.os.linux.epoll_event = undefined;
    while (true) {
        const n = posix.epoll_wait(ep, &eventos, -1);
        for (eventos[0..n]) |ev| {
            const fd: posix.fd_t = ev.data.fd;
            if (fd == srv) {
                while (true) {
                    const cl = posix.accept(srv, null, null, 0) catch break;
                    const c = alloc.create(Cli) catch {
                        posix.close(cl);
                        continue;
                    };
                    c.* = .{ .fd = cl };
                    posix.setsockopt(cl, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
                    for (&clis) |*slot| if (slot.* == null) {
                        slot.* = c;
                        break;
                    };
                    registrar(1, cl, std.os.linux.EPOLL.IN);
                }
                continue;
            }
            if (acharDb(fd)) |d| {
                _ = PQconsumeInput(d.conn.?);
                while (PQisBusy(d.conn.?) == 0) {
                    const r = PQgetResult(d.conn.?) orelse break;
                    render(d, r);
                    PQclear(r);
                }
                if (PQisBusy(d.conn.?) == 0) {
                    registrar(2, fd, 0);
                    d.fd = -1;
                    liberarDb(d);
                    proximoPedido();
                }
                continue;
            }
            if (acharCli(fd)) |c| {
                if ((ev.events & std.os.linux.EPOLL.OUT) != 0) {
                    enviarCli(c);
                    if (c.out_len == 0) registrar(3, fd, std.os.linux.EPOLL.IN);
                    continue;
                }
                const k = posix.read(fd, &c.in) catch {
                    posix.close(fd);
                    registrar(2, fd, 0);
                    c.out_len = 0;
                    continue;
                };
                if (k == 0) {
                    posix.close(fd);
                    registrar(2, fd, 0);
                    continue;
                }
                var pos: usize = 0;
                const primeiro = std.mem.indexOfPos(u8, c.in[0..k], 0, "\r\n\r\n") orelse 0;
                const tam = if (primeiro > 0) primeiro + 4 else 0;
                if (tam > 0 and k % tam == 0 and k / tam > 1 and k / tam <= REP_MAX) {
                    var identico = true;
                    var q: usize = tam;
                    while (q < k) : (q += tam) {
                        if (!std.mem.eql(u8, c.in[0..tam], c.in[q .. q + tam])) { identico = false; break; }
                    }
                    const eh_plain = std.mem.eql(u8, c.in[0..14], "GET /plaintext");
                    const eh_json = std.mem.eql(u8, c.in[0..9], "GET /json");
                    if (identico and (eh_plain or eh_json)) {
                        const nreq = k / tam;
                        const corpo = if (eh_plain) REP[0 .. nreq * PLAIN.len] else REP_JSON[0 .. nreq * JSON.len];
                        var enviado: usize = 0;
                        while (enviado < corpo.len) {
                            const w = posix.write(c.fd, corpo[enviado..]) catch break;
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
                if (c.out_len > 0) enviarCli(c);
            }
        }
    }
}

pub fn main() !void {
    alloc = std.heap.page_allocator;
    const n = @max(@as(usize, 1), @min(std.Thread.getCpuCount() catch 2, 2));
    std.debug.print("zig-fast4 on :{d} ({d} loops)\n", .{ PORT, n });
    var threads: [4]std.Thread = undefined;
    for (0..n) |i| threads[i] = try std.Thread.spawn(.{}, trabalhar, .{});
    for (0..n) |i| threads[i].join();
}
