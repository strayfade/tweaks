using System.ComponentModel;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using ScreenMirroringViewer.Models;

namespace ScreenMirroringViewer.Services;

/// <summary>
/// mDNS discovery using the Windows DNS Service API, matching ShareClipboard for Windows:
/// register a local service, then browse for peers.
/// </summary>
public sealed class WindowsMdnsDiscoveryService : IDisposable
{
    private const uint DnsQueryRequestVersion1 = 1;
    private const ushort DnsTypePtr = 12;
    private const int DnsFreeRecordList = 1;
    private const uint ErrorSuccess = 0;
    // DNS_REQUEST_PENDING from windns.h — async success, not an error (ShareClipboard treats this as OK).
    private const uint DnsRequestPending = 9506;

    private static readonly string[] BrowseQueries =
    [
        "_screenmirroring._tcp.local",
        "_rfb._tcp.local",
    ];

    private readonly object _gate = new();
    private readonly HashSet<string> _reportedHosts = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _pendingResolves = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<DNS_SERVICE_CANCEL> _browseCancels = new();

    private readonly DNS_SERVICE_BROWSE_CALLBACK _browseCallback;
    private readonly DNS_SERVICE_RESOLVE_CALLBACK _resolveCallback;
    private readonly DNS_SERVICE_REGISTER_CALLBACK _registerCallback;

    private TcpListener? _registrationListener;
    private IntPtr _registeredInstance;
    private DNS_SERVICE_CANCEL _registerCancel;
    private bool _registerActive;
    private bool _browseActive;
    private bool _disposed;
    private string? _lastError;

    public event Action<DiscoveredDevice>? DeviceFound;
    public event Action<string>? StatusChanged;

    public string? LastError => _lastError;

    public WindowsMdnsDiscoveryService()
    {
        _browseCallback = OnBrowseResult;
        _resolveCallback = OnResolveResult;
        _registerCallback = OnRegisterResult;
    }

    public bool StartBrowsing()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (!NetworkInitializer.TryEnsureInitialized())
        {
            _lastError = "Winsock could not be initialized.";
            StatusChanged?.Invoke(_lastError);
            return false;
        }

        StopBrowsing();

        lock (_gate)
        {
            _reportedHosts.Clear();
            _pendingResolves.Clear();
            _lastError = null;
        }

        StatusChanged?.Invoke("Searching for Screen Mirroring devices…");

        if (!StartLocalRegistration())
        {
            StatusChanged?.Invoke(_lastError ?? "Local mDNS registration failed; continuing search…");
        }

        var startedAny = false;
        foreach (var query in BrowseQueries)
        {
            if (TryStartBrowseQuery(query))
            {
                startedAny = true;
            }
        }

        _browseActive = startedAny;
        if (!startedAny)
        {
            _lastError ??= "Discovery failed to start.";
            StatusChanged?.Invoke(_lastError);
            StopLocalRegistration();
            return false;
        }

        return true;
    }

    public void StopBrowsing()
    {
        foreach (var cancel in _browseCancels)
        {
            var copy = cancel;
            _ = DnsServiceBrowseCancel(ref copy);
        }

        _browseCancels.Clear();
        _browseActive = false;
        StopLocalRegistration();
    }

    private bool StartLocalRegistration()
    {
        try
        {
            _registrationListener = new TcpListener(IPAddress.Any, 0);
            _registrationListener.Start();
            var port = ((IPEndPoint)_registrationListener.LocalEndpoint).Port;

            var hostName = LocalMdnsHostName();
            var serviceName = $"{SanitizedComputerName()}.{ScreenMirroringProtocol.ViewerRegistrationType}";
            var keys = new[] { "v", "id", "platform" };
            var values = new[] { "1", Guid.NewGuid().ToString("N"), "windows" };

            var keysPtr = AllocStringArray(keys);
            var valuesPtr = AllocStringArray(values);
            try
            {
                _registeredInstance = DnsServiceConstructInstance(
                    serviceName,
                    hostName,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    (ushort)port,
                    0,
                    0,
                    (uint)keys.Length,
                    keysPtr,
                    valuesPtr);
            }
            finally
            {
                FreeStringArray(keys, keysPtr);
                FreeStringArray(values, valuesPtr);
            }

            if (_registeredInstance == IntPtr.Zero)
            {
                _lastError = "Could not construct the local mDNS registration.";
                StatusChanged?.Invoke(_lastError);
                return false;
            }

            var registerRequest = new DNS_SERVICE_REGISTER_REQUEST
            {
                Version = DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                pServiceInstance = _registeredInstance,
                pRegisterCompletionCallback = _registerCallback,
                pQueryContext = IntPtr.Zero,
                unicastEnabled = false,
            };

            var status = DnsServiceRegister(ref registerRequest, out _registerCancel);
            if (!IsAcceptableDnsStatus(status))
            {
                _lastError = FormatWin32Error("DnsServiceRegister", status);
                StatusChanged?.Invoke(_lastError);
                DnsServiceFreeInstance(_registeredInstance);
                _registeredInstance = IntPtr.Zero;
                return false;
            }

            _registerActive = true;
            return true;
        }
        catch (Exception ex)
        {
            _lastError = $"Local mDNS registration failed: {ex.Message}";
            StatusChanged?.Invoke(_lastError);
            return false;
        }
    }

    private void StopLocalRegistration()
    {
        if (_registerActive)
        {
            _ = DnsServiceRegisterCancel(ref _registerCancel);
            _registerActive = false;
        }

        if (_registeredInstance != IntPtr.Zero)
        {
            DnsServiceFreeInstance(_registeredInstance);
            _registeredInstance = IntPtr.Zero;
        }

        _registrationListener?.Stop();
        _registrationListener = null;
    }

    private bool TryStartBrowseQuery(string queryName)
    {
        var request = new DNS_SERVICE_BROWSE_REQUEST
        {
            Version = DnsQueryRequestVersion1,
            InterfaceIndex = 0,
            QueryName = queryName,
            pBrowseCallback = _browseCallback,
            pQueryContext = IntPtr.Zero,
        };

        var status = DnsServiceBrowse(ref request, out var cancel);
        if (IsAcceptableDnsStatus(status))
        {
            _browseCancels.Add(cancel);
            return true;
        }

        _lastError = FormatWin32Error($"DnsServiceBrowse ({queryName})", status);
        return false;
    }

    private void OnRegisterResult(uint status, IntPtr context, IntPtr instance)
    {
        if (instance != IntPtr.Zero)
        {
            DnsServiceFreeInstance(instance);
        }

        if (!IsAcceptableDnsStatus(status))
        {
            _lastError = FormatWin32Error("mDNS registration", status);
        }
    }

    private static bool IsAcceptableDnsStatus(uint status) =>
        status == ErrorSuccess || status == DnsRequestPending;

    private void OnBrowseResult(uint status, IntPtr context, IntPtr recordList)
    {
        if (status != ErrorSuccess)
        {
            FreeRecordList(recordList);
            return;
        }

        if (recordList == IntPtr.Zero)
        {
            return;
        }

        try
        {
            for (var current = recordList; current != IntPtr.Zero; current = ReadRecordNext(current))
            {
                var record = Marshal.PtrToStructure<DnsRecord>(current);
                if (record.wType != DnsTypePtr)
                {
                    continue;
                }

                var instanceName = ReadUnicodeString(record.Data.pNameHost);
                if (string.IsNullOrWhiteSpace(instanceName))
                {
                    continue;
                }

                lock (_gate)
                {
                    if (!_pendingResolves.Add(instanceName))
                    {
                        continue;
                    }
                }

                ResolveInstance(instanceName);
            }
        }
        finally
        {
            FreeRecordList(recordList);
        }
    }

    private void ResolveInstance(string instanceName)
    {
        var request = new DNS_SERVICE_RESOLVE_REQUEST
        {
            Version = DnsQueryRequestVersion1,
            InterfaceIndex = 0,
            QueryName = instanceName,
            pResolveCompletionCallback = _resolveCallback,
            pQueryContext = IntPtr.Zero,
        };

        var status = DnsServiceResolve(ref request, out _);
        if (!IsAcceptableDnsStatus(status))
        {
            lock (_gate)
            {
                _pendingResolves.Remove(instanceName);
            }
        }
    }

    private void OnResolveResult(uint status, IntPtr context, IntPtr instancePtr)
    {
        if (status != ErrorSuccess || instancePtr == IntPtr.Zero)
        {
            FreeInstance(instancePtr);
            return;
        }

        try
        {
            var instance = Marshal.PtrToStructure<DNS_SERVICE_INSTANCE>(instancePtr);
            var device = CreateDevice(instance);
            if (device is null)
            {
                return;
            }

            lock (_gate)
            {
                if (!_reportedHosts.Add(device.Host))
                {
                    return;
                }
            }

            StatusChanged?.Invoke($"Found {device.Name} ({device.Host})");
            DeviceFound?.Invoke(device);
        }
        finally
        {
            FreeInstance(instancePtr);
        }
    }

    private static DiscoveredDevice? CreateDevice(in DNS_SERVICE_INSTANCE instance)
    {
        var name = ReadUnicodeString(instance.pszInstanceName);
        var hostName = ReadUnicodeString(instance.pszHostName);
        if (string.IsNullOrWhiteSpace(hostName))
        {
            return null;
        }

        var host = ResolveHostAddress(hostName, instance.ip4Address) ?? hostName;
        if (!IsUsableHost(host))
        {
            return null;
        }

        var txt = ReadTxtRecords(instance);
        txt.TryGetValue("platform", out var platform);
        txt.TryGetValue("vendor", out var vendor);

        var instanceName = name ?? string.Empty;
        var isScreenMirroringInstance =
            instanceName.Contains("screenmirroring", StringComparison.OrdinalIgnoreCase) ||
            instanceName.Contains("screen-mirroring", StringComparison.OrdinalIgnoreCase);

        if (string.Equals(platform, "windows", StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        if (!isScreenMirroringInstance)
        {
            var hasVendor = !string.IsNullOrWhiteSpace(vendor);
            var hasPlatform = !string.IsNullOrWhiteSpace(platform);
            if (hasVendor &&
                !string.Equals(vendor, ScreenMirroringProtocol.VendorId, StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            if (hasPlatform &&
                !string.Equals(platform, ScreenMirroringProtocol.PlatformId, StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            if (!hasVendor && !hasPlatform)
            {
                return null;
            }
        }

        var port = instance.wPort > 0 ? instance.wPort : ScreenMirroringProtocol.ServerPort;
        if (port != ScreenMirroringProtocol.ServerPort)
        {
            port = ScreenMirroringProtocol.ServerPort;
        }

        return new DiscoveredDevice
        {
            Name = string.IsNullOrWhiteSpace(name) ? host : SanitizeDisplayName(name),
            Host = host,
            Port = port,
            Platform = platform ?? ScreenMirroringProtocol.PlatformId,
            Vendor = vendor ?? ScreenMirroringProtocol.VendorId,
            Source = DiscoverySource.Bonjour,
        };
    }

    private static string? ResolveHostAddress(string hostName, IntPtr ip4AddressPtr)
    {
        if (ip4AddressPtr != IntPtr.Zero)
        {
            var bytes = new byte[4];
            Marshal.Copy(ip4AddressPtr, bytes, 0, 4);
            if (bytes.Any(b => b != 0))
            {
                return new IPAddress(bytes).ToString();
            }
        }

        try
        {
            return Dns.GetHostAddresses(hostName, AddressFamily.InterNetwork).FirstOrDefault()?.ToString();
        }
        catch
        {
            return null;
        }
    }

    private static Dictionary<string, string> ReadTxtRecords(in DNS_SERVICE_INSTANCE instance)
    {
        var txt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (instance.dwPropertyCount == 0 || instance.keys == IntPtr.Zero || instance.values == IntPtr.Zero)
        {
            return txt;
        }

        for (uint index = 0; index < instance.dwPropertyCount; index++)
        {
            var keyPtr = Marshal.ReadIntPtr(instance.keys, (int)(index * IntPtr.Size));
            var valuePtr = Marshal.ReadIntPtr(instance.values, (int)(index * IntPtr.Size));
            var key = ReadUnicodeString(keyPtr);
            var value = ReadUnicodeString(valuePtr);
            if (!string.IsNullOrWhiteSpace(key))
            {
                txt[key] = value ?? string.Empty;
            }
        }

        return txt;
    }

    private static string LocalMdnsHostName()
    {
        var computerName = Environment.MachineName;
        var sanitized = SanitizedComputerName();
        return $"{sanitized}.local";
    }

    private static string SanitizedComputerName()
    {
        var raw = Environment.MachineName;
        if (string.IsNullOrWhiteSpace(raw))
        {
            return "ScreenMirroring-PC";
        }

        var chars = raw
            .Select(ch => ch is ' ' or '_' ? '-' : ch)
            .Where(ch => char.IsLetterOrDigit(ch) || ch == '-')
            .ToArray();
        var sanitized = new string(chars);
        if (sanitized.Length == 0)
        {
            sanitized = "ScreenMirroring-PC";
        }

        return sanitized.Length > 63 ? sanitized[..63] : sanitized;
    }

    private static string SanitizeDisplayName(string instanceName)
    {
        var trimmed = instanceName;
        foreach (var suffix in new[]
                 {
                     "._screenmirroring._tcp.local",
                     "._screenmirroring._tcp.local.",
                     "._rfb._tcp.local",
                     "._rfb._tcp.local.",
                 })
        {
            if (trimmed.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                trimmed = trimmed[..^suffix.Length];
                break;
            }
        }

        return trimmed.Replace('-', ' ');
    }

    private static bool IsUsableHost(string host) =>
        IPAddress.TryParse(host, out _) || host.Contains('.', StringComparison.Ordinal);

    private static string FormatWin32Error(string operation, uint status)
    {
        if (status == 0)
        {
            return $"{operation} failed.";
        }

        var message = new Win32Exception((int)status).Message;
        return $"{operation} failed (Win32 {status}): {message}";
    }

    private static IntPtr AllocStringArray(string[] values)
    {
        var arrayPtr = Marshal.AllocHGlobal(IntPtr.Size * values.Length);
        for (var index = 0; index < values.Length; index++)
        {
            Marshal.WriteIntPtr(arrayPtr, index * IntPtr.Size, Marshal.StringToHGlobalUni(values[index]));
        }

        return arrayPtr;
    }

    private static void FreeStringArray(string[] values, IntPtr arrayPtr)
    {
        for (var index = 0; index < values.Length; index++)
        {
            var stringPtr = Marshal.ReadIntPtr(arrayPtr, index * IntPtr.Size);
            if (stringPtr != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(stringPtr);
            }
        }

        Marshal.FreeHGlobal(arrayPtr);
    }

    private static string? ReadUnicodeString(IntPtr value) =>
        value == IntPtr.Zero ? null : Marshal.PtrToStringUni(value);

    private static IntPtr ReadRecordNext(IntPtr record)
    {
        if (record == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        return Marshal.PtrToStructure<DnsRecord>(record).pNext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsRecord
    {
        public IntPtr pNext;
        public IntPtr pName;
        public ushort wType;
        public ushort wDataLength;
        public uint Flags;
        public uint dwReserved;
        public DnsPtrData Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsPtrData
    {
        public IntPtr pNameHost;
    }

    private static void FreeRecordList(IntPtr recordList)
    {
        if (recordList != IntPtr.Zero)
        {
            DnsRecordListFree(recordList, DnsFreeRecordList);
        }
    }

    private static void FreeInstance(IntPtr instancePtr)
    {
        if (instancePtr != IntPtr.Zero)
        {
            DnsServiceFreeInstance(instancePtr);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        StopBrowsing();
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void DNS_SERVICE_BROWSE_CALLBACK(uint status, IntPtr context, IntPtr record);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void DNS_SERVICE_RESOLVE_CALLBACK(uint status, IntPtr context, IntPtr instance);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void DNS_SERVICE_REGISTER_CALLBACK(uint status, IntPtr context, IntPtr instance);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DNS_SERVICE_BROWSE_REQUEST
    {
        public uint Version;
        public uint InterfaceIndex;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string QueryName;
        public DNS_SERVICE_BROWSE_CALLBACK? pBrowseCallback;
        public IntPtr pQueryContext;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DNS_SERVICE_RESOLVE_REQUEST
    {
        public uint Version;
        public uint InterfaceIndex;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string QueryName;
        public DNS_SERVICE_RESOLVE_CALLBACK? pResolveCompletionCallback;
        public IntPtr pQueryContext;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DNS_SERVICE_REGISTER_REQUEST
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr pServiceInstance;
        public DNS_SERVICE_REGISTER_CALLBACK? pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        [MarshalAs(UnmanagedType.Bool)]
        public bool unicastEnabled;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DNS_SERVICE_CANCEL
    {
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DNS_SERVICE_INSTANCE
    {
        public IntPtr pszInstanceName;
        public IntPtr pszHostName;
        public IntPtr ip4Address;
        public IntPtr ip6Address;
        public ushort wPort;
        public ushort wPriority;
        public ushort wWeight;
        public uint dwPropertyCount;
        public IntPtr keys;
        public IntPtr values;
        public uint dwInterfaceIndex;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr DnsServiceConstructInstance(
        string pServiceName,
        string pHostName,
        IntPtr pIp4,
        IntPtr pIp6,
        ushort wPort,
        ushort wPriority,
        ushort wWeight,
        uint dwPropertyCount,
        IntPtr keys,
        IntPtr values);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint DnsServiceRegister(ref DNS_SERVICE_REGISTER_REQUEST request, out DNS_SERVICE_CANCEL cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceRegisterCancel", SetLastError = true)]
    private static extern uint DnsServiceRegisterCancel(ref DNS_SERVICE_CANCEL cancel);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint DnsServiceBrowse(ref DNS_SERVICE_BROWSE_REQUEST request, out DNS_SERVICE_CANCEL cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceBrowseCancel", SetLastError = true)]
    private static extern uint DnsServiceBrowseCancel(ref DNS_SERVICE_CANCEL cancel);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint DnsServiceResolve(ref DNS_SERVICE_RESOLVE_REQUEST request, out DNS_SERVICE_CANCEL cancel);

    [DllImport("dnsapi.dll", EntryPoint = "DnsServiceFreeInstance")]
    private static extern void DnsServiceFreeInstance(IntPtr instance);

    [DllImport("dnsapi.dll", EntryPoint = "DnsRecordListFree")]
    private static extern void DnsRecordListFree(IntPtr recordList, int freeType);
}
