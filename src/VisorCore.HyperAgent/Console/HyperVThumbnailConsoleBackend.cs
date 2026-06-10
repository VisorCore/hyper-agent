using System.Drawing;
using System.Drawing.Imaging;
using System.Management;
using System.Runtime.InteropServices;

namespace VisorCore.HyperAgent.Console;

public sealed class HyperVThumbnailConsoleBackend(ILogger<HyperVThumbnailConsoleBackend> logger) : IConsoleBackend
{
    public async IAsyncEnumerable<ConsoleFrame> StartAsync(
        string sessionId,
        string vmName,
        int targetFps,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var delay = TimeSpan.FromMilliseconds(Math.Max(75, 1000 / Math.Clamp(targetFps, 1, 24)));
        long sequence = 0;
        while (!cancellationToken.IsCancellationRequested)
        {
            var frame = CaptureFrame(sessionId, vmName, ++sequence);
            yield return frame;
            await Task.Delay(delay, cancellationToken);
        }
    }

    public Task SendInputAsync(string vmName, ConsoleInput input, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        switch (input.Type)
        {
            case "console.input.text":
                if (!string.IsNullOrEmpty(input.Text)) GetKeyboard(vmName).InvokeMethod("TypeText", new object[] { input.Text });
                break;
            case "console.input.key":
                if (input.KeyCode is > 0) GetKeyboard(vmName).InvokeMethod("TypeKey", new object[] { input.KeyCode.Value });
                break;
            case "console.input.mouse":
                SendMouse(vmName, input);
                break;
        }
        return Task.CompletedTask;
    }

    private ConsoleFrame CaptureFrame(string sessionId, string vmName, long sequence)
    {
        using var vm = FindVm(vmName);
        using var settings = GetVmSettings(vm);
        using var video = GetRelated(vm, "Msvm_VideoHead").Cast<ManagementObject>().FirstOrDefault();
        var width = 1280;
        var height = 720;
        if (video != null)
        {
            try
            {
                width = Convert.ToInt32(((ushort[])video["CurrentHorizontalResolution"])[0]);
                height = Convert.ToInt32(((ushort[])video["CurrentVerticalResolution"])[0]);
            }
            catch { }
        }
        width = Math.Clamp(width, 640, 1280);
        height = Math.Clamp(height, 360, 1024);

        using var vmms = new ManagementObjectSearcher(@"root\virtualization\v2", "SELECT * FROM Msvm_VirtualSystemManagementService")
            .Get()
            .Cast<ManagementObject>()
            .First();
        using var inParams = vmms.GetMethodParameters("GetVirtualSystemThumbnailImage");
        inParams["TargetSystem"] = settings.Path.Path;
        inParams["WidthPixels"] = (ushort)width;
        inParams["HeightPixels"] = (ushort)height;
        using var outParams = vmms.InvokeMethod("GetVirtualSystemThumbnailImage", inParams, null);
        var returnCode = Convert.ToUInt32(outParams?["ReturnValue"] ?? 1);
        if (returnCode != 0)
        {
            throw new InvalidOperationException($"Hyper-V thumbnail capture returned {returnCode} for VM '{vmName}'.");
        }

        var imageData = (byte[])(outParams?["ImageData"] ?? Array.Empty<byte>());
        if (imageData.Length == 0) throw new InvalidOperationException($"Hyper-V returned an empty frame for VM '{vmName}'.");

        using var bitmap = new Bitmap(width, height, PixelFormat.Format16bppRgb565);
        var rect = new Rectangle(0, 0, width, height);
        var bitmapData = bitmap.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format16bppRgb565);
        try
        {
            Marshal.Copy(imageData, 0, bitmapData.Scan0, Math.Min(imageData.Length, Math.Abs(bitmapData.Stride) * bitmapData.Height));
        }
        finally
        {
            bitmap.UnlockBits(bitmapData);
        }

        using var stream = new MemoryStream();
        bitmap.Save(stream, ImageFormat.Jpeg);
        logger.LogDebug("Captured console frame {Sequence} for {VmName}", sequence, vmName);
        return new ConsoleFrame(sessionId, "image/jpeg", stream.ToArray(), width, height, sequence, DateTimeOffset.UtcNow);
    }

    private void SendMouse(string vmName, ConsoleInput input)
    {
        using var vm = FindVm(vmName);
        using var mouse = GetRelated(vm, "Msvm_SyntheticMouse").Cast<ManagementObject>().FirstOrDefault()
            ?? throw new InvalidOperationException($"Hyper-V mouse channel is unavailable for VM '{vmName}'.");
        mouse.InvokeMethod("SetAbsolutePosition", new object[] { input.X ?? 0, input.Y ?? 0 });
        if (string.Equals(input.Action, "move", StringComparison.OrdinalIgnoreCase)) return;
        var button = (input.Button ?? "left").ToLowerInvariant() switch
        {
            "right" => 2,
            "middle" => 3,
            _ => 1
        };
        mouse.InvokeMethod("ClickButton", new object[] { button });
    }

    private static ManagementObject GetKeyboard(string vmName)
    {
        using var vm = FindVm(vmName);
        return GetRelated(vm, "Msvm_Keyboard").Cast<ManagementObject>().FirstOrDefault()
            ?? throw new InvalidOperationException($"Hyper-V keyboard channel is unavailable for VM '{vmName}'.");
    }

    private static ManagementObject FindVm(string vmName)
    {
        var query = "SELECT * FROM Msvm_ComputerSystem WHERE Caption = 'Virtual Machine'";
        return new ManagementObjectSearcher(@"root\virtualization\v2", query)
            .Get()
            .Cast<ManagementObject>()
            .FirstOrDefault(vm => string.Equals(Convert.ToString(vm["ElementName"]), vmName, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException($"VM '{vmName}' was not found.");
    }

    private static ManagementObject GetVmSettings(ManagementObject vm)
    {
        return GetRelated(vm, "Msvm_VirtualSystemSettingData").Cast<ManagementObject>().FirstOrDefault()
            ?? throw new InvalidOperationException("Hyper-V VM settings were not available.");
    }

    private static ManagementObjectCollection GetRelated(ManagementObject source, string className)
    {
        return source.GetRelated(className);
    }
}
