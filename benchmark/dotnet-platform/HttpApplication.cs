using System.Buffers;
using System.Buffers.Text;
using System.IO.Pipelines;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using Microsoft.AspNetCore.Connections;

namespace DotnetBench.Platform;

/// <summary>
/// Minimal HTTP/1.1 server loop on top of Kestrel's socket transport: one PipeReader/PipeWriter
/// per connection, a span-based request-line parser, pipelining support (all complete requests in a
/// read are answered before a single flush) and pre-rendered response heads. This is the same
/// approach as the "platform" aspnetcore entries in TechEmpower: no HttpContext, no feature
/// collection, no header dictionaries.
/// </summary>
public sealed class HttpApplication(IDb db)
{
    public enum Route : byte { NotFound, Plaintext, Json, Db, Queries, Fortunes, Updates }

    static ReadOnlySpan<byte> PlaintextHead => "HTTP/1.1 200 OK\r\nServer: K\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n"u8;
    static ReadOnlySpan<byte> JsonHead => "HTTP/1.1 200 OK\r\nServer: K\r\nContent-Type: application/json\r\nContent-Length: 27\r\n"u8;
    static ReadOnlySpan<byte> JsonHeadNoLength => "HTTP/1.1 200 OK\r\nServer: K\r\nContent-Type: application/json\r\nContent-Length: "u8;
    static ReadOnlySpan<byte> HtmlHeadNoLength => "HTTP/1.1 200 OK\r\nServer: K\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "u8;
    static ReadOnlySpan<byte> NotFoundHead => "HTTP/1.1 404 Not Found\r\nServer: K\r\nContent-Length: 0\r\n"u8;
    static ReadOnlySpan<byte> HelloWorld => "Hello, World!"u8;

    static readonly JsonMessage HelloWorldMessage = new("Hello, World!");
    static readonly JsonWriterOptions JsonOptions = new() { SkipValidation = true };

    [ThreadStatic] static Utf8JsonWriter? t_jsonWriter;
    [ThreadStatic] static ArrayBufferWriter<byte>? t_buffer;

    // ---- connection loop -----------------------------------------------------------------------

    public async Task ProcessConnectionAsync(ConnectionContext connection)
    {
        var input = connection.Transport.Input;
        var output = connection.Transport.Output;
        try
        {
            while (true)
            {
                var read = await input.ReadAsync();
                var buffer = read.Buffer;

                while (TryParseRequest(ref buffer, out var route, out var count))
                    await HandleAsync(route, count, output);

                input.AdvanceTo(buffer.Start, buffer.End);

                var flush = await output.FlushAsync();
                if (read.IsCompleted || flush.IsCompleted) break;
            }
        }
        catch (Exception)
        {
            // connection reset / aborted by the peer: just drop it
        }
        finally
        {
            input.Complete();
            output.Complete();
            await connection.DisposeAsync();
        }
    }

    public ValueTask HandleAsync(Route route, int count, IBufferWriter<byte> output)
    {
        switch (route)
        {
            case Route.Plaintext: WriteResponse(output, PlaintextHead, HelloWorld); return default;
            case Route.Json: WriteJsonMessage(output); return default;
            case Route.Db: return DbAsync(output);
            case Route.Queries: return QueriesAsync(output, count);
            case Route.Fortunes: return FortunesAsync(output);
            case Route.Updates: return UpdatesAsync(output, count);
            default: WriteResponse(output, NotFoundHead, default); return default;
        }
    }

    async ValueTask DbAsync(IBufferWriter<byte> output)
    {
        var world = await db.LoadSingleWorld();
        WriteJson(output, world, AppJsonContext.Default.World);
    }

    async ValueTask QueriesAsync(IBufferWriter<byte> output, int count)
    {
        var worlds = await db.LoadMultipleWorlds(count);
        WriteJson(output, worlds, AppJsonContext.Default.WorldArray);
    }

    async ValueTask UpdatesAsync(IBufferWriter<byte> output, int count)
    {
        var worlds = await db.UpdateWorlds(count);
        WriteJson(output, worlds, AppJsonContext.Default.WorldArray);
    }

    async ValueTask FortunesAsync(IBufferWriter<byte> output)
    {
        var fortunes = await db.LoadFortunes();
        var buffer = GetBuffer();
        FortunesRenderer.Render(buffer, fortunes);
        WriteResponseWithLength(output, HtmlHeadNoLength, buffer.WrittenSpan);
    }

    // ---- request parsing -----------------------------------------------------------------------

    /// <summary>Consumes one complete request (through the blank line) from the front of <paramref name="buffer"/>.</summary>
    static bool TryParseRequest(ref ReadOnlySequence<byte> buffer, out Route route, out int count)
    {
        route = Route.NotFound;
        count = 1;
        if (buffer.IsEmpty) return false;

        if (buffer.IsSingleSegment)
        {
            var span = buffer.FirstSpan;
            var end = span.IndexOf("\r\n\r\n"u8);
            if (end < 0) return false;
            ParseRequestLine(span[..end], out route, out count);
            buffer = buffer.Slice(end + 4);
            return true;
        }

        var reader = new SequenceReader<byte>(buffer);
        if (!reader.TryReadTo(out ReadOnlySequence<byte> head, "\r\n\r\n"u8, advancePastDelimiter: true)) return false;
        ParseRequestLine(head.IsSingleSegment ? head.FirstSpan : head.ToArray(), out route, out count);
        buffer = buffer.Slice(reader.Position);
        return true;
    }

    /// <summary>Span variant for the raw-socket loop: one complete request from the front of <paramref name="data"/>.</summary>
    public static bool TryParseRequest(ReadOnlySpan<byte> data, out int consumed, out Route route, out int count)
    {
        var end = data.IndexOf("\r\n\r\n"u8);
        if (end < 0) { consumed = 0; route = Route.NotFound; count = 1; return false; }
        ParseRequestLine(data[..end], out route, out count);
        consumed = end + 4;
        return true;
    }

    static void ParseRequestLine(ReadOnlySpan<byte> head, out Route route, out int count)
    {
        route = Route.NotFound;
        count = 1;

        // "GET /path?query HTTP/1.1"
        var methodEnd = head.IndexOf((byte)' ');
        if (methodEnd < 0) return;
        var target = head[(methodEnd + 1)..];
        var targetEnd = target.IndexOfAny((byte)' ', (byte)'\r');
        if (targetEnd >= 0) target = target[..targetEnd];

        var q = target.IndexOf((byte)'?');
        var path = q < 0 ? target : target[..q];
        var query = q < 0 ? default : target[(q + 1)..];

        if (path.SequenceEqual("/plaintext"u8)) route = Route.Plaintext;
        else if (path.SequenceEqual("/json"u8)) route = Route.Json;
        else if (path.SequenceEqual("/db"u8)) route = Route.Db;
        else if (path.SequenceEqual("/fortunes"u8)) route = Route.Fortunes;
        else if (path.SequenceEqual("/queries"u8)) { route = Route.Queries; count = ParseQueryCount(query); }
        else if (path.SequenceEqual("/updates"u8)) { route = Route.Updates; count = ParseQueryCount(query); }
    }

    /// <summary>Mirror of the Rust parse_params: missing/invalid → 1, then clamp to 1..500.</summary>
    static int ParseQueryCount(ReadOnlySpan<byte> query)
    {
        while (!query.IsEmpty)
        {
            var amp = query.IndexOf((byte)'&');
            var segment = amp < 0 ? query : query[..amp];
            if (segment.Length >= 2 && segment[0] == (byte)'q' && segment[1] == (byte)'=')
            {
                var value = segment[2..];
                if (!Utf8Parser.TryParse(value, out int n, out var consumed) || consumed != value.Length) return 1;
                return Math.Clamp(n, 1, 500);
            }
            if (amp < 0) break;
            query = query[(amp + 1)..];
        }
        return 1;
    }

    // ---- response writing ----------------------------------------------------------------------

    static void WriteResponse(IBufferWriter<byte> output, ReadOnlySpan<byte> head, ReadOnlySpan<byte> body)
    {
        var date = DateHeader.Bytes;
        var span = output.GetSpan(head.Length + date.Length + body.Length);
        head.CopyTo(span);
        date.CopyTo(span[head.Length..]);
        body.CopyTo(span[(head.Length + date.Length)..]);
        output.Advance(head.Length + date.Length + body.Length);
    }

    static void WriteResponseWithLength(IBufferWriter<byte> output, ReadOnlySpan<byte> headNoLength, ReadOnlySpan<byte> body)
    {
        var date = DateHeader.Bytes;
        var span = output.GetSpan(headNoLength.Length + 12 + date.Length + body.Length);
        headNoLength.CopyTo(span);
        var pos = headNoLength.Length;
        Utf8Formatter.TryFormat(body.Length, span[pos..], out var digits);
        pos += digits;
        span[pos++] = (byte)'\r';
        span[pos++] = (byte)'\n';
        date.CopyTo(span[pos..]);
        pos += date.Length;
        body.CopyTo(span[pos..]);
        output.Advance(pos + body.Length);
    }

    static void WriteJsonMessage(IBufferWriter<byte> output)
    {
        WriteResponse(output, JsonHead, default);
        var writer = GetJsonWriter(output);
        JsonSerializer.Serialize(writer, HelloWorldMessage, AppJsonContext.Default.JsonMessage);
        writer.Flush();
    }

    static void WriteJson<T>(IBufferWriter<byte> output, T value, JsonTypeInfo<T> typeInfo)
    {
        var buffer = GetBuffer();
        var writer = GetJsonWriter(buffer);
        JsonSerializer.Serialize(writer, value, typeInfo);
        writer.Flush();
        WriteResponseWithLength(output, JsonHeadNoLength, buffer.WrittenSpan);
    }

    static Utf8JsonWriter GetJsonWriter(IBufferWriter<byte> output)
    {
        var writer = t_jsonWriter;
        if (writer is null) t_jsonWriter = writer = new Utf8JsonWriter(output, JsonOptions);
        else writer.Reset(output);
        return writer;
    }

    static ArrayBufferWriter<byte> GetBuffer()
    {
        var buffer = t_buffer;
        if (buffer is null) t_buffer = buffer = new ArrayBufferWriter<byte>(32 * 1024);
        else buffer.ResetWrittenCount();
        return buffer;
    }
}
