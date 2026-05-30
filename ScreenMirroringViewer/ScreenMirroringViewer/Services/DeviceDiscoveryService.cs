using ScreenMirroringViewer.Models;

namespace ScreenMirroringViewer.Services;

public sealed class DeviceDiscoveryService : IDisposable
{
    private readonly WindowsMdnsDiscoveryService _mdns = new();
    private readonly object _gate = new();
    private readonly HashSet<string> _reportedHosts = new(StringComparer.OrdinalIgnoreCase);
    private CancellationTokenSource? _probeCts;

    public event Action<DiscoveredDevice>? DeviceFound;
    public event Action<string>? StatusChanged;

    public bool IsBrowsing { get; private set; }
    public string? LastError => _mdns.LastError;

    public DeviceDiscoveryService()
    {
        _mdns.DeviceFound += ReportDeviceIfNew;
        _mdns.StatusChanged += status => StatusChanged?.Invoke(status);
    }

    public bool StartBrowsing()
    {
        if (IsBrowsing)
        {
            return true;
        }

        StopProbing();

        lock (_gate)
        {
            _reportedHosts.Clear();
        }

        var mdnsStarted = _mdns.StartBrowsing();
        if (!mdnsStarted)
        {
            StatusChanged?.Invoke(_mdns.LastError ?? "mDNS browse unavailable; scanning local network…");
        }

        _probeCts = new CancellationTokenSource();
        _ = RunSubnetProbeLoopAsync(_probeCts.Token);
        IsBrowsing = true;

        return true;
    }

    public void StopBrowsing()
    {
        if (!IsBrowsing)
        {
            return;
        }

        StopProbing();
        _mdns.StopBrowsing();
        IsBrowsing = false;
    }

    public void ResetReportedHosts()
    {
        lock (_gate)
        {
            _reportedHosts.Clear();
        }
    }

    public void ForgetReportedHost(string host)
    {
        lock (_gate)
        {
            _reportedHosts.Remove(host);
        }
    }

    private async Task RunSubnetProbeLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);

            while (!cancellationToken.IsCancellationRequested)
            {
                StatusChanged?.Invoke("Scanning the local network for Screen Mirroring…");

                var devices = await SubnetProbeService.FindDevicesAsync(cancellationToken);
                foreach (var device in devices)
                {
                    ReportDeviceIfNew(device);
                }

                if (devices.Count > 0)
                {
                    StatusChanged?.Invoke($"Found {devices.Count} device(s) via network scan.");
                }

                await Task.Delay(TimeSpan.FromSeconds(30), cancellationToken);
            }
        }
        catch (OperationCanceledException)
        {
            // expected on shutdown
        }
    }

    private void ReportDeviceIfNew(DiscoveredDevice device)
    {
        lock (_gate)
        {
            if (!_reportedHosts.Add(device.Host))
            {
                return;
            }
        }

        DeviceFound?.Invoke(device);
    }

    private void StopProbing()
    {
        _probeCts?.Cancel();
        _probeCts?.Dispose();
        _probeCts = null;
    }

    public void Dispose()
    {
        StopBrowsing();
        _mdns.Dispose();
    }
}
