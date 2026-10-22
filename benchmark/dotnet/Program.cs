using DotnetBench;
using DotnetBench.Platform.Pg;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Npgsql;

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();

var port = int.TryParse(Environment.GetEnvironmentVariable("PORT"), out var p) ? p : 8080;
var inlineCompletions = Environment.GetEnvironmentVariable("DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS") == "1";

builder.WebHost.UseKestrel(o =>
{
    o.AddServerHeader = true; // "Server: Kestrel" (the suite requires Server + Date headers)
    o.ConfigureEndpointDefaults(e => e.Protocols = HttpProtocols.Http1);
    o.ListenAnyIP(port);
});
builder.WebHost.UseSockets(o =>
{
    o.Backlog = 4096;
    o.WaitForDataBeforeAllocatingBuffer = false;
    o.UnsafePreferInlineScheduling = inlineCompletions;
    if (int.TryParse(Environment.GetEnvironmentVariable("KESTREL_IO_QUEUE_COUNT"), out var ioQueues))
        o.IOQueueCount = ioQueues; // 0 = dispatch continuations straight to the thread pool
});

var connString = Environment.GetEnvironmentVariable("POSTGRES_CONNECTION")
    ?? "Server=127.0.0.1;Port=5432;Database=hello_world;User Id=benchmarkdbuser;Password=benchmarkdbpass;"
     + "Multiplexing=true;Write Coalescing Buffer Threshold Bytes=1000;"
     + "Maximum Pool Size=" + (Environment.GetEnvironmentVariable("POSTGRES_MAX_POOL_SIZE") ?? "4") + ";" // per data source
     + "Max Auto Prepare=16;Auto Prepare Min Usages=1;No Reset On Close=true";

var shards = int.TryParse(Environment.GetEnvironmentVariable("POSTGRES_DATA_SOURCES"), out var ds) ? ds : 1;
var driver = Environment.GetEnvironmentVariable("DB_DRIVER") ?? "npgsql";
IDb db = driver == "raw"
    ? await RawDb.ConnectAsync("127.0.0.1", 5432, "benchmarkdbuser", "benchmarkdbpass", "hello_world",
        int.TryParse(Environment.GetEnvironmentVariable("POSTGRES_RAW_CONNECTIONS"), out var rc) ? rc : Environment.ProcessorCount,
        int.TryParse(Environment.GetEnvironmentVariable("POSTGRES_RAW_HEAVY_CONNECTIONS"), out var hc) ? hc : 0)
    : new Db(connString, shards);
var handlers = new Handlers(db);

var app = builder.Build();
((IApplicationBuilder)app).Run(handlers.Handle);

Console.WriteLine($"started dotnet server on port {port} (db driver: {driver}, inline completions: {inlineCompletions}, cpus: {Environment.ProcessorCount}, server GC: {System.Runtime.GCSettings.IsServerGC}).");
app.Run();
