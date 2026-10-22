using System.Buffers.Binary;
using System.Text;
using System.Threading.Tasks.Sources;

namespace DotnetBench.Platform.Pg;

/// <summary>An in-flight operation: receives its DataRows, then is completed on ReadyForQuery.</summary>
public abstract class PendingOp
{
    public abstract void OnDataRow(ReadOnlySpan<byte> row);
    public abstract void Complete();
    public abstract void Fail(Exception e);

    protected static int ReadInt4Column(ReadOnlySpan<byte> row, ref int offset)
    {
        var length = BinaryPrimitives.ReadInt32BigEndian(row[offset..]);
        var value = BinaryPrimitives.ReadInt32BigEndian(row[(offset + 4)..]);
        offset += 4 + length;
        return value;
    }
}

/// <summary>Base for operations awaited as ValueTask&lt;T&gt;; continuations run inline on the read loop (like tokio).</summary>
public abstract class PendingOp<T> : PendingOp, IValueTaskSource<T>
{
    ManualResetValueTaskSourceCore<T> _core = new() { RunContinuationsAsynchronously = false };
    bool _failed;

    public short Version => _core.Version;
    protected abstract T Result { get; }

    public override void Complete() { if (!_failed) _core.SetResult(Result); }
    public override void Fail(Exception e) { if (!_failed) { _failed = true; _core.SetException(e); } }

    /// <summary>Called once the awaiter has taken the result; pooled subclasses reset and recycle here.</summary>
    protected virtual void Released() { }
    protected void ResetCore() { _core.Reset(); _failed = false; }

    T IValueTaskSource<T>.GetResult(short token)
    {
        var result = _core.GetResult(token);
        Released();
        return result;
    }
    ValueTaskSourceStatus IValueTaskSource<T>.GetStatus(short token) => _core.GetStatus(token);
    void IValueTaskSource<T>.OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags) => _core.OnCompleted(continuation, state, token, flags);
}

public sealed class SingleWorldOp : PendingOp<World>
{
    // An op is only ever touched by one thread at a time (creator → read loop → inline continuation),
    // so a per-thread free list is safe: whoever takes the result puts it back on its own thread's list.
    [ThreadStatic] static Stack<SingleWorldOp>? t_pool;

    public static SingleWorldOp Rent()
    {
        var pool = t_pool;
        return pool is { Count: > 0 } ? pool.Pop() : new SingleWorldOp();
    }

    protected override void Released()
    {
        ResetCore();
        var pool = t_pool ??= new Stack<SingleWorldOp>();
        if (pool.Count < 1024) pool.Push(this);
    }

    World _world;
    protected override World Result => _world;
    public override void OnDataRow(ReadOnlySpan<byte> row)
    {
        var offset = 2;   // column count
        var id = ReadInt4Column(row, ref offset);
        var number = ReadInt4Column(row, ref offset);
        _world = new World(id, number);
    }
}

public sealed class WorldsOp(int count) : PendingOp<World[]>
{
    readonly World[] _worlds = new World[count];
    int _index;
    protected override World[] Result => _worlds;
    public override void OnDataRow(ReadOnlySpan<byte> row)
    {
        var offset = 2;
        var id = ReadInt4Column(row, ref offset);
        var number = ReadInt4Column(row, ref offset);
        if (_index < _worlds.Length) _worlds[_index++] = new World(id, number);
    }
}

public sealed class FortunesOp : PendingOp<List<Fortune>>
{
    readonly List<Fortune> _fortunes = new(16) { new(0, "Additional fortune added at request time.") };
    protected override List<Fortune> Result => _fortunes;
    public override void OnDataRow(ReadOnlySpan<byte> row)
    {
        var offset = 2;
        var id = ReadInt4Column(row, ref offset);
        var length = BinaryPrimitives.ReadInt32BigEndian(row[offset..]);
        var message = Encoding.UTF8.GetString(row.Slice(offset + 4, length));
        _fortunes.Add(new Fortune(id, message));
    }
}

/// <summary>Statement with no result rows (the batched UPDATE).</summary>
public sealed class ExecOp : PendingOp, IValueTaskSource
{
    ManualResetValueTaskSourceCore<bool> _core = new() { RunContinuationsAsynchronously = false };
    bool _failed;
    public short Version => _core.Version;
    public override void OnDataRow(ReadOnlySpan<byte> row) { }
    public override void Complete() { if (!_failed) _core.SetResult(true); }
    public override void Fail(Exception e) { if (!_failed) { _failed = true; _core.SetException(e); } }
    void IValueTaskSource.GetResult(short token) => _core.GetResult(token);
    ValueTaskSourceStatus IValueTaskSource.GetStatus(short token) => _core.GetStatus(token);
    void IValueTaskSource.OnCompleted(Action<object?> continuation, object? state, short token, ValueTaskSourceOnCompletedFlags flags) => _core.OnCompleted(continuation, state, token, flags);
}
