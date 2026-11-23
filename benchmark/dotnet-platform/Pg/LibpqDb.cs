using System.Runtime.InteropServices;
using DotnetBench.Platform.EventLoop;

namespace DotnetBench.Platform.Pg;

/// <summary>libpq (the C client) via P/Invoke as the event-loop database driver: prepared
/// statements, text arrays, pipeline mode. Parsing of results happens in libpq, not in managed
/// row callbacks; the win is largest for the multi-row tests.</summary>
public sealed unsafe class LibpqDb : IDisposable
{
    [DllImport("libpq.so.5")] static extern IntPtr PQconnectdb(byte* conninfo);
    [DllImport("libpq.so.5")] static extern int PQstatus(IntPtr conn);
    [DllImport("libpq.so.5")] static extern byte* PQerrorMessage(IntPtr conn);
    [DllImport("libpq.so.5")] static extern IntPtr PQprepare(IntPtr conn, byte* stmtName, byte* sql, int nParams, uint* paramTypes);
    [DllImport("libpq.so.5")] static extern IntPtr PQexecPrepared(IntPtr conn, byte* stmtName, int nParams, byte** paramValues, int* paramLengths, int* paramFormats, int resultFormat);
    [DllImport("libpq.so.5")] static extern int PQsendQueryPrepared(IntPtr conn, byte* stmtName, int nParams, byte** paramValues, int* paramLengths, int* paramFormats, int resultFormat);
    [DllImport("libpq.so.5")] static extern IntPtr PQgetResult(IntPtr conn);
    [DllImport("libpq.so.5")] static extern int PQconsumeInput(IntPtr conn);
    [DllImport("libpq.so.5")] static extern int PQenterPipelineMode(IntPtr conn);
    [DllImport("libpq.so.5")] static extern int PQexitPipelineMode(IntPtr conn);
    [DllImport("libpq.so.5")] static extern int PQpipelineSync(IntPtr conn);
    [DllImport("libpq.so.5")] static extern int PQresultStatus(IntPtr res);
    [DllImport("libpq.so.5")] static extern int PQntuples(IntPtr res);
    [DllImport("libpq.so.5")] static extern byte* PQgetvalue(IntPtr res, int row, int col);
    [DllImport("libpq.so.5")] static extern void PQclear(IntPtr res);
    [DllImport("libpq.so.5")] static extern void PQfinish(IntPtr conn);

    const int CommandOk = 1;
    const int TuplesOk = 2;
    const int Int4ArrayOid = 1007;

    static byte* s_a, s_u, s_f, s_sqlA, s_sqlU;

    readonly IntPtr _conn;

    public LibpqDb()
    {
        byte* ci = stackalloc byte[512];
        var host = Environment.GetEnvironmentVariable("PG_HOST") ?? "127.0.0.1";
        var baseText = "host=" + host + " port=5432 user=benchmarkdbuser password=benchmarkdbpass dbname=hello_world";
        var opts = Environment.GetEnvironmentVariable("PG_OPTIONS");
        if (!string.IsNullOrEmpty(opts)) baseText += " options='" + opts + "'";
        var text = System.Text.Encoding.UTF8.GetBytes(baseText);
        text.CopyTo(new Span<byte>(ci, text.Length)); ci[text.Length] = 0;
        _conn = PQconnectdb(ci);
        if (PQstatus(_conn) != 0) throw new InvalidOperationException("libpq connect: " + Marshal.PtrToStringUTF8((IntPtr)PQerrorMessage(_conn)));

        s_a = Name("a"); s_u = Name("u"); s_f = Name("f");
        s_sqlA = Sql("SELECT w.id, w.randomnumber FROM unnest($1::int[]) WITH ORDINALITY AS u(id, ord) JOIN world w ON w.id = u.id ORDER BY u.ord");
        s_sqlU = Sql("UPDATE world SET randomnumber = n.rn FROM (SELECT * FROM UNNEST($1::int[], $2::int[]) AS v(id, rn) ORDER BY 1) AS n WHERE world.id = n.id");

        uint oneArray = Int4ArrayOid;
        Prepare(s_a, s_sqlA, 1, &oneArray);
        uint* two = stackalloc uint[2]; two[0] = Int4ArrayOid; two[1] = Int4ArrayOid;
        Prepare(s_u, s_sqlU, 2, two);
        Prepare(s_f, Sql("SELECT id, message FROM fortune"), 0, null);
    }

    static byte* Name(string s)
    {
        var p = (byte*)NativeMemory.Alloc((nuint)(s.Length + 1));
        for (var i = 0; i < s.Length; i++) p[i] = (byte)s[i];
        p[s.Length] = 0;
        return p;
    }
    static byte* Sql(string s) => Name(s);

    void Prepare(byte* name, byte* sql, int n, uint* types)
    {
        var res = PQprepare(_conn, name, sql, n, types);
        if (res == IntPtr.Zero || PQresultStatus(res) != CommandOk)
            throw new InvalidOperationException("libpq prepare: " + Marshal.PtrToStringUTF8((IntPtr)PQerrorMessage(_conn)));
        PQclear(res);
    }

    public void RunSingles(List<LoopOp> ops)
    {
        if (ops.Count == 0) return;
        Span<int> ids = ops.Count <= 512 ? stackalloc int[ops.Count] : new int[ops.Count];
        for (var i = 0; i < ops.Count; i++) ids[i] = ops[i].SingleId;
        byte* arr = stackalloc byte[2 + ops.Count * 6];
        var len = BuildArray(arr, ids);
        byte** parms = stackalloc byte*[1]; parms[0] = arr;
        var res = PQexecPrepared(_conn, s_a, 1, parms, null, null, 0);
        var ok = res != IntPtr.Zero && PQresultStatus(res) == TuplesOk && PQntuples(res) == ops.Count;
        if (ok)
        {
            for (var i = 0; i < ops.Count; i++)
            {
                ops[i].Single = new World(Atoi(PQgetvalue(res, i, 0)), Atoi(PQgetvalue(res, i, 1)));
                ops[i].Complete();
            }
            PQclear(res);
        }
        else
        {
            if (res != IntPtr.Zero) PQclear(res);
            foreach (var op in ops) op.Fail("libpq singles error");
        }
        ops.Clear();
    }

    public void RunHeavy(List<LoopOp> ops)
    {
        // bounded pipeline: C++ uses chunks of 8 and that keeps PostgreSQL latency low
        var chunk = 8;
        for (var start = 0; start < ops.Count; start += chunk)
        {
            var count = Math.Min(chunk, ops.Count - start);
            RunHeavyChunk(ops, start, count);
        }
        ops.Clear();
    }

    /// <summary>One read of the (read-only) fortunes table per event-loop round, fanned out to all
    /// waiting requests. This is batch reading, not a cross-request cache: the query still runs once
    /// per round against PostgreSQL.</summary>
    public void RunFortunes(List<LoopOp> ops)
    {
        if (ops.Count == 0) return;
        var res = PQexecPrepared(_conn, s_f, 0, null, null, null, 0);
        var ok = res != IntPtr.Zero && PQresultStatus(res) == TuplesOk;
        foreach (var op in ops)
        {
            if (ok) op.RenderFortunes(res);
            else op.Fail("libpq fortunes error");
        }
        if (res != IntPtr.Zero) PQclear(res);
        ops.Clear();
    }

    void RunHeavyChunk(List<LoopOp> ops, int start, int count)
    {
        PQenterPipelineMode(_conn);

        // One SQL statement for all /queries requests in this chunk: concatenated ids, ordered by
        // ordinality, then split by each request's count. Cuts parse/plan/execute overhead per request.
        var totalIds = 0;
        for (var i = start; i < start + count; i++)
            if (ops[i].Route == HttpApplication.Route.Queries) totalIds += ops[i].Count;
        var hasQueries = totalIds > 0;
        byte* combined = stackalloc byte[2 + totalIds * 6];
        if (hasQueries)
        {
            var pos = 0; combined[pos++] = (byte)'{';
            var first = true;
            for (var i = start; i < start + count; i++)
            {
                if (ops[i].Route != HttpApplication.Route.Queries) continue;
                var ids = ops[i].Ids!;
                for (var k = 0; k < ids.Length; k++)
                {
                    if (!first) combined[pos++] = (byte)',';
                    first = false;
                    var v = ids[k]; var q = 16; Span<byte> tmp = stackalloc byte[16];
                    while (v > 0) { tmp[--q] = (byte)('0' + v % 10); v /= 10; }
                    for (; q < 16; q++) combined[pos++] = tmp[q];
                }
            }
            combined[pos++] = (byte)'}';
            byte** p = stackalloc byte*[1]; p[0] = combined;
            PQsendQueryPrepared(_conn, s_a, 1, p, null, null, 0);
        }

        var store = new List<byte[]>(count * 2);
        for (var i = start; i < start + count; i++)
        {
            var op = ops[i];
            if (op.Route == HttpApplication.Route.Queries) continue;
            if (op.Route == HttpApplication.Route.Fortunes)
            {
                PQsendQueryPrepared(_conn, s_f, 0, null, null, null, 0);
                continue;
            }
            var a = ArrayLiteral(op.Ids!);
            store.Add(a);
            var b = ArrayLiteral(op.Numbers!);
            store.Add(b);
            fixed (byte* pa = a) fixed (byte* pb = b)
            {
                byte** p = stackalloc byte*[2]; p[0] = pa; p[1] = pb;
                PQsendQueryPrepared(_conn, s_u, 2, p, null, null, 0);
            }
        }
        PQpipelineSync(_conn);

        if (hasQueries)
        {
            var res = Next(_conn);
            var ok = res != IntPtr.Zero && PQresultStatus(res) == TuplesOk;
            var row = 0;
            for (var i = start; i < start + count; i++)
            {
                var op = ops[i];
                if (op.Route != HttpApplication.Route.Queries) continue;
                if (ok) op.RenderQueriesFromRows(res, row, op.Count);
                else op.Fail("libpq combined query error");
                row += op.Count;
            }
            if (res != IntPtr.Zero) PQclear(res);
        }

        for (var i = start; i < start + count; i++)
        {
            var op = ops[i];
            if (op.Route == HttpApplication.Route.Queries) continue;
            var res = Next(_conn);
            if (res == IntPtr.Zero) { op.Fail("libpq pipeline error"); continue; }
            if (op.Route == HttpApplication.Route.Fortunes) op.RenderFortunes(res);
            else { PQclear(res); op.Complete(); }
        }
        var sync = Next(_conn);
        if (sync != IntPtr.Zero) PQclear(sync);
        PQexitPipelineMode(_conn);
    }

    static byte[] ArrayLiteral(int[] values)
    {
        var bytes = new List<byte>(2 + values.Length * 6) { (byte)'{' };
        Span<byte> tmp = stackalloc byte[16];
        for (var i = 0; i < values.Length; i++)
        {
            if (i != 0) bytes.Add((byte)',');
            if (values[i] == 0) { bytes.Add((byte)'0'); continue; }
            var v = values[i]; var p = 16;
            while (v > 0) { tmp[--p] = (byte)('0' + v % 10); v /= 10; }
            for (; p < 16; p++) bytes.Add(tmp[p]);
        }
        bytes.Add((byte)'}');
        return bytes.ToArray();
    }

    static int BuildArray(byte* dst, Span<int> values)
    {
        var p = 0; dst[p++] = (byte)'{';
        Span<byte> tmp = stackalloc byte[16];
        for (var i = 0; i < values.Length; i++)
        {
            if (i != 0) dst[p++] = (byte)',';
            var v = values[i]; var q = 16;
            while (v > 0) { tmp[--q] = (byte)('0' + v % 10); v /= 10; }
            for (; q < 16; q++) dst[p++] = tmp[q];
        }
        dst[p++] = (byte)'}';
        return p;
    }

    public static int Atoi(byte* p)
    {
        var v = 0;
        while (*p >= (byte)'0' && *p <= (byte)'9') { v = v * 10 + (*p - (byte)'0'); p++; }
        return v;
    }

    static IntPtr Next(IntPtr conn)
    {
        while (true)
        {
            var res = PQgetResult(conn);
            if (res != IntPtr.Zero) return res;
            if (PQconsumeInput(conn) == 0) return IntPtr.Zero;
        }
    }

    public static int Rows(IntPtr res) => PQresultStatus(res) == TuplesOk ? PQntuples(res) : 0;
    public static byte* Value(IntPtr res, int row, int col) => PQgetvalue(res, row, col);

    public void Dispose() => PQfinish(_conn);
}
