using System.Text.Json.Serialization;

namespace site;

/// <summary>
/// Catálogo (implementações e testes) + uma medição por host. O schema atual é
/// <c>{ impls, tests, hosts[] }</c>; o formato antigo (<c>host</c>, <c>tests[].results</c> e
/// <c>metrics</c> no topo) continua sendo lido para não quebrar data.json publicado antes.
/// </summary>
public sealed class BenchData
{
    public List<Impl> Impls { get; set; } = new();
    public List<TestData> Tests { get; set; } = new();
    public List<HostData> Hosts { get; set; } = new();

    // Formato antigo (host único) — usado só como fallback.
    public HostInfo? Host { get; set; }
    public List<Metric> Metrics { get; set; } = new();

    /// <summary>Medições efetivas: a lista nova ou o host único do formato antigo.</summary>
    public IReadOnlyList<HostData> Medicoes()
    {
        if (Hosts.Count > 0)
            return Hosts;
        if (Host is null)
            return Array.Empty<HostData>();
        return [new HostData { Host = Host, Tests = Tests, Metrics = Metrics }];
    }
}

public sealed class HostData
{
    public HostInfo? Host { get; set; }
    public List<TestData> Tests { get; set; } = new();
    public List<Metric> Metrics { get; set; } = new();
}

public sealed class HostInfo
{
    public string Id { get; set; } = "";
    public string Cpu { get; set; } = "";
    public string Memory { get; set; } = "";
    public string Os { get; set; } = "";
    public string Postgres { get; set; } = "";
    public string Storage { get; set; } = "";
    public string Date { get; set; } = "";
    public string Notes { get; set; } = "";
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
