using System.Security.Cryptography;
using System.Text;

namespace ScreenMirroringViewer.Services;

/// <summary>
/// VNC authentication (RFB security type 2) using DES-ECB with bit-reversed key bytes.
/// Matches <c>smVNCEncryptChallenge</c> in the Screen Mirroring tweak.
/// </summary>
internal static class VncAuth
{
    public static byte[] EncryptChallenge(byte[] challenge, string password)
    {
        if (challenge.Length != 16)
        {
            throw new ArgumentException("Challenge must be 16 bytes.", nameof(challenge));
        }

        var key = PrepareDesKey(password);
        using var des = DES.Create();
        des.Mode = CipherMode.ECB;
        des.Padding = PaddingMode.None;
        des.Key = key;

        using var encryptor = des.CreateEncryptor();
        var response = new byte[16];
        encryptor.TransformBlock(challenge, 0, 8, response, 0);
        encryptor.TransformBlock(challenge, 8, 8, response, 8);
        return response;
    }

    private static byte[] PrepareDesKey(string password)
    {
        var key = new byte[8];
        for (var index = 0; index < 8; index++)
        {
            var value = index < password.Length ? (byte)password[index] : (byte)0;
            key[index] = ReverseBits(value);
        }

        return key;
    }

    private static byte ReverseBits(byte value)
    {
        byte reversed = 0;
        for (var bit = 0; bit < 8; bit++)
        {
            if ((value & (1 << bit)) != 0)
            {
                reversed |= (byte)(1 << (7 - bit));
            }
        }

        return reversed;
    }
}
