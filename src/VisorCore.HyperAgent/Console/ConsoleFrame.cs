namespace VisorCore.HyperAgent.Console;

public sealed record ConsoleFrame(
    string SessionId,
    string Mime,
    byte[] Payload,
    int Width,
    int Height,
    long Sequence,
    DateTimeOffset CapturedAtUtc);
