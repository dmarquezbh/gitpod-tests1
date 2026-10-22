using System.Buffers;
using System.Net;
using System.Net.Sockets;

namespace DotnetBench.Platform;

/// <summary>
/// HTTP/1.1 connection loop straight on <see cref="Socket"/>: receive into a per-connection byte
/// array, parse every complete request, append the responses to a per-connection output buffer,
/// one send per read. No Pipe, no transport layer, no copies between socket and application
/// buffers — the same shape as a hyper connection task on a current-thread Tokio runtime.
/// </summary>
public sealed class RawSocketServer(HttpApplication app)
{
    public async Task RunAsync(int port)
    {
        var listener = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        listener.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        listener.Bind(new IPEndPoint(IPAddress.Any, port));
        listener.Listen(4096);
        while (true)
        {
            var socket = await listener.AcceptAsync();
            socket.NoDelay = true;
            _ = ProcessConnectionAsync(socket);
        }
    }

    async Task ProcessConnectionAsync(Socket socket)
    {
        var input = new byte[8 * 1024];
        var inputLength = 0;
        var output = new ArrayBufferWriter<byte>(16 * 1024);
        try
        {
            while (true)
            {
                if (inputLength == input.Length) Array.Resize(ref input, input.Length * 2);
                var received = await socket.ReceiveAsync(input.AsMemory(inputLength), SocketFlags.None);
                if (received == 0) break;
                inputLength += received;

                var consumed = 0;
                while (HttpApplication.TryParseRequest(input.AsSpan(consumed, inputLength - consumed), out var used, out var route, out var count))
                {
                    consumed += used;
                    await app.HandleAsync(route, count, output);
                }
                if (consumed > 0)
                {
                    inputLength -= consumed;
                    if (inputLength > 0) Buffer.BlockCopy(input, consumed, input, 0, inputLength);
                }

                if (output.WrittenCount > 0)
                {
                    var pending = output.WrittenMemory;
                    while (!pending.IsEmpty)
                    {
                        var sent = await socket.SendAsync(pending, SocketFlags.None);
                        pending = pending[sent..];
                    }
                    output.ResetWrittenCount();
                }
            }
        }
        catch (Exception)
        {
            // peer reset / aborted: drop the connection
        }
        finally
        {
            try { socket.Shutdown(SocketShutdown.Both); } catch { }
            socket.Dispose();
        }
    }
}
