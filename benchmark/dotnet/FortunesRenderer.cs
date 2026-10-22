using System.Buffers;
using System.Buffers.Text;
using System.Text;

namespace DotnetBench;

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
