using System.Buffers;
using System.Net;
using System.Net.Sockets;
using DotnetBench.Platform.Pg;
using static DotnetBench.Platform.EventLoop.Native;

namespace DotnetBench.Platform.EventLoop;

/// <summary>
/// One event loop per core, hyper/tokio style: each loop owns an epoll instance, a listening socket
/// (SO_REUSEPORT, so the kernel spreads connections), its HTTP connections and its PostgreSQL
/// connections. Everything runs on the loop thread with libc recv/send; there is no thread pool,
/// no async state machine and no synchronisation. Database requests are callbacks on pending
/// operations, and the PostgreSQL write buffers are flushed once per epoll batch, so concurrent
/// requests coalesce into a single write exactly like a tokio-postgres connection task.
/// </summary>
public static class EventLoopServer
{
    public static void Run(int port, int loops, int heavyConnectionsPerLoop, bool pgNoDelay)
    {
        var threads = new Thread[loops];
        for (var i = 0; i < loops; i++)
        {
            var loop = new EventLoop(i, port, heavyConnectionsPerLoop, pgNoDelay);
            threads[i] = new Thread(loop.Run) { Name = $"loop-{i}", IsBackground = false };
            threads[i].Start();
        }
        foreach (var t in threads) t.Join();
    }
}

public abstract class LoopSocket(int fd)
{
    public readonly int Fd = fd;
    public abstract void OnReadable();
    public abstract void OnWritable();
    public abstract void OnError();
}

public sealed unsafe class EventLoop
{
    readonly int _epfd;
    readonly Socket _listener;             // kept alive: owns the listening fd
    readonly int _listenFd;
    LoopSocket?[] _byFd = new LoopSocket?[4096];
    readonly PgLoopConnection _primary;
    readonly PgLoopConnection[] _heavy;
    readonly PgLoopConnection[] _singleConns;
    int _heavyRotation;
    int _singleRotation;
    readonly List<PgLoopConnection> _dirty = new();
    readonly Stack<LoopOp> _opPool = new();
    readonly List<LoopOp> _singleBatch = new();
    readonly List<LoopOp> _libpqSingles = new();
    readonly List<LoopOp> _libpqFortunes = new();
    List<LoopOp>[]? _libpqHeavy;
    LibpqDb? _libpqSingle;
    LibpqDb[]? _libpqHeavyDb;
    int _libpqHeavyRot;
    public readonly Random Random = new();

    public EventLoop(int index, int port, int heavyConnections, bool pgNoDelay)
    {
        _epfd = epoll_create1(0);
        if (_epfd < 0) throw new InvalidOperationException($"epoll_create1 failed, errno {Errno}");

        _listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        _listener.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        SetInt((int)_listener.Handle, SOL_SOCKET, SO_REUSEPORT, 1);   // not in .NET's option enum: set it via libc
        _listener.Bind(new IPEndPoint(IPAddress.Any, port));
        _listener.Listen(4096);
        _listener.Blocking = false;
        _listenFd = (int)_listener.Handle;
        EpollAdd(_epfd, _listenFd, EPOLLIN);

        _primary = new PgLoopConnection(this, false, pgNoDelay);
        _heavy = new PgLoopConnection[heavyConnections];
        for (var i = 0; i < heavyConnections; i++) _heavy[i] = new PgLoopConnection(this, true, pgNoDelay);
        if (Environment.GetEnvironmentVariable("PG_LIBPQ") == "1")
        {
            _libpqSingle = new LibpqDb();
            _libpqHeavyDb = new LibpqDb[heavyConnections == 0 ? 1 : heavyConnections];
            _libpqHeavy = new List<LoopOp>[_libpqHeavyDb.Length];
            for (var i = 0; i < _libpqHeavyDb.Length; i++)
            {
                _libpqHeavyDb[i] = new LibpqDb();
                _libpqHeavy[i] = new List<LoopOp>();
            }
        }
        _singleConns = new PgLoopConnection[1 + heavyConnections];
        _singleConns[0] = _primary;
        for (var i = 0; i < heavyConnections; i++) _singleConns[i + 1] = _heavy[i];
    }

    public int EpollFd => _epfd;

    public void Register(LoopSocket socket, uint events)
    {
        if (socket.Fd >= _byFd.Length) Array.Resize(ref _byFd, Math.Max(_byFd.Length * 2, socket.Fd + 1));
        _byFd[socket.Fd] = socket;
        EpollAdd(_epfd, socket.Fd, events);
    }

    public void Unregister(LoopSocket socket)
    {
        EpollDel(_epfd, socket.Fd);
        _byFd[socket.Fd] = null;
    }

    public void MarkDirty(PgLoopConnection pg)
    {
        if (!pg.Dirty) { pg.Dirty = true; _dirty.Add(pg); }
    }

    public PgLoopConnection PrimaryPg => _primary;
    /// <summary>Fortunes are read-only and parallel-friendly: spread them over all loop connections.</summary>
    public PgLoopConnection NextFortunePg() => _singleConns[_singleRotation++ % _singleConns.Length];
    public PgLoopConnection HeavyPg => _heavy.Length == 0 ? _primary : _heavy[(_heavyRotation++ & 0x7fffffff) % _heavy.Length];

    public LoopOp RentOp() => _opPool.Count > 0 ? _opPool.Pop() : new LoopOp();
    public void ReturnOp(LoopOp op) { op.Reset(); if (_opPool.Count < 4096) _opPool.Push(op); }

    /// <summary>Single-row /db requests wait for the end of the current epoll batch, then go to
    /// PostgreSQL as one SELECT over an int4[] (one Bind/Execute for the whole batch).</summary>
    public void EnqueueSingle(LoopOp op) => _singleBatch.Add(op);
    public bool UseLibpq => _libpqSingle is not null;
    public void EnqueueLibpqSingle(LoopOp op) => _libpqSingles.Add(op);
    public void EnqueueLibpqFortune(LoopOp op) => _libpqFortunes.Add(op);
    public void EnqueueLibpqHeavy(LoopOp op)
    {
        var slot = (_libpqHeavyRot++) % _libpqHeavy!.Length;
        _libpqHeavy[slot].Add(op);
    }

    void FlushSingleBatch()
    {
        if (_singleBatch.Count == 0) return;
        // singles keep to the loop's primary connection: more PG connections made /db and q=1 slower
        var conn = _primary;
        if (_singleBatch.Count == 1)
        {
            var only = _singleBatch[0];
            _singleBatch.Clear();
            conn.Enqueue(only);
            conn.Write.WriteBindWorld(only.SingleId);
        }
        else
        {
            var op = new SingleBatchOp(_singleBatch);
            _singleBatch.Clear();
            conn.Enqueue(op);
            conn.Write.WriteBindWorldsAny(op.Ids);
        }
        conn.Write.WriteSync();
        MarkDirty(conn);
    }


    public void Run()
    {
        var events = stackalloc EpollEvent[512];
        while (true)
        {
            var n = epoll_wait(_epfd, events, 512, -1);
            if (n < 0)
            {
                if (Errno == EINTR) continue;
                throw new InvalidOperationException($"epoll_wait failed, errno {Errno}");
            }
            for (var i = 0; i < n; i++)
            {
                var fd = (int)events[i].Data;
                var flags = events[i].Events;
                if (fd == _listenFd) { Accept(); continue; }
                var socket = fd < _byFd.Length ? _byFd[fd] : null;
                if (socket is null) continue;
                if ((flags & (EPOLLERR | EPOLLHUP)) != 0) { socket.OnError(); continue; }
                if ((flags & EPOLLIN) != 0) socket.OnReadable();
                if ((flags & EPOLLOUT) != 0 && _byFd[fd] == socket) socket.OnWritable();
            }
            FlushSingleBatch();
            _libpqSingle?.RunSingles(_libpqSingles);
            _libpqSingle?.RunFortunes(_libpqFortunes);
            if (_libpqHeavyDb is not null)
            {
                for (var s = 0; s < _libpqHeavyDb!.Length; s++) _libpqHeavyDb[s].RunHeavy(_libpqHeavy![s]);
            }
            if (_dirty.Count > 0)
            {
                foreach (var pg in _dirty) { pg.Dirty = false; pg.Flush(); }
                _dirty.Clear();
            }
        }
    }

    void Accept()
    {
        while (true)
        {
            var fd = accept4(_listenFd, null, null, SOCK_NONBLOCK | SOCK_CLOEXEC);
            if (fd < 0) return;                                   // EAGAIN: no more pending connections
            SetInt(fd, IPPROTO_TCP, TCP_NODELAY, 1);
            Register(new HttpConn(this, fd), EPOLLIN | EPOLLRDHUP);
        }
    }
}

/// <summary>Raw output buffer: a plain byte[] with length, no ArrayBufferWriter bookkeeping.</summary>
public sealed class ConnOutput : IBufferWriter<byte>
{
    public byte[] Buf = new byte[16 * 1024];
    public int Length;
    public int Sent;
    public void Reset() { Length = 0; Sent = 0; }
    public void Write(ReadOnlySpan<byte> source)
    {
        Ensure(source.Length);
        source.CopyTo(Buf.AsSpan(Length));
        Length += source.Length;
    }
    public Memory<byte> GetMemory(int sizeHint = 0) { Ensure(sizeHint); return Buf.AsMemory(Length); }
    public Span<byte> GetSpan(int sizeHint = 0) { Ensure(sizeHint); return Buf.AsSpan(Length); }
    public void Advance(int count) => Length += count;
    void Ensure(int bytes)
    {
        if (Length + bytes > Buf.Length) Array.Resize(ref Buf, Math.Max(Buf.Length * 2, Length + bytes));
    }
}

/// <summary>An HTTP/1.1 connection: input buffer, output buffer, at most one database operation in flight
/// (later pipelined requests wait so responses keep request order).</summary>
public sealed unsafe class HttpConn(EventLoop loop, int fd) : LoopSocket(fd)
{
    byte[] _in = new byte[8 * 1024];
    int _inLen;
    readonly ConnOutput _out = new();
    int _outSent;
    bool _wantWrite, _busy, _closed;

    public bool Closed => _closed;
    public ConnOutput Output => _out;
    public void OnLibpqComplete() { _busy = false; if (!_closed) ProcessInput(); }

    public override void OnReadable()
    {
        while (true)
        {
            if (_inLen == _in.Length) Array.Resize(ref _in, _in.Length * 2);
            nint n;
            fixed (byte* p = _in) n = recv(Fd, p + _inLen, (nuint)(_in.Length - _inLen), 0);
            if (n > 0)
            {
                _inLen += (int)n;
                if (_inLen < _in.Length) break;           // buffer not full: nothing more to read right now
                continue;                                 // full: there may be more
            }
            if (n == 0 || Errno != EAGAIN) { Close(); return; }
            break;                                        // EAGAIN
        }
        ProcessInput();
    }

    void ProcessInput()
    {
        if (_closed) return;
        var consumed = 0;
        while (!_busy && HttpApplication.TryParseRequest(_in.AsSpan(consumed, _inLen - consumed), out var used, out var route, out var count))
        {
            consumed += used;
            Dispatch(route, count);
        }
        if (consumed > 0)
        {
            _inLen -= consumed;
            if (_inLen > 0) Buffer.BlockCopy(_in, consumed, _in, 0, _inLen);
        }
        TrySend();
    }

    void Dispatch(HttpApplication.Route route, int count)
    {
        switch (route)
        {
            case HttpApplication.Route.Plaintext: _out.Write(HttpApplication.PlaintextResponse); break;
            case HttpApplication.Route.Json: _out.Write(HttpApplication.JsonResponse); break;
            case HttpApplication.Route.NotFound: HttpApplication.WriteResponse(_out, HttpApplication.NotFoundHead, default); break;
            default:
                _busy = true;
                var op = loop.RentOp();
                op.Start(this, route, count, loop);
                break;
        }
    }

    /// <summary>Called by the pending operation on the loop thread when its result is complete.</summary>
    public void OnDbComplete(LoopOp op)
    {
        _busy = false;
        if (_closed) return;
        switch (op.Route)
        {
            case HttpApplication.Route.Db: HttpApplication.WriteWorldJson(_out, op.Single); break;
            case HttpApplication.Route.Queries:
            case HttpApplication.Route.Updates: HttpApplication.WriteWorldsJson(_out, op.Worlds!); break;
            case HttpApplication.Route.Fortunes: op.WriteFortunes(_out); break;
        }
        ProcessInput();                                   // remaining pipelined requests, then send
    }

    public void OnDbError(string message)
    {
        _busy = false;
        if (_closed) return;
        var body = System.Text.Encoding.UTF8.GetBytes(message);
        HttpApplication.WriteResponseWithLength(_out, "HTTP/1.1 500 Internal Server Error\r\nServer: K\r\nContent-Type: text/plain\r\nContent-Length: "u8, body);
        ProcessInput();
    }

    void TrySend()
    {
        if (_wantWrite || _closed) return;
        var pending = _out.Buf.AsSpan(_outSent, _out.Length - _outSent);
        if (pending.IsEmpty) return;
        nint n;
        fixed (byte* p = pending) n = send(Fd, p, (nuint)pending.Length, MSG_NOSIGNAL);
        if (n == pending.Length) { _out.Reset(); _outSent = 0; return; }
        if (n >= 0) { _outSent += (int)n; WaitWritable(); return; }
        if (Errno == EAGAIN) { WaitWritable(); return; }
        Close();
    }

    void WaitWritable()
    {
        _wantWrite = true;
        EpollMod(loop.EpollFd, Fd, EPOLLIN | EPOLLOUT | EPOLLRDHUP);
    }

    public override void OnWritable()
    {
        if (_closed) return;
        _wantWrite = false;
        EpollMod(loop.EpollFd, Fd, EPOLLIN | EPOLLRDHUP);
        TrySend();
    }

    public override void OnError() => Close();

    void Close()
    {
        if (_closed) return;
        _closed = true;
        loop.Unregister(this);
        close(Fd);
    }
}

/// <summary>A pending database operation owned by one HTTP connection; completed by the PostgreSQL read path.</summary>
public sealed class LoopOp : PendingOp
{
    public HttpConn Conn = null!;
    public HttpApplication.Route Route;
    public int Count;
    public World Single;
    public int SingleId => _singleId;
    public int[]? Ids => _ids;
    public int[]? Numbers => _numbers;
    public World[]? Worlds;
    byte[] _fbuf = new byte[4096];
    int _flen;
    readonly int[] _fid = new int[32];
    readonly int[] _foff = new int[32];
    readonly int[] _fmsgLen = new int[32];
    int _fcount;
    byte[] _frbuf = new byte[4096];
    int _frlen;
    int _index, _stage, _singleId;
    int[]? _ids, _numbers;
    PgLoopConnection _pg = null!;
    EventLoop _loop = null!;

    public void Reset() { Conn = null!; Worlds = null; _flen = 0; _fcount = 0; _frlen = 0; _index = 0; _stage = 0; _singleId = 0; _ids = null; _numbers = null; _pg = null!; _loop = null!; }

    public void Start(HttpConn conn, HttpApplication.Route route, int count, EventLoop loop)
    {
        Conn = conn; Route = route; Count = count; _loop = loop;
        var rng = loop.Random;
        switch (route)
        {
            case HttpApplication.Route.Db:
                _singleId = rng.Next(1, 10_001);
                if (loop.UseLibpq) loop.EnqueueLibpqSingle(this);
                else loop.EnqueueSingle(this);
                return;                                  // flushed once per epoll batch
            case HttpApplication.Route.Fortunes:
                if (loop.UseLibpq) { loop.EnqueueLibpqFortune(this); return; }
                _pg = loop.PrimaryPg;
                _pg.Enqueue(this);
                _pg.Write.WriteBindNoParams(PgProtocol.FortunesStatement);
                break;
            case HttpApplication.Route.Queries:
                Worlds = new World[count];
                _ids = new int[count];
                for (var i = 0; i < count; i++) _ids[i] = rng.Next(1, 10_001);
                if (count == 1) { _singleId = _ids[0]; if (loop.UseLibpq) loop.EnqueueLibpqSingle(this); else loop.EnqueueSingle(this); return; }
                if (loop.UseLibpq) { loop.EnqueueLibpqHeavy(this); return; }
                _pg = loop.HeavyPg;
                _pg.Enqueue(this);
                _pg.Write.WriteBindWorldsAny(_ids);
                break;
            case HttpApplication.Route.Updates:
                Worlds = new World[count];
                _ids = new int[count];
                _numbers = new int[count];
                for (var i = 0; i < count; i++)
                {
                    _ids[i] = rng.Next(1, 10_001);
                    _numbers[i] = rng.Next(1, 10_001);
                    Worlds[i] = new World(_ids[i], _numbers[i]);
                }
                if (loop.UseLibpq && count == 1) { loop.EnqueueLibpqHeavy(this); return; }
                _pg = loop.HeavyPg;
                _pg.Enqueue(this);
                _pg.Write.WriteBindUpdate(_ids, _numbers);
                break;
        }
        _pg.Write.WriteSync();
        loop.MarkDirty(_pg);
    }

    public override void OnDataRow(ReadOnlySpan<byte> row)
    {
        var offset = 2;
        switch (Route)
        {
            case HttpApplication.Route.Db:
            {
                Single = new World(_singleId, PgProtocol.ReadInt4Column(row, ref offset));
                break;
            }
            case HttpApplication.Route.Fortunes:
            {
                if (_fcount < _fid.Length)
                {
                    var idLen = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(row[offset..]);
                    var idSpan = row.Slice(offset + 4, idLen);
                    var id = 0;
                    foreach (var b in idSpan) id = id * 10 + (b - (byte)'0');
                    offset += 4 + idLen;
                    var len = System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(row[offset..]);
                    if (_flen + len > _fbuf.Length) Array.Resize(ref _fbuf, Math.Max(_fbuf.Length * 2, _flen + len));
                    row.Slice(offset + 4, len).CopyTo(_fbuf.AsSpan(_flen));
                    _fid[_fcount] = id; _foff[_fcount] = _flen; _fmsgLen[_fcount] = len; _flen += len; _fcount++;
                }
                break;
            }
            default:
                if (Route == HttpApplication.Route.Queries && Worlds!.Length == 1)
                {
                    Worlds[0] = new World(_ids![0], PgProtocol.ReadInt4Column(row, ref offset));
                }
                else if (_index < Worlds!.Length)
                {
                    var id = PgProtocol.ReadInt4Column(row, ref offset);
                    Worlds[_index++] = new World(id, PgProtocol.ReadInt4Column(row, ref offset));
                }
                break;
        }
    }

    /// <summary>ReadyForQuery for this operation arrived.</summary>
    public override void Complete()
    {

        var conn = Conn; var loop = _loop;
        conn.OnDbComplete(this);
        loop.ReturnOp(this);
    }

    static ReadOnlySpan<byte> FHead => "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>"u8;
    static ReadOnlySpan<byte> FTail => "</table></body></html>"u8;
    static ReadOnlySpan<byte> FRowStart => "<tr><td>"u8;
    static ReadOnlySpan<byte> FRowMiddle => "</td><td>"u8;
    static ReadOnlySpan<byte> FRowEnd => "</td></tr>"u8;
    static ReadOnlySpan<byte> FExtra => "Additional fortune added at request time."u8;

    ReadOnlySpan<byte> FortuneMsg(int i) => i < 0 ? FExtra : _fbuf.AsSpan(_foff[i], _fmsgLen[i]);

    static int CompareFortune(ReadOnlySpan<byte> a, ReadOnlySpan<byte> b)
    {
        var n = Math.Min(a.Length, b.Length);
        for (var i = 0; i < n; i++)
        {
            var d = a[i] - b[i];
            if (d != 0) return d;
        }
        return a.Length - b.Length;
    }

    static int Digits(int v) => v < 10 ? 1 : v < 100 ? 2 : v < 1000 ? 3 : v < 10000 ? 4 : 5;

    static int EscapedLen(ReadOnlySpan<byte> s)
    {
        var len = 0;
        foreach (var b in s)
            len += b switch { (byte)'&' => 5, (byte)'<' => 4, (byte)'>' => 4, (byte)'"' => 6, (byte)'\'' => 6, (byte)'/' => 6, _ => 1 };
        return len;
    }

    static int WriteEscaped(Span<byte> dst, ReadOnlySpan<byte> s)
    {
        var p = 0;
        foreach (var b in s)
        {
            switch (b)
            {
                case (byte)'&': "&amp;"u8.CopyTo(dst[p..]); p += 5; break;
                case (byte)'<': "&lt;"u8.CopyTo(dst[p..]); p += 4; break;
                case (byte)'>': "&gt;"u8.CopyTo(dst[p..]); p += 4; break;
                case (byte)'"': "&quot;"u8.CopyTo(dst[p..]); p += 6; break;
                case (byte)'\'': "&#x27;"u8.CopyTo(dst[p..]); p += 6; break;
                case (byte)'/': "&#x2f;"u8.CopyTo(dst[p..]); p += 6; break;
                default: dst[p++] = b; break;
            }
        }
        return p;
    }

    /// <summary>Renders the fortune rows straight from the PostgreSQL UTF-8 bytes (no strings, no list).</summary>
    public void WriteFortunes(ConnOutput output)
    {
        var n = _fcount + 1;
        Span<int> order = stackalloc int[n];
        for (var i = 0; i < _fcount; i++) order[i] = i;
        order[_fcount] = -1;
        for (var i = 1; i < n; i++)
        {
            var key = order[i];
            var j = i - 1;
            while (j >= 0 && CompareFortune(FortuneMsg(order[j]), FortuneMsg(key)) > 0) { order[j + 1] = order[j]; j--; }
            order[j + 1] = key;
        }

        var bodyLen = FHead.Length + FTail.Length;
        for (var i = 0; i < n; i++)
        {
            var idx = order[i];
            bodyLen += FRowStart.Length + FRowMiddle.Length + FRowEnd.Length + Digits(idx < 0 ? 0 : _fid[idx]) + EscapedLen(FortuneMsg(idx));
        }

        var span = output.GetSpan(HttpApplication.HtmlHeadNoLength.Length + 14 + bodyLen);
        HttpApplication.HtmlHeadNoLength.CopyTo(span);
        var pos = HttpApplication.HtmlHeadNoLength.Length;
        System.Buffers.Text.Utf8Formatter.TryFormat(bodyLen, span[pos..], out var digits); pos += digits;
        span[pos++] = (byte)'\r'; span[pos++] = (byte)'\n';
        span[pos++] = (byte)'\r'; span[pos++] = (byte)'\n';
        FHead.CopyTo(span[pos..]); pos += FHead.Length;
        for (var i = 0; i < n; i++)
        {
            var idx = order[i];
            FRowStart.CopyTo(span[pos..]); pos += FRowStart.Length;
            System.Buffers.Text.Utf8Formatter.TryFormat(idx < 0 ? 0 : _fid[idx], span[pos..], out digits); pos += digits;
            FRowMiddle.CopyTo(span[pos..]); pos += FRowMiddle.Length;
            pos += WriteEscaped(span[pos..], FortuneMsg(idx));
            FRowEnd.CopyTo(span[pos..]); pos += FRowEnd.Length;
        }
        FTail.CopyTo(span[pos..]); pos += FTail.Length;
        output.Advance(pos);
    }

    public unsafe void RenderFortunes(IntPtr result)
    {
        var n = LibpqDb.Rows(result);
        Span<int> order = stackalloc int[n + 1];
        byte** msgs = stackalloc byte*[n + 1];
        Span<int> ids = stackalloc int[n + 1];
        for (var i = 0; i < n; i++)
        {
            ids[i] = Atoi(LibpqDb.Value(result, i, 0));
            msgs[i] = LibpqDb.Value(result, i, 1);
            order[i] = i;
        }
        order[n] = n; msgs[n] = null; ids[n] = 0;

        for (var i = 1; i <= n; i++)
        {
            var key = order[i];
            var j = i - 1;
            while (j >= 0 && CompareFortune(MsgOf(msgs, order[j], n), MsgOf(msgs, key, n)) > 0) { order[j + 1] = order[j]; j--; }
            order[j + 1] = key;
        }

        // one render pass into the op's scratch buffer, then one copy to the connection
        var p = 0;
        WriteConst(_frbuf, ref p, FHead);
        for (var i = 0; i <= n; i++)
        {
            var idx = order[i];
            WriteConst(_frbuf, ref p, FRowStart);
            EnsureScratchAt(ref p, 11);
            System.Buffers.Text.Utf8Formatter.TryFormat(ids[idx], _frbuf.AsSpan(p), out var digits); p += digits;
            WriteConst(_frbuf, ref p, FRowMiddle);
            WriteEscapedPtr(_frbuf, ref p, MsgOf(msgs, idx, n));
            WriteConst(_frbuf, ref p, FRowEnd);
        }
        WriteConst(_frbuf, ref p, FTail);

        var output = Conn.Output;
        var span = output.GetSpan(HttpApplication.HtmlHeadNoLength.Length + 14 + p);
        HttpApplication.HtmlHeadNoLength.CopyTo(span);
        var pos = HttpApplication.HtmlHeadNoLength.Length;
        System.Buffers.Text.Utf8Formatter.TryFormat(p, span[pos..], out var digits2); pos += digits2;
        span[pos++] = (byte)'\r'; span[pos++] = (byte)'\n';
        span[pos++] = (byte)'\r'; span[pos++] = (byte)'\n';
        _frbuf.AsSpan(0, p).CopyTo(span[pos..]);
        output.Advance(pos + p);
        Conn.OnLibpqComplete();
    }

    static unsafe void WriteConst(byte[] dst, ref int p, ReadOnlySpan<byte> src)
    {
        src.CopyTo(dst.AsSpan(p));
        p += src.Length;
    }

    static unsafe void WriteEscapedPtr(byte[] dst, ref int p, ReadOnlySpan<byte> src)
    {
        foreach (var b in src)
        {
            switch (b)
            {
                case (byte)'&': "&amp;"u8.CopyTo(dst.AsSpan(p)); p += 5; break;
                case (byte)'<': "&lt;"u8.CopyTo(dst.AsSpan(p)); p += 4; break;
                case (byte)'>': "&gt;"u8.CopyTo(dst.AsSpan(p)); p += 4; break;
                case (byte)'"': "&quot;"u8.CopyTo(dst.AsSpan(p)); p += 6; break;
                case (byte)'\'': "&#x27;"u8.CopyTo(dst.AsSpan(p)); p += 6; break;
                case (byte)'/': "&#x2f;"u8.CopyTo(dst.AsSpan(p)); p += 6; break;
                default: dst[p++] = b; break;
            }
        }
    }

    void EnsureScratchAt(ref int p, int extra)
    {
        if (p + extra > _frbuf.Length) Array.Resize(ref _frbuf, Math.Max(_frbuf.Length * 2, p + extra));
    }

    static unsafe ReadOnlySpan<byte> MsgOf(byte** msgs, int idx, int extra) =>
        idx == extra ? FExtra : System.Runtime.InteropServices.MemoryMarshal.CreateReadOnlySpanFromNullTerminated(msgs[idx]);

    static unsafe int Atoi(byte* p)
    {
        var v = 0;
        while (*p >= (byte)'0' && *p <= (byte)'9') { v = v * 10 + (*p - (byte)'0'); p++; }
        return v;
    }

    public void FailLibpq() => Conn.OnLibpqComplete();

    /// <summary>Renders /queries straight from a libpq result: no World[] and no serializer.</summary>
    public void RenderQueriesFromResult(IntPtr result) => RenderQueriesFromRows(result, 0, LibpqDb.Rows(result));

    public unsafe void RenderQueriesFromRows(IntPtr result, int startRow, int count)
    {
        var available = LibpqDb.Rows(result);
        var n = count;
        if (startRow + n > available) n = Math.Max(0, available - startRow);
        Span<byte> body = stackalloc byte[2 + n * 40];
        var p = 0;
        body[p++] = (byte)'[';
        for (var i = 0; i < n; i++)
        {
            if (i != 0) body[p++] = (byte)',';
            "{\"id\":"u8.CopyTo(body[p..]); p += 6;
            System.Buffers.Text.Utf8Formatter.TryFormat(LibpqDb.Atoi(LibpqDb.Value(result, startRow + i, 0)), body[p..], out var digits); p += digits;
            ",\"randomNumber\":"u8.CopyTo(body[p..]); p += 16;
            System.Buffers.Text.Utf8Formatter.TryFormat(LibpqDb.Atoi(LibpqDb.Value(result, startRow + i, 1)), body[p..], out digits); p += digits;
            body[p++] = (byte)'}';
        }
        body[p++] = (byte)']';
        HttpApplication.WriteResponseWithLength(Conn.Output, HttpApplication.JsonHeadNoLength, body[..p]);
        var c = Conn; var l = _loop;
        c.OnLibpqComplete();
        l.ReturnOp(this);
    }

    public override void Fail(Exception e) => Fail(e.Message);

    public void Fail(string message)
    {
        var conn = Conn; var loop = _loop;
        conn.OnDbError(message);
        loop.ReturnOp(this);
    }
}

/// <summary>A PostgreSQL connection owned by one loop: handshake done synchronously on a blocking .NET
/// socket (no SocketAsyncEngine registration), then the raw fd is driven by the loop's epoll.</summary>
public sealed unsafe class PgLoopConnection : LoopSocket
{
    readonly EventLoop _loop;
    readonly Socket _socket;                      // kept alive: owns the fd
    public readonly PgWriteBuffer Write = new();
    int _writeSent;
    bool _wantWrite;
    public bool Dirty;
    readonly Queue<PendingOp> _pending = new();
    byte[] _read = new byte[64 * 1024];
    int _readLen;
    public readonly bool Heavy;

    public PgLoopConnection(EventLoop loop, bool heavy, bool noDelay) : this(loop, heavy, Connect(noDelay)) { }

    PgLoopConnection(EventLoop loop, bool heavy, Socket socket) : base((int)socket.Handle)
    {
        _loop = loop; _socket = socket; Heavy = heavy;
        loop.Register(this, EPOLLIN);
    }

    static Socket Connect(bool noDelay)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = noDelay, Blocking = true };
        socket.Connect(new IPEndPoint(IPAddress.Loopback, 5432));
        var buffer = new byte[64 * 1024]; var len = 0;
        var auth = new PgAuthenticator("benchmarkdbuser", "benchmarkdbpass");
        socket.Send(PgProtocol.StartupMessage("benchmarkdbuser", "hello_world"));
        var ready = false;
        while (!ready)
        {
            while (!PgProtocol.TryGetMessage(buffer.AsSpan(0, len), out var type, out var body))
            {
                var n = socket.Receive(buffer, len, buffer.Length - len, SocketFlags.None);
                if (n <= 0) throw new EndOfStreamException("PostgreSQL closed the connection during startup");
                len += n;
            }
            PgProtocol.TryGetMessage(buffer.AsSpan(0, len), out var t, out var b);
            var reply = auth.Handle(t, b, out ready);
            var consumed = 5 + b.Length; len -= consumed; if (len > 0) Buffer.BlockCopy(buffer, consumed, buffer, 0, len);
            if (reply is not null) socket.Send(reply);
        }
        socket.Send(PgProtocol.PrepareBatch());
        while (true)
        {
            while (!PgProtocol.TryGetMessage(buffer.AsSpan(0, len), out _, out _))
            {
                var n = socket.Receive(buffer, len, buffer.Length - len, SocketFlags.None);
                if (n <= 0) throw new EndOfStreamException("PostgreSQL closed the connection during prepare");
                len += n;
            }
            PgProtocol.TryGetMessage(buffer.AsSpan(0, len), out var t, out var b);
            var consumed = 5 + b.Length; len -= consumed; if (len > 0) Buffer.BlockCopy(buffer, consumed, buffer, 0, len);
            if (t == (byte)'E') throw new InvalidOperationException("prepare failed: " + PgProtocol.ParseError(b));
            if (t == (byte)'Z') break;
        }
        socket.Blocking = false;
        return socket;
    }

    public void Enqueue(PendingOp op) => _pending.Enqueue(op);

    /// <summary>Send everything queued since the last flush (one write per epoll batch).</summary>
    public void Flush()
    {
        if (_wantWrite) return;
        var pending = Write.Buffer.AsSpan(_writeSent, Write.Length - _writeSent);
        if (pending.IsEmpty) return;
        nint n;
        fixed (byte* p = pending) n = send(Fd, p, (nuint)pending.Length, MSG_NOSIGNAL);
        if (n == pending.Length) { Write.Reset(); _writeSent = 0; return; }
        if (n >= 0) { _writeSent += (int)n; WaitWritable(); return; }
        if (Errno == EAGAIN) { WaitWritable(); return; }
        throw new IOException($"send to PostgreSQL failed, errno {Errno}");
    }

    void WaitWritable()
    {
        _wantWrite = true;
        EpollMod(_loop.EpollFd, Fd, EPOLLIN | EPOLLOUT);
    }

    public override void OnWritable()
    {
        _wantWrite = false;
        EpollMod(_loop.EpollFd, Fd, EPOLLIN);
        Flush();
    }

    public override void OnReadable()
    {
        while (true)
        {
            if (_readLen == _read.Length) Array.Resize(ref _read, _read.Length * 2);
            nint n;
            fixed (byte* p = _read) n = recv(Fd, p + _readLen, (nuint)(_read.Length - _readLen), 0);
            if (n > 0)
            {
                _readLen += (int)n;
                if (_readLen < _read.Length) break;
                continue;
            }
            if (n == 0) throw new EndOfStreamException("PostgreSQL closed the connection");
            if (Errno != EAGAIN) throw new IOException($"recv from PostgreSQL failed, errno {Errno}");
            break;
        }

        var consumed = 0;
        while (PgProtocol.TryGetMessage(_read.AsSpan(consumed, _readLen - consumed), out var type, out var body))
        {
            consumed += 5 + body.Length;
            switch (type)
            {
                case (byte)'D':
                    if (_pending.TryPeek(out var op)) op.OnDataRow(body);
                    break;
                case (byte)'Z':
                    if (_pending.TryDequeue(out var done)) done.Complete();
                    break;
                case (byte)'E':
                    if (_pending.TryDequeue(out var failed)) failed.Fail(new InvalidOperationException("PostgreSQL error: " + PgProtocol.ParseError(body)));
                    break;
            }
        }
        if (consumed > 0)
        {
            _readLen -= consumed;
            if (_readLen > 0) Buffer.BlockCopy(_read, consumed, _read, 0, _readLen);
        }
    }

    public override void OnError() => throw new IOException("PostgreSQL connection error (EPOLLERR/EPOLLHUP)");
}

/// <summary>One SELECT over the int4[] of every /db request seen in an epoll batch; rows come back in
/// request order (ORDER BY ordinality) and are handed to the waiting operations.</summary>
public sealed class SingleBatchOp : PendingOp
{
    public readonly int[] Ids;
    readonly LoopOp[] _ops;
    int _rows;

    public SingleBatchOp(List<LoopOp> ops)
    {
        _ops = ops.ToArray();
        Ids = new int[_ops.Length];
        for (var i = 0; i < _ops.Length; i++) Ids[i] = _ops[i].SingleId;
    }

    public override void OnDataRow(ReadOnlySpan<byte> row)
    {
        var offset = 2;
        var id = PgProtocol.ReadInt4Column(row, ref offset);
        var number = PgProtocol.ReadInt4Column(row, ref offset);
        if (_rows < _ops.Length)
        {
            var op = _ops[_rows++];
            if (op.Route == HttpApplication.Route.Queries && op.Worlds!.Length == 1) op.Worlds[0] = new World(id, number);
            else op.Single = new World(id, number);
        }
    }

    public override void Complete()
    {
        for (var i = 0; i < _ops.Length; i++)
        {
            if (i < _rows) _ops[i].Complete();
            else _ops[i].Fail("missing row in batched /db");
        }
    }

    public override void Fail(Exception e)
    {
        for (var i = 0; i < _ops.Length; i++) _ops[i].Fail(e.Message);
    }
}

