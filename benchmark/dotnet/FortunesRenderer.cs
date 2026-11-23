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

    /// <summary>Exact byte length of Render, so the response can be written once into the output buffer.</summary>
    public static int Measure(List<Fortune> fortunes)
    {
        var len = Head.Length + Tail.Length;
        foreach (var fortune in System.Runtime.InteropServices.CollectionsMarshal.AsSpan(fortunes))
        {
            len += RowStart.Length + RowMiddle.Length + RowEnd.Length + Digits(fortune.Id) + EscapedLength(fortune.Message);
        }
        return len;
    }

    /// <summary>Renders into an exactly sized span (see Measure).</summary>
    public static void Render(Span<byte> dst, List<Fortune> fortunes)
    {
        var p = 0;
        Head.CopyTo(dst); p += Head.Length;
        foreach (var fortune in System.Runtime.InteropServices.CollectionsMarshal.AsSpan(fortunes))
        {
            RowStart.CopyTo(dst[p..]); p += RowStart.Length;
            Utf8Formatter.TryFormat(fortune.Id, dst[p..], out var written); p += written;
            RowMiddle.CopyTo(dst[p..]); p += RowMiddle.Length;
            p += WriteHtmlEscaped(dst[p..], fortune.Message);
            RowEnd.CopyTo(dst[p..]); p += RowEnd.Length;
        }
        Tail.CopyTo(dst[p..]);
    }

    static int Digits(int value) => value < 10 ? 1 : value < 100 ? 2 : value < 1000 ? 3 : value < 10000 ? 4 : 5;

    static int EscapedLength(string text)
    {
        var len = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c < 0x80)
            {
                len += c switch { '&' => 5, '<' => 4, '>' => 4, '"' => 6, '\'' => 6, '/' => 6, _ => 1 };
            }
            else
            {
                Rune rune;
                if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) { rune = new Rune(c, text[i + 1]); i++; }
                else rune = Rune.IsValid(c) ? new Rune(c) : Rune.ReplacementChar;
                len += rune.Utf8SequenceLength;
            }
        }
        return len;
    }

    static int WriteHtmlEscaped(Span<byte> dst, string text)
    {
        var pos = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c < 0x80)
            {
                switch (c)
                {
                    case '&': "&amp;"u8.CopyTo(dst[pos..]); pos += 5; break;
                    case '<': "&lt;"u8.CopyTo(dst[pos..]); pos += 4; break;
                    case '>': "&gt;"u8.CopyTo(dst[pos..]); pos += 4; break;
                    case '"': "&quot;"u8.CopyTo(dst[pos..]); pos += 6; break;
                    case '\'': "&#x27;"u8.CopyTo(dst[pos..]); pos += 6; break;
                    case '/': "&#x2f;"u8.CopyTo(dst[pos..]); pos += 6; break;
                    default: dst[pos++] = (byte)c; break;
                }
            }
            else
            {
                Rune rune;
                if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) { rune = new Rune(c, text[i + 1]); i++; }
                else rune = Rune.IsValid(c) ? new Rune(c) : Rune.ReplacementChar;
                pos += rune.EncodeToUtf8(dst[pos..]);
            }
        }
        return pos;
    }

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
