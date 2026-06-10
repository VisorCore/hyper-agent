using Microsoft.Extensions.Options;
using VisorCore.HyperAgent;
using VisorCore.HyperAgent.Console;
using VisorCore.HyperAgent.Relay;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options => options.ServiceName = "VisorCore Hyper Agent");
builder.Services.Configure<AgentOptions>(builder.Configuration.GetSection("VisorCore"));
builder.Services.AddSingleton<IConsoleBackend, HyperVThumbnailConsoleBackend>();
builder.Services.AddSingleton<RelayClient>();
builder.Services.AddHostedService<Worker>();

await builder.Build().RunAsync();

namespace VisorCore.HyperAgent
{
    public sealed class Worker(RelayClient relayClient, ILogger<Worker> logger, IOptions<AgentOptions> options) : BackgroundService
    {
        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            logger.LogInformation("VisorCore Hyper Agent native gateway starting for host {HostId}", options.Value.HostId);
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await relayClient.RunAsync(stoppingToken);
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex)
                {
                    logger.LogError(ex, "Relay client failed; reconnecting shortly.");
                    await Task.Delay(TimeSpan.FromSeconds(3), stoppingToken);
                }
            }
        }
    }
}
