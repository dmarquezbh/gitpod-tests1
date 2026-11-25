// Zig: HTTP epoll com burst (como fast.zig) + cliente PostgreSQL wire PRÓPRIO com pipelining.
// O cliente abre N conexões por thread de banco, manda até K queries por conexão sem esperar
// resposta (protocolo simples do PG) e lê os ReadyForQuery na ordem.
const std = @import("std");
const posix = std.posix;

const PORT: u16 = 8098;
const PG_PORT: u16 = 5432;
const PG_USER = "benchmarkdbuser";
const PG_DB = "hello_world";
const CONNS_POR_THREAD = 1;
const PIPELINE = 1;
const MAX_CONN = 8192;
const MAX_FILA = 8192;

const PLAIN = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!";
const JSON = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"message\":\"Hello, World!\"}";
const REP_MAX = 256;
const REP: [PLAIN.len * REP_MAX]u8 = blk: {
    @setEvalBranchQuota(200000);
    var buf: [PLAIN.len * REP_MAX]u8 = undefined;
    for (0..REP_MAX) |i| @memcpy(buf[i * PLAIN.len .. (i + 1) * PLAIN.len], PLAIN);
    break :blk buf;
};

const Conn = struct {
    fd: posix.fd_t,
    in: [65536]u8 = undefined,
    out: [32768]u8 = undefined,
    out_len: usize = 0,
    out_pos: usize = 0,
};
var conns: [MAX_CONN]?*Conn = [_]?*Conn{null} ** MAX_CONN;
var alloc: std.mem.Allocator = undefined;

const PF = struct {
    fd: posix.fd_t,
    buf: [512]u8 = undefined,
    len: usize = 0,
    kind: u8 = 0,
};
var mutex: std.Thread.Mutex = .{};
var cond: std.Thread.Condition = .{};
var fila: [MAX_FILA]PF = undefined;
var q_ini: usize = 0;
var q_fim: usize = 0;

fn registrar(ep: posix.fd_t, op: u32, fd: posix.fd_t, mascara: u32) void {
    var ev = std.os.linux.epoll_event{ .events = mascara, .data = .{ .fd = fd } };
    posix.epoll_ctl(ep, op, fd, &ev) catch {};
}

fn escreverCli(c: *Conn, corpo: []const u8, tipo: []const u8) void {
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
    var wb = std.io.fixedBufferStream(&p.buf);
    const w = wb.writer();
    if (std.mem.eql(u8, alvo, "/db")) {
        p.kind = 0;
        w.print("SELECT id, randomnumber FROM world WHERE id = {d}", .{std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
    } else if (std.mem.startsWith(u8, alvo, "/queries")) {
        p.kind = 1;
        const q = qtd(alvo);
        w.writeAll("SELECT id, randomnumber FROM world WHERE id IN (") catch return;
        var i: usize = 0;
        while (i < q) : (i += 1) {
            if (i > 0) w.writeAll(",") catch return;
            w.print("{d}", .{std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
        }
        w.writeAll(")") catch return;
    } else if (std.mem.startsWith(u8, alvo, "/updates")) {
        p.kind = 2;
        const q = qtd(alvo);
        w.writeAll("UPDATE world SET randomnumber = v.rn FROM (VALUES ") catch return;
        var i: usize = 0;
        while (i < q) : (i += 1) {
            if (i > 0) w.writeAll(",") catch return;
            w.print("({d},{d})", .{std.crypto.random.intRangeAtMost(u16, 1, 10000), std.crypto.random.intRangeAtMost(u16, 1, 10000)}) catch return;
        }
        w.writeAll(") AS v(id, rn) WHERE world.id = v.id RETURNING world.id, world.randomnumber") catch return;
    } else if (std.mem.eql(u8, alvo, "/fortunes")) {
        p.kind = 3;
        w.writeAll("SELECT id, message FROM fortune") catch return;
    } else {
        const nao = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
        @memcpy(c.out[c.out_len .. c.out_len + nao.len], nao);
        c.out_len += nao.len;
        return;
    }
    p.len = wb.pos;
    mutex.lock();
    defer mutex.unlock();
    fila[q_fim % MAX_FILA] = p;
    q_fim += 1;
    cond.signal();
}

// ── cliente PostgreSQL wire ────────────────────────────────────────────────────
const Pg = struct {
    fd: posix.fd_t,
    buf: [65536]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,
};

fn lerExato(fd: posix.fd_t, dst: []u8) !void {
    var off: usize = 0;
    while (off < dst.len) {
        const n = try posix.read(fd, dst[off..]);
        if (n == 0) return error.Eof;
        off += n;
    }
}

fn lerMensagem(pg: *Pg, payload: *[65536]u8) !u8 {
    var cab: [5]u8 = undefined;
    try lerExato(pg.fd, &cab);
    const tipo = cab[0];
    const tam = std.mem.readInt(i32, cab[1..5], .big);
    const corpo_len: usize = @intCast(tam - 4);
    if (corpo_len > payload.len) return error.MensagemGrande;
    try lerExato(pg.fd, payload[0..corpo_len]);
    pg.len = corpo_len;
    return tipo;
}

fn enviar(pg: *Pg, dados: []const u8) !void {
    var off: usize = 0;
    while (off < dados.len) {
        const n = try posix.write(pg.fd, dados[off..]);
        off += n;
    }
}

fn conectarPg() !Pg {
    const s = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    var end = try std.net.Address.parseIp("127.0.0.1", PG_PORT);
    try posix.connect(s, &end.any, end.getOsSockLen());
    posix.setsockopt(s, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
    var msg: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&msg);
    const w = fbs.writer();
    try w.writeInt(i32, 0, .big); // placeholder do tamanho
    try w.writeInt(i32, 196608, .big);
    try w.writeAll("user\x00" ++ PG_USER ++ "\x00database\x00" ++ PG_DB ++ "\x00\x00");
    const total: i32 = @intCast(fbs.pos);
    var copia = msg;
    std.mem.writeInt(i32, copia[0..4], total, .big);
    var tmp = Pg{ .fd = s };
    try enviar(&tmp, copia[0..fbs.pos]);
    var pg = Pg{ .fd = s };
    var payload: [65536]u8 = undefined;
    while (true) {
        const t = try lerMensagem(&pg, &payload);
        if (t == 'E') return error.Auth;
        if (t == 'Z') break;
    }
    return pg;
}

const Resposta = struct {
    tipo: u8 = 0,
    linhas: usize = 0,
    dados: [24000]u8 = undefined,
    len: usize = 0,
};

fn processarResposta(pg: *Pg, kind: u8, saida: *[24000]u8) usize {
    var payload: [65536]u8 = undefined;
    var fb = std.io.fixedBufferStream(saida);
    const w = fb.writer();
    var primeiro = true;
    var finalizado = false;
    switch (kind) {
        1, 2 => w.writeAll("[") catch {},
        3 => w.writeAll("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>") catch {},
        else => {},
    }
    while (true) {
        const t = lerMensagem(pg, &payload) catch return 0;
        if (t == 'D') {
            var off: usize = 0;
            const ncampos = std.mem.readInt(i16, payload[off..][0..2], .big);
            off += 2;
            var campos: [4][]const u8 = undefined;
            var i: usize = 0;
            while (i < @as(usize, @intCast(ncampos))) : (i += 1) {
                const tam = std.mem.readInt(i32, payload[off..][0..4], .big);
                off += 4;
                if (tam < 0) {
                    campos[i] = "";
                } else {
                    const l: usize = @intCast(tam);
                    campos[i] = payload[off .. off + l];
                    off += l;
                }
            }
            switch (kind) {
                0 => {
                    w.print("{{\"id\":{s},\"randomNumber\":{s}}}", .{ campos[0], campos[1] }) catch {};
                    primeiro = false;
                },
                1, 2 => {
                    if (!primeiro) w.writeAll(",") catch {};
                    primeiro = false;
                    w.print("{{\"id\":{s},\"randomNumber\":{s}}}", .{ campos[0], campos[1] }) catch {};
                },
                3 => {
                    w.writeAll("<tr><td>") catch {};
                    w.writeAll(campos[0]) catch {};
                    w.writeAll("</td><td>") catch {};
                    for (campos[1]) |ch| switch (ch) {
                        '&' => w.writeAll("&amp;") catch {},
                        '<' => w.writeAll("&lt;") catch {},
                        '>' => w.writeAll("&gt;") catch {},
                        '"' => w.writeAll("&quot;") catch {},
                        else => w.writeByte(ch) catch {},
                    };
                    w.writeAll("</td></tr>") catch {};
                },
                else => {},
            }
        } else if (t == 'Z') {
            finalizado = true;
            break;
        } else if (t == 'E') {
            break;
        }
    }
    if (!finalizado) return 0;
    switch (kind) {
        1, 2 => w.writeAll("]") catch {},
        3 => w.writeAll("</table></body></html>") catch {},
        else => {},
    }
    return fb.pos;
}

fn enviarQuery(pg: *Pg, sql: []const u8) !void {
    var cab: [5]u8 = undefined;
    cab[0] = 'Q';
    std.mem.writeInt(i32, cab[1..5], @intCast(4 + sql.len + 1), .big);
    try enviar(pg, &cab);
    try enviar(pg, sql);
    try enviar(pg, "\x00");
}

fn responderFd(fd: posix.fd_t, corpo: []const u8, tipo: []const u8) void {
    var cab: [128]u8 = undefined;
    const h = std.fmt.bufPrint(&cab, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ tipo, corpo.len }) catch return;
    _ = posix.write(fd, h) catch {};
    var off: usize = 0;
    while (off < corpo.len) {
        const n = posix.write(fd, corpo[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

fn banco() void {
    var pgs: [CONNS_POR_THREAD]Pg = undefined;
    for (&pgs) |*p| p.* = conectarPg() catch return;
    var lote: [1]PF = undefined;
    var saidas: [1][24000]u8 = undefined;
    while (true) {
        var n: usize = 0;
        mutex.lock();
        while (q_ini == q_fim) cond.wait(&mutex);
        while (n < PIPELINE and q_ini != q_fim) : (n += 1) {
            lote[n] = fila[q_ini % MAX_FILA];
            q_ini += 1;
        }
        mutex.unlock();
        const pg = &pgs[std.crypto.random.intRangeAtMost(u16, 0, CONNS_POR_THREAD - 1)];
        for (lote[0..n]) |p| {
            enviarQuery(pg, p.buf[0..p.len]) catch continue;
        }
        for (lote[0..n], 0..) |p, i| {
            const tam = processarResposta(pg, p.kind, &saidas[i]);
            if (tam == 0) continue;
            const tipo: []const u8 = switch (p.kind) {
                3 => "text/html; charset=utf-8",
                else => "application/json",
            };
            responderFd(p.fd, saidas[i][0..tam], tipo);
        }
    }
}

fn tratarCli(ep: posix.fd_t, fd: posix.fd_t, c: *Conn, buf: []u8) void {
    _ = ep;
    _ = buf;
    _ = c;
    _ = fd;
}

fn flush(ep: posix.fd_t, c: *Conn) void {
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
        registrar(ep, 3, c.fd, std.os.linux.EPOLL.OUT);
    }
}

fn fechar(ep: posix.fd_t, c: *Conn) void {
    registrar(ep, 2, c.fd, 0);
    posix.close(c.fd);
    for (&conns) |*slot| if (slot.* == c) {
        slot.* = null;
        break;
    };
    alloc.destroy(c);
}

fn trabalhar() void {
    const ep = posix.epoll_create1(0) catch return;
    const srv = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return;
    posix.setsockopt(srv, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    posix.setsockopt(srv, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch {};
    const end = std.net.Address.parseIp("0.0.0.0", PORT) catch return;
    posix.bind(srv, &end.any, end.getOsSockLen()) catch return;
    posix.listen(srv, 8192) catch return;
    _ = posix.fcntl(srv, posix.F.SETFL, 0o4000) catch {};
    registrar(ep, 1, srv, std.os.linux.EPOLL.IN);
    var eventos: [256]std.os.linux.epoll_event = undefined;
    while (true) {
        const n = posix.epoll_wait(ep, &eventos, -1);
        for (eventos[0..n]) |ev| {
            const fd: posix.fd_t = ev.data.fd;
            if (fd == srv) {
                while (true) {
                    const cl = posix.accept(srv, null, null, 0) catch break;
                    const c = alloc.create(Conn) catch {
                        posix.close(cl);
                        continue;
                    };
                    c.* = .{ .fd = cl };
                    posix.setsockopt(cl, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
                    for (&conns) |*slot| if (slot.* == null) {
                        slot.* = c;
                        break;
                    };
                    registrar(ep, 1, cl, std.os.linux.EPOLL.IN);
                }
                continue;
            }
            var c: ?*Conn = null;
            for (&conns) |*slot| if (slot.*) |p| if (p.fd == fd) {
                c = p;
                break;
            };
            if (c == null) continue;
            const cc = c.?;
            if ((ev.events & std.os.linux.EPOLL.OUT) != 0) {
                flush(ep, cc);
                continue;
            }
            const k = posix.read(fd, &cc.in) catch {
                fechar(ep, cc);
                continue;
            };
            if (k == 0) {
                fechar(ep, cc);
                continue;
            }
            var pos: usize = 0;
            const primeiro = std.mem.indexOfPos(u8, cc.in[0..k], 0, "\r\n\r\n") orelse 0;
            const tam = if (primeiro > 0) primeiro + 4 else 0;
            if (tam > 0 and k % tam == 0 and k / tam > 1 and k / tam <= REP_MAX) {
                var identico = true;
                var qq: usize = tam;
                while (qq < k) : (qq += tam) {
                    if (!std.mem.eql(u8, cc.in[0..tam], cc.in[qq .. qq + tam])) {
                        identico = false;
                        break;
                    }
                }
                if (identico and std.mem.eql(u8, cc.in[0..14], "GET /plaintext")) {
                    const nreq = k / tam;
                    const corpo = REP[0 .. nreq * PLAIN.len];
                    var off: usize = 0;
                    while (off < corpo.len) {
                        const w = posix.write(fd, corpo[off..]) catch break;
                        if (w == 0) break;
                        off += w;
                    }
                    continue;
                }
            }
            while (pos < k) {
                const fim2 = std.mem.indexOfPos(u8, cc.in[0..k], pos, "\r\n\r\n") orelse break;
                tratar(cc, cc.in[pos .. fim2 + 4]);
                pos = fim2 + 4;
            }
            if (cc.out_len > 0) flush(ep, cc);
        }
    }
}

pub fn main() !void {
    alloc = std.heap.page_allocator;
    const cpus = @max(@as(usize, 1), @min(std.Thread.getCpuCount() catch 2, 2));
    std.debug.print("zig-fast6 on :{d} ({d} loops HTTP, {d} conns PG/thread)\n", .{ PORT, cpus, CONNS_POR_THREAD });
    for (0..16) |_| _ = try std.Thread.spawn(.{}, banco, .{});
    for (0..cpus) |_| _ = try std.Thread.spawn(.{}, trabalhar, .{});
    while (true) std.time.sleep(3600 * std.time.ns_per_s);
}
