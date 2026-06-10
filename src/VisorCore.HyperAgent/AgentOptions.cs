namespace VisorCore.HyperAgent;

public sealed class AgentOptions
{
    public string WorkspaceId { get; set; } = "";
    public string HostId { get; set; } = "";
    public string AgentToken { get; set; } = "";
    public Uri RelayUri { get; set; } = new("wss://relay.hyper.visorcore.com/agent");
    public int DefaultConsoleFps { get; set; } = 15;
}
