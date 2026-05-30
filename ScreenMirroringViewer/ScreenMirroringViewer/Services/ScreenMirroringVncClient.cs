using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ScreenMirroringViewer.Services;

public sealed class ScreenMirroringVncClient : IAsyncDisposable
{
    private const int EncodingRaw = 0;
    private const int EncodingLastRect = unchecked((int)0xFFFFFF20);

    private readonly object _bitmapLock = new();
    private NetworkStream? _stream;
    private TcpClient? _client;
    private CancellationTokenSource? _sessionCts;
    private WriteableBitmap? _frameBuffer;
    private int _frameWidth;
    private int _frameHeight;
    private bool _connected;
    private bool _sessionEstablished;

    public event Action<string>? StatusChanged;
    public event Action<Exception>? ConnectionFailed;
    public event Action? Disconnected;
    public event Action<int, int>? FrameDimensionsChanged;

    public WriteableBitmap? FrameBuffer
    {
        get
        {
            lock (_bitmapLock)
            {
                return _frameBuffer;
            }
        }
    }

    public int FrameWidth => _frameWidth;
    public int FrameHeight => _frameHeight;
    public bool IsConnected => _connected;

    public async Task ConnectAsync(string host, int port, string password, CancellationToken cancellationToken = default)
    {
        await DisconnectAsync();

        _sessionCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = _sessionCts.Token;

        StatusChanged?.Invoke($"Connecting to {host}:{port}…");

        _sessionEstablished = false;
        _client = new TcpClient(AddressFamily.InterNetwork)
        {
            NoDelay = true,
        };
        await ConnectPreferIpv4Async(host, port, token);
        _stream = _client.GetStream();

        await PerformHandshakeAsync(password, token);
        _connected = true;
        _sessionEstablished = true;
        StatusChanged?.Invoke($"Connected ({_frameWidth}×{_frameHeight}).");

        _ = Task.Run(() => ReceiveLoopAsync(token), token);
    }

    public async Task DisconnectAsync()
    {
        _connected = false;
        _sessionEstablished = false;
        _sessionCts?.Cancel();

        if (_stream is not null)
        {
            try
            {
                await _stream.DisposeAsync();
            }
            catch
            {
                // ignored
            }
        }

        _client?.Close();
        _client?.Dispose();
        _stream = null;
        _client = null;

        _sessionCts?.Dispose();
        _sessionCts = null;
    }

    public void SendPointerEvent(byte buttonMask, int x, int y)
    {
        if (_stream is null || !_connected)
        {
            return;
        }

        x = Math.Clamp(x, 0, Math.Max(0, _frameWidth - 1));
        y = Math.Clamp(y, 0, Math.Max(0, _frameHeight - 1));

        Span<byte> payload = stackalloc byte[6];
        payload[0] = 5;
        payload[1] = buttonMask;
        BinaryPrimitives.WriteUInt16BigEndian(payload[2..], (ushort)x);
        BinaryPrimitives.WriteUInt16BigEndian(payload[4..], (ushort)y);
        Write(payload);
    }

    public void SendPointerMove(int x, int y) => SendPointerEvent(0, x, y);

    public void SendPointerButton(byte buttonMask, bool pressed, int x, int y) =>
        SendPointerEvent(pressed ? buttonMask : (byte)0, x, y);

    public void SendKeyEvent(bool pressed, uint keysym)
    {
        if (_stream is null || !_connected || keysym == 0)
        {
            return;
        }

        Span<byte> payload = stackalloc byte[8];
        payload[0] = 4;
        payload[1] = (byte)(pressed ? 1 : 0);
        BinaryPrimitives.WriteUInt32BigEndian(payload[4..], keysym);
        Write(payload);
    }

    private async Task PerformHandshakeAsync(string password, CancellationToken cancellationToken)
    {
        if (_stream is null)
        {
            throw new InvalidOperationException("Network stream is not available.");
        }

        var serverVersion = await ReadExactAsync(12, cancellationToken);
        if (Encoding.ASCII.GetString(serverVersion).Trim() is not { Length: > 0 } versionText ||
            !versionText.StartsWith("RFB ", StringComparison.Ordinal))
        {
            throw new IOException("Unexpected VNC server version banner.");
        }

        await WriteAsync(Encoding.ASCII.GetBytes("RFB 003.008\n"), cancellationToken);

        var countBytes = await ReadExactAsync(1, cancellationToken);
        var typeCount = countBytes[0];
        var offeredTypes = await ReadExactAsync(typeCount, cancellationToken);
        if (!offeredTypes.Contains((byte)2))
        {
            throw new IOException("VNC password authentication is not supported by the server.");
        }

        await WriteAsync(new byte[] { 2 }, cancellationToken);

        var challenge = await ReadExactAsync(16, cancellationToken);
        var response = VncAuth.EncryptChallenge(challenge, password);
        await WriteAsync(response, cancellationToken);

        var authResultBytes = await ReadExactAsync(4, cancellationToken);
        var authResult = BinaryPrimitives.ReadUInt32BigEndian(authResultBytes);
        if (authResult != 0)
        {
            var reasonLengthBytes = await ReadExactAsync(4, cancellationToken);
            var reasonLength = (int)BinaryPrimitives.ReadUInt32BigEndian(reasonLengthBytes);
            var reasonBytes = reasonLength > 0 ? await ReadExactAsync(reasonLength, cancellationToken) : Array.Empty<byte>();
            var reason = reasonBytes.Length > 0 ? Encoding.UTF8.GetString(reasonBytes) : "Authentication failed.";
            throw new IOException(reason);
        }

        // RFB 3.8+: client sends ClientInit (shared-flag), then server sends ServerInit.
        await WriteAsync(new byte[] { 1 }, cancellationToken);

        var widthBytes = await ReadExactAsync(2, cancellationToken);
        var heightBytes = await ReadExactAsync(2, cancellationToken);
        _frameWidth = BinaryPrimitives.ReadUInt16BigEndian(widthBytes);
        _frameHeight = BinaryPrimitives.ReadUInt16BigEndian(heightBytes);

        _ = await ReadExactAsync(16, cancellationToken);

        var nameLengthBytes = await ReadExactAsync(4, cancellationToken);
        var nameLength = BinaryPrimitives.ReadUInt32BigEndian(nameLengthBytes);
        if (nameLength > 0)
        {
            _ = await ReadExactAsync((int)nameLength, cancellationToken);
        }

        AllocateFrameBuffer(_frameWidth, _frameHeight);
        FrameDimensionsChanged?.Invoke(_frameWidth, _frameHeight);

        await SendSetPixelFormatAsync(cancellationToken);
        await SendSetEncodingsAsync(cancellationToken);
        await SendFramebufferUpdateRequestAsync(false, 0, 0, (ushort)_frameWidth, (ushort)_frameHeight, cancellationToken);
    }

    private void AllocateFrameBuffer(int width, int height)
    {
        Application.Current.Dispatcher.Invoke(() =>
        {
            lock (_bitmapLock)
            {
                _frameBuffer = new WriteableBitmap(width, height, 96, 96, PixelFormats.Bgra32, null);
            }
        });
    }

    private async Task SendSetPixelFormatAsync(CancellationToken cancellationToken)
    {
        var message = new byte[]
        {
            0, 0, 0, 0,
            32, 24, 0, 1,
            0, 255, 0, 255, 0, 255,
            16, 8, 0,
            0, 0, 0,
        };
        await WriteAsync(message, cancellationToken);
    }

    private async Task SendSetEncodingsAsync(CancellationToken cancellationToken)
    {
        var message = new byte[12];
        message[0] = 2;
        message[1] = 0;
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(2, 2), 2);
        BinaryPrimitives.WriteInt32BigEndian(message.AsSpan(4, 4), EncodingRaw);
        BinaryPrimitives.WriteInt32BigEndian(message.AsSpan(8, 4), EncodingLastRect);
        await WriteAsync(message, cancellationToken);
    }

    private async Task SendFramebufferUpdateRequestAsync(
        bool incremental,
        ushort x,
        ushort y,
        ushort width,
        ushort height,
        CancellationToken cancellationToken)
    {
        var message = new byte[10];
        message[0] = 3;
        message[1] = (byte)(incremental ? 1 : 0);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(2, 2), x);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(4, 2), y);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(6, 2), width);
        BinaryPrimitives.WriteUInt16BigEndian(message.AsSpan(8, 2), height);
        await WriteAsync(message, cancellationToken);
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested && _stream is not null)
            {
                var typeBytes = await ReadExactAsync(1, cancellationToken);
                var messageType = typeBytes[0];
                if (messageType != 0)
                {
                    if (!await SkipServerMessageAsync(messageType, cancellationToken))
                    {
                        break;
                    }

                    continue;
                }

                _ = await ReadExactAsync(1, cancellationToken);
                var countBytes = await ReadExactAsync(2, cancellationToken);
                var rectangleCount = BinaryPrimitives.ReadUInt16BigEndian(countBytes);

                for (var index = 0; index < rectangleCount; index++)
                {
                    var header = await ReadExactAsync(12, cancellationToken);
                    var rectX = BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(0, 2));
                    var rectY = BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(2, 2));
                    var rectWidth = BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(4, 2));
                    var rectHeight = BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(6, 2));
                    var encoding = BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(8, 4));

                    if (encoding == EncodingLastRect)
                    {
                        continue;
                    }

                    if (encoding != EncodingRaw)
                    {
                        throw new IOException($"Unsupported VNC encoding: {encoding}.");
                    }

                    var pixelCount = rectWidth * rectHeight;
                    var byteCount = pixelCount * 4;
                    var pixels = await ReadExactAsync(byteCount, cancellationToken);
                    QueueRawRect(rectX, rectY, rectWidth, rectHeight, pixels);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // expected during shutdown
        }
        catch (Exception ex)
        {
            ConnectionFailed?.Invoke(ex);
        }
        finally
        {
            var hadSession = _sessionEstablished;
            _connected = false;
            _sessionEstablished = false;
            if (hadSession)
            {
                Disconnected?.Invoke();
            }
        }
    }

    private async Task ConnectPreferIpv4Async(string host, int port, CancellationToken cancellationToken)
    {
        if (IPAddress.TryParse(host, out var parsed) && parsed.AddressFamily == AddressFamily.InterNetwork)
        {
            await ConnectToAddressAsync(parsed, port, cancellationToken);
            return;
        }

        var addresses = await Dns.GetHostAddressesAsync(host, cancellationToken);
        var ipv4 = addresses.FirstOrDefault(address => address.AddressFamily == AddressFamily.InterNetwork);
        if (ipv4 is not null)
        {
            await ConnectToAddressAsync(ipv4, port, cancellationToken);
            return;
        }

        if (addresses.Length == 0)
        {
            throw new IOException($"Could not resolve '{host}'.");
        }

        await ConnectToAddressAsync(addresses[0], port, cancellationToken);
    }

    private async Task ConnectToAddressAsync(IPAddress address, int port, CancellationToken cancellationToken)
    {
        if (_client is null)
        {
            throw new InvalidOperationException("TCP client is not available.");
        }

        await _client.ConnectAsync(new IPEndPoint(address, port), cancellationToken);
    }

    private void QueueRawRect(int x, int y, int width, int height, byte[] pixels)
    {
        var rowBytes = width * 4;
        var copy = GC.AllocateUninitializedArray<byte>(rowBytes * height);
        Buffer.BlockCopy(pixels, 0, copy, 0, copy.Length);

        Application.Current.Dispatcher.BeginInvoke(DispatcherPriority.Render, () =>
        {
            ApplyRawRectCopy(x, y, width, height, copy, rowBytes);
        });
    }

    private void ApplyRawRectCopy(int x, int y, int width, int height, byte[] pixels, int sourceStride)
    {
        lock (_bitmapLock)
        {
            if (_frameBuffer is null)
            {
                return;
            }

            if (_frameBuffer.PixelWidth != _frameWidth || _frameBuffer.PixelHeight != _frameHeight)
            {
                AllocateFrameBuffer(_frameWidth, _frameHeight);
            }

            _frameBuffer!.Lock();
            try
            {
                var stride = _frameBuffer.BackBufferStride;
                var destination = _frameBuffer.BackBuffer;

                for (var row = 0; row < height; row++)
                {
                    var destinationRow = destination + ((y + row) * stride) + (x * 4);
                    Marshal.Copy(pixels, row * sourceStride, (IntPtr)destinationRow, sourceStride);
                }

                _frameBuffer.AddDirtyRect(new Int32Rect(x, y, width, height));
            }
            finally
            {
                _frameBuffer.Unlock();
            }
        }
    }

    private async Task<bool> SkipServerMessageAsync(byte messageType, CancellationToken cancellationToken)
    {
        switch (messageType)
        {
            case 1:
                _ = await ReadExactAsync(3, cancellationToken);
                return true;
            case 2:
                _ = await ReadExactAsync(3, cancellationToken);
                var lengthBytes = await ReadExactAsync(4, cancellationToken);
                var length = BinaryPrimitives.ReadUInt32BigEndian(lengthBytes);
                if (length > 0)
                {
                    _ = await ReadExactAsync((int)length, cancellationToken);
                }

                return true;
            default:
                return false;
        }
    }

    private async Task<byte[]> ReadExactAsync(int length, CancellationToken cancellationToken)
    {
        if (_stream is null)
        {
            throw new IOException("Connection closed.");
        }

        var buffer = new byte[length];
        var offset = 0;
        while (offset < length)
        {
            var read = await _stream.ReadAsync(buffer.AsMemory(offset, length - offset), cancellationToken);
            if (read == 0)
            {
                throw new IOException("Connection closed by server.");
            }

            offset += read;
        }

        return buffer;
    }

    private async Task WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken)
    {
        if (_stream is null)
        {
            throw new IOException("Connection closed.");
        }

        await _stream.WriteAsync(buffer, cancellationToken);
    }

    private void Write(ReadOnlySpan<byte> buffer)
    {
        if (_stream is null)
        {
            return;
        }

        _stream.Write(buffer);
    }

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync();
    }
}
