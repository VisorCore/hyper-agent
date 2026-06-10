using System.Buffers.Binary;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;
using VisorCore.HyperAgent.Console;

namespace VisorCore.HyperAgent.Relay;

public sealed class RelayClient(
    IOptions<AgentOptions> options,
    IConsoleBackend consoleBackend,
    ILogger<RelayClient> logger)
{
    private readonly AgentOptions _options = options.Value;
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private CancellationTokenSource? _sessionCts;
    private string _activeVm = "";

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        using var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("Authorization", $"Bearer {_options.AgentToken}");
        await socket.ConnectAsync(_options.RelayUri, cancellationToken);
        await SendJsonAsync(socket, new
        {
            type = "agent.hello",
            workspaceId = _options.WorkspaceId,
            hostId = _options.HostId,
            agentVersion = ThisAssembly.Version
        }, cancellationToken);

        var buffer = new byte[1024 * 64];
        while (!cancellationToken.IsCancellationRequested && socket.State == WebSocketState.Open)
        {
            var message = await ReceiveTextAsync(socket, buffer, cancellationToken);
            if (message.Length == 0) continue;
            await HandleMessageAsync(socket, message, cancellationToken);
        }
    }

    private async Task HandleMessageAsync(ClientWebSocket socket, string json, CancellationToken cancellationToken)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var type = root.GetProperty("type").GetString() ?? "";
        switch (type)
        {
            case "console.start":
                await StartConsoleAsync(socket, root, cancellationToken);
                break;
            case "console.stop":
                _sessionCts?.Cancel();
                break;
            case "console.input.text":
            case "console.input.key":
            case "console.input.mouse":
                await consoleBackend.SendInputAsync(_activeVm, ToInput(root), cancellationToken);
                break;
        }
    }

    private async Task StartConsoleAsync(ClientWebSocket socket, JsonElement root, CancellationToken cancellationToken)
    {
        _sessionCts?.Cancel();
        _sessionCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var sessionId = root.GetProperty("sessionId").GetString() ?? "";
        _activeVm = root.GetProperty("vmName").GetString() ?? "";
        var fps = root.TryGetProperty("targetFps", out var fpsElement) ? fpsElement.GetInt32() : _options.DefaultConsoleFps;

        _ = Task.Run(async () =>
        {
            try
            {
                await foreach (var frame in consoleBackend.StartAsync(sessionId, _activeVm, fps, _sessionCts.Token))
                {
                    await SendFrameAsync(socket, frame, _sessionCts.Token);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                logger.LogError(ex, "Console session failed for VM {VmName}", _activeVm);
            }
        }, _sessionCts.Token);
    }

    private static ConsoleInput ToInput(JsonElement root)
    {
        string? ReadString(string name) => root.TryGetProperty(name, out var value) ? value.GetString() : null;
        int? ReadInt(string name) => root.TryGetProperty(name, out var value) && value.TryGetInt32(out var number) ? number : null;
        return new ConsoleInput(root.GetProperty("type").GetString() ?? "", ReadString("text"), ReadString("key"), ReadInt("keyCode"), ReadInt("x"), ReadInt("y"), ReadString("button"), ReadString("action"));
    }

    private async Task SendJsonAsync(ClientWebSocket socket, object payload, CancellationToken cancellationToken)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(payload);
        await _sendLock.WaitAsync(cancellationToken);
        try
        {
            await socket.SendAsync(bytes, WebSocketMessageType.Text, true, cancellationToken);
        }
        finally
        {
            _sendLock.Release();
        }
    }

    private async Task SendFrameAsync(ClientWebSocket socket, ConsoleFrame frame, CancellationToken cancellationToken)
    {
        var header = JsonSerializer.SerializeToUtf8Bytes(new
        {
            type = "console.frame",
            sessionId = frame.SessionId,
            mime = frame.Mime,
            width = frame.Width,
            height = frame.Height,
            sequence = frame.Sequence,
            capturedAtUtc = frame.CapturedAtUtc
        });
        var payload = new byte[4 + header.Length + frame.Payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(payload.AsSpan(0, 4), (uint)header.Length);
        header.CopyTo(payload.AsSpan(4));
        frame.Payload.CopyTo(payload.AsSpan(4 + header.Length));

        await _sendLock.WaitAsync(cancellationToken);
        try
        {
            await socket.SendAsync(payload, WebSocketMessageType.Binary, true, cancellationToken);
        }
        finally
        {
            _sendLock.Release();
        }
    }

    private static async Task<string> ReceiveTextAsync(ClientWebSocket socket, byte[] buffer, CancellationToken cancellationToken)
    {
        using var stream = new MemoryStream();
        WebSocketReceiveResult result;
        do
        {
            result = await socket.ReceiveAsync(buffer, cancellationToken);
            if (result.MessageType == WebSocketMessageType.Close) return "";
            stream.Write(buffer, 0, result.Count);
        } while (!result.EndOfMessage);
        return result.MessageType == WebSocketMessageType.Text ? Encoding.UTF8.GetString(stream.ToArray()) : "";
    }
}

internal static class ThisAssembly
{
    public const string Version = "1.0.0-preview.1";
}
