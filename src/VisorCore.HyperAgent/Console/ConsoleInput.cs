namespace VisorCore.HyperAgent.Console;

public sealed record ConsoleInput(
    string Type,
    string? Text,
    string? Key,
    int? KeyCode,
    int? X,
    int? Y,
    string? Button,
    string? Action);
