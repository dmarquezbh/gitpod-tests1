namespace DotnetBench.Platform.Pg;

/// <summary>
/// IDb over the raw client: one PgConnection per shard, a thread sticks to one shard (with inline
/// socket completions that is one connection per IO thread, exactly the axum-pg layout: one
/// tokio-postgres connection per current-thread runtime).
/// </summary>
public sealed class RawDb : IDb
{
    readonly PgConnection[] _connections;
    static int s_next;
    [ThreadStatic] static PgConnection? t_connection;   // fallback for threads that read no connection
    [ThreadStatic] static int t_rotation;

    RawDb(PgConnection[] connections) => _connections = connections;

    public static async Task<RawDb> ConnectAsync(string host, int port, string user, string password, string database, int connections)
    {
        var all = new PgConnection[connections];
        for (var i = 0; i < connections; i++) all[i] = await PgConnection.ConnectAsync(host, port, user, password, database);
        return new RawDb(all);
    }

    PgConnection Connection
    {
        get
        {
            var local = PgConnection.LocalConnections;
            if (local is not null && local.Count > 0) return local[(t_rotation++ & 0x7fffffff) % local.Count];
            var c = t_connection;
            if (c is null) t_connection = c = _connections[(Interlocked.Increment(ref s_next) - 1) % _connections.Length];
            return c;
        }
    }

    static int RandomId() => Random.Shared.Next(1, 10_001);

    public ValueTask<World> LoadSingleWorld() => Connection.QueryWorld(RandomId());

    public ValueTask<World[]> LoadMultipleWorlds(int count)
    {
        Span<int> ids = count <= 512 ? stackalloc int[count] : new int[count];
        for (var i = 0; i < count; i++) ids[i] = RandomId();
        return Connection.QueryWorlds(ids);
    }

    public async ValueTask<World[]> UpdateWorlds(int count)
    {
        var connection = Connection;
        var worlds = await LoadMultipleWorlds(count);
        var ids = new int[count];
        var numbers = new int[count];
        for (var i = 0; i < count; i++)
        {
            var w = worlds[i] with { RandomNumber = RandomId() };
            worlds[i] = w;
            ids[i] = w.Id;
            numbers[i] = w.RandomNumber;
        }
        await connection.UpdateWorlds(ids, numbers);
        return worlds;
    }

    public async ValueTask<List<Fortune>> LoadFortunes()
    {
        var fortunes = await Connection.QueryFortunes();
        fortunes.Sort(static (a, b) => string.CompareOrdinal(a.Message, b.Message));
        return fortunes;
    }
}
