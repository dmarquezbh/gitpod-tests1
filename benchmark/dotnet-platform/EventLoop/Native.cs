using System.Runtime.InteropServices;

namespace DotnetBench.Platform.EventLoop;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct EpollEvent
{
    public uint Events;
    public ulong Data;
}

/// <summary>The handful of libc calls the event loop needs. x86-64 Linux only (epoll_event is packed there).</summary>
internal static unsafe class Native
{
    const string Libc = "libc.so.6";

    public const int EPOLL_CTL_ADD = 1, EPOLL_CTL_DEL = 2, EPOLL_CTL_MOD = 3;
    public const uint EPOLLIN = 0x001, EPOLLOUT = 0x004, EPOLLERR = 0x008, EPOLLHUP = 0x010, EPOLLRDHUP = 0x2000;
    public const int SOCK_NONBLOCK = 0x800, SOCK_CLOEXEC = 0x80000;
    public const int SOL_SOCKET = 1, SO_REUSEPORT = 15;
    public const int IPPROTO_TCP = 6, TCP_NODELAY = 1;
    public const int MSG_NOSIGNAL = 0x4000;
    public const int EAGAIN = 11, EINTR = 4;

    [DllImport(Libc, SetLastError = true)] public static extern int epoll_create1(int flags);
    [DllImport(Libc, SetLastError = true)] public static extern int epoll_ctl(int epfd, int op, int fd, EpollEvent* ev);
    [DllImport(Libc, SetLastError = true)] public static extern int epoll_wait(int epfd, EpollEvent* events, int maxevents, int timeout);
    [DllImport(Libc, SetLastError = true)] public static extern int accept4(int fd, void* addr, uint* addrlen, int flags);
    [DllImport(Libc, SetLastError = true)] public static extern nint recv(int fd, byte* buf, nuint len, int flags);
    [DllImport(Libc, SetLastError = true)] public static extern nint send(int fd, byte* buf, nuint len, int flags);
    [DllImport(Libc, SetLastError = true)] public static extern int setsockopt(int fd, int level, int optname, int* optval, uint optlen);
    [DllImport(Libc, SetLastError = true)] public static extern int close(int fd);

    public static int Errno => Marshal.GetLastPInvokeError();

    public static void EpollAdd(int epfd, int fd, uint events)
    {
        var ev = new EpollEvent { Events = events, Data = (ulong)fd };
        if (epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev) != 0) throw new InvalidOperationException($"epoll_ctl ADD failed, errno {Errno}");
    }

    public static void EpollMod(int epfd, int fd, uint events)
    {
        var ev = new EpollEvent { Events = events, Data = (ulong)fd };
        if (epoll_ctl(epfd, EPOLL_CTL_MOD, fd, &ev) != 0) throw new InvalidOperationException($"epoll_ctl MOD failed, errno {Errno}");
    }

    public static void EpollDel(int epfd, int fd) => epoll_ctl(epfd, EPOLL_CTL_DEL, fd, null);

    public static void SetInt(int fd, int level, int option, int value) => setsockopt(fd, level, option, &value, 4);
}
