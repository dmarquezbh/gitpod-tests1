using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace DotnetBench.Platform.Pg;

/// <summary>Pure PostgreSQL wire-protocol helpers shared by the async client and the event-loop client.</summary>
public static class PgProtocol
{
    public const int Int4Oid = 23;
    public const int Int4ArrayOid = 1007;

    public const string WorldStatement = "w";
    public const string FortunesStatement = "f";
    public const string UpdateStatement = "u";

    public static byte[] StartupMessage(string user, string database)
    {
        var parameters = Encoding.UTF8.GetBytes($"user\0{user}\0database\0{database}\0client_encoding\0UTF8\0\0");
        var msg = new byte[8 + parameters.Length];
        BinaryPrimitives.WriteInt32BigEndian(msg, msg.Length);
        BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(4), 196608);   // protocol 3.0
        parameters.CopyTo(msg, 8);
        return msg;
    }

    public static byte[] PasswordMessage(byte[] password)
    {
        var msg = new byte[5 + password.Length + 1];
        msg[0] = (byte)'p'; BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(1), msg.Length - 1);
        password.CopyTo(msg.AsSpan(5));
        return msg;
    }

    public static byte[] SaslInitialResponse(byte[] clientFirst)
    {
        var mech = "SCRAM-SHA-256\0"u8;
        var msg = new byte[5 + mech.Length + 4 + clientFirst.Length];
        msg[0] = (byte)'p'; BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(1), msg.Length - 1);
        mech.CopyTo(msg.AsSpan(5));
        BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(5 + mech.Length), clientFirst.Length);
        clientFirst.CopyTo(msg.AsSpan(9 + mech.Length));
        return msg;
    }

    public static byte[] SaslResponse(byte[] clientFinal)
    {
        var msg = new byte[5 + clientFinal.Length];
        msg[0] = (byte)'p'; BinaryPrimitives.WriteInt32BigEndian(msg.AsSpan(1), msg.Length - 1);
        clientFinal.CopyTo(msg.AsSpan(5));
        return msg;
    }

    /// <summary>Parse messages for the three prepared statements, followed by Sync.</summary>
    public static byte[] PrepareBatch()
    {
        var buffer = new List<byte>();
        AppendParse(buffer, WorldStatement, "SELECT id, randomnumber FROM world WHERE id = $1", [Int4Oid]);
        AppendParse(buffer, FortunesStatement, "SELECT id, message FROM fortune", []);
        AppendParse(buffer, UpdateStatement,
            "UPDATE world SET randomnumber = new.rnum FROM (SELECT * FROM UNNEST($1::int[], $2::int[]) AS v(id, rnum) ORDER BY 1) AS new WHERE world.id = new.id",
            [Int4ArrayOid, Int4ArrayOid]);
        buffer.AddRange([(byte)'S', 0, 0, 0, 4]);
        return buffer.ToArray();
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

    public static bool TryGetMessage(ReadOnlySpan<byte> data, out byte type, out ReadOnlySpan<byte> body)
    {
        type = 0; body = default;
        if (data.Length < 5) return false;
        var length = BinaryPrimitives.ReadInt32BigEndian(data[1..]);   // includes the 4 length bytes
        if (data.Length < 1 + length) return false;
        type = data[0];
        body = data.Slice(5, length - 4);
        return true;
    }

    public static string ParseError(ReadOnlySpan<byte> body)
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

    public static int ReadInt4Column(ReadOnlySpan<byte> row, ref int offset)
    {
        var length = BinaryPrimitives.ReadInt32BigEndian(row[offset..]);
        var value = BinaryPrimitives.ReadInt32BigEndian(row[(offset + 4)..]);
        offset += 4 + length;
        return value;
    }

    public static string ReadTextColumn(ReadOnlySpan<byte> row, ref int offset)
    {
        var length = BinaryPrimitives.ReadInt32BigEndian(row[offset..]);
        var value = Encoding.UTF8.GetString(row.Slice(offset + 4, length));
        offset += 4 + length;
        return value;
    }
}

/// <summary>Authentication state machine (AuthenticationOk, cleartext, MD5, SCRAM-SHA-256) driven by the
/// messages received after the StartupMessage; returns the bytes to send back, if any.</summary>
public sealed class PgAuthenticator(string user, string password)
{
    string? _clientFirstBare, _clientNonce;

    /// <returns>Bytes to send, or null. <paramref name="ready"/> is true once ReadyForQuery arrived.</returns>
    public byte[]? Handle(byte type, ReadOnlySpan<byte> body, out bool ready)
    {
        ready = false;
        if (type == (byte)'E') throw new InvalidOperationException("PostgreSQL error during startup: " + PgProtocol.ParseError(body));
        if (type == (byte)'Z') { ready = true; return null; }
        if (type != (byte)'R') return null;              // ParameterStatus / BackendKeyData / Notice

        var code = BinaryPrimitives.ReadInt32BigEndian(body);
        switch (code)
        {
            case 0: return null;                           // AuthenticationOk
            case 3: return PgProtocol.PasswordMessage(Encoding.UTF8.GetBytes(password));
            case 5:
            {
                var salt = body.Slice(4, 4).ToArray();
                var inner = Convert.ToHexStringLower(MD5.HashData(Encoding.UTF8.GetBytes(password + user)));
                var outer = Convert.ToHexStringLower(MD5.HashData([.. Encoding.ASCII.GetBytes(inner), .. salt]));
                return PgProtocol.PasswordMessage(Encoding.ASCII.GetBytes("md5" + outer));
            }
            case 10:                                       // SASL: offer SCRAM-SHA-256
                _clientNonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));
                _clientFirstBare = $"n=,r={_clientNonce}";
                return PgProtocol.SaslInitialResponse(Encoding.UTF8.GetBytes("n,," + _clientFirstBare));
            case 11:                                       // SASLContinue: server-first-message
            {
                var serverFirst = Encoding.UTF8.GetString(body[4..]);
                string? nonce = null, saltB64 = null; var iterations = 0;
                foreach (var part in serverFirst.Split(','))
                {
                    if (part.StartsWith("r=")) nonce = part[2..];
                    else if (part.StartsWith("s=")) saltB64 = part[2..];
                    else if (part.StartsWith("i=")) iterations = int.Parse(part[2..]);
                }
                if (nonce is null || saltB64 is null || !nonce.StartsWith(_clientNonce!)) throw new InvalidOperationException("bad SCRAM server-first-message");
                var saltedPassword = Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), Convert.FromBase64String(saltB64), iterations, HashAlgorithmName.SHA256, 32);
                var clientKey = HMACSHA256.HashData(saltedPassword, "Client Key"u8);
                var storedKey = SHA256.HashData(clientKey);
                var clientFinalNoProof = $"c=biws,r={nonce}";
                var authMessage = Encoding.UTF8.GetBytes($"{_clientFirstBare},{serverFirst},{clientFinalNoProof}");
                var clientSignature = HMACSHA256.HashData(storedKey, authMessage);
                var proof = new byte[32];
                for (var i = 0; i < 32; i++) proof[i] = (byte)(clientKey[i] ^ clientSignature[i]);
                return PgProtocol.SaslResponse(Encoding.UTF8.GetBytes($"{clientFinalNoProof},p={Convert.ToBase64String(proof)}"));
            }
            case 12: return null;                          // SASLFinal; AuthenticationOk follows
            default: throw new NotSupportedException($"PostgreSQL authentication method {code} is not supported");
        }
    }
}

/// <summary>Growable buffer with the Bind/Execute/Sync encoders for the three prepared statements.</summary>
public sealed class PgWriteBuffer
{
    public byte[] Buffer = new byte[64 * 1024];
    public int Length;

    public void Reset() => Length = 0;

    void Ensure(int bytes)
    {
        if (Length + bytes > Buffer.Length) Array.Resize(ref Buffer, Math.Max(Buffer.Length * 2, Length + bytes));
    }

    public void WriteBindWorld(int id)
    {
        // Bind: portal "" + statement "w" + 1 param format (binary) + 1 param (int4) + 1 result format (binary); Execute: portal "", no limit
        const int bindLen = 4 + 1 + 2 + 2 + 2 + 2 + (4 + 4) + 2 + 2;
        Ensure(1 + bindLen + 10);
        var s = Buffer.AsSpan(Length);
        s[0] = (byte)'B'; BinaryPrimitives.WriteInt32BigEndian(s[1..], bindLen);
        s[5] = 0;
        s[6] = (byte)'w'; s[7] = 0;
        BinaryPrimitives.WriteInt16BigEndian(s[8..], 1); BinaryPrimitives.WriteInt16BigEndian(s[10..], 1);
        BinaryPrimitives.WriteInt16BigEndian(s[12..], 1);
        BinaryPrimitives.WriteInt32BigEndian(s[14..], 4); BinaryPrimitives.WriteInt32BigEndian(s[18..], id);
        BinaryPrimitives.WriteInt16BigEndian(s[22..], 1); BinaryPrimitives.WriteInt16BigEndian(s[24..], 1);
        WriteExecute(s[26..]);
        Length += 26 + 10;
    }

    public void WriteBindNoParams(string statement)
    {
        var bindLen = 4 + 1 + (statement.Length + 1) + 2 + 2 + 2 + 2;
        Ensure(1 + bindLen + 10);
        var s = Buffer.AsSpan(Length);
        s[0] = (byte)'B'; BinaryPrimitives.WriteInt32BigEndian(s[1..], bindLen);
        s[5] = 0;
        var p = 6;
        p += Encoding.ASCII.GetBytes(statement, s[p..]); s[p++] = 0;
        BinaryPrimitives.WriteInt16BigEndian(s[p..], 0); p += 2;
        BinaryPrimitives.WriteInt16BigEndian(s[p..], 0); p += 2;
        BinaryPrimitives.WriteInt16BigEndian(s[p..], 1); p += 2; BinaryPrimitives.WriteInt16BigEndian(s[p..], 1); p += 2;
        WriteExecute(s[p..]);
        Length += p + 10;
    }

    public void WriteBindUpdate(int[] ids, int[] numbers)
    {
        var arrayLen = 20 + ids.Length * 8;
        var bindLen = 4 + 1 + 2 + 2 + 2 + 2 + 2 * (4 + arrayLen) + 2 + 2;
        Ensure(1 + bindLen + 10);
        var s = Buffer.AsSpan(Length);
        s[0] = (byte)'B'; BinaryPrimitives.WriteInt32BigEndian(s[1..], bindLen);
        s[5] = 0;
        s[6] = (byte)'u'; s[7] = 0;
        BinaryPrimitives.WriteInt16BigEndian(s[8..], 1); BinaryPrimitives.WriteInt16BigEndian(s[10..], 1);
        BinaryPrimitives.WriteInt16BigEndian(s[12..], 2);
        var p = 14;
        p += WriteInt4Array(s[p..], ids);
        p += WriteInt4Array(s[p..], numbers);
        BinaryPrimitives.WriteInt16BigEndian(s[p..], 1); p += 2; BinaryPrimitives.WriteInt16BigEndian(s[p..], 1); p += 2;
        WriteExecute(s[p..]);
        Length += p + 10;
    }

    static int WriteInt4Array(Span<byte> s, int[] values)
    {
        BinaryPrimitives.WriteInt32BigEndian(s, 20 + values.Length * 8);
        BinaryPrimitives.WriteInt32BigEndian(s[4..], 1);
        BinaryPrimitives.WriteInt32BigEndian(s[8..], 0);
        BinaryPrimitives.WriteInt32BigEndian(s[12..], PgProtocol.Int4Oid);
        BinaryPrimitives.WriteInt32BigEndian(s[16..], values.Length);
        BinaryPrimitives.WriteInt32BigEndian(s[20..], 1);
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

    public void WriteSync()
    {
        Ensure(5);
        var s = Buffer.AsSpan(Length);
        s[0] = (byte)'S'; BinaryPrimitives.WriteInt32BigEndian(s[1..], 4);
        Length += 5;
    }
}
