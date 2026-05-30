namespace ScreenMirroringViewer.Models;

using ScreenMirroringViewer.Services;

public sealed class DiscoveredDevice
{
    public required string Name { get; init; }
    public required string Host { get; init; }
    public required int Port { get; init; }
    public string? Platform { get; init; }
    public string? Vendor { get; init; }
    public DiscoverySource Source { get; init; }

    public bool IsScreenMirroring =>
        string.Equals(Vendor, ScreenMirroringProtocol.VendorId, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(Platform, ScreenMirroringProtocol.PlatformId, StringComparison.OrdinalIgnoreCase);

    public override string ToString() => $"{Name} ({Host}:{Port})";
}
