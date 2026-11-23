using System.Text.Json.Serialization;

namespace site;

public sealed class BenchData
{
    public List<Impl> Impls { get; set; } = new();
    public List<TestData> Tests { get; set; } = new();
    public List<Metric> Metrics { get; set; } = new();
}

public sealed class Impl
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
}

public sealed class TestData
{
    public string Id { get; set; } = "";
    public string Label { get; set; } = "";
    public string Note { get; set; } = "";
    public List<Result> Results { get; set; } = new();
}

public sealed class Result
{
    public string Impl { get; set; } = "";
    public double Rps { get; set; }
    public int Level { get; set; }
    public int Errors { get; set; }
}

public sealed class Metric
{
    public string Impl { get; set; } = "";
    public long RssKb { get; set; }
    public long AppBytes { get; set; }
    public long RuntimeBytes { get; set; }
    public long TotalBytes { get; set; }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(BenchData))]
internal partial class AppJson : JsonSerializerContext
{
}
