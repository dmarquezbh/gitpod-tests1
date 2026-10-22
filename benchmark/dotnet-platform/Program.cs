using System.Net;
using DotnetBench;
using DotnetBench.Platform;
using DotnetBench.Platform.Pg;
using Microsoft.AspNetCore.Server.Kestrel.Transport.Sockets;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Npgsql;

var port = int.TryParse(Environment.GetEnvironmentVariable("PORT"), out var p) ? p : 8081;
var inlineCompletions = Environment.GetEnvironmentVariable("DOTNET_SYSTEM_NET_SOCKETS_INLINE_COMPLETIONS") == "1";

var connString = Environment.GetEnvironmentVariable("POSTGRES_CONNECTION")
    ?? "Server=127.0.0.1;Port=5432;Database=hello_world;User Id=benchmarkdbuser;Password=benchmarkdbpass;"
     + "Multiplexing=true;Write Coalescing Buffer Threshold Bytes=1000;"
     + "Maximum Pool Size=" + (Environment.GetEnvironmentVariable("POSTGRES_MAX_POOL_SIZE") ?? "4") + ";" // per data source
     + "Max Auto Prepare=16;Auto Prepare Min Usages=1;No Reset On Close=true";

var shards = int.TryParse(Environment.GetEnvironmentVariable("POSTGRES_DATA_SOURCES"), out var ds) ? ds : 1;
var driver = Environment.GetEnvironmentVariable("DB_DRIVER") ?? "npgsql";
IDb db = driver == "raw"
    ? await RawDb.ConnectAsync("127.0.0.1", 5432, "benchmarkdbuser", "benchmarkdbpass", "hello_world",
        int.TryParse(Environment.GetEnvironmentVariable("POSTGRES_RAW_CONNECTIONS"), out var rc) ? rc : Environment.ProcessorCount)
    : new Db(connString, shards);
var app = new HttpApplication(db);

var httpTransport = Environment.GetEnvironmentVariable("HTTP_TRANSPORT") ?? "kestrel-sockets";
if (httpTransport == "raw")
{
    DateHeader.Start();
    Console.WriteLine($"started dotnet platform server on port {port} (http transport: raw sockets, db driver: {driver}, inline completions: {inlineCompletions}, cpus: {Environment.ProcessorCount}, server GC: {System.Runtime.GCSettings.IsServerGC}).");
    await new RawSocketServer(app).RunAsync(port);
    return;
}

var transportOptions = new SocketTransportOptions
{
    Backlog = 4096,
    WaitForDataBeforeAllocatingBuffer = false,
    UnsafePreferInlineScheduling = inlineCompletions,
};
if (int.TryParse(Environment.GetEnvironmentVariable("KESTREL_IO_QUEUE_COUNT"), out var ioQueues))
    transportOptions.IOQueueCount = ioQueues;

var transport = new SocketTransportFactory(Options.Create(transportOptions), NullLoggerFactory.Instance);
var listener = await transport.BindAsync(new IPEndPoint(IPAddress.Any, port));

DateHeader.Start();
Console.WriteLine($"started dotnet platform server on port {port} (http transport: kestrel sockets, db driver: {driver}, inline completions: {inlineCompletions}, cpus: {Environment.ProcessorCount}, server GC: {System.Runtime.GCSettings.IsServerGC}).");

while (true)
{
    var connection = await listener.AcceptAsync();
    if (connection is null) break;
    _ = app.ProcessConnectionAsync(connection);
}
