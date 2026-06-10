namespace VisorCore.HyperAgent.Console;

public interface IConsoleBackend
{
    IAsyncEnumerable<ConsoleFrame> StartAsync(string sessionId, string vmName, int targetFps, CancellationToken cancellationToken);
    Task SendInputAsync(string vmName, ConsoleInput input, CancellationToken cancellationToken);
}
