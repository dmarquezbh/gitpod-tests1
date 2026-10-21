using System.Data;
using Npgsql;

namespace DotnetBench;

/// <summary>Raw Npgsql data access, mirroring the tokio-postgres variant of the Rust app
/// (same SQL, same single-UPDATE-with-UNNEST strategy, same pipelining of the N selects).</summary>
public sealed class Db(NpgsqlDataSource dataSource)
{
    const string SelectWorldById = "SELECT id, randomnumber FROM world WHERE id = $1 LIMIT 1";
    const string SelectAllFortunes = "SELECT id, message FROM fortune";
    const string UpdateWorldsSql =
        "UPDATE world SET randomnumber = new.rnum FROM (SELECT * FROM UNNEST($1::int[], $2::int[]) AS v(id, rnum) ORDER BY 1) AS new WHERE world.id = new.id";

    static int RandomId() => Random.Shared.Next(1, 10_001);

    public async Task<World> LoadSingleWorld()
    {
        await using var cmd = dataSource.CreateCommand(SelectWorldById);
        cmd.Parameters.Add(new NpgsqlParameter<int> { TypedValue = RandomId() });
        await using var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SingleRow);
        await reader.ReadAsync();
        return new World(reader.GetInt32(0), reader.GetInt32(1));
    }

    /// <summary>N separate SELECT statements sent as one pipelined batch (one round trip).</summary>
    public async Task<World[]> LoadMultipleWorlds(int count)
    {
        var worlds = new World[count];
        await using var batch = dataSource.CreateBatch();
        var cmds = batch.BatchCommands;
        for (var i = 0; i < count; i++)
        {
            var bc = new NpgsqlBatchCommand(SelectWorldById);
            bc.Parameters.Add(new NpgsqlParameter<int> { TypedValue = RandomId() });
            cmds.Add(bc);
        }

        await using var reader = await batch.ExecuteReaderAsync();
        for (var i = 0; i < count; i++)
        {
            await reader.ReadAsync();
            worlds[i] = new World(reader.GetInt32(0), reader.GetInt32(1));
            await reader.NextResultAsync();
        }
        return worlds;
    }

    public async Task<World[]> UpdateWorlds(int count)
    {
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

        await using var cmd = dataSource.CreateCommand(UpdateWorldsSql);
        cmd.Parameters.Add(new NpgsqlParameter<int[]> { TypedValue = ids });
        cmd.Parameters.Add(new NpgsqlParameter<int[]> { TypedValue = numbers });
        await cmd.ExecuteNonQueryAsync();
        return worlds;
    }

    public async Task<List<Fortune>> LoadFortunes()
    {
        var fortunes = new List<Fortune>(16) { new(0, "Additional fortune added at request time.") };
        await using var cmd = dataSource.CreateCommand(SelectAllFortunes);
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            fortunes.Add(new Fortune(reader.GetInt32(0), reader.GetString(1)));

        // Rust sorts with String::cmp (byte-wise); ordinal is the equivalent here.
        fortunes.Sort(static (a, b) => string.CompareOrdinal(a.Message, b.Message));
        return fortunes;
    }
}
