using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;

namespace DotnetBench.Platform.Pg;

/// <summary>
/// Minimal pipelined PostgreSQL client: one TCP connection, extended query protocol, binary
/// parameters and results, statements prepared once at startup. Commands are appended to a write
/// buffer and flushed by a double-buffered send loop, so concurrent requests on the same connection
/// are coalesced into one socket write (the same pipelining a tokio-postgres connection does);
/// responses are matched to pending operations in FIFO order by a single read loop, which completes
/// each operation's ValueTask inline. No pool, no locks on the read path, no reflection.
/// </summary>
public sealed class PgConnection : IThreadPoolWorkItem
{
    public const string WorldStatement = "w";
    public const string FortunesStatement = "f";
    public const string UpdateStatement = "u";

    const int Int4Oid = 23;
    const int Int4ArrayOid = 1007;

    readonly Socket _socket;
    readonly ConcurrentQueue<PendingOp> _pending = new();

    // write side (guarded by _writeLock)
    readonly object _writeLock = new();
    byte[] _writeBuffer = new byte[64 * 1024];
    int _writeLength;
    byte[] _sendBuffer = new byte[64 * 1024];
    bool _sending;

    // read side (read loop only)
    byte[] _readBuffer = new byte[64 * 1024];
    int _readLength;

    /// <summary>Connections whose read loop runs on the current thread (set by the read loop itself,
    /// so with inline socket completions an IO thread only ever talks to connections it also reads).</summary>
    [ThreadStatic] static List<PgConnection>? t_local;
    bool _registered;

    public static List<PgConnection>? LocalConnections => t_local;

    PgConnection(Socket socket) => _socket = socket;

    public static async Task<PgConnection> ConnectAsync(string host, int port, string user, string password, string database)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp) { NoDelay = Environment.GetEnvironmentVariable("PG_NODELAY") != "0" };
        await socket.ConnectAsync(new IPEndPoint(IPAddress.Parse(host), port));
        var connection = new PgConnection(socket);
        await connection.StartupAsync(user, password, database);
        await connection.PrepareAsync();
        _ = connection.ReadLoopAsync();
        await connection.QueryWorld(1);   // first round trip: lets the read loop register itself on its IO thread
        return connection;
    }

    // ---- public operations --------------------------------------------------------------------

    public ValueTask<World> QueryWorld(int id)
    {
        var op = new SingleWorldOp();
        lock (_writeLock)
        {
            _pending.Enqueue(op);
            WriteBindWorld(id);
            WriteSync();
            FlushLocked();
        }
        return new ValueTask<World>(op, op.Version);
    }

    /// <summary>N separate SELECTs, one Sync: a single round trip (and usually a single write).</summary>
    public ValueTask<World[]> QueryWorlds(ReadOnlySpan<int> ids)
    {
        var op = new WorldsOp(ids.Length);
        lock (_writeLock)
        {
            _pending.Enqueue(op);
            foreach (var id in ids) WriteBindWorld(id);
            WriteSync();
            FlushLocked();
        }
        return new ValueTask<World[]>(op, op.Version);
    }

    public ValueTask UpdateWorlds(int[] ids, int[] numbers)
    {
        var op = new ExecOp();
        lock (_writeLock)
        {
            _pending.Enqueue(op);
            WriteBindUpdate(ids, numbers);
            WriteSync();
            FlushLocked();
        }
        return new ValueTask(op, op.Version);
    }

    public ValueTask<List<Fortune>> QueryFortunes()
    {
        var op = new FortunesOp();
        lock (_writeLock)
        {
            _pending.Enqueue(op);
            WriteBindNoParams(FortunesStatement);
            WriteSync();
            FlushLocked();
        }
        return new ValueTask<List<Fortune>>(op, op.Version);
    }

    // ---- message encoding (always called under _writeLock) ------------------------------------

    void Ensure(int bytes)
    {
        if (_writeLength + bytes > _writeBuffer.Length) Array.Resize(ref _writeBuffer, Math.Max(_writeBuffer.Length * 2, _writeLength + bytes));
    }

    void WriteBindWorld(int id)
    {
        // Bind: portal "" + statement "w" + 1 param format (binary) + 1 param (int4) + 1 result format (binary); Execute: portal "", no limit
        const int bindLen = 4 + 1 + 2 + 2 + 2 + 2 + (4 + 4) + 2 + 2;
        Ensure(1 + bindLen + 1 + 4 + 1 + 4);
        var s = _writeBuffer.AsSpan(_writeLength);
        s[0] = (byte)'B'; BinaryPrimitives.WriteInt32BigEndian(s[1..], bindLen);
        s[5] = 0;                                   // portal ""
        s[6] = (byte)'w'; s[7] = 0;                 // statement
        BinaryPrimitives.WriteInt16BigEndian(s[8..], 1); BinaryPrimitives.WriteInt16BigEndian(s[10..], 1);   // param formats: binary
        BinaryPrimitives.WriteInt16BigEndian(s[12..], 1);                                                     // 1 param
        BinaryPrimitives.WriteInt32BigEndian(s[14..], 4); BinaryPrimitives.WriteInt32BigEndian(s[18..], id);
        BinaryPrimitives.WriteInt16BigEndian(s[22..], 1); BinaryPrimitives.WriteInt16BigEndian(s[24..], 1);   // result formats: binary
        WriteExecute(s[26..]);
        _writeLength += 26 + 10;
    }

    void WriteBindNoParams(string statement)
    {
        var bindLen = 4 + 1 + (statement.Length + 1) + 2 + 2 + 2 + 2;
        Ensure(1 + bindLen + 10);
        var s = _writeBuffer.AsSpan(_writeLength);
        s[0] = (byte)'B'; BinaryPrimitives.WriteInt32BigEndian(s[1..], bindLen);
        s[5] = 0;
        var p = 6;
        p += Encoding.ASCII.GetBytes(statement, s[p..]); s[p++] = 0;
        BinaryPrimitives.WriteInt16BigEndian(s[p..], 0); p += 2;   // no param formats
        BinaryPrimitives.WriteInt16BigEndian(s[p..], 0); p += 2;   // no params
        BinaryPrimitives.WriteInt16BigEndian(s[p..], 1); p += 2; BinaryPrimitives.WriteInt16BigEndian(s[p..], 1); p += 2; // results binary
        WriteExecute(s[p..]);
        _writeLength += p + 10;
    }

    void WriteBindUpdate(int[] ids, int[] numbers)
    {
        var arrayLen = 20 + ids.Length * 8;         // ndim, hasnull, elem oid, dim, lbound + (len+value) per element
        var bindLen = 4 + 1 + 2 + 2 + 2 + 2 + 2 * (4 + arrayLen) + 2 + 2;
        Ensure(1 + bindLen + 10);
        var s = _writeBuffer.AsSpan(_writeLength);
        s[0] = (byte)'B'; BinaryPrimitives.WriteInt32BigEndian(s[1..], bindLen);
        s[5] = 0;
        s[6] = (byte)'u'; s[7] = 0;
        BinaryPrimitives.WriteInt16BigEndian(s[8..], 1); BinaryPrimitives.WriteInt16BigEndian(s[10..], 1);   // all params binary
        BinaryPrimitives.WriteInt16BigEndian(s[12..], 2);
        var p = 14;
        p += WriteInt4Array(s[p..], ids);
        p += WriteInt4Array(s[p..], numbers);
        BinaryPrimitives.WriteInt16BigEndian(s[p..], 1); p += 2; BinaryPrimitives.WriteInt16BigEndian(s[p..], 1); p += 2;
        WriteExecute(s[p..]);
        _writeLength += p + 10;
    }

    static int WriteInt4Array(Span<byte> s, int[] values)
    {
        BinaryPrimitives.WriteInt32BigEndian(s, 20 + values.Length * 8);
        BinaryPrimitives.WriteInt32BigEndian(s[4..], 1);            // ndim
        BinaryPrimitives.WriteInt32BigEndian(s[8..], 0);            // has nulls
        BinaryPrimitives.WriteInt32BigEndian(s[12..], Int4Oid);
        BinaryPrimitives.WriteInt32BigEndian(s[16..], values.Length);
        BinaryPrimitives.WriteInt32BigEndian(s[20..], 1);           // lower bound
        var p = 24;
        foreach (var v in values)
        {
            BinaryPrimitives.WriteInt32BigEndian(s[p..], 4); BinaryPrimitives.WriteInt32BigEndian(s[(p + 4)..], v); p += 8;
        }
        return p;
    }

    static void WriteExecute(Span<byte> s)
    {
        s[0] = (byte)'E'; BinaryPrimitives.WriteInt32BigEndian(s[1..], 9); s[5] = 0; BinaryPrimitives.WriteInt32BigEndian(s[6..], 0);
    }

    void WriteSync()
    {
        Ensure(5);
        var s = _writeBuffer.AsSpan(_writeLength);
        s[0] = (byte)'S'; BinaryPrimitives.WriteInt32BigEndian(s[1..], 4);
        _writeLength += 5;
    }

    // ---- send loop -----------------------------------------------------------------------------

    /// <summary>Schedules (rather than performs) the send: everything enqueued by the IO thread while
    /// it finishes its current batch of socket events is coalesced into one write, which is what the
    /// tokio-postgres connection task gets for free by being polled after the request tasks.</summary>
    void FlushLocked()
    {
        if (_sending) return;           // the in-flight send loop will pick this data up
        _sending = true;
        if (s_deferredSend) ThreadPool.UnsafeQueueUserWorkItem(this, preferLocal: false);
        else { var (buffer, length) = SwapLocked(); _ = SendLoopAsync(buffer, length); }
    }

    static readonly bool s_deferredSend = Environment.GetEnvironmentVariable("PG_DEFERRED_SEND") == "1";   // measured slower: the thread hop costs more than the coalescing saves

    void IThreadPoolWorkItem.Execute()
    {
        byte[] buffer; int length;
        lock (_writeLock) (buffer, length) = SwapLocked();
        _ = SendLoopAsync(buffer, length);
    }

    (byte[] buffer, int length) SwapLocked()
    {
        var buffer = _writeBuffer; var length = _writeLength;
        _writeBuffer = _sendBuffer; _writeLength = 0;
        _sendBuffer = buffer;
        return (buffer, length);
    }

    async Task SendLoopAsync(byte[] buffer, int length)
    {
        try
        {
            while (true)
            {
                var sent = 0;
                while (sent < length) sent += await _socket.SendAsync(buffer.AsMemory(sent, length - sent), SocketFlags.None);
                lock (_writeLock)
                {
                    if (_writeLength == 0) { _sending = false; return; }
                    (buffer, length) = SwapLocked();
                }
            }
        }
        catch (Exception e)
        {
            FailAll(e);
        }
    }

    // ---- read loop -----------------------------------------------------------------------------

    async Task ReadLoopAsync()
    {
        try
        {
            while (true)
            {
                if (_readLength == _readBuffer.Length) Array.Resize(ref _readBuffer, _readBuffer.Length * 2);
                var n = await _socket.ReceiveAsync(_readBuffer.AsMemory(_readLength), SocketFlags.None);
                if (n == 0) throw new EndOfStreamException("PostgreSQL closed the connection");
                _readLength += n;
                if (!_registered) { _registered = true; (t_local ??= new List<PgConnection>()).Add(this); }

                var consumed = 0;
                while (TryGetMessage(_readBuffer.AsSpan(consumed, _readLength - consumed), out var type, out var body))
                {
                    consumed += 5 + body.Length;
                    OnMessage(type, body);
                }
                if (consumed > 0)
                {
                    _readLength -= consumed;
                    if (_readLength > 0) Buffer.BlockCopy(_readBuffer, consumed, _readBuffer, 0, _readLength);
                }
            }
        }
        catch (Exception e)
        {
            FailAll(e);
        }
    }

    static bool TryGetMessage(ReadOnlySpan<byte> data, out byte type, out ReadOnlySpan<byte> body)
    {
        type = 0; body = default;
        if (data.Length < 5) return false;
        var length = BinaryPrimitives.ReadInt32BigEndian(data[1..]);   // includes the 4 length bytes
        if (data.Length < 1 + length) return false;
        type = data[0];
        body = data.Slice(5, length - 4);
        return true;
    }

    void OnMessage(byte type, ReadOnlySpan<byte> body)
    {
        switch (type)
        {
            case (byte)'D':                             // DataRow
                if (_pending.TryPeek(out var op)) op.OnDataRow(body);
                break;
            case (byte)'Z':                             // ReadyForQuery: the head operation is finished
                if (_pending.TryDequeue(out var done)) done.Complete();
                break;
            case (byte)'E':                             // ErrorResponse (the Sync will still produce a ReadyForQuery)
                if (_pending.TryPeek(out var failed)) failed.Fail(new InvalidOperationException("PostgreSQL error: " + ParseError(body)));
                break;
            // '2' BindComplete, 'C' CommandComplete, 'T' RowDescription, 'n' NoData, 'N' NoticeResponse, 'S' ParameterStatus: nothing to do
        }
    }

    static string ParseError(ReadOnlySpan<byte> body)
    {
        var sb = new StringBuilder();
        while (!body.IsEmpty && body[0] != 0)
        {
            var end = body.IndexOf((byte)0);
            sb.Append((char)body[0]).Append('=').Append(Encoding.UTF8.GetString(body[1..end])).Append(' ');
            body = body[(end + 1)..];
        }
        return sb.ToString();
    }

    void FailAll(Exception e)
    {
        while (_pending.TryDequeue(out var op)) op.Fail(e);
    }

    // ---- startup (synchronous request/response, before the read loop starts) -----------------

    async Task StartupAsync(string user, string password, string database)
    {
        var parameters = Encoding.UTF8.GetBytes($"user\0{user}\0database\0{database}\0client_encoding\0UTF8\0\0");
        var startup = new byte[8 + parameters.Length];
        BinaryPrimitives.WriteInt32BigEndian(startup, startup.Length);
        BinaryPrimitives.WriteInt32BigEndian(startup.AsSpan(4), 196608);   // protocol 3.0
        parameters.CopyTo(startup, 8);
        await SendAllAsync(startup);

        string? clientFirstBare = null, clientNonce = null;
        while (true)
        {
            var (type, body) = await ReadMessageAsync();
            if (type == (byte)'E') throw new InvalidOperationException("PostgreSQL error during startup: " + ParseError(body));
            if (type == (byte)'Z') return;
            if (type != (byte)'R') continue;            // ParameterStatus / BackendKeyData

            var code = BinaryPrimitives.ReadInt32BigEndian(body);
            switch (code)
            {
                case 0: break;                           // AuthenticationOk
                case 3:                                  // cleartext
                    await SendAllAsync(PasswordMessage(Encoding.UTF8.GetBytes(password)));
                    break;
                case 5:                                  // md5
                {
                    var salt = body.AsSpan(4, 4).ToArray();
                    var inner = Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(password + user)));
                    var outer = Convert.ToHexStringLower(MD5.HashData([.. Encoding.ASCII.GetBytes(inner), .. salt]));
                    await SendAllAsync(PasswordMessage(Encoding.ASCII.GetBytes("md5" + outer)));
                    break;
                }
                case 10:                                 // SASL: offer SCRAM-SHA-256
                {
                    clientNonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));
                    clientFirstBare = $"n=,r={clientNonce}";
                    var clientFirst = Encoding.UTF8.GetBytes("n,," + clientFirstBare);
                    var mech = "SCRAM-SHA-256\0"u8;
                    var msg = new byte[5 + mech.Length + 4 + clientFirst.Length];
                    msg[0] = (byte)'p'; BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(1), msg.Length - 1);
                    mech.CopyTo(msg.AsSpan(5));
                    BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(5 + mech.Length), clientFirst.Length);
                    clientFirst.CopyTo(msg.AsSpan(9 + mech.Length));
                    await SendAllAsync(msg);
                    break;
                }
                case 11:                                 // SASLContinue: server-first-message
                {
                    var serverFirst = Encoding.UTF8.GetString(body[4..]);
                    string? nonce = null, saltB64 = null; var iterations = 0;
                    foreach (var part in serverFirst.Split(','))
                    {
                        if (part.StartsWith("r=")) nonce = part[2..];
                        else if (part.StartsWith("s=")) saltB64 = part[2..];
                        else if (part.StartsWith("i=")) iterations = int.Parse(part[2..]);
                    }
                    if (nonce is null || saltB64 is null || !nonce.StartsWith(clientNonce!)) throw new InvalidOperationException("bad SCRAM server-first-message");
                    var saltedPassword = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), Convert.FromBase64String(saltB64), iterations, HashAlgorithmName.SHA256, 32);
                    var clientKey = HMACSHA256.HashData(saltedPassword, "Client Key"u8);
                    var storedKey = SHA256.HashData(clientKey);
                    var clientFinalNoProof = $"c=biws,r={nonce}";
                    var authMessage = Encoding.UTF8.GetBytes($"{clientFirstBare},{serverFirst},{clientFinalNoProof}");
                    var clientSignature = HMACSHA256.HashData(storedKey, authMessage);
                    var proof = new byte[32];
                    for (var i = 0; i < 32; i++) proof[i] = (byte)(clientKey[i] ^ clientSignature[i]);
                    var clientFinal = Encoding.UTF8.GetBytes($"{clientFinalNoProof},p={Convert.ToBase64String(proof)}");
                    var msg = new byte[5 + clientFinal.Length];
                    msg[0] = (byte)'p'; BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(1), msg.Length - 1);
                    clientFinal.CopyTo(msg.AsSpan(5));
                    await SendAllAsync(msg);
                    break;
                }
                case 12: break;                          // SASLFinal (server signature): AuthenticationOk follows
                default: throw new NotSupportedException($"PostgreSQL authentication method {code} is not supported");
            }
        }
    }

    static byte[] PasswordMessage(byte[] password)
    {
        var msg = new byte[5 + password.Length + 1];
        msg[0] = (byte)'p'; BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(1), msg.Length - 1);
        password.CopyTo(msg.AsSpan(5));
        return msg;
    }

    async Task PrepareAsync()
    {
        var buffer = new List<byte>();
        AppendParse(buffer, WorldStatement, "SELECT id, randomnumber FROM world WHERE id = $1", [Int4Oid]);
        AppendParse(buffer, FortunesStatement, "SELECT id, message FROM fortune", []);
        AppendParse(buffer, UpdateStatement,
            "UPDATE world SET randomnumber = new.rnum FROM (SELECT * FROM UNNEST($1::int[], $2::int[]) AS v(id, rnum) ORDER BY 1) AS new WHERE world.id = new.id",
            [Int4ArrayOid, Int4ArrayOid]);
        buffer.AddRange([(byte)'S', 0, 0, 0, 4]);
        await SendAllAsync(buffer.ToArray());
        while (true)
        {
            var (type, body) = await ReadMessageAsync();
            if (type == (byte)'E') throw new InvalidOperationException("prepare failed: " + ParseError(body));
            if (type == (byte)'Z') return;
        }
    }

    static void AppendParse(List<byte> buffer, string name, string sql, int[] paramOids)
    {
        var nameBytes = Encoding.ASCII.GetBytes(name); var sqlBytes = Encoding.UTF8.GetBytes(sql);
        var len = 4 + nameBytes.Length + 1 + sqlBytes.Length + 1 + 2 + 4 * paramOids.Length;
        var msg = new byte[1 + len]; var s = msg.AsSpan();
        s[0] = (byte)'P'; BinaryPrimitives.WriteInt32BigEndian(s[1..], len);
        var p = 5;
        nameBytes.CopyTo(s[p..]); p += nameBytes.Length; s[p++] = 0;
        sqlBytes.CopyTo(s[p..]); p += sqlBytes.Length; s[p++] = 0;
        BinaryPrimitives.WriteInt16BigEndian(s[p..], (short)paramOids.Length); p += 2;
        foreach (var oid in paramOids) { BinaryPrimitives.WriteInt32BigEndian(s[p..], oid); p += 4; }
        buffer.AddRange(msg);
    }

    async Task SendAllAsync(byte[] data)
    {
        var sent = 0;
        while (sent < data.Length) sent += await _socket.SendAsync(data.AsMemory(sent), SocketFlags.None);
    }

    async Task<(byte type, byte[] body)> ReadMessageAsync()
    {
        while (true)
        {
            if (TryGetMessage(_readBuffer.AsSpan(0, _readLength), out var type, out var body))
            {
                var copy = body.ToArray();
                var consumed = 5 + body.Length;
                _readLength -= consumed;
                if (_readLength > 0) Buffer.BlockCopy(_readBuffer, consumed, _readBuffer, 0, _readLength);
                return (type, copy);
            }
            var n = await _socket.ReceiveAsync(_readBuffer.AsMemory(_readLength), SocketFlags.None);
            if (n == 0) throw new EndOfStreamException("PostgreSQL closed the connection during startup");
            _readLength += n;
        }
    }
}
