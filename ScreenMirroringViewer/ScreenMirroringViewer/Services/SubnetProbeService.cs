using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Numerics;
using System.Text;
using ScreenMirroringViewer.Models;

namespace ScreenMirroringViewer.Services;

internal static class SubnetProbeService
{
    public static async Task<IReadOnlyList<DiscoveredDevice>> FindDevicesAsync(CancellationToken cancellationToken)
    {
        var found = new List<DiscoveredDevice>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var targets = EnumerateProbeTargets().ToList();

        await Parallel.ForEachAsync(
            targets,
            new ParallelOptions
            {
                MaxDegreeOfParallelism = 64,
                CancellationToken = cancellationToken,
            },
            async (host, token) =>
            {
                if (!await LooksLikeScreenMirroringServerAsync(host, ScreenMirroringProtocol.ServerPort, token))
                {
                    return;
                }

                lock (seen)
                {
                    if (!seen.Add(host))
                    {
                        return;
                    }

                    found.Add(new DiscoveredDevice
                    {
                        Name = host,
                        Host = host,
                        Port = ScreenMirroringProtocol.ServerPort,
                        Platform = ScreenMirroringProtocol.PlatformId,
                        Vendor = ScreenMirroringProtocol.VendorId,
                        Source = DiscoverySource.SubnetProbe,
                    });
                }
            });

        return found;
    }

    private static IEnumerable<string> EnumerateProbeTargets()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up)
            {
                continue;
            }

            if (network.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
            {
                continue;
            }

            IPInterfaceProperties properties;
            try
            {
                properties = network.GetIPProperties();
            }
            catch (NetworkInformationException)
            {
                continue;
            }

            foreach (var address in properties.UnicastAddresses)
            {
                if (address.Address.AddressFamily != AddressFamily.InterNetwork || address.IPv4Mask is null)
                {
                    continue;
                }

                var localBytes = address.Address.GetAddressBytes();
                var maskBytes = address.IPv4Mask.GetAddressBytes();
                var networkBytes = new byte[4];
                for (var index = 0; index < 4; index++)
                {
                    networkBytes[index] = (byte)(localBytes[index] & maskBytes[index]);
                }

                var prefixLength = CountMaskBits(maskBytes);
                var hostCount = Math.Min(1 << Math.Max(0, 32 - prefixLength), 512);
                for (var offset = 1; offset < hostCount - 1; offset++)
                {
                    var candidate = ApplyOffset(networkBytes, offset);
                    if (candidate.SequenceEqual(localBytes))
                    {
                        continue;
                    }

                    var text = new IPAddress(candidate).ToString();
                    if (seen.Add(text))
                    {
                        yield return text;
                    }
                }
            }
        }
    }

    private static int CountMaskBits(byte[] maskBytes)
    {
        var bits = 0;
        foreach (var value in maskBytes)
        {
            bits += BitOperations.PopCount(value);
        }

        return bits;
    }

    private static byte[] ApplyOffset(byte[] networkBytes, int offset)
    {
        var value =
            ((uint)networkBytes[0] << 24) |
            ((uint)networkBytes[1] << 16) |
            ((uint)networkBytes[2] << 8) |
            networkBytes[3];
        value += (uint)offset;
        return new[]
        {
            (byte)((value >> 24) & 0xFF),
            (byte)((value >> 16) & 0xFF),
            (byte)((value >> 8) & 0xFF),
            (byte)(value & 0xFF),
        };
    }

    private static async Task<bool> LooksLikeScreenMirroringServerAsync(string host, int port, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromMilliseconds(400));

        try
        {
            using var client = new TcpClient { NoDelay = true };
            await client.ConnectAsync(host, port, timeout.Token);
            using var stream = client.GetStream();
            var banner = new byte[12];
            if (!await ReadExactAsync(stream, banner, timeout.Token))
            {
                return false;
            }

            return Encoding.ASCII.GetString(banner).StartsWith("RFB ", StringComparison.Ordinal);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        catch
        {
            return false;
        }
    }

    private static async Task<bool> ReadExactAsync(NetworkStream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset, buffer.Length - offset), cancellationToken);
            if (read == 0)
            {
                return false;
            }

            offset += read;
        }

        return true;
    }
}
