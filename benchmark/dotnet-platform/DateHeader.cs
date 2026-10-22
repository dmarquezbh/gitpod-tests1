namespace DotnetBench.Platform;

/// <summary>"Date: &lt;RFC 1123&gt;\r\n\r\n" refreshed once per second, so responses never format a date.</summary>
public static class DateHeader
{
    public const int Length = 6 + 29 + 4; // "Date: " + "Wed, 21 Oct 2026 23:02:22 GMT" + "\r\n\r\n"

    static byte[] s_bytes = Render();
    static Timer? s_timer;

    public static ReadOnlySpan<byte> Bytes => Volatile.Read(ref s_bytes);

    public static void Start() => s_timer ??= new Timer(static _ => Volatile.Write(ref s_bytes, Render()), null, 1000, 1000);

    static byte[] Render()
    {
        var bytes = new byte[Length];
        "Date: "u8.CopyTo(bytes);
        DateTime.UtcNow.TryFormat(bytes.AsSpan(6), out var written, "R");
        "\r\n\r\n"u8.CopyTo(bytes.AsSpan(6 + written));
        return bytes;
    }
}
