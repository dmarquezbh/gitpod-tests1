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
    int _heavyRotation;
    readonly List<PgLoopConnection> _dirty = new();
    readonly Stack<LoopOp> _opPool = new();
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
    public PgLoopConnection HeavyPg => _heavy.Length == 0 ? _primary : _heavy[(_heavyRotation++ & 0x7fffffff) % _heavy.Length];

    public LoopOp RentOp() => _opPool.Count > 0 ? _opPool.Pop() : new LoopOp();
    public void ReturnOp(LoopOp op) { op.Reset(); if (_opPool.Count < 4096) _opPool.Push(op); }

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

/// <summary>An HTTP/1.1 connection: input buffer, output buffer, at most one database operation in flight
/// (later pipelined requests wait so responses keep request order).</summary>
public sealed unsafe class HttpConn(EventLoop loop, int fd) : LoopSocket(fd)
{
    byte[] _in = new byte[8 * 1024];
    int _inLen;
    readonly ArrayBufferWriter<byte> _out = new(16 * 1024);
    int _outSent;
    bool _wantWrite, _busy, _closed;

    public bool Closed => _closed;

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
            case HttpApplication.Route.Plaintext: HttpApplication.WriteResponse(_out, HttpApplication.PlaintextHead, HttpApplication.HelloWorld); break;
            case HttpApplication.Route.Json: HttpApplication.WriteJsonMessage(_out); break;
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
            case HttpApplication.Route.Db: HttpApplication.WriteJson(_out, op.Single, AppJsonContext.Default.World); break;
            case HttpApplication.Route.Queries:
            case HttpApplication.Route.Updates: HttpApplication.WriteJson(_out, op.Worlds!, AppJsonContext.Default.WorldArray); break;
            case HttpApplication.Route.Fortunes:
            {
                var buffer = HttpApplication.GetBuffer();
                FortunesRenderer.Render(buffer, op.Fortunes!);
                HttpApplication.WriteResponseWithLength(_out, HttpApplication.HtmlHeadNoLength, buffer.WrittenSpan);
                break;
            }
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
        var pending = _out.WrittenSpan[_outSent..];
        if (pending.IsEmpty) return;
        nint n;
        fixed (byte* p = pending) n = send(Fd, p, (nuint)pending.Length, MSG_NOSIGNAL);
        if (n == pending.Length) { _out.ResetWrittenCount(); _outSent = 0; return; }
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
public sealed class LoopOp
{
    public HttpConn Conn = null!;
    public HttpApplication.Route Route;
    public int Count;
    public World Single;
    public World[]? Worlds;
    public List<Fortune>? Fortunes;
    int _index, _stage;
    PgLoopConnection _pg = null!;
    EventLoop _loop = null!;

    public void Reset() { Conn = null!; Worlds = null; Fortunes = null; _index = 0; _stage = 0; _pg = null!; _loop = null!; }

    public void Start(HttpConn conn, HttpApplication.Route route, int count, EventLoop loop)
    {
        Conn = conn; Route = route; Count = count; _loop = loop;
        var rng = loop.Random;
        switch (route)
        {
            case HttpApplication.Route.Db:
                _pg = loop.PrimaryPg;
                _pg.Enqueue(this);
                _pg.Write.WriteBindWorld(rng.Next(1, 10_001));
                break;
            case HttpApplication.Route.Fortunes:
                Fortunes = new List<Fortune>(16) { new(0, "Additional fortune added at request time.") };
                _pg = loop.PrimaryPg;
                _pg.Enqueue(this);
                _pg.Write.WriteBindNoParams(PgProtocol.FortunesStatement);
                break;
            case HttpApplication.Route.Queries:
            case HttpApplication.Route.Updates:
                Worlds = new World[count];
                _pg = count > 1 || route == HttpApplication.Route.Updates ? loop.HeavyPg : loop.PrimaryPg;
                _pg.Enqueue(this);
                for (var i = 0; i < count; i++) _pg.Write.WriteBindWorld(rng.Next(1, 10_001));
                break;
        }
        _pg.Write.WriteSync();
        loop.MarkDirty(_pg);
    }

    public void OnDataRow(ReadOnlySpan<byte> row)
    {
        var offset = 2;
        switch (Route)
        {
            case HttpApplication.Route.Db:
            {
                var id = PgProtocol.ReadInt4Column(row, ref offset);
                Single = new World(id, PgProtocol.ReadInt4Column(row, ref offset));
                break;
            }
            case HttpApplication.Route.Fortunes:
            {
                var id = PgProtocol.ReadInt4Column(row, ref offset);
                Fortunes!.Add(new Fortune(id, PgProtocol.ReadTextColumn(row, ref offset)));
                break;
            }
            default:
                if (_stage == 0 && _index < Worlds!.Length)
                {
                    var id = PgProtocol.ReadInt4Column(row, ref offset);
                    Worlds[_index++] = new World(id, PgProtocol.ReadInt4Column(row, ref offset));
                }
                break;
        }
    }

    /// <summary>ReadyForQuery for this operation arrived.</summary>
    public void Complete()
    {
        switch (Route)
        {
            case HttpApplication.Route.Fortunes:
                Fortunes!.Sort(static (a, b) => string.CompareOrdinal(a.Message, b.Message));
                break;
            case HttpApplication.Route.Updates when _stage == 0:
            {
                // stage 2: one UPDATE with the new numbers, pipelined on the same connection
                _stage = 1;
                var worlds = Worlds!;
                var ids = new int[worlds.Length];
                var numbers = new int[worlds.Length];
                var rng = _loop.Random;
                for (var i = 0; i < worlds.Length; i++)
                {
                    var w = worlds[i] with { RandomNumber = rng.Next(1, 10_001) };
                    worlds[i] = w; ids[i] = w.Id; numbers[i] = w.RandomNumber;
                }
                _pg.Enqueue(this);
                _pg.Write.WriteBindUpdate(ids, numbers);
                _pg.Write.WriteSync();
                _loop.MarkDirty(_pg);
                return;                                   // not finished yet
            }
        }
        var conn = Conn; var loop = _loop;
        conn.OnDbComplete(this);
        loop.ReturnOp(this);
    }

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
    readonly Queue<LoopOp> _pending = new();
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

    public void Enqueue(LoopOp op) => _pending.Enqueue(op);

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
                    if (_pending.TryDequeue(out var failed)) failed.Fail("PostgreSQL error: " + PgProtocol.ParseError(body));
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
