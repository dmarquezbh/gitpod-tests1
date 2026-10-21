using System.Text.Json.Serialization;

namespace DotnetBench;

public readonly record struct JsonMessage(string Message);

public readonly record struct World(int Id, int RandomNumber);

public readonly record struct Fortune(int Id, string Message);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, GenerationMode = JsonSourceGenerationMode.Serialization)]
[JsonSerializable(typeof(JsonMessage))]
[JsonSerializable(typeof(World))]
[JsonSerializable(typeof(World[]))]
public partial class AppJsonContext : JsonSerializerContext;
