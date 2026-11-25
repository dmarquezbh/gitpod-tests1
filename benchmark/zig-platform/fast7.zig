// Zig: HTTP epoll com burst (como fast.zig) + cliente PostgreSQL wire dentro do MESMO loop,
// com batching por rodada do epoll (o desenho do .NET "platform"): todas as requisições de /db e
// /queries de uma rodada viram UMA consulta com int4[] (unnest + ordinality), os /updates viram um
// UPDATE só, e o /fortunes é consultado uma vez por rodada e renderizado uma vez.
// O socket do PostgreSQL é bloqueante por rodada: quando o lote roda, todos os clientes daquele
// loop já têm a requisição em voo (wrk mantém uma por conexão), então não há trabalho HTTP perdido.
const std = @import("std");
const posix = std.posix;

const PORT: u16 = 8098;
const PG_PORT: u16 = 5432;
const PG_USER = "benchmarkdbuser";
const PG_DB = "hello_world";
const LOOPS: usize = 2;
const MAX_CONN = 4096;
const MAX_OPS = 2048;
const MAX_Q = 500;
const MAX_FORTUNES = 64;
const REP_MAX = 256;

const PLAIN = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!";
const JSON = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"message\":\"Hello, World!\"}";
const JSON_INI = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
const HTML_INI = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ";
const FIM_CAB = "\r\n\r\n";
const NAO_ACHOU = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
const ERRO_500 = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n";
const F_HEAD = "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>";
const F_ROW_INI = "<tr><td>";
const F_ROW_MEIO = "</td><td>";
const F_ROW_FIM = "</td></tr>";
const F_TAIL = "</table></body></html>";
const FORTUNE_EXTRA = "Additional fortune added at request time.";

// SQL preparado uma vez por conexão (evita reparsear 3 KB de array a cada lote).
const SQL_PREP = "PREPARE wq(int[]) AS SELECT w.id, w.randomnumber FROM unnest($1::int[]) WITH ORDINALITY AS u(id, ord) JOIN world w ON w.id = u.id ORDER BY u.ord; " ++
    "PREPARE fq AS SELECT id, message FROM fortune; " ++
    "PREPARE uq(int[], int[]) AS UPDATE world SET randomnumber = v.rn FROM (SELECT * FROM UNNEST($1::int[], $2::int[]) AS w2(id, rn) ORDER BY 1) AS v(id, rn) WHERE world.id = v.id;";

const REP: [PLAIN.len * REP_MAX]u8 = blk: {
    @setEvalBranchQuota(200000);
    var buf: [PLAIN.len * REP_MAX]u8 = undefined;
    for (0..REP_MAX) |i| @memcpy(buf[i * PLAIN.len .. (i + 1) * PLAIN.len], PLAIN);
    break :blk buf;
};

const Conn = struct {
    fd: posix.fd_t,
    in: [16384]u8 = undefined,
    out: [65536]u8 = undefined,
    out_len: usize = 0,
    idx_abertas: usize = 0,
    morto: bool = false,
};

const Op = struct {
    c: *Conn,
    kind: u8, // 0 db, 1 queries, 2 updates, 3 fortunes
    q: u16,
    ids: [MAX_Q]i32,
    nums: [MAX_Q]i32,
};

const Loop = struct {
    ep: posix.fd_t = -1,
    pg: posix.fd_t = -1,
    srv: posix.fd_t = -1,
    conns: [MAX_CONN]?*Conn = [_]?*Conn{null} ** MAX_CONN,
    abertas: [MAX_CONN]*Conn = undefined,
    n_abertas: usize = 0,
    lixo: [MAX_CONN]*Conn = undefined,
    n_lixo: usize = 0,
    ops: [MAX_OPS]Op = undefined,
    n_ops: usize = 0,
    sql: [512 * 1024]u8 = undefined,
    resp: [1024 * 1024]u8 = undefined,
    body: [64 * 1024]u8 = undefined,
    rng: u64 = 0x2545F4914F6CDD1D,
};

var alloc: std.mem.Allocator = undefined;

// ── utilidades ────────────────────────────────────────────────────────────────
fn registrar(ep: posix.fd_t, op: u32, fd: posix.fd_t, mascara: u32) void {
    var ev = std.os.linux.epoll_event{ .events = mascara, .data = .{ .fd = fd } };
    posix.epoll_ctl(ep, op, fd, &ev) catch {};
}

fn enviar(fd: posix.fd_t, dados: []const u8) !void {
    var off: usize = 0;
    while (off < dados.len) {
        const n = try posix.write(fd, dados[off..]);
        if (n == 0) return error.Eof;
        off += n;
    }
}

fn copiar(dst: []u8, p: usize, src: []const u8) usize {
    @memcpy(dst[p .. p + src.len], src);
    return src.len;
}

fn escreverNum(dst: []u8, v: u32) usize {
    var tmp: [10]u8 = undefined;
    var i: usize = tmp.len;
    var x = v;
    while (true) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
        if (x == 0) break;
    }
    const n = tmp.len - i;
    @memcpy(dst[0..n], tmp[i..]);
    return n;
}

fn rnd(lp: *Loop) u32 {
    var x = lp.rng;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    lp.rng = x;
    return @intCast(1 + (x % 10000));
}

fn qtd(alvo: []const u8) usize {
    const i = std.mem.indexOf(u8, alvo, "q=") orelse return 1;
    var n: usize = 0;
    for (alvo[i + 2 ..]) |ch| {
        if (ch < '0' or ch > '9') break;
        n = n * 10 + (ch - '0');
    }
    return @min(@max(n, 1), MAX_Q);
}

fn anexar(c: *Conn, dados: []const u8) void {
    if (c.morto) return;
    if (c.out_len + dados.len > c.out.len) {
        enviar(c.fd, c.out[0..c.out_len]) catch {
            c.morto = true;
            return;
        };
        c.out_len = 0;
        if (dados.len > c.out.len) {
            enviar(c.fd, dados) catch {
                c.morto = true;
            };
            return;
        }
    }
    @memcpy(c.out[c.out_len .. c.out_len + dados.len], dados);
    c.out_len += dados.len;
}

fn responder(c: *Conn, corpo: []const u8, tipo: []const u8) void {
    if (c.morto) return;
    var lenbuf: [12]u8 = undefined;
    const digits = escreverNum(&lenbuf, @intCast(corpo.len));
    if (c.out_len + tipo.len + digits + 4 + corpo.len > c.out.len) {
        enviar(c.fd, c.out[0..c.out_len]) catch {
            c.morto = true;
            return;
        };
        c.out_len = 0;
    }
    var p = c.out_len;
    p += copiar(&c.out, p, tipo);
    p += copiar(&c.out, p, lenbuf[0..digits]);
    p += copiar(&c.out, p, FIM_CAB);
    p += copiar(&c.out, p, corpo);
    c.out_len = p;
}

// ── PostgreSQL wire ───────────────────────────────────────────────────────────
fn temReady(buf: []const u8) bool {
    var i: usize = 0;
    while (i + 5 <= buf.len) {
        const tam = std.mem.readInt(i32, buf[i + 1 ..][0..4], .big);
        if (tam < 4) return true;
        const total: usize = 1 + @as(usize, @intCast(tam));
        if (i + total > buf.len) return false;
        if (buf[i] == 'Z') return true;
        i += total;
    }
    return false;
}

fn lerAteZ(fd: posix.fd_t, buf: []u8) !usize {
    var len: usize = 0;
    while (!temReady(buf[0..len])) {
        if (len == buf.len) return error.RespostaGrande;
        const n = try posix.read(fd, buf[len..]);
        if (n == 0) return error.Eof;
        len += n;
    }
    return len;
}

fn conectarPg() !posix.fd_t {
    const s = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const end = try std.net.Address.parseIp("127.0.0.1", PG_PORT);
    try posix.connect(s, &end.any, end.getOsSockLen());
    posix.setsockopt(s, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
    var msg: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&msg);
    const w = fbs.writer();
    try w.writeInt(i32, 0, .big);
    try w.writeInt(i32, 196608, .big);
    try w.writeAll("user\x00" ++ PG_USER ++ "\x00database\x00" ++ PG_DB ++ "\x00\x00");
    std.mem.writeInt(i32, msg[0..4], @intCast(fbs.pos), .big);
    try enviar(s, msg[0..fbs.pos]);
    var buf: [65536]u8 = undefined;
    const n = try lerAteZ(s, &buf);
    if (contemErroPg(buf[0..n])) return error.Auth;
    return s;
}

fn enviarSql(lp: *Loop, sql: []const u8) ![]u8 {
    var cab: [5]u8 = undefined;
    cab[0] = 'Q';
    std.mem.writeInt(i32, cab[1..5], @intCast(4 + sql.len + 1), .big);
    try enviar(lp.pg, &cab);
    try enviar(lp.pg, sql);
    try enviar(lp.pg, "\x00");
    const n = try lerAteZ(lp.pg, &lp.resp);
    return lp.resp[0..n];
}

const Mensagem = struct { tipo: u8, corpo: []const u8 };

fn proxima(buf: []const u8, pos: *usize) ?Mensagem {
    if (pos.* + 5 > buf.len) return null;
    const tam = std.mem.readInt(i32, buf[pos.* + 1 ..][0..4], .big);
    if (tam < 4) return null;
    const total: usize = 1 + @as(usize, @intCast(tam));
    if (pos.* + total > buf.len) return null;
    const m = Mensagem{ .tipo = buf[pos.*], .corpo = buf[pos.* + 5 .. pos.* + total] };
    pos.* += total;
    return m;
}

const Campos = struct { vals: [2][]const u8 };

fn camposDataRow(corpo: []const u8) Campos {
    var c = Campos{ .vals = .{ "", "" } };
    var off: usize = 2;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const tam = std.mem.readInt(i32, corpo[off..][0..4], .big);
        off += 4;
        if (tam < 0) {
            c.vals[i] = "";
        } else {
            const l: usize = @intCast(tam);
            c.vals[i] = corpo[off .. off + l];
            off += l;
        }
    }
    return c;
}

fn temErro(resp: []const u8) bool {
    var pos: usize = 0;
    while (proxima(resp, &pos)) |m| {
        if (m.tipo == 'E') return true;
    }
    return false;
}

fn contemErroPg(resp: []const u8) bool {
    return temErro(resp);
}

// ── lote de banco ─────────────────────────────────────────────────────────────
fn proximaSimples(lp: *Loop, oi: usize) usize {
    var i = oi;
    while (i < lp.n_ops and lp.ops[i].kind > 1) i += 1;
    return i;
}

fn renderizarSimples(lp: *Loop, resp: []const u8) void {
    var pos: usize = 0;
    var oi = proximaSimples(lp, 0);
    var linhas: usize = 0;
    var blen: usize = 0;
    while (proxima(resp, &pos)) |m| {
        if (m.tipo == 'E') break;
        if (m.tipo != 'D') continue;
        oi = proximaSimples(lp, oi);
        if (oi >= lp.n_ops) break;
        const op = &lp.ops[oi];
        if (linhas == 0 and op.kind == 1) blen += copiar(&lp.body, blen, "[");
        if (linhas > 0) blen += copiar(&lp.body, blen, ",");
        const campos = camposDataRow(m.corpo);
        blen += copiar(&lp.body, blen, "{\"id\":");
        blen += copiar(&lp.body, blen, campos.vals[0]);
        blen += copiar(&lp.body, blen, ",\"randomNumber\":");
        blen += copiar(&lp.body, blen, campos.vals[1]);
        blen += copiar(&lp.body, blen, "}");
        linhas += 1;
        if (linhas == op.q) {
            if (op.kind == 1) blen += copiar(&lp.body, blen, "]");
            responder(op.c, lp.body[0..blen], JSON_INI);
            blen = 0;
            linhas = 0;
            oi += 1;
        }
    }
    // respostas que a consulta não cobriu (erro do PG / rodada truncada)
    while (oi < lp.n_ops) : (oi += 1) {
        if (lp.ops[oi].kind <= 1) anexar(lp.ops[oi].c, ERRO_500);
    }
}

fn executarSimples(lp: *Loop) void {
    var algum = false;
    for (lp.ops[0..lp.n_ops]) |op| {
        if (op.kind <= 1) {
            algum = true;
            break;
        }
    }
    if (!algum) return;
    var p: usize = 0;
    p += copiar(&lp.sql, p, "EXECUTE wq('{");
    var primeiro = true;
    for (lp.ops[0..lp.n_ops]) |op| {
        if (op.kind > 1) continue;
        for (op.ids[0..op.q]) |id| {
            if (!primeiro) p += copiar(&lp.sql, p, ",");
            primeiro = false;
            p += escreverNum(lp.sql[p..], @intCast(id));
        }
    }
    p += copiar(&lp.sql, p, "}');");
    const resp = enviarSql(lp, lp.sql[0..p]) catch {
        for (lp.ops[0..lp.n_ops]) |op| if (op.kind <= 1) anexar(op.c, ERRO_500);
        return;
    };
    renderizarSimples(lp, resp);
}

fn executarUpdates(lp: *Loop) void {
    const LOTE = 2048; // pares por UPDATE
    var base: usize = 0;
    while (base < lp.n_ops) {
        var total: usize = 0;
        var fim = base;
        var tem = false;
        while (fim < lp.n_ops) {
            const op = &lp.ops[fim];
            if (op.kind == 2) {
                if (total > 0 and total + op.q > LOTE) break;
                total += op.q;
                tem = true;
            }
            fim += 1;
        }
        if (!tem) {
            base = fim + 1;
            continue;
        }
        var p: usize = 0;
        p += copiar(&lp.sql, p, "EXECUTE uq('{");
        var primeiro = true;
        for (lp.ops[base..fim]) |op| {
            if (op.kind != 2) continue;
            for (op.ids[0..op.q]) |id| {
                if (!primeiro) p += copiar(&lp.sql, p, ",");
                primeiro = false;
                p += escreverNum(lp.sql[p..], @intCast(id));
            }
        }
        p += copiar(&lp.sql, p, "}','{");
        primeiro = true;
        for (lp.ops[base..fim]) |op| {
            if (op.kind != 2) continue;
            for (op.nums[0..op.q]) |n| {
                if (!primeiro) p += copiar(&lp.sql, p, ",");
                primeiro = false;
                p += escreverNum(lp.sql[p..], @intCast(n));
            }
        }
        p += copiar(&lp.sql, p, "}');");
        const resp = enviarSql(lp, lp.sql[0..p]) catch {
            for (lp.ops[base..fim]) |op| if (op.kind == 2) anexar(op.c, ERRO_500);
            base = fim;
            continue;
        };
        const erro = temErro(resp);
        for (lp.ops[base..fim]) |op| {
            if (op.kind != 2) continue;
            if (erro) {
                anexar(op.c, ERRO_500);
                continue;
            }
            var blen: usize = 0;
            blen += copiar(&lp.body, blen, "[");
            for (op.ids[0..op.q], 0..) |id, i| {
                if (i > 0) blen += copiar(&lp.body, blen, ",");
                blen += copiar(&lp.body, blen, "{\"id\":");
                blen += escreverNum(lp.body[blen..], @intCast(id));
                blen += copiar(&lp.body, blen, ",\"randomNumber\":");
                blen += escreverNum(lp.body[blen..], @intCast(op.nums[i]));
                blen += copiar(&lp.body, blen, "}");
            }
            blen += copiar(&lp.body, blen, "]");
            responder(op.c, lp.body[0..blen], JSON_INI);
        }
        base = fim;
    }
}

fn compararFortune(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        if (a[i] != b[i]) return a[i] < b[i];
    }
    return a.len < b.len;
}

fn executarFortunes(lp: *Loop) void {
    var algum = false;
    for (lp.ops[0..lp.n_ops]) |op| {
        if (op.kind == 3) {
            algum = true;
            break;
        }
    }
    if (!algum) return;
    const resp = enviarSql(lp, "EXECUTE fq;") catch {
        for (lp.ops[0..lp.n_ops]) |op| if (op.kind == 3) anexar(op.c, ERRO_500);
        return;
    };
    if (temErro(resp)) {
        for (lp.ops[0..lp.n_ops]) |op| if (op.kind == 3) anexar(op.c, ERRO_500);
        return;
    }
    var ids: [MAX_FORTUNES]i32 = undefined;
    var msgs: [MAX_FORTUNES][]const u8 = undefined;
    var n: usize = 0;
    var pos: usize = 0;
    while (proxima(resp, &pos)) |m| {
        if (m.tipo != 'D' or n == MAX_FORTUNES) continue;
        const campos = camposDataRow(m.corpo);
        var id: i32 = 0;
        for (campos.vals[0]) |ch| {
            if (ch < '0' or ch > '9') break;
            id = id * 10 + (ch - '0');
        }
        ids[n] = id;
        msgs[n] = campos.vals[1];
        n += 1;
    }
    // linha extra exigida pelo TechEmpower, ordenada junto (comparação byte a byte, como o .NET)
    ids[n] = 0;
    msgs[n] = FORTUNE_EXTRA;
    const total = n + 1;
    var ordem: [MAX_FORTUNES]usize = undefined;
    for (0..total) |i| ordem[i] = i;
    var i: usize = 1;
    while (i < total) : (i += 1) {
        const chave = ordem[i];
        var j = i;
        while (j > 0 and compararFortune(msgs[ordem[j - 1]], msgs[chave])) : (j -= 1) {
            ordem[j] = ordem[j - 1];
        }
        ordem[j] = chave;
    }
    var blen: usize = 0;
    blen += copiar(&lp.body, blen, F_HEAD);
    for (ordem[0..total]) |oi| {
        blen += copiar(&lp.body, blen, F_ROW_INI);
        blen += escreverNum(lp.body[blen..], @intCast(ids[oi]));
        blen += copiar(&lp.body, blen, F_ROW_MEIO);
        for (msgs[oi]) |ch| switch (ch) {
            '&' => blen += copiar(&lp.body, blen, "&amp;"),
            '<' => blen += copiar(&lp.body, blen, "&lt;"),
            '>' => blen += copiar(&lp.body, blen, "&gt;"),
            '"' => blen += copiar(&lp.body, blen, "&quot;"),
            '\'' => blen += copiar(&lp.body, blen, "&#x27;"),
            '/' => blen += copiar(&lp.body, blen, "&#x2f;"),
            else => {
                lp.body[blen] = ch;
                blen += 1;
            },
        };
        blen += copiar(&lp.body, blen, F_ROW_FIM);
    }
    blen += copiar(&lp.body, blen, F_TAIL);
    for (lp.ops[0..lp.n_ops]) |op| {
        if (op.kind == 3) responder(op.c, lp.body[0..blen], HTML_INI);
    }
}

fn executar(lp: *Loop) void {
    if (lp.n_ops == 0) return;
    executarSimples(lp);
    executarUpdates(lp);
    executarFortunes(lp);
    lp.n_ops = 0;
}

fn descarregar(lp: *Loop) void {
    for (lp.abertas[0..lp.n_abertas]) |c| {
        if (c.morto or c.out_len == 0) continue;
        enviar(c.fd, c.out[0..c.out_len]) catch {
            c.morto = true;
            continue;
        };
        c.out_len = 0;
    }
    for (lp.lixo[0..lp.n_lixo]) |c| {
        for (&lp.conns) |*slot| if (slot.* == c) {
            slot.* = null;
            break;
        };
        alloc.destroy(c);
    }
    lp.n_lixo = 0;
}

// ── HTTP ──────────────────────────────────────────────────────────────────────
fn tratar(lp: *Loop, c: *Conn, pedido: []const u8) void {
    if (pedido.len >= 14 and std.mem.eql(u8, pedido[4..14], "/plaintext")) {
        anexar(c, PLAIN);
        return;
    }
    if (pedido.len >= 9 and std.mem.eql(u8, pedido[4..9], "/json")) {
        anexar(c, JSON);
        return;
    }
    const linha = std.mem.sliceTo(pedido, '\r');
    var partes = std.mem.tokenizeScalar(u8, linha, ' ');
    _ = partes.next();
    const alvo = partes.next() orelse return;
    if (lp.n_ops == MAX_OPS) {
        anexar(c, ERRO_500);
        return;
    }
    var op = &lp.ops[lp.n_ops];
    op.c = c;
    if (std.mem.eql(u8, alvo, "/db")) {
        op.kind = 0;
        op.q = 1;
        op.ids[0] = @intCast(rnd(lp));
    } else if (std.mem.startsWith(u8, alvo, "/queries")) {
        op.kind = 1;
        const q = qtd(alvo);
        op.q = @intCast(q);
        for (0..q) |i| op.ids[i] = @intCast(rnd(lp));
    } else if (std.mem.startsWith(u8, alvo, "/updates")) {
        op.kind = 2;
        const q = qtd(alvo);
        op.q = @intCast(q);
        for (0..q) |i| {
            op.ids[i] = @intCast(rnd(lp));
            op.nums[i] = @intCast(rnd(lp));
        }
    } else if (std.mem.eql(u8, alvo, "/fortunes")) {
        op.kind = 3;
        op.q = 1;
    } else {
        anexar(c, NAO_ACHOU);
        return;
    }
    lp.n_ops += 1;
}

fn fechar(lp: *Loop, c: *Conn) void {
    if (c.morto) return;
    c.morto = true;
    posix.close(c.fd);
    const i = c.idx_abertas;
    if (i < lp.n_abertas and lp.abertas[i] == c) {
        lp.n_abertas -= 1;
        lp.abertas[i] = lp.abertas[lp.n_abertas];
        lp.abertas[i].idx_abertas = i;
    }
    if (lp.n_lixo < MAX_CONN) {
        lp.lixo[lp.n_lixo] = c;
        lp.n_lixo += 1;
    }
}

fn achar(lp: *Loop, fd: posix.fd_t) ?*Conn {
    for (lp.abertas[0..lp.n_abertas]) |c| {
        if (c.fd == fd) return c;
    }
    return null;
}

fn ler(lp: *Loop, c: *Conn) void {
    if (c.morto) return;
    const k = posix.read(c.fd, &c.in) catch {
        fechar(lp, c);
        return;
    };
    if (k == 0) {
        fechar(lp, c);
        return;
    }
    // rajada de /plaintext idêntica (pipelining do wrk): uma cópia de respostas prontas
    const primeiro = std.mem.indexOfPos(u8, c.in[0..k], 0, "\r\n\r\n") orelse 0;
    const tam = if (primeiro > 0) primeiro + 4 else 0;
    if (tam > 0 and k % tam == 0 and k / tam > 1 and k / tam <= REP_MAX) {
        var identico = true;
        var qq: usize = tam;
        while (qq < k) : (qq += tam) {
            if (!std.mem.eql(u8, c.in[0..tam], c.in[qq .. qq + tam])) {
                identico = false;
                break;
            }
        }
        if (identico and std.mem.eql(u8, c.in[0..14], "GET /plaintext")) {
            const nreq = k / tam;
            anexar(c, REP[0 .. nreq * PLAIN.len]);
            return;
        }
    }
    var pos: usize = 0;
    while (pos < k) {
        const fim = std.mem.indexOfPos(u8, c.in[0..k], pos, "\r\n\r\n") orelse break;
        tratar(lp, c, c.in[pos .. fim + 4]);
        pos = fim + 4;
    }
}

fn aceitar(lp: *Loop) void {
    while (true) {
        const cl = posix.accept(lp.srv, null, null, 0) catch break;
        const c = alloc.create(Conn) catch {
            posix.close(cl);
            continue;
        };
        c.* = .{ .fd = cl, .idx_abertas = lp.n_abertas };
        posix.setsockopt(cl, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        lp.abertas[lp.n_abertas] = c;
        lp.n_abertas += 1;
        registrar(lp.ep, 1, cl, std.os.linux.EPOLL.IN);
    }
}

fn processarEventos(lp: *Loop, eventos: []const std.os.linux.epoll_event) void {
    for (eventos) |ev| {
        const fd: posix.fd_t = ev.data.fd;
        if (fd == lp.srv) {
            aceitar(lp);
            continue;
        }
        const c = achar(lp, fd) orelse continue;
        if ((ev.events & (std.os.linux.EPOLL.ERR | std.os.linux.EPOLL.HUP)) != 0) {
            fechar(lp, c);
            continue;
        }
        ler(lp, c);
    }
}

fn aguardarMais(lp: *Loop) void {
    const alvo: usize = 192;
    const limite_ns: u64 = 1000 * std.time.ns_per_us;
    if (lp.n_ops == 0 or lp.n_ops >= alvo) return;
    const t0 = std.time.nanoTimestamp();
    var extra: [1024]std.os.linux.epoll_event = undefined;
    while (lp.n_ops < alvo) {
        const decorrido: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t0));
        if (decorrido >= limite_ns) break;
        const restante_ms: i32 = @intCast(@max(1, (limite_ns - decorrido) / std.time.ns_per_ms));
        const m = posix.epoll_wait(lp.ep, &extra, restante_ms);
        if (m == 0) break;
        processarEventos(lp, extra[0..m]);
    }
}

fn trabalhar(indice: usize) void {
    const lp = alloc.create(Loop) catch return;
    lp.* = .{ .rng = 0x9E3779B97F4A7C15 +% indice *% 0x2545F4914F6CDD1D };
    lp.ep = posix.epoll_create1(0) catch return;
    lp.pg = conectarPg() catch |e| {
        std.debug.print("zig-fast7 pg: {}\n", .{e});
        return;
    };
    _ = enviarSql(lp, SQL_PREP) catch {
        std.debug.print("zig-fast7 pg prepare falhou\n", .{});
        return;
    };
    lp.srv = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return;
    posix.setsockopt(lp.srv, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
    posix.setsockopt(lp.srv, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch {};
    const end = std.net.Address.parseIp("0.0.0.0", PORT) catch return;
    posix.bind(lp.srv, &end.any, end.getOsSockLen()) catch return;
    posix.listen(lp.srv, 8192) catch return;
    _ = posix.fcntl(lp.srv, posix.F.SETFL, 0o4000) catch {};
    registrar(lp.ep, 1, lp.srv, std.os.linux.EPOLL.IN);
    var eventos: [1024]std.os.linux.epoll_event = undefined;
    while (true) {
        const n = posix.epoll_wait(lp.ep, &eventos, -1);
        if (n == 0) continue;
        processarEventos(lp, eventos[0..n]);
        // espera curta para o lote encher: o custo da consulta ao PG domina a espera
        aguardarMais(lp);
        executar(lp);
        descarregar(lp);
    }
}

pub fn main() !void {
    alloc = std.heap.page_allocator;
    std.debug.print("zig-fast7 on :{d} ({d} loops HTTP+PG, batching por rodada)\n", .{ PORT, LOOPS });
    for (0..LOOPS) |i| _ = try std.Thread.spawn(.{}, trabalhar, .{i});
    while (true) std.time.sleep(3600 * std.time.ns_per_s);
}
