using System.Buffers;
using System.Buffers.Text;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using Microsoft.Extensions.Primitives;

namespace DotnetBench;

/// <summary>
/// Single terminal middleware: dispatches on the raw path, no routing/DI/model-binding per request.
/// Bodies are produced into per-thread reusable buffers so every response carries a Content-Length
/// (no chunked framing), then copied once into Kestrel's output pipe.
/// </summary>
public sealed class Handlers(Db db)
{
    static readonly StringValues TextPlain = "text/plain";
    static readonly StringValues ApplicationJson = "application/json";
    static readonly StringValues TextHtmlUtf8 = "text/html; charset=utf-8";

    static readonly byte[] HelloWorldBytes = "Hello, World!"u8.ToArray();
    static readonly JsonMessage HelloWorldMessage = new("Hello, World!");

    static readonly JsonWriterOptions JsonOptions = new() { SkipValidation = true };

    [ThreadStatic] static Utf8JsonWriter? t_jsonWriter;
    [ThreadStatic] static ArrayBufferWriter<byte>? t_buffer;

    public Task Handle(HttpContext ctx)
    {
        switch (ctx.Request.Path.Value)
        {
            case "/plaintext": return Plaintext(ctx);
            case "/json": return Json(ctx);
            case "/db": return DbSingle(ctx);
            case "/queries": return Queries(ctx);
            case "/fortunes": return Fortunes(ctx);
            case "/updates": return Updates(ctx);
            default:
                ctx.Response.StatusCode = StatusCodes.Status404NotFound;
                return Task.CompletedTask;
        }
    }

    static Task Plaintext(HttpContext ctx)
    {
        var response = ctx.Response;
        response.Headers.ContentType = TextPlain;
        response.ContentLength = HelloWorldBytes.Length;
        response.BodyWriter.Write(HelloWorldBytes);
        return Task.CompletedTask;
    }

    static Task Json(HttpContext ctx)
    {
        var response = ctx.Response;
        response.Headers.ContentType = ApplicationJson;
        response.ContentLength = 27; // {"message":"Hello, World!"}

        var writer = GetJsonWriter(response.BodyWriter);
        JsonSerializer.Serialize(writer, HelloWorldMessage, AppJsonContext.Default.JsonMessage);
        writer.Flush();
        return Task.CompletedTask;
    }

    async Task DbSingle(HttpContext ctx)
    {
        var world = await db.LoadSingleWorld();
        WriteJson(ctx, world, AppJsonContext.Default.World);
    }

    async Task Queries(HttpContext ctx)
    {
        var count = ParseQueryCount(ctx.Request.QueryString.Value);
        var worlds = await db.LoadMultipleWorlds(count);
        WriteJson(ctx, worlds, AppJsonContext.Default.WorldArray);
    }

    async Task Updates(HttpContext ctx)
    {
        var count = ParseQueryCount(ctx.Request.QueryString.Value);
        var worlds = await db.UpdateWorlds(count);
        WriteJson(ctx, worlds, AppJsonContext.Default.WorldArray);
    }

    async Task Fortunes(HttpContext ctx)
    {
        var fortunes = await db.LoadFortunes();

        var buffer = GetBuffer();
        FortunesRenderer.Render(buffer, fortunes);

        var response = ctx.Response;
        response.Headers.ContentType = TextHtmlUtf8;
        response.ContentLength = buffer.WrittenCount;
        response.BodyWriter.Write(buffer.WrittenSpan);
    }

    // ---- helpers ------------------------------------------------------------------------------

    /// <summary>Mirror of the Rust parse_params: missing/invalid → 1, then clamp to 1..500.</summary>
    internal static int ParseQueryCount(string? queryString)
    {
        if (string.IsNullOrEmpty(queryString) || queryString.Length < 3) return 1;

        var span = queryString.AsSpan(1); // skip '?'
        while (!span.IsEmpty)
        {
            var amp = span.IndexOf('&');
            var segment = amp < 0 ? span : span[..amp];
            if (segment.Length >= 2 && segment[0] == 'q' && segment[1] == '=')
            {
                var value = segment[2..];
                if (!int.TryParse(value, System.Globalization.NumberStyles.Integer, null, out var n)) return 1;
                return Math.Clamp(n, 1, 500);
            }
            if (amp < 0) break;
            span = span[(amp + 1)..];
        }
        return 1;
    }

    static Utf8JsonWriter GetJsonWriter(IBufferWriter<byte> output)
    {
        var writer = t_jsonWriter;
        if (writer is null)
        {
            writer = new Utf8JsonWriter(output, JsonOptions);
            t_jsonWriter = writer;
        }
        else
        {
            writer.Reset(output);
        }
        return writer;
    }

    static ArrayBufferWriter<byte> GetBuffer()
    {
        var buffer = t_buffer;
        if (buffer is null)
        {
            buffer = new ArrayBufferWriter<byte>(32 * 1024);
            t_buffer = buffer;
        }
        else
        {
            buffer.ResetWrittenCount();
        }
        return buffer;
    }

    static void WriteJson<T>(HttpContext ctx, T value, JsonTypeInfo<T> typeInfo)
    {
        var buffer = GetBuffer();
        var writer = GetJsonWriter(buffer);
        JsonSerializer.Serialize(writer, value, typeInfo);
        writer.Flush();

        var response = ctx.Response;
        response.Headers.ContentType = ApplicationJson;
        response.ContentLength = buffer.WrittenCount;
        response.BodyWriter.Write(buffer.WrittenSpan);
    }
}

/// <summary>Hand-rolled equivalent of templates/fortunes.html.hbs (yarte trims the whitespace around each row).</summary>
public static class FortunesRenderer
{
    static ReadOnlySpan<byte> Head => "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>"u8;
    static ReadOnlySpan<byte> RowStart => "<tr><td>"u8;
    static ReadOnlySpan<byte> RowMiddle => "</td><td>"u8;
    static ReadOnlySpan<byte> RowEnd => "</td></tr>"u8;
    static ReadOnlySpan<byte> Tail => "</table></body></html>"u8;

    public static void Render(ArrayBufferWriter<byte> buffer, List<Fortune> fortunes)
    {
        buffer.Write(Head);
        foreach (var fortune in System.Runtime.InteropServices.CollectionsMarshal.AsSpan(fortunes))
        {
            buffer.Write(RowStart);
            var span = buffer.GetSpan(11);
            Utf8Formatter.TryFormat(fortune.Id, span, out var written);
            buffer.Advance(written);
            buffer.Write(RowMiddle);
            WriteHtmlEscaped(buffer, fortune.Message);
            buffer.Write(RowEnd);
        }
        buffer.Write(Tail);
    }

    /// <summary>UTF-8 output with HTML escaping of &amp; &lt; &gt; &quot; &#x27; &#x2f; (byte-identical to what yarte emits).</summary>
    static void WriteHtmlEscaped(ArrayBufferWriter<byte> buffer, string text)
    {
        // Worst case: every char becomes a 6-byte entity, or a 4-byte UTF-8 sequence.
        var span = buffer.GetSpan(text.Length * 6 + 4);
        var pos = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c < 0x80)
            {
                switch (c)
                {
                    case '&': pos += Copy("&amp;"u8, span[pos..]); break;
                    case '<': pos += Copy("&lt;"u8, span[pos..]); break;
                    case '>': pos += Copy("&gt;"u8, span[pos..]); break;
                    case '"': pos += Copy("&quot;"u8, span[pos..]); break;
                    case '\'': pos += Copy("&#x27;"u8, span[pos..]); break;
                    case '/': pos += Copy("&#x2f;"u8, span[pos..]); break;
                    default: span[pos++] = (byte)c; break;
                }
            }
            else
            {
                Rune rune;
                if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
                {
                    rune = new Rune(c, text[i + 1]);
                    i++;
                }
                else
                {
                    rune = Rune.IsValid(c) ? new Rune(c) : Rune.ReplacementChar;
                }
                pos += rune.EncodeToUtf8(span[pos..]);
            }
        }
        buffer.Advance(pos);

        static int Copy(ReadOnlySpan<byte> src, Span<byte> dst)
        {
            src.CopyTo(dst);
            return src.Length;
        }
    }
}
