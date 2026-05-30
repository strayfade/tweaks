using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace ScreenMirroringViewer.Services;

internal static class NetworkInitializer
{
    private const int WsaDataSize = 408;
    private static readonly object Gate = new();
    private static bool _initialized;

    public static bool TryEnsureInitialized()
    {
        lock (Gate)
        {
            if (_initialized)
            {
                return true;
            }

            try
            {
                using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                socket.Bind(new IPEndPoint(IPAddress.Any, 0));
            }
            catch
            {
                return false;
            }

            var wsaData = new byte[WsaDataSize];
            if (WSAStartup(0x0202, wsaData) != 0)
            {
                return false;
            }

            _initialized = true;
            return true;
        }
    }

    [DllImport("ws2_32.dll", SetLastError = true)]
    private static extern int WSAStartup(ushort versionRequested, byte[] wsaData);
}
