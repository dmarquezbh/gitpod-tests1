// TechEmpower-style benchmark server in Zero C# (C# without a runtime or GC):
// pthreads + epoll + libpq, all through DllImport. No async, no exceptions.
// One event loop per worker (SO_REUSEPORT), 4 PostgreSQL connections per worker.
using System;
using System.Runtime.InteropServices;

public static class Program
{
    // ---------------- libc ----------------
    [DllImport("libc")] static unsafe extern int socket(int domain, int type, int protocol);
    [DllImport("libc")] static unsafe extern int setsockopt(int fd, int level, int name, void* val, int len);
    [DllImport("libc")] static unsafe extern int bind(int fd, SockAddrIn* addr, int len);
    [DllImport("libc")] static unsafe extern int listen(int fd, int backlog);
    [DllImport("libc")] static unsafe extern int accept4(int fd, void* addr, void* len, int flags);
    [DllImport("libc")] static unsafe extern nint recv(int fd, byte* buf, nuint len, int flags);
    [DllImport("libc")] static unsafe extern nint send(int fd, byte* buf, nuint len, int flags);
    [DllImport("libc")] static unsafe extern int close(int fd);
    [DllImport("libc")] static unsafe extern int epoll_create1(int flags);
    [DllImport("libc")] static unsafe extern int epoll_ctl(int epfd, int op, int fd, EpollEvent* ev);
    [DllImport("libc")] static unsafe extern int epoll_wait(int epfd, EpollEvent* evs, int max, int timeout);
    [DllImport("libc")] static unsafe extern void* malloc(nuint n);
    [DllImport("libc")] static unsafe extern void free(void* p);
    [DllImport("libc")] static safe extern int get_nprocs();
    [DllImport("libc")] static unsafe extern int pthread_create(nint* t, void* attr, delegate* unmanaged<void*, void*> fn, void* arg);
    [DllImport("libc")] static unsafe extern int pthread_join(nint t, void** r);
    [DllImport("libc")] static safe extern nint signal(int signum, nint handler);
    [DllImport("libc")] static unsafe extern byte* getenv(byte* name);
    [DllImport("libc")] static unsafe extern int atoi(byte* s);

    // ---------------- libpq ----------------
    [DllImport("libpq.so.5")] static unsafe extern void* PQconnectdb(byte* conninfo);
    [DllImport("libpq.so.5")] static unsafe extern int PQstatus(void* conn);
    [DllImport("libpq.so.5")] static unsafe extern byte* PQerrorMessage(void* conn);
    [DllImport("libpq.so.5")] static unsafe extern void* PQexecParams(void* conn, byte* cmd, int nParams, void* types, byte** values, void* lengths, void* formats, int resultFormat);
    [DllImport("libpq.so.5")] static unsafe extern int PQresultStatus(void* res);
    [DllImport("libpq.so.5")] static unsafe extern int PQsendQueryParams(void* conn, byte* cmd, int nParams, void* types, byte** values, void* lengths, void* formats, int resultFormat);
    [DllImport("libpq.so.5")] static unsafe extern void* PQgetResult(void* conn);
    [DllImport("libpq.so.5")] static unsafe extern int PQenterPipelineMode(void* conn);
    [DllImport("libpq.so.5")] static unsafe extern int PQexitPipelineMode(void* conn);
    [DllImport("libpq.so.5")] static unsafe extern int PQpipelineSync(void* conn);
    [DllImport("libpq.so.5")] static unsafe extern int PQconsumeInput(void* conn);
    [DllImport("libpq.so.5")] static unsafe extern int PQntuples(void* res);
    [DllImport("libpq.so.5")] static unsafe extern byte* PQgetvalue(void* res, int row, int col);
    [DllImport("libpq.so.5")] static unsafe extern void PQclear(void* res);

    // ---------------- constants ----------------
    const int AF_INET = 2, SOCK_STREAM = 1, SOL_SOCKET = 1, SO_REUSEADDR = 2, SO_REUSEPORT = 15;
    const int IPPROTO_TCP = 6, TCP_NODELAY = 1, SOCK_NONBLOCK = 0x800;
    const int EPOLL_CTL_ADD = 1, EPOLL_CTL_MOD = 3, EPOLL_CTL_DEL = 2;
    const uint EPOLLIN = 1, EPOLLOUT = 4, EPOLLERR = 8, EPOLLHUP = 0x10, EPOLLRDHUP = 0x2000;
    const int MSG_NOSIGNAL = 0x4000, EAGAIN = 11;
    const int IN_CAP = 65536, OUT_CAP = 131072, MAX_EVENTS = 512, CONNS_PER_WORKER = 4096;
    const int WORKERS = 16, PG_PER_WORKER = 4, MAX_FORTUNES = 64;

    [StructLayout(LayoutKind.Sequential)]
    struct SockAddrIn { public ushort family; public ushort port; public uint addr; public ulong zero; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct EpollEvent { public uint events; public ulong data; }

    struct Conn
    {
        public int fd;
        public int inLen;
        public int outLen;
        public int outOff;
        public uint interest;
        public byte* inBuf;
        public byte* outBuf;
    }

    struct FR { public int id; public byte* msg; }

    struct Worker
    {
        public int index;
        public void** pg;
        public int pgCount;
        public uint rng;
    }

    static unsafe void Copy(byte* d, byte* s, int n)
    {
        for (int i = 0; i < n; i++) d[i] = s[i];
    }

    static unsafe void Utf8(string s, byte* d)
    {
        int n = s.Length;
        for (int i = 0; i < n; i++) d[i] = (byte)s[i];
        d[n] = 0;
    }

    static unsafe int AppendBytes(byte* dst, int len, byte* src, int n)
    {
        for (int i = 0; i < n; i++) dst[len + i] = src[i];
        return len + n;
    }

    static unsafe int AppendAscii(byte* dst, int len, string s)
    {
        int n = s.Length;
        for (int i = 0; i < n; i++) dst[len + i] = (byte)s[i];
        return len + n;
    }

    static unsafe int AppendInt(byte* dst, int len, int v)
    {
        if (v < 0) { dst[len++] = (byte)'-'; v = -v; }
        if (v >= 100000) dst[len++] = (byte)('0' + (v / 100000) % 10);
        if (v >= 10000) dst[len++] = (byte)('0' + (v / 10000) % 10);
        if (v >= 1000) dst[len++] = (byte)('0' + (v / 1000) % 10);
        if (v >= 100) dst[len++] = (byte)('0' + (v / 100) % 10);
        if (v >= 10) dst[len++] = (byte)('0' + (v / 10) % 10);
        dst[len++] = (byte)('0' + v % 10);
        return len;
    }

    static unsafe int FormatInt(byte* dst, int v)
    {
        int len = 0;
        if (v >= 10000) dst[len++] = (byte)('0' + (v / 10000) % 10);
        if (v >= 1000) dst[len++] = (byte)('0' + (v / 1000) % 10);
        if (v >= 100) dst[len++] = (byte)('0' + (v / 100) % 10);
        if (v >= 10) dst[len++] = (byte)('0' + (v / 10) % 10);
        dst[len++] = (byte)('0' + v % 10);
        dst[len] = 0;
        return len;
    }

    static unsafe int Atoi(byte* s)
    {
        int v = 0;
        while (*s >= (byte)'0' && *s <= (byte)'9') { v = v * 10 + (*s - (byte)'0'); s++; }
        return v;
    }

    static unsafe bool Eq(byte* a, string s)
    {
        for (int i = 0; i < s.Length; i++)
            if (a[i] != (byte)s[i]) return false;
        return a[s.Length] == 0;
    }

    static unsafe bool Starts(byte* a, string s)
    {
        for (int i = 0; i < s.Length; i++)
            if (a[i] != (byte)s[i]) return false;
        return true;
    }

    static unsafe int CompareBytes(byte* a, byte* b)
    {
        while (*a != 0 && *a == *b) { a++; b++; }
        return (int)(*a - *b);
    }

    static unsafe void AppendEscaped(byte* dst, ref int len, byte* src)
    {
        while (*src != 0)
        {
            byte b = *src++;
            if (b == (byte)'&') { len = AppendAscii(dst, len, "&amp;"); }
            else if (b == (byte)'<') { len = AppendAscii(dst, len, "&lt;"); }
            else if (b == (byte)'>') { len = AppendAscii(dst, len, "&gt;"); }
            else if (b == (byte)'"') { len = AppendAscii(dst, len, "&quot;"); }
            else if (b == (byte)'\'') { len = AppendAscii(dst, len, "&#x27;"); }
            else if (b == (byte)'/') { len = AppendAscii(dst, len, "&#x2F;"); }
            else dst[len++] = b;
        }
    }

    static unsafe uint NextRandom(ref uint state)
    {
        uint x = state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        state = x;
        return x;
    }

    static unsafe int RandomId(ref uint state)
    {
        return (int)(NextRandom(ref state) % 10000u) + 1;
    }

    static unsafe void* NextResult(void* pg)
    {
        while (true)
        {
            void* r = PQgetResult(pg);
            if (r != null) return r;
            PQconsumeInput(pg);
        }
    }

    static unsafe void* PickPg(Worker* w, ref int counter)
    {
        int slot = counter % w->pgCount;
        counter++;
        return w->pg[slot];
    }

    static unsafe int WorldQuery(void* pg, int id, byte* outJson, int pos)
    {
        byte* idBuf = stackalloc byte[16];
        FormatInt(idBuf, id);
        byte** parms = stackalloc byte*[1];
        parms[0] = idBuf;
        byte* sql = stackalloc byte[128];
        Utf8("SELECT id, randomnumber FROM world WHERE id = $1", sql);
        void* res = PQexecParams(pg, sql, 1, null, parms, null, null, 0);
        if (res == null || PQresultStatus(res) != 2 || PQntuples(res) != 1)
        {
            if (res != null) PQclear(res);
            pos = AppendAscii(outJson, pos, "{}");
            return pos;
        }
        byte* idv = PQgetvalue(res, 0, 0);
        byte* rnv = PQgetvalue(res, 0, 1);
        pos = AppendAscii(outJson, pos, "{\"id\":");
        pos = AppendInt(outJson, pos, Atoi(idv));
        pos = AppendAscii(outJson, pos, ",\"randomNumber\":");
        pos = AppendInt(outJson, pos, Atoi(rnv));
        pos = AppendAscii(outJson, pos, "}");
        PQclear(res);
        return pos;
    }

    static unsafe int HandleDb(Worker* w, byte* outBuf, int pos, ref int pgCounter)
    {
        int id = RandomId(ref w->rng);
        void* pg = PickPg(w, ref pgCounter);
        return WorldQuery(pg, id, outBuf, pos);
    }

    static unsafe int HandleQueries(Worker* w, byte* outBuf, int pos, ref int pgCounter, int q)
    {
        void* pg = PickPg(w, ref pgCounter);
        byte* sql = stackalloc byte[128];
        Utf8("SELECT id, randomnumber FROM world WHERE id = $1", sql);
        byte** parms = stackalloc byte*[1];
        byte* paramArea = stackalloc byte[16 * q];
        PQenterPipelineMode(pg);
        for (int i = 0; i < q; i++)
        {
            byte* idBuf = paramArea + i * 16;
            FormatInt(idBuf, RandomId(ref w->rng));
            parms[0] = idBuf;
            PQsendQueryParams(pg, sql, 1, null, parms, null, null, 0);
        }
        PQpipelineSync(pg);
        outBuf[pos++] = (byte)'[';
        for (int i = 0; i < q; i++)
        {
            void* res = NextResult(pg);
            if (i > 0) outBuf[pos++] = (byte)',';
            if (res != null && PQresultStatus(res) == 2 && PQntuples(res) == 1)
            {
                pos = AppendAscii(outBuf, pos, "{\"id\":");
                pos = AppendInt(outBuf, pos, Atoi(PQgetvalue(res, 0, 0)));
                pos = AppendAscii(outBuf, pos, ",\"randomNumber\":");
                pos = AppendInt(outBuf, pos, Atoi(PQgetvalue(res, 0, 1)));
                outBuf[pos++] = (byte)'}';
            }
            else
            {
                outBuf[pos++] = (byte)'{';
                outBuf[pos++] = (byte)'}';
            }
            if (res != null) PQclear(res);
        }
        void* sync = NextResult(pg);
        if (sync != null) PQclear(sync);
        PQexitPipelineMode(pg);
        outBuf[pos++] = (byte)']';
        return pos;
    }

    static unsafe int HandleUpdates(Worker* w, byte* outBuf, int pos, ref int pgCounter, int q)
    {
        void* pg = PickPg(w, ref pgCounter);
        byte* sql = stackalloc byte[128];
        Utf8("UPDATE world SET randomnumber = $1 WHERE id = $2", sql);
        byte** parms = stackalloc byte*[2];
        int* ids = stackalloc int[q];
        int* rns = stackalloc int[q];
        byte* paramArea = stackalloc byte[32 * q];
        PQenterPipelineMode(pg);
        for (int i = 0; i < q; i++)
        {
            ids[i] = RandomId(ref w->rng);
            rns[i] = RandomId(ref w->rng);
            byte* p1 = paramArea + i * 32;
            byte* p2 = paramArea + i * 32 + 16;
            FormatInt(p1, rns[i]);
            FormatInt(p2, ids[i]);
            parms[0] = p1;
            parms[1] = p2;
            PQsendQueryParams(pg, sql, 2, null, parms, null, null, 0);
        }
        PQpipelineSync(pg);
        outBuf[pos++] = (byte)'[';
        for (int i = 0; i < q; i++)
        {
            void* res = NextResult(pg);
            if (res != null) PQclear(res);
            if (i > 0) outBuf[pos++] = (byte)',';
            pos = AppendAscii(outBuf, pos, "{\"id\":");
            pos = AppendInt(outBuf, pos, ids[i]);
            pos = AppendAscii(outBuf, pos, ",\"randomNumber\":");
            pos = AppendInt(outBuf, pos, rns[i]);
            outBuf[pos++] = (byte)'}';
        }
        void* sync = NextResult(pg);
        if (sync != null) PQclear(sync);
        PQexitPipelineMode(pg);
        outBuf[pos++] = (byte)']';
        return pos;
    }

    static unsafe int HandleFortunes(Worker* w, byte* outBuf, int pos, ref int pgCounter)
    {
        void* pg = PickPg(w, ref pgCounter);
        byte* sql = stackalloc byte[64];
        Utf8("SELECT id, message FROM fortune", sql);
        void* res = PQexecParams(pg, sql, 0, null, null, null, null, 0);
        FR* rows = stackalloc FR[MAX_FORTUNES];
        int n = 0;
        if (res != null && PQresultStatus(res) == 2)
        {
            n = PQntuples(res);
            if (n > MAX_FORTUNES - 1) n = MAX_FORTUNES - 1;
            for (int i = 0; i < n; i++)
            {
                rows[i].id = Atoi(PQgetvalue(res, i, 0));
                rows[i].msg = PQgetvalue(res, i, 1);
            }
            PQclear(res);
        }
        byte* extra = stackalloc byte[64];
        Utf8("Additional fortune added at request time.", extra);
        rows[n].id = 0;
        rows[n].msg = extra;
        int total = n + 1;
        for (int i = 1; i < total; i++)
        {
            FR key = rows[i];
            int j = i - 1;
            while (j >= 0 && CompareBytes(rows[j].msg, key.msg) > 0) { rows[j + 1] = rows[j]; j--; }
            rows[j + 1] = key;
        }
        pos = AppendAscii(outBuf, pos, "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>");
        for (int i = 0; i < total; i++)
        {
            pos = AppendAscii(outBuf, pos, "<tr><td>");
            pos = AppendInt(outBuf, pos, rows[i].id);
            pos = AppendAscii(outBuf, pos, "</td><td>");
            AppendEscaped(outBuf, ref pos, rows[i].msg);
            pos = AppendAscii(outBuf, pos, "</td></tr>");
        }
        pos = AppendAscii(outBuf, pos, "</table></body></html>");
        return pos;
    }

    static unsafe int QueryParam(byte* target, string name)
    {
        int i = 0;
        while (target[i] != 0 && target[i] != (byte)'?') i++;
        if (target[i] == 0) return 0;
        i++;
        while (target[i] != 0)
        {
            int start = i;
            while (target[i] != 0 && target[i] != (byte)'=' && target[i] != (byte)'&') i++;
            int nameEnd = i;
            if (target[i] == (byte)'=')
            {
                i++;
                int valStart = i;
                while (target[i] != 0 && target[i] != (byte)'&') i++;
                bool match = (nameEnd - start) == name.Length;
                if (match)
                    for (int k = 0; k < name.Length; k++)
                        if (target[start + k] != (byte)name[k]) { match = false; break; }
                if (match)
                {
                    byte* val = stackalloc byte[16];
                    int vlen = i - valStart;
                    if (vlen > 15) vlen = 15;
                    Copy(val, target + valStart, vlen);
                    val[vlen] = 0;
                    return Atoi(val);
                }
                if (target[i] == (byte)'&') i++;
            }
            else
            {
                if (target[i] == (byte)'&') i++;
                else break;
            }
        }
        return 0;
    }

    static unsafe int BuildResponse(byte* outBuf, int pos, byte* target, Worker* w, ref int pgCounter)
    {
        if (Eq(target, "/plaintext"))
        {
            pos = AppendAscii(outBuf, pos, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nHello, World!");
            return pos;
        }
        if (Eq(target, "/json"))
        {
            pos = AppendAscii(outBuf, pos, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 27\r\n\r\n{\"message\":\"Hello, World!\"}");
            return pos;
        }
        if (Eq(target, "/db"))
        {
            byte* body = stackalloc byte[256];
            int blen = HandleDb(w, body, 0, ref pgCounter);
            pos = AppendAscii(outBuf, pos, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ");
            pos = AppendInt(outBuf, pos, blen);
            pos = AppendAscii(outBuf, pos, "\r\n\r\n");
            pos = AppendBytes(outBuf, pos, body, blen);
            return pos;
        }
        if (Starts(target, "/queries"))
        {
            int q = QueryParam(target, "q");
            if (q == 0) q = QueryParam(target, "queries");
            if (q < 1) q = 1;
            if (q > 500) q = 500;
            byte* body = stackalloc byte[40000];
            int blen = HandleQueries(w, body, 0, ref pgCounter, q);
            pos = AppendAscii(outBuf, pos, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ");
            pos = AppendInt(outBuf, pos, blen);
            pos = AppendAscii(outBuf, pos, "\r\n\r\n");
            pos = AppendBytes(outBuf, pos, body, blen);
            return pos;
        }
        if (Starts(target, "/updates"))
        {
            int q = QueryParam(target, "q");
            if (q == 0) q = QueryParam(target, "queries");
            if (q < 1) q = 1;
            if (q > 500) q = 500;
            byte* body = stackalloc byte[40000];
            int blen = HandleUpdates(w, body, 0, ref pgCounter, q);
            pos = AppendAscii(outBuf, pos, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ");
            pos = AppendInt(outBuf, pos, blen);
            pos = AppendAscii(outBuf, pos, "\r\n\r\n");
            pos = AppendBytes(outBuf, pos, body, blen);
            return pos;
        }
        if (Eq(target, "/fortunes"))
        {
            byte* body = stackalloc byte[40000];
            int blen = HandleFortunes(w, body, 0, ref pgCounter);
            pos = AppendAscii(outBuf, pos, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ");
            pos = AppendInt(outBuf, pos, blen);
            pos = AppendAscii(outBuf, pos, "\r\n\r\n");
            pos = AppendBytes(outBuf, pos, body, blen);
            return pos;
        }
        return AppendAscii(outBuf, pos, "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nNot Found");
    }

    static unsafe void ProcessRequests(Conn* c, Worker* w, ref int pgCounter)
    {
        int off = 0;
        byte* target = stackalloc byte[2048];
        while (true)
        {
            int hdr = -1;
            for (int i = off; i + 3 < c->inLen; i++)
            {
                if (c->inBuf[i] == (byte)'\r' && c->inBuf[i + 1] == (byte)'\n' &&
                    c->inBuf[i + 2] == (byte)'\r' && c->inBuf[i + 3] == (byte)'\n')
                { hdr = i; break; }
            }
            if (hdr < 0) break;
            int sp1 = -1, sp2 = -1;
            for (int i = off; i < hdr; i++)
            {
                if (c->inBuf[i] == (byte)' ')
                {
                    if (sp1 < 0) sp1 = i;
                    else { sp2 = i; break; }
                }
            }
            if (sp1 < 0 || sp2 < 0) break;
            int tlen = sp2 - sp1 - 1;
            if (tlen > 2047) tlen = 2047;
            Copy(target, c->inBuf + sp1 + 1, tlen);
            target[tlen] = 0;
            if (c->outLen + 40000 > OUT_CAP) break;
            c->outLen = BuildResponse(c->outBuf, c->outLen, target, w, ref pgCounter);
            off = hdr + 4;
        }
        if (off > 0)
        {
            int remain = c->inLen - off;
            for (int i = 0; i < remain; i++) c->inBuf[i] = c->inBuf[off + i];
            c->inLen = remain;
        }
    }

    static unsafe void SetInterest(int epfd, Conn* c, uint interest)
    {
        if (c->interest == interest) return;
        EpollEvent ev;
        ev.events = interest;
        ev.data = (ulong)c;
        epoll_ctl(epfd, EPOLL_CTL_MOD, c->fd, &ev);
        c->interest = interest;
    }

    static unsafe void CloseConn(int epfd, Conn* c)
    {
        epoll_ctl(epfd, EPOLL_CTL_DEL, c->fd, null);
        close(c->fd);
        free(c);
    }

    static unsafe void Flush(int epfd, Conn* c)
    {
        while (c->outOff < c->outLen)
        {
            nint n = send(c->fd, c->outBuf + c->outOff, (nuint)(c->outLen - c->outOff), MSG_NOSIGNAL);
            if (n <= 0) return;
            c->outOff += (int)n;
        }
        c->outOff = 0;
        c->outLen = 0;
    }

    static unsafe void Loop(int idx)
    {
        Worker w;
        w.index = idx;
        w.rng = (uint)(0x9E3779B9u ^ (uint)(idx * 2654435761u));
        if (w.rng == 0) w.rng = 12345;

        byte* portEnv = stackalloc byte[16];
        Utf8("PORT_NUM", portEnv);
        byte* pv = getenv(portEnv);
        int port = 18092;
        if (pv != null) port = atoi(pv);

        byte* ci = stackalloc byte[256];
        Utf8("host=127.0.0.1 port=5432 user=benchmarkdbuser password=benchmarkdbpass dbname=hello_world", ci);
        w.pgCount = PG_PER_WORKER;
        w.pg = (void**)malloc((nuint)(sizeof(void*) * PG_PER_WORKER));
        if (w.pg == null) { Out.Line("zero: no memory"); return; }
        for (int i = 0; i < PG_PER_WORKER; i++)
        {
            w.pg[i] = PQconnectdb(ci);
            if (PQstatus(w.pg[i]) != 0)
            {
                Out.Line("zero: cannot connect to PostgreSQL");
                return;
            }
        }
        int pgCounter = idx * PG_PER_WORKER;

        int lfd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
        int one = 1;
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, 4);
        setsockopt(lfd, SOL_SOCKET, SO_REUSEPORT, &one, 4);
        SockAddrIn addr;
        addr.family = AF_INET;
        addr.port = (ushort)(((port & 0xFF) << 8) | ((port >> 8) & 0xFF));
        addr.addr = 0;
        addr.zero = 0;
        if (bind(lfd, &addr, 16) != 0 || listen(lfd, 4096) != 0)
        {
            Out.Line("zero: cannot bind/listen");
            return;
        }
        int epfd = epoll_create1(0);
        EpollEvent lev;
        lev.events = EPOLLIN;
        lev.data = (ulong)lfd;
        epoll_ctl(epfd, EPOLL_CTL_ADD, lfd, &lev);

        EpollEvent* evs = stackalloc EpollEvent[MAX_EVENTS];
        while (true)
        {
            int n = epoll_wait(epfd, evs, MAX_EVENTS, -1);
            if (n <= 0) continue;
            for (int i = 0; i < n; i++)
            {
                if ((int)evs[i].data == lfd)
                {
                    while (true)
                    {
                        int fd = accept4(lfd, null, null, SOCK_NONBLOCK);
                        if (fd < 0) break;
                        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4);
                        byte* mem = (byte*)malloc((nuint)(sizeof(Conn) + IN_CAP + OUT_CAP));
                        if (mem == null) { close(fd); break; }
                        Conn* c = (Conn*)mem;
                        c->fd = fd;
                        c->inLen = 0;
                        c->outLen = 0;
                        c->outOff = 0;
                        c->interest = EPOLLIN | EPOLLRDHUP;
                        c->inBuf = mem + sizeof(Conn);
                        c->outBuf = c->inBuf + IN_CAP;
                        EpollEvent cev;
                        cev.events = c->interest;
                        cev.data = (ulong)c;
                        if (epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &cev) != 0)
                        {
                            close(fd);
                            free(mem);
                        }
                    }
                    continue;
                }

                Conn* conn = (Conn*)evs[i].data;
                uint ev = evs[i].events;
                if ((ev & (EPOLLERR | EPOLLHUP)) != 0)
                {
                    CloseConn(epfd, conn);
                    continue;
                }
                if ((ev & EPOLLIN) != 0)
                {
                    bool closed = false;
                    while (true)
                    {
                        if (conn->inLen >= IN_CAP) break;
                        nint r = recv(conn->fd, conn->inBuf + conn->inLen, (nuint)(IN_CAP - conn->inLen), 0);
                        if (r == 0) { closed = true; break; }
                        if (r < 0) break;
                        conn->inLen += (int)r;
                    }
                    if (closed) { CloseConn(epfd, conn); continue; }
                    ProcessRequests(conn, &w, ref pgCounter);
                    if (conn->outLen > 0) Flush(epfd, conn);
                    if (conn->outLen > 0) SetInterest(epfd, conn, EPOLLIN | EPOLLOUT | EPOLLRDHUP);
                    else
                    {
                        SetInterest(epfd, conn, EPOLLIN | EPOLLRDHUP);
                        if (conn->inLen > 0) ProcessRequests(conn, &w, ref pgCounter);
                    }
                }
                else if ((ev & EPOLLOUT) != 0)
                {
                    Flush(epfd, conn);
                    if (conn->outLen == 0)
                    {
                        SetInterest(epfd, conn, EPOLLIN | EPOLLRDHUP);
                        if (conn->inLen > 0) ProcessRequests(conn, &w, ref pgCounter);
                    }
                }
            }
        }
    }

    [UnmanagedCallersOnly]
    static unsafe void* LoopEntry(void* arg)
    {
        int idx = (int)(nint)arg;
        Loop(idx);
        return null;
    }

    public static unsafe int Main()
    {
        signal(13, 1); // SIGPIPE -> SIG_IGN
        int workers = WORKERS;
        nint* threads = stackalloc nint[WORKERS];
        int started = 0;
        for (int i = 1; i < workers; i++)
        {
            if (pthread_create(&threads[started], null, &LoopEntry, (void*)(nint)i) == 0)
                started++;
        }
        Out.Line("started Zero C# server");
        Loop(0);
        for (int i = 0; i < started; i++) pthread_join(threads[i], null);
        return 0;
    }
}
