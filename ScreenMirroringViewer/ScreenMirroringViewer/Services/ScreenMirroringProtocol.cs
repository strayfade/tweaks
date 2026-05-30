namespace ScreenMirroringViewer.Services;

public static class ScreenMirroringProtocol
{
    /// <summary>Fixed TCP port for Screen Mirroring VNC (matches the iOS tweak).</summary>
    public const int ServerPort = 45900;

    /// <summary>Dedicated Bonjour service published by the tweak (ShareClipboard-compatible mDNS on Windows).</summary>
    public const string ServiceType = "_screenmirroring._tcp.local";

    /// <summary>Older builds that advertised generic VNC over mDNS.</summary>
    public const string LegacyServiceType = "_rfb._tcp.local";

    /// <summary>Windows viewer-only registration (not browsed; wakes the DNS Client).</summary>
    public const string ViewerRegistrationType = "_smviewer._tcp.local";

    public const string VendorId = "strayfade";
    public const string PlatformId = "ios";
}
